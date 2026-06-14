// Synchronous first-word-fall-through (FWFT) record FIFO.
// Buffers completed name records between the farm arbiter (<=1 push/cycle) and the AXI
// write master (<=1 pop/cycle). `dout` is the combinational head: valid whenever `empty`
// is low, so the writer can pack a beat from the FIFO head and pop it in the same cycle
// (the axi_write_master relies on this FWFT contract -- do NOT add a read pipeline stage).
//
// Depth = 1<<AW. The default AW=6 (64 deep) keeps the read mux in distributed LUT-RAM and
// timing-friendly. Deeper FIFOs (AW>=9) decouple the farm from a bursty/back-pressured
// writer; for those, set RAM_STYLE="block" so the storage maps to BRAM/URAM instead of
// exploding distributed RAM. The full/empty/count logic is depth-agnostic. Single clock.
`default_nettype none
module record_fifo #(
    parameter integer W   = 192,
    parameter integer AW  = 6,                 // DEPTH = 1<<AW
    parameter         RAM_STYLE = "distributed" // "distributed" (small) or "block" (deep)
) (
    input  wire          clk,
    input  wire          srst,                 // synchronous flush
    input  wire          wr_en,
    input  wire [W-1:0]  din,
    output wire          full,
    input  wire          rd_en,
    output wire [W-1:0]  dout,
    output wire          empty,
    output reg  [AW:0]   count
);
    (* ram_style = RAM_STYLE *) reg [W-1:0] mem [0:(1<<AW)-1];
    reg [AW:0] wr_ptr, rd_ptr;                 // one extra MSB to tell full from empty

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
            wr_ptr <= {(AW+1){1'b0}};
            rd_ptr <= {(AW+1){1'b0}};
            count  <= {(AW+1){1'b0}};
        end else begin
            if (do_wr) wr_ptr <= wr_ptr + 1'b1;
            if (do_rd) rd_ptr <= rd_ptr + 1'b1;
            count <= count + (do_wr ? 1'b1 : 1'b0) - (do_rd ? 1'b1 : 1'b0);
        end
    end
endmodule
`default_nettype wire
