// Self-test for the Alveo farm RTL (no XRT, no Vitis): drive namegen_farm, act as the
// AXI write master by popping the record FIFO, decode each name record and check it.
//
// In GREEDY mode (sample_mode=0) the model is seed-independent and every name is "alaya"
// (tokens [1,12,1,25,1] -> name bytes [0,11,0,24,0]). So every record must decode to
// "alaya" with len=5. This exercises the entire reused core + the new farm/arbiter/FIFO.
//
//   iverilog -g2012 -o /tmp/tb_farm -s tb_farm alveo/sim/tb_farm.v \
//            alveo/rtl/record_fifo.v alveo/rtl/namegen_farm.v alveo/gen_src/*.v
//   vvp /tmp/tb_farm
`timescale 1ns/1ps
module tb_farm;
    localparam integer NUM_GEN = 4;
    localparam integer WANT    = 40;     // records to collect before declaring PASS

    reg clk = 0, resetn = 0, srst = 0, run_en = 0, sample_mode = 0;
    reg signed [15:0] inv_temp = 16'sd2926;   // 1/0.7 in Q5.11 (used when sampling)
    reg [31:0] base_seed = 32'hC0FFEE11;

    // run modes:  default greedy (expect 'alaya');  +sample -> sampled, expect variety
    initial begin
        if ($test$plusargs("sample")) sample_mode = 1;
        void'($value$plusargs("seed=%h", base_seed));
    end

    wire [175:0] rec_dout;
    wire         rec_empty;
    reg          rec_rd_en = 0;

    namegen_farm #(.NUM_GEN(NUM_GEN), .MAX_LEN(16), .FIFO_AW(6), .PAY_W(176)) dut (
        .clk(clk), .resetn(resetn), .srst(srst), .run_en(run_en),
        .base_seed(base_seed), .inv_temp(inv_temp), .sample_mode(sample_mode),
        .rec_dout(rec_dout), .rec_empty(rec_empty), .rec_rd_en(rec_rd_en));

    always #5 clk = ~clk;   // 100 MHz

    integer got = 0, fails = 0, n_diff = 0, i;
    reg [7:0]   r_len, r_gid;
    reg [31:0]  r_seed;
    reg [127:0] r_name, first_name;
    reg [8*16-1:0] str;
    reg [7:0]   ch;

    // expected greedy name
    reg [7:0] exp [0:4];
    initial begin exp[0]=0; exp[1]=11; exp[2]=0; exp[3]=24; exp[4]=0; end // a l a y a

    // pop one record per cycle when available (acts as the writer)
    always @(posedge clk) begin
        rec_rd_en <= 0;
        if (run_en && !rec_empty && !rec_rd_en) begin
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
            if (!sample_mode) begin
                // greedy is seed-independent: every name must be 'alaya'
                if (r_len !== 8'd5) fails = fails + 1;
                for (i = 0; i < 5; i = i + 1)
                    if (r_name[i*8 +: 8] !== exp[i]) fails = fails + 1;
            end
            if (got == 0) first_name = r_name;
            else if (r_name !== first_name) n_diff = n_diff + 1;
            if (got < 8)
                $display("  rec[%0d] gid=%0d len=%0d seed=%08x name=%s",
                         got, r_gid, r_len, r_seed, str);
            got = got + 1;
        end
    end

    initial begin
        resetn = 0; srst = 0; run_en = 0;
        repeat (8) @(posedge clk);
        resetn = 1;
        @(posedge clk);
        srst = 1;  @(posedge clk);          // flush + re-seed (1 cycle, like the top FSM)
        srst = 0;  run_en = 1;
        // run until WANT records or timeout
        fork
            begin : watchdog
                repeat (4_000_000) @(posedge clk);
                $display("TIMEOUT: only %0d/%0d records", got, WANT);
                $display("FARM FAIL");
                $finish;
            end
            begin : collect
                wait (got >= WANT);
                disable watchdog;
            end
        join
        if (sample_mode && n_diff == 0) begin
            $display("FARM FAIL: sampled mode produced no variety over %0d records", got);
        end else if (fails == 0) begin
            if (sample_mode) $display("FARM PASS: %0d valid sampled names, %0d differ from the first", got, n_diff);
            else             $display("FARM PASS: %0d records, all 'alaya' (greedy)", got);
        end else begin
            $display("FARM FAIL: %0d field mismatches over %0d records", fails, got);
        end
        $finish;
    end
endmodule
