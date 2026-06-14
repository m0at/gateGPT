// Write-only AXI4 master: drains name records from the farm FIFO and writes one
// 64-byte record per single-beat 512-bit transaction to out_ptr + seq*64.
//
// Deliberately serialized (one outstanding transaction at a time): trivially correct,
// no 4KB-boundary math, and still ~30M writes/s at 300MHz -- far above the farm's rate.
// DDR/PCIe is nowhere near the bottleneck, so simplicity wins. Burst-batching is a
// documented future optimization (see SPEC.md).
`default_nettype none
module axi_write_master #(
    parameter integer ADDR_WIDTH = 64,
    parameter integer DATA_WIDTH = 512,
    parameter integer ID_WIDTH   = 1,
    parameter integer PAY_W      = 176     // record FIFO payload width
) (
    input  wire                    clk,
    input  wire                    resetn,

    // control
    input  wire                    start,        // 1-cycle pulse
    input  wire [ADDR_WIDTH-1:0]   base_addr,
    input  wire [31:0]             n_records,
    output reg                     busy,
    output reg                     done,         // 1-cycle pulse when all writes retired

    // record source (FWFT FIFO)
    input  wire [PAY_W-1:0]        rec_dout,
    input  wire                    rec_empty,
    output reg                     rec_rd_en,

    // AXI4 write address
    output reg  [ID_WIDTH-1:0]     awid,
    output reg  [ADDR_WIDTH-1:0]   awaddr,
    output wire [7:0]              awlen,
    output wire [2:0]              awsize,
    output wire [1:0]              awburst,
    output reg                     awvalid,
    input  wire                    awready,
    // AXI4 write data
    output reg  [DATA_WIDTH-1:0]   wdata,
    output wire [DATA_WIDTH/8-1:0] wstrb,
    output wire                    wlast,
    output reg                     wvalid,
    input  wire                    wready,
    // AXI4 write response
    input  wire [ID_WIDTH-1:0]     bid,
    input  wire [1:0]              bresp,
    input  wire                    bvalid,
    output reg                     bready
);
    localparam [2:0] S_IDLE = 0, S_GET = 1, S_ADDR_DATA = 2, S_RESP = 3, S_DONE = 4;
    reg [2:0]  state;
    reg [31:0] n_recs, cnt;          // cnt = next seq to write
    reg        aw_acc, w_acc;

    assign awlen   = 8'd0;                       // single beat
    assign awsize  = (DATA_WIDTH == 512) ? 3'd6 : // 64 bytes/beat
                     (DATA_WIDTH == 256) ? 3'd5 : 3'd4;
    assign awburst = 2'b01;                      // INCR
    assign wstrb   = {(DATA_WIDTH/8){1'b1}};
    assign wlast   = 1'b1;

    // record payload fields
    wire [7:0]   f_len  = rec_dout[7:0];
    wire [7:0]   f_gid  = rec_dout[15:8];
    wire [31:0]  f_seed = rec_dout[47:16];
    wire [127:0] f_name = rec_dout[175:48];

    always @(posedge clk) begin
        if (!resetn) begin
            state <= S_IDLE; busy <= 0; done <= 0; rec_rd_en <= 0;
            awvalid <= 0; wvalid <= 0; bready <= 0; aw_acc <= 0; w_acc <= 0;
            awaddr <= 0; awid <= 0; wdata <= 0; n_recs <= 0; cnt <= 0;
        end else begin
            done      <= 0;
            rec_rd_en <= 0;
            case (state)
                S_IDLE: begin
                    busy <= 0;
                    if (start) begin
                        n_recs <= n_records;
                        cnt    <= 0;
                        busy   <= 1;
                        state  <= (n_records == 0) ? S_DONE : S_GET;
                    end
                end

                // pop one record from the FWFT FIFO and latch the AXI beat
                S_GET: if (!rec_empty) begin
                    rec_rd_en <= 1'b1;                 // advance FIFO (capture dout this cycle)
                    awaddr    <= base_addr + (cnt << 6);
                    awid      <= {ID_WIDTH{1'b0}};
                    wdata     <= { {(DATA_WIDTH-256){1'b0}},  // pad to top
                                   {32'd0, cnt},              // [255:192] seq (cnt zero-extended)
                                   f_name,                    // [191:64]  name chars
                                   f_seed,                    // [63:32]   seed
                                   16'h4E47,                  // [31:16]   magic 'GN'
                                   f_gid,                     // [15:8]    generator id
                                   f_len };                   // [7:0]     name length
                    awvalid <= 1'b1;
                    wvalid  <= 1'b1;
                    aw_acc  <= 1'b0;
                    w_acc   <= 1'b0;
                    state   <= S_ADDR_DATA;
                end

                // handshake AW and W independently (either order)
                S_ADDR_DATA: begin
                    if (awvalid && awready) begin awvalid <= 1'b0; aw_acc <= 1'b1; end
                    if (wvalid  && wready ) begin wvalid  <= 1'b0; w_acc  <= 1'b1; end
                    if ((aw_acc || (awvalid && awready)) &&
                        (w_acc  || (wvalid  && wready ))) begin
                        bready <= 1'b1;
                        state  <= S_RESP;
                    end
                end

                S_RESP: if (bvalid) begin
                    bready <= 1'b0;
                    cnt    <= cnt + 1'b1;
                    state  <= (cnt + 1'b1 == n_recs) ? S_DONE : S_GET;
                end

                S_DONE: begin
                    busy <= 0;
                    done <= 1'b1;
                    state <= S_IDLE;
                end

                default: state <= S_IDLE;
            endcase
        end
    end
endmodule
`default_nettype wire
