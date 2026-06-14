// Self-test for the Alveo farm RTL (no XRT, no Vitis): drive namegen_farm, act as the
// AXI write master by popping the record FIFO, decode each name record and check it.
//
// In GREEDY mode (sample_mode=0) the model is seed-independent and every name is "alaya"
// (tokens [1,12,1,25,1] -> name bytes [0,11,0,24,0]). So every record must decode to
// "alaya" with len=5. This exercises the entire reused core + the new farm/arbiter/FIFO.
//
// This bench is deliberately STRICT -- it is the gate the rest of the swarm relies on:
//   * backpressure / FIFO-full: the record drain (acting as the writer) stalls hard so the
//     FIFO fills, asserts `full`, and back-pressures the arbiter/generators. We require the
//     `full` flag to actually fire during the run (proving the path is exercised) and verify
//     ZERO records are lost or duplicated under that pressure.
//   * determinism: the same (base_seed, sample_mode) must yield identical record CONTENT
//     per generator regardless of buffer/arrival order. Each generator's seed is advanced by
//     a fixed Weyl step from a fixed start, so its k-th emitted record (seed, name, len) is
//     run-independent. We run the DUT twice -- once with a stalling drain, once with a fast
//     drain (different arrival ORDER) -- and require the per-generator record SEQUENCES to be
//     byte-identical.
//   * distribution sanity: sampled names have len in [1,16], all chars 0..25, reasonable
//     variety, and per-position character spread; greedy stays exactly 'alaya'.
//   * no cross-generator seed collisions: every (gen,seed) used in a run is unique, and no
//     two distinct generators ever share a seed.
//
//   iverilog -g2012 -o /tmp/tb_farm -s tb_farm alveo/sim/tb_farm.v \
//            alveo/rtl/record_fifo.v alveo/rtl/namegen_farm.v alveo/gen_src/*.v
//   vvp /tmp/tb_farm
//   vvp /tmp/tb_farm +sample
`timescale 1ns/1ps
module tb_farm;
    // Small FIFO + slow drain so the FIFO actually saturates and `full` propagates back to
    // the arbiter/generators. NUM_GEN > FIFO depth keeps it pinned full for the whole run.
    localparam integer NUM_GEN = 8;
    localparam integer FIFO_AW = 2;          // DEPTH = 4 < NUM_GEN, so the FIFO fills once
                                             // >4 generators complete while the drain stalls
    localparam integer WANT    = 96;         // records to collect before declaring PASS
    localparam integer MAXREC  = 64;         // per-generator record-sequence capacity

    reg clk = 0, resetn = 0, srst = 0, run_en = 0, sample_mode = 0;
    reg signed [15:0] inv_temp = 16'sd2926;   // 1/0.7 in Q5.11 (used when sampling)
    reg [31:0] base_seed = 32'hC0FFEE11;

    // run modes:  default greedy (expect 'alaya');  +sample -> sampled, expect variety
    integer slow_drain;                       // 0 = pop every cycle, >0 = stall-heavy drain
    initial begin
        if ($test$plusargs("sample")) sample_mode = 1;
        void'($value$plusargs("seed=%h", base_seed));
    end

    wire [175:0] rec_dout;
    wire         rec_empty;
    reg          rec_rd_en = 0;

    namegen_farm #(.NUM_GEN(NUM_GEN), .MAX_LEN(16), .FIFO_AW(FIFO_AW), .PAY_W(176)) dut (
        .clk(clk), .resetn(resetn), .srst(srst), .run_en(run_en),
        .base_seed(base_seed), .inv_temp(inv_temp), .sample_mode(sample_mode),
        .rec_dout(rec_dout), .rec_empty(rec_empty), .rec_rd_en(rec_rd_en));

    always #5 clk = ~clk;   // 100 MHz

    integer got = 0, fails = 0, n_diff = 0, i;
    integer full_seen = 0;                    // # cycles the FIFO reported `full` (stress proof)
    reg [7:0]   r_len, r_gid;
    reg [31:0]  r_seed;
    reg [127:0] r_name, first_name;
    reg [8*16-1:0] str;
    reg [7:0]   ch;

    // ---- per-generator record sequences (dense, portable: no assoc arrays) ----
    // For generator g, its k-th emitted record's content. The per-generator seed walk is
    // deterministic, so these sequences must be identical across runs (determinism), and
    // every seed within a gen's sequence must be unique (no duplication / no record loss
    // that would cause a re-emit).
    reg [31:0]  gseed [0:NUM_GEN-1][0:MAXREC-1];
    reg [127:0] gname [0:NUM_GEN-1][0:MAXREC-1];
    reg [7:0]   glen  [0:NUM_GEN-1][0:MAXREC-1];
    integer     gcnt  [0:NUM_GEN-1];          // how many records gen g has produced this run
    integer     dups = 0;
    integer     g, kk, h, m;

    // expected greedy name
    reg [7:0] exp [0:4];
    initial begin exp[0]=0; exp[1]=11; exp[2]=0; exp[3]=24; exp[4]=0; end // a l a y a

    // ---- per-position character histogram (distribution sanity, sampled mode) ----
    integer pos_distinct [0:15];              // # distinct chars seen at each position
    reg     pos_seen [0:15][0:25];

    task clear_run_state;
        integer a, b;
        begin
            for (a = 0; a < NUM_GEN; a = a + 1) gcnt[a] = 0;
            for (a = 0; a < 16; a = a + 1) begin
                pos_distinct[a] = 0;
                for (b = 0; b < 26; b = b + 1) pos_seen[a][b] = 1'b0;
            end
        end
    endtask

    // ---- backpressure drain: stall the pop so the FIFO fills & back-pressures ----
    // slow_drain==0 : pop whenever data is available (fast path).
    // slow_drain >0 : BURST-STALL. Pop freely for a short window, then FREEZE the drain for a
    //                 long window. During the freeze, completed names keep landing until the
    //                 (depth < NUM_GEN) FIFO is full -> `full` asserts -> the arbiter stops
    //                 granting -> generators hold their records in ST_PEND. This deterministically
    //                 exercises the back-pressure path regardless of per-mode generation timing.
    //                 An LFSR adds per-pop jitter inside the drain window so arrival order also
    //                 differs from the fast run (strengthens the determinism check).
    localparam integer STALL_HI = 1400;       // freeze length (cycles) -- long enough that
                                              // >DEPTH generators complete & overflow the FIFO
    localparam integer STALL_LO = 48;         // drain-window length (cycles)
    reg [15:0] lfsr  = 16'hACE1;
    integer    phase = 0;                     // counts within the current drain/freeze window
    reg        draining = 1'b1;
    always @(posedge clk) begin
        lfsr <= {lfsr[14:0], lfsr[15]^lfsr[13]^lfsr[12]^lfsr[10]};
        if (slow_drain == 0) begin draining <= 1'b1; phase <= 0; end
        else begin
            phase <= phase + 1;
            if (draining && phase >= STALL_LO) begin draining <= 1'b0; phase <= 0; end
            else if (!draining && phase >= STALL_HI) begin draining <= 1'b1; phase <= 0; end
        end
    end
    wire drain_go = (slow_drain == 0) ? 1'b1 : (draining && lfsr[2:0] != 3'd0);

    // observe FIFO-full directly (hierarchical ref into the DUT's FIFO instance)
    always @(posedge clk) if (run_en && dut.rec_full) full_seen = full_seen + 1;

    // pop one record when available AND the drain says go (acts as a back-pressuring writer)
    always @(posedge clk) begin
        rec_rd_en <= 0;
        if (run_en && !rec_empty && !rec_rd_en && drain_go) begin
            rec_rd_en <= 1'b1;
            r_len  = rec_dout[7:0];
            r_gid  = rec_dout[15:8];
            r_seed = rec_dout[47:16];
            r_name = rec_dout[175:48];
            // decode + check
            str = 0;
            for (i = 0; i < 16; i = i + 1) begin
                ch = r_name[i*8 +: 8];
                if (i < r_len) str[(15-i)*8 +: 8] = "a" + ch;
            end
            // always: valid length and valid chars
            if (r_len < 8'd1 || r_len > 8'd16) fails = fails + 1;
            for (i = 0; i < 16; i = i + 1)
                if (i < r_len && r_name[i*8 +: 8] > 8'd25) fails = fails + 1;
            if (r_gid >= NUM_GEN) fails = fails + 1;
            if (!sample_mode) begin
                // greedy is seed-independent: every name must be 'alaya'
                if (r_len !== 8'd5) fails = fails + 1;
                for (i = 0; i < 5; i = i + 1)
                    if (r_name[i*8 +: 8] !== exp[i]) fails = fails + 1;
            end

            // record into this generator's sequence; check no seed reused within the gen
            if (r_gid < NUM_GEN) begin
                for (kk = 0; kk < gcnt[r_gid]; kk = kk + 1)
                    if (gseed[r_gid][kk] === r_seed) dups = dups + 1; // re-emitted seed = lost+redone
                if (gcnt[r_gid] < MAXREC) begin
                    gseed[r_gid][gcnt[r_gid]] = r_seed;
                    gname[r_gid][gcnt[r_gid]] = r_name;
                    glen [r_gid][gcnt[r_gid]] = r_len;
                    gcnt [r_gid] = gcnt[r_gid] + 1;
                end
            end

            // per-position char histogram (for distribution sanity in sampled mode)
            for (i = 0; i < 16; i = i + 1) begin
                if (i < r_len) begin
                    ch = r_name[i*8 +: 8];
                    if (ch <= 8'd25 && !pos_seen[i][ch]) begin
                        pos_seen[i][ch] = 1'b1;
                        pos_distinct[i] = pos_distinct[i] + 1;
                    end
                end
            end

            if (got == 0) first_name = r_name;
            else if (r_name !== first_name) n_diff = n_diff + 1;
            if (got < 8)
                $display("  rec[%0d] gid=%0d len=%0d seed=%08x name=%s",
                         got, r_gid, r_len, r_seed, str);
            got = got + 1;
        end
    end

    // run the DUT once with a given drain speed, collecting WANT records
    task run_once(input integer slow);
        begin
            got = 0; fails = 0; n_diff = 0; full_seen = 0; dups = 0;
            clear_run_state();
            slow_drain = slow;
            resetn = 0; srst = 0; run_en = 0; rec_rd_en = 0;
            repeat (8) @(posedge clk);
            resetn = 1;
            @(posedge clk);
            srst = 1;  @(posedge clk);          // flush + re-seed (1 cycle, like the top FSM)
            srst = 0;  run_en = 1;
            fork
                begin : watchdog
                    repeat (8_000_000) @(posedge clk);
                    $display("TIMEOUT: only %0d/%0d records (slow=%0d)", got, WANT, slow);
                    $display("FARM FAIL");
                    $finish;
                end
                begin : collect
                    wait (got >= WANT);
                    disable watchdog;
                end
            join
            run_en = 0;
            repeat (4) @(posedge clk);
        end
    endtask

    // snapshot of RUN A's per-generator sequences, to diff against RUN B
    reg [31:0]  rseed [0:NUM_GEN-1][0:MAXREC-1];
    reg [127:0] rname [0:NUM_GEN-1][0:MAXREC-1];
    reg [7:0]   rlen  [0:NUM_GEN-1][0:MAXREC-1];
    integer     rcnt  [0:NUM_GEN-1];
    integer     mism, common, ncmp;

    initial begin
        // ---- RUN A: stalling drain -> exercise FIFO-full + backpressure ----
        run_once(16);                            // ~1 pop / 16 cycles
        if (fails != 0) begin
            $display("FARM FAIL: %0d field mismatches over %0d records (backpressure run)", fails, got);
            $finish;
        end
        if (dups != 0) begin
            $display("FARM FAIL: %0d re-emitted (gen,seed) records under backpressure -- record loss/dup", dups);
            $finish;
        end
        if (full_seen == 0) begin
            // the whole point of this run is to prove the FIFO actually back-pressures.
            $display("FARM FAIL: FIFO never reported `full` under the slow drain -- backpressure path NOT exercised");
            $finish;
        end
        // cross-generator seed-collision check (no two gens share a seed)
        for (g = 0; g < NUM_GEN; g = g + 1)
            for (kk = 0; kk < gcnt[g]; kk = kk + 1)
                for (h = g + 1; h < NUM_GEN; h = h + 1)
                    for (m = 0; m < gcnt[h]; m = m + 1)
                        if (gseed[g][kk] === gseed[h][m]) fails = fails + 1;
        if (fails != 0) begin
            $display("FARM FAIL: %0d cross-generator seed collisions -- seed diversification broken", fails);
            $finish;
        end
        $display("backpressure: %0d records, FIFO full for %0d cycles, 0 lost / 0 dup / 0 seed-collision",
                 got, full_seen);

        // snapshot RUN A
        for (g = 0; g < NUM_GEN; g = g + 1) begin
            rcnt[g] = gcnt[g];
            for (kk = 0; kk < gcnt[g]; kk = kk + 1) begin
                rseed[g][kk] = gseed[g][kk];
                rname[g][kk] = gname[g][kk];
                rlen [g][kk] = glen [g][kk];
            end
        end

        // ---- RUN B: fast drain (no stalls) -> different arrival ORDER, same CONTENT ----
        run_once(0);
        if (fails != 0) begin
            $display("FARM FAIL: %0d field mismatches over %0d records (fast run)", fails, got);
            $finish;
        end
        if (dups != 0) begin
            $display("FARM FAIL: %0d re-emitted (gen,seed) records (fast run)", dups);
            $finish;
        end

        // ---- DETERMINISM: per-generator sequences identical across the two runs ----
        // Compare the common prefix (min count) of each generator's sequence. The per-gen
        // seed walk is run-independent, so element k must match byte-for-byte regardless of
        // how the global arrival order was scrambled by the drain.
        mism = 0; common = 0;
        for (g = 0; g < NUM_GEN; g = g + 1) begin
            ncmp = (rcnt[g] < gcnt[g]) ? rcnt[g] : gcnt[g];
            for (kk = 0; kk < ncmp; kk = kk + 1) begin
                common = common + 1;
                if (rseed[g][kk] !== gseed[g][kk] ||
                    rname[g][kk] !== gname[g][kk] ||
                    rlen [g][kk] !== glen [g][kk]) mism = mism + 1;
            end
        end
        if (common < 8) begin
            $display("FARM FAIL: determinism check compared only %0d records -- too few to trust", common);
            $finish;
        end
        if (mism != 0) begin
            $display("FARM FAIL: %0d/%0d per-generator records differ between runs -- NON-DETERMINISTIC",
                     mism, common);
            $finish;
        end
        $display("determinism: %0d per-generator records identical across slow/fast drain", common);

        // ---- DISTRIBUTION sanity (uses RUN B's histogram) ----
        if (sample_mode) begin
            if (n_diff == 0) begin
                $display("FARM FAIL: sampled mode produced no variety over %0d records", got);
                $finish;
            end
            // position 0 must show several distinct starting letters across the corpus
            if (pos_distinct[0] < 3) begin
                $display("FARM FAIL: only %0d distinct first-letters over %0d names -- suspiciously low variety",
                         pos_distinct[0], got);
                $finish;
            end
            $display("distribution: pos0 distinct first-letters=%0d, names differing from first=%0d",
                     pos_distinct[0], n_diff);
            $display("FARM PASS: %0d valid sampled names, backpressure+determinism+distribution OK", got);
        end else begin
            // greedy must ALWAYS be exactly 'alaya' (per-record checks above enforced it);
            // every position therefore has exactly one observed character.
            if (pos_distinct[0] != 1 || pos_distinct[1] != 1) begin
                $display("FARM FAIL: greedy must be deterministic 'alaya' but per-position variety>1");
                $finish;
            end
            $display("FARM PASS: %0d records, all 'alaya' (greedy), backpressure+determinism OK", got);
        end
        $finish;
    end
endmodule
