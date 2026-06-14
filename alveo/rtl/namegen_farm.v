// Throughput farm: NUM_GEN independent name_generators, each running its own
// autoregressive stream from an evolving per-generator seed. Completed names are
// captured into per-generator holding registers; a round-robin arbiter drains them
// into a single record FIFO that the AXI write master pops.
//
// NUM_GEN must be a power of two (the arbiter uses a bitmask for round-robin).
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
    reg  [31:0]      seed_used [0:NUM_GEN-1];
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
                seed_used[g]    <= 32'd0;
            end else begin
                gen_start[g] <= 1'b0;                              // default: 1-cycle pulse
                case (st[g])
                    ST_START: if (run_en && !hold_valid_r[g]) begin
                        gen_start[g] <= 1'b1;
                        seed_used[g] <= seed_r[g];
                        st[g]        <= ST_RUN;
                    end
                    ST_RUN: if (gen_done[g]) begin
                        hold_flat[g]    <= gen_flat[g];
                        hold_len[g]     <= {3'd0, gen_len[g]};
                        hold_seed[g]    <= seed_used[g];
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
`default_nettype wire
