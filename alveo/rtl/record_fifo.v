// Small synchronous first-word-fall-through FIFO (distributed RAM).
// One instance buffers completed name records between the farm arbiter (<=1 push/cycle)
// and the AXI write master (<=1 pop/cycle). Combinational read: `dout` is valid whenever
// `empty` is low. Shallow by design (DEPTH=64) so the read mux stays timing-friendly.
`default_nettype none
module record_fifo #(
    parameter integer W  = 192,
    parameter integer AW = 6              // DEPTH = 1<<AW
) (
    input  wire          clk,
    input  wire          srst,            // synchronous flush
    input  wire          wr_en,
    input  wire [W-1:0]  din,
    output wire          full,
    input  wire          rd_en,
    output wire [W-1:0]  dout,
    output wire          empty,
    output reg  [AW:0]   count
);
    (* ram_style = "distributed" *) reg [W-1:0] mem [0:(1<<AW)-1];
    reg [AW:0] wr_ptr, rd_ptr;            // one extra MSB to distinguish full from empty

    wire [AW-1:0] wa = wr_ptr[AW-1:0];
    wire [AW-1:0] ra = rd_ptr[AW-1:0];

    assign empty = (wr_ptr == rd_ptr);
    assign full  = (wa == ra) && (wr_ptr[AW] != rd_ptr[AW]);
    assign dout  = mem[ra];

    wire do_wr = wr_en && !full;
    wire do_rd = rd_en && !empty;

    always @(posedge clk) begin
        if (do_wr) mem[wa] <= din;
    end

    always @(posedge clk) begin
        if (srst) begin
            wr_ptr <= 0;
            rd_ptr <= 0;
            count  <= 0;
        end else begin
            if (do_wr) wr_ptr <= wr_ptr + 1'b1;
            if (do_rd) rd_ptr <= rd_ptr + 1'b1;
            count <= count + (do_wr ? 1'b1 : 1'b0) - (do_rd ? 1'b1 : 1'b0);
        end
    end
endmodule
`default_nettype wire
