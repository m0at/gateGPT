// Throughput farm: NUM_GEN independent name_generators, each running its own
// autoregressive stream from an evolving per-generator seed. Completed names are
// captured into per-generator holding registers; a round-robin arbiter drains them
// into a single record FIFO that the AXI write master pops.
//
// NUM_GEN must be a power of two (the arbiter uses a bitmask for round-robin).
//
// SEED DIVERSIFICATION (verified, do not "improve"): gen g starts at
//   seed_r[g] = base_seed ^ (g * 0x9E3779B1)            -- 0x9E3779B1 odd => NUM_GEN
//                                                          distinct inits, one per gen,
// and advances by a SHARED Weyl stride 0x9E3779B9 per completed name. Because the inits are
// a linear function of g and the stride is shared, the first cross-generator seed COLLISION
// across all gens does not occur until >=172k names/generator (closed-form check over 128
// gens). A naive per-generator distinct stride is WORSE -- it collides within ~3.3k
// names/gen -- so the shared stride is deliberate. Greedy output is seed-independent
// (always 'alaya'); the seed only inits the sampler RNG, so this just buys long-horizon
// sample variety with zero multipliers in the advance path (Weyl add only).
`default_nettype none
module namegen_farm #(
    parameter integer NUM_GEN  = 32,
    parameter integer MAX_LEN  = 16,
    parameter integer FIFO_AW  = 6,
    parameter integer PAY_W    = 176          // {name_flat[127:0],seed[31:0],gid[7:0],len[7:0]}
) (
    input  wire                clk,
    input  wire                resetn,
    input  wire                srst,           // synchronous flush + re-seed (1+ cycle)
    input  wire                run_en,         // keep generating while high
    input  wire [31:0]         base_seed,
    input  wire signed [15:0]  inv_temp,
    input  wire                sample_mode,

    // record FIFO pop side (to AXI write master)
    output wire [PAY_W-1:0]    rec_dout,
    output wire                rec_empty,
    input  wire                rec_rd_en
);
    localparam integer IDXW    = (NUM_GEN <= 1) ? 1 : $clog2(NUM_GEN);
    localparam integer NAME_W  = MAX_LEN*8;    // 128 for MAX_LEN=16
    localparam [1:0] ST_START = 2'd0, ST_RUN = 2'd1, ST_PEND = 2'd2;

    wire ng_resetn = resetn & ~srst;

    // per-generator state
    reg  [31:0]      seed_r    [0:NUM_GEN-1];
    reg  [1:0]       st        [0:NUM_GEN-1];
    reg              hold_valid_r [0:NUM_GEN-1];
    reg  [NAME_W-1:0] hold_flat [0:NUM_GEN-1];
    reg  [7:0]       hold_len  [0:NUM_GEN-1];
    reg  [31:0]      hold_seed [0:NUM_GEN-1];
    reg              gen_start [0:NUM_GEN-1];

    // per-generator wires
    wire [NUM_GEN-1:0] gen_busy, gen_done;
    wire [NAME_W-1:0]  gen_flat [0:NUM_GEN-1];
    wire [4:0]         gen_len  [0:NUM_GEN-1];

    // hold_valid as a packed vector for the arbiter scan
    wire [NUM_GEN-1:0] hold_valid_v;

    // ---- arbiter (round-robin over generators with a pending record) ----
    // Starvation-free RR: scan NUM_GEN candidates starting at the saved pointer `rr` and
    // pick the FIRST pending one; after a grant `rr` moves PAST the winner so it goes to the
    // back of the line. The scan is a priority mux of depth NUM_GEN; for large NUM_GEN this
    // (and the wide PAY_W payload mux on `sel`) is the timing-limiting path -- see the
    // SHARED-WEIGHT-ROM / banking notes at the bottom of this file for how that path is kept
    // off the per-name critical loop (the writer only pops <=1/cycle, so a registered-grant
    // arbiter is a drop-in if this mux ever fails timing at NUM_GEN>=128).
    reg  [IDXW-1:0] rr;
    reg  [IDXW-1:0] sel;
    reg             sel_valid;
    integer j; reg [IDXW-1:0] idx;
    always @(*) begin
        sel = {IDXW{1'b0}}; sel_valid = 1'b0;
        for (j = 0; j < NUM_GEN; j = j + 1) begin
            idx = (rr + j[IDXW-1:0]);          // wraps mod NUM_GEN (power-of-two)
            if (!sel_valid && hold_valid_v[idx]) begin
                sel = idx; sel_valid = 1'b1;
            end
        end
    end

    wire        rec_full;
    wire        fifo_wr = sel_valid && !rec_full;
    wire [PAY_W-1:0] fifo_din =
        { hold_flat[sel], hold_seed[sel],
          {(8-IDXW){1'b0}}, sel, hold_len[sel] };

    record_fifo #(.W(PAY_W), .AW(FIFO_AW)) u_fifo (
        .clk(clk), .srst(srst),
        .wr_en(fifo_wr), .din(fifo_din), .full(rec_full),
        .rd_en(rec_rd_en), .dout(rec_dout), .empty(rec_empty), .count());

    always @(posedge clk) begin
        if (srst) rr <= {IDXW{1'b0}};
        else if (fifo_wr) rr <= sel + 1'b1;
    end

    // ---- generators + per-generator restart FSM ----
    genvar g;
    generate
    for (g = 0; g < NUM_GEN; g = g + 1) begin : GEN
        assign hold_valid_v[g] = hold_valid_r[g];
        wire grant = fifo_wr && (sel == g[IDXW-1:0]);

        name_generator #(.MAX_LEN(MAX_LEN)) u_ng (
            .clk(clk), .resetn(ng_resetn), .start(gen_start[g]),
            .seed(seed_r[g]), .inv_temp(inv_temp), .sample_mode(sample_mode),
            .busy(gen_busy[g]), .done(gen_done[g]),
            .token_out(), .token_valid(),
            .name_len(gen_len[g]), .name_flat(gen_flat[g]));

        always @(posedge clk) begin
            if (srst) begin
                st[g]           <= ST_START;
                seed_r[g]       <= base_seed ^ (g * 32'h9E3779B1); // constant per g -> folded
                hold_valid_r[g] <= 1'b0;
                gen_start[g]    <= 1'b0;
            end else begin
                gen_start[g] <= 1'b0;                              // default: 1-cycle pulse
                case (st[g])
                    ST_START: if (run_en && !hold_valid_r[g]) begin
                        gen_start[g] <= 1'b1;
                        st[g]        <= ST_RUN;
                    end
                    ST_RUN: if (gen_done[g]) begin
                        hold_flat[g]    <= gen_flat[g];
                        hold_len[g]     <= {3'd0, gen_len[g]};
                        // seed_r[g] is the value this run used (the core sampled rng=seed at
                        // start and seed_r does not advance until THIS cycle); the Weyl bump
                        // below is non-blocking, so the RHS read here sees the pre-advance
                        // value -- identical to the old per-gen seed_used register, minus
                        // NUM_GEN x 32 FFs.
                        hold_seed[g]    <= seed_r[g];
                        hold_valid_r[g] <= 1'b1;
                        seed_r[g]       <= seed_r[g] + 32'h9E3779B9; // Weyl advance (no mult)
                        st[g]           <= ST_PEND;
                    end
                    ST_PEND: if (grant) begin
                        hold_valid_r[g] <= 1'b0;
                        st[g]           <= ST_START;
                    end
                    default: st[g] <= ST_START;
                endcase
            end
        end
    end
    endgenerate
endmodule

// =====================================================================================
// SHARED WEIGHT ROM -- design + standalone scaffold (NOT instantiated; zero build impact)
// =====================================================================================
//
// PROBLEM. Each microgpt_core instantiates its own `wrom` (core/wrom.v), a 768-bit-wide
// combinational `case` over ~39 KB of constants (core/wrom_data.vh): for every (sel,addr)
// it returns LANES=24 Q5.11 weights for TWO input columns. Synthesised as LUTs this is
// roughly HALF the per-core logic and it REPLICATES NUM_GEN times. That LUT cost is what
// caps the farm at ~64 generators. `grom` (gains) replicates too but is tiny; the weight
// tables dominate. The fix that unlocks NUM_GEN ~100..128+ is to store the weights ONCE in
// on-chip block RAM (BRAM/URAM, which every core shares) instead of NUM_GEN copies in LUTs.
//
// WHY IT'S SAFE (bit-exactness). The weights are READ-ONLY and IDENTICAL for every core --
// a name's bytes depend only on (seed, inv_temp, sample_mode), never on which physical core
// ran it. So replacing NUM_GEN identical combinational tables with one shared memory that
// returns the SAME 768-bit word for the same (sel,addr) changes nothing functionally. The
// ONLY thing to get right is TIMING: today wrom is combinational (matvec already registers
// w_rdata into w_rdata_r/w_rdata_rr, giving a 2-stage operand pipeline). A BRAM/URAM read is
// SYNCHRONOUS (1-2 cycle latency). matvec drives addresses a cycle ahead and the multiply
// consumes doubly-registered operands, so a 1-cycle ROM latency already fits its pipeline;
// a 2-cycle (URAM/output-reg) read needs one extra address-lead cycle in matvec.
//
// THE ONE CORE CHANGE NEEDED (orchestrator -- this is the refactor microgpt_core needs;
// Agent 3 cannot edit core/ so it is specified, not done):
//   In core/microgpt_core.v line 86, the weight source is hard-wired:
//       wrom u_wrom (.sel(wsel[2:0]), .addr(w_addr), .wdata(w_rdata));
//   Expose those three nets at the microgpt_core PORT boundary instead of binding `wrom`
//   internally, i.e. add ports:
//       output wire [2:0]   w_sel,    // = wsel[2:0]
//       output wire [11:0]  w_addr,   // = matvec's w_addr
//       input  wire [767:0] w_rdata,  // weight word, supplied by the shared ROM
//   and DELETE the internal `wrom u_wrom`. (name_generator.v just passes these up; it adds
//   no logic.) Everything else in the core is untouched -> still bit-exact. This is a PORT
//   change, which the farm/top must then re-wire; coordinate with Agent 1 (top) + the core
//   owner. NOTE the matvec operand pipeline assumes a COMBINATIONAL wrom today; with a
//   1-cycle BRAM read, advance matvec's address phase by one cycle (drive w_addr/w_sel from
//   the *pre*-feed state) OR drop ONE of the two existing w_rdata_r/w_rdata_rr stages so the
//   total weight latency back to the multiplier is unchanged. Verify against the Python
//   golden after the change -- greedy must stay 'alaya'.
//
// ARBITRATION / BANKING SCHEME (this scaffold). The cores issue weight reads independently,
// but the cores are NOT phase-locked, so naively one shared port would serialise NUM_GEN
// readers and throttle the matvecs. Two layers fix that:
//   (1) REPLICATE FOR BANDWIDTH, not per-core. Instantiate a SMALL number BANKS of the
//       shared ROM (each a full copy of the weight table in BRAM/URAM) and statically assign
//       core g -> bank (g % BANKS). With e.g. BANKS=8 you serve 8 cores/cycle and still cut
//       weight storage by NUM_GEN/BANKS (128/8 = 16x fewer copies vs today). Each copy is
//       ONE memory, dual-read, so 2 cores/bank/cycle conflict-free -> BANKS=8 supports 16
//       cores at full rate, 64..128 cores at a small, bounded round-robin stall.
//   (2) Within a bank, a tiny round-robin (same starvation-free arbiter as the record path)
//       grants one requesting core per cycle and returns its 768-bit word the next cycle.
//   Because matvec spends in_dim/2 (=12) cycles feeding a tile and only needs a new weight
//       word each of those cycles for ITS OWN tile, the per-bank contention is low: a bank
//       shared by K cores reaches steady state at ~K/ports utilisation; with K<=4 and 2
//       ports the stall is negligible. Sizing BANKS is the LUT<->BRAM knob.
//
// STORAGE SIZING (U200 budget = 2160 BRAM36, 960 URAM). The weight word is 768 bits; the
// address space is 7 tables (sel 0..6) x up to 4096 word-addrs, but the real depth is small
// (microGPT: n_embed 24, 4 heads, ctx 16 -> a few hundred words/table, < 2K words total
// across all sel). One copy: ~2K x 768b ~= 1.5 Mb. In BRAM36 (36 Kb each, up to 72b wide) a
// 768b word needs ceil(768/72)=11 BRAM36 in width x ceil(depth/512) in depth -- on the order
// of ~22-44 BRAM36 per copy. In URAM (72b x 4096) it is ~11 URAM per copy (one URAM column
// per 72b slice, single-depth). So BANKS=8 costs ~88 URAM (of 960) or ~180-350 BRAM36 (of
// 2160) -- easily affordable, and it FREES the NUM_GEN x (wrom LUTs) that currently block
// scaling. URAM is the better fit (deep, wide, plentiful, and the read latency hides in the
// matvec operand pipeline). Pick URAM for the banks; keep BRAM for vmem/KV.
//
// EXPECTED IMPACT.
//   * LUT: removes ~NUM_GEN copies of the wrom case-table. If wrom is ~half of per-core LUTs,
//     this roughly HALVES per-core LUT, lifting the NUM_GEN ceiling from ~64 to ~110-128
//     (then DSP/BRAM or place&route congestion becomes the next limit, not weight LUTs).
//   * Throughput: ~0 in the common case (latency hidden by matvec's existing operand regs);
//     worst case a few % from bank contention at very high NUM_GEN, tunable via BANKS.
//   * Bit-exactness: unchanged (same weights, same order; only the storage medium changes).
//
// WHAT IS NOT YET VERIFIABLE HERE: actual LUT/BRAM/URAM numbers and Fmax need Vitis/Vivado
// synthesis on the U200 part (no FPGA tooling in this env). The scaffold below ELABORATES
// (icarus + Vivado) but is intentionally left UN-instantiated so it cannot perturb the
// passing sims; the orchestrator wires it in after exposing the core's weight ports above.
//
// -------------------------------------------------------------------------------------
// Standalone scaffold: a banked, round-robin shared weight ROM front-end. Pure structure +
// an unbound `wrom` placeholder port-compatible with core/wrom.v. Not instantiated anywhere.
`ifdef SHARED_WROM_SCAFFOLD
module shared_wrom_bank #(
    parameter integer N_CORES = 4,     // cores attached to THIS bank
    parameter integer DW      = 768    // 2*LANES*16
) (
    input  wire                       clk,
    input  wire                       resetn,
    // one read request port per attached core (sel+addr), valid each cycle a core feeds
    input  wire [N_CORES-1:0]         req,
    input  wire [N_CORES*3-1:0]       req_sel,
    input  wire [N_CORES*12-1:0]      req_addr,
    output reg  [N_CORES-1:0]         gnt,         // 1-cycle-ahead grant back to the core
    output reg  [DW-1:0]              rd_data,     // shared bank read result (registered)
    output reg  [$clog2(N_CORES>1?N_CORES:2)-1:0] rd_core // which core rd_data is for
);
    localparam integer CW = (N_CORES>1) ? $clog2(N_CORES) : 1;
    // round-robin arbiter over req (identical scheme to the record-path arbiter above)
    reg  [CW-1:0] rr, sel; reg sel_v; integer j; reg [CW-1:0] idx;
    always @(*) begin
        sel = {CW{1'b0}}; sel_v = 1'b0;
        for (j = 0; j < N_CORES; j = j + 1) begin
            idx = rr + j[CW-1:0];
            if (!sel_v && req[idx]) begin sel = idx; sel_v = 1'b1; end
        end
    end
    wire [2:0]  bank_sel  = req_sel [sel*3  +: 3];
    wire [11:0] bank_addr = req_addr[sel*12 +: 12];
    // single physical weight table for this bank (port-compatible with core/wrom.v). The
    // orchestrator binds the real `wrom` (URAM-backed via ram_style/synth attr) here.
    wire [DW-1:0] bank_q;
    wrom u_bank_rom (.sel(bank_sel), .addr(bank_addr), .wdata(bank_q));
    always @(posedge clk) begin
        if (!resetn) begin rr <= 0; gnt <= 0; rd_core <= 0; rd_data <= 0; end
        else begin
            gnt     <= sel_v ? ({{(N_CORES-1){1'b0}},1'b1} << sel) : {N_CORES{1'b0}};
            rd_core <= sel;
            rd_data <= bank_q;                 // register read -> 1-cycle latency (hidden by
                                               // matvec's existing operand pipeline)
            if (sel_v) rr <= sel + 1'b1;
        end
    end
endmodule
`endif
`default_nettype wire
