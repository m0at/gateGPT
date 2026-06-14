// AXI4-Lite control/register slave for krnl_namegen (ap_ctrl_hs).
// Canonical Vitis RTL-kernel control-slave structure. Register map (must match
// krnl_namegen.xml argument offsets):
//   0x00 AP_CTRL : [0]ap_start(RW/SC) [1]ap_done(RO/COR) [2]ap_idle(RO) [3]ap_ready(RO/COR) [7]auto_restart
//   0x04 GIE     : [0] global interrupt enable
//   0x08 IP_IER  : [0] enable ap_done irq, [1] enable ap_ready irq
//   0x0C IP_ISR  : [0] ap_done status, [1] ap_ready status (toggle-on-write)
//   0x10/0x14 out (64-bit global-memory pointer)
//   0x1C n_records   0x24 base_seed   0x2C inv_temp   0x34 sample_mode
`timescale 1ns/1ps
`default_nettype none
module krnl_namegen_control_s_axi #(
    parameter integer C_S_AXI_ADDR_WIDTH = 8,
    parameter integer C_S_AXI_DATA_WIDTH = 32
) (
    input  wire                              ACLK,
    input  wire                              ARESET,
    input  wire                              ACLK_EN,
    input  wire [C_S_AXI_ADDR_WIDTH-1:0]     AWADDR,
    input  wire                              AWVALID,
    output wire                              AWREADY,
    input  wire [C_S_AXI_DATA_WIDTH-1:0]     WDATA,
    input  wire [C_S_AXI_DATA_WIDTH/8-1:0]   WSTRB,
    input  wire                              WVALID,
    output wire                              WREADY,
    output wire [1:0]                        BRESP,
    output wire                              BVALID,
    input  wire                              BREADY,
    input  wire [C_S_AXI_ADDR_WIDTH-1:0]     ARADDR,
    input  wire                              ARVALID,
    output wire                              ARREADY,
    output wire [C_S_AXI_DATA_WIDTH-1:0]     RDATA,
    output wire [1:0]                        RRESP,
    output wire                              RVALID,
    input  wire                              RREADY,
    output wire                              interrupt,
    // user / kernel-facing
    output wire                              ap_start,
    input  wire                              ap_done,
    input  wire                              ap_ready,
    input  wire                              ap_idle,
    output wire [63:0]                       out_r,
    output wire [31:0]                       n_records,
    output wire [31:0]                       base_seed,
    output wire [31:0]                       inv_temp,
    output wire [31:0]                       sample_mode
);
    localparam [C_S_AXI_ADDR_WIDTH-1:0]
        ADDR_AP_CTRL   = 8'h00, ADDR_GIE       = 8'h04,
        ADDR_IER       = 8'h08, ADDR_ISR       = 8'h0C,
        ADDR_OUT_0     = 8'h10, ADDR_OUT_1     = 8'h14,
        ADDR_NREC      = 8'h1C, ADDR_SEED      = 8'h24,
        ADDR_ITEMP     = 8'h2C, ADDR_SMODE     = 8'h34;
    localparam [1:0] WRIDLE = 2'd0, WRDATA = 2'd1, WRRESP = 2'd2;
    localparam [1:0] RDIDLE = 2'd0, RDDATA = 2'd1;

    reg  [1:0]  wstate, wnext, rstate, rnext;
    reg  [C_S_AXI_ADDR_WIDTH-1:0] waddr;
    wire [C_S_AXI_DATA_WIDTH-1:0] wmask;
    wire aw_hs, w_hs, ar_hs;
    reg  [C_S_AXI_DATA_WIDTH-1:0] rdata_r;

    // registers
    reg        int_ap_idle, int_ap_ready, int_ap_done, int_ap_start, int_auto_restart;
    reg        int_gie;
    reg  [1:0] int_ier, int_isr;
    reg  [63:0] int_out;
    reg  [31:0] int_nrec, int_seed, int_itemp, int_smode;

    // ---------------- write channel ----------------
    assign AWREADY = (wstate == WRIDLE);
    assign WREADY  = (wstate == WRDATA);
    assign BRESP   = 2'b00;
    assign BVALID  = (wstate == WRRESP);
    assign wmask   = {{8{WSTRB[3]}}, {8{WSTRB[2]}}, {8{WSTRB[1]}}, {8{WSTRB[0]}}};
    assign aw_hs   = AWVALID & AWREADY;
    assign w_hs    = WVALID  & WREADY;

    always @(posedge ACLK) if (ARESET) wstate <= WRIDLE; else if (ACLK_EN) wstate <= wnext;
    always @(*) begin
        case (wstate)
            WRIDLE: wnext = AWVALID ? WRDATA : WRIDLE;
            WRDATA: wnext = WVALID  ? WRRESP : WRDATA;
            WRRESP: wnext = BREADY  ? WRIDLE : WRRESP;
            default: wnext = WRIDLE;
        endcase
    end
    always @(posedge ACLK) if (ACLK_EN && aw_hs) waddr <= AWADDR;

    // ---------------- read channel ----------------
    assign ARREADY = (rstate == RDIDLE);
    assign RVALID  = (rstate == RDDATA);
    assign RRESP   = 2'b00;
    assign RDATA   = rdata_r;
    assign ar_hs   = ARVALID & ARREADY;

    always @(posedge ACLK) if (ARESET) rstate <= RDIDLE; else if (ACLK_EN) rstate <= rnext;
    always @(*) begin
        case (rstate)
            RDIDLE: rnext = ARVALID ? RDDATA : RDIDLE;
            RDDATA: rnext = (RREADY & RVALID) ? RDIDLE : RDDATA;
            default: rnext = RDIDLE;
        endcase
    end
    always @(posedge ACLK) begin
        if (ACLK_EN && ar_hs) begin
            rdata_r <= 32'd0;
            case (ARADDR)
                ADDR_AP_CTRL: rdata_r <= {24'd0, int_auto_restart, 3'd0,
                                          int_ap_ready, int_ap_idle, int_ap_done, int_ap_start};
                ADDR_GIE:     rdata_r <= {31'd0, int_gie};
                ADDR_IER:     rdata_r <= {30'd0, int_ier};
                ADDR_ISR:     rdata_r <= {30'd0, int_isr};
                ADDR_OUT_0:   rdata_r <= int_out[31:0];
                ADDR_OUT_1:   rdata_r <= int_out[63:32];
                ADDR_NREC:    rdata_r <= int_nrec;
                ADDR_SEED:    rdata_r <= int_seed;
                ADDR_ITEMP:   rdata_r <= int_itemp;
                ADDR_SMODE:   rdata_r <= int_smode;
                default:      rdata_r <= 32'd0;
            endcase
        end
    end

    // ---------------- control / status ----------------
    assign ap_start    = int_ap_start;
    assign out_r       = int_out;
    assign n_records   = int_nrec;
    assign base_seed   = int_seed;
    assign inv_temp    = int_itemp;
    assign sample_mode = int_smode;
    assign interrupt   = int_gie & (|int_isr);

    // ap_start: set by host write of bit0; cleared on ap_ready (unless auto-restart)
    always @(posedge ACLK) begin
        if (ARESET) int_ap_start <= 1'b0;
        else if (ACLK_EN) begin
            if (w_hs && waddr == ADDR_AP_CTRL && WSTRB[0] && WDATA[0]) int_ap_start <= 1'b1;
            else if (int_ap_ready) int_ap_start <= int_auto_restart;
        end
    end
    // Reset value 1: the kernel IS idle out of reset. Canonical Vitis resets ap_idle high
    // so a host reading AP_CTRL immediately after reset never sees a spurious "busy" CU.
    always @(posedge ACLK) if (ARESET) int_ap_idle <= 1'b1; else if (ACLK_EN) int_ap_idle <= ap_idle;
    always @(posedge ACLK) if (ARESET) int_ap_ready <= 1'b0; else if (ACLK_EN) int_ap_ready <= ap_ready;
    always @(posedge ACLK) begin
        if (ARESET) int_ap_done <= 1'b0;
        else if (ACLK_EN) begin
            if (ap_done) int_ap_done <= 1'b1;
            else if (ar_hs && ARADDR == ADDR_AP_CTRL) int_ap_done <= 1'b0; // clear on read
        end
    end
    always @(posedge ACLK) begin
        if (ARESET) int_auto_restart <= 1'b0;
        else if (ACLK_EN && w_hs && waddr == ADDR_AP_CTRL && WSTRB[0]) int_auto_restart <= WDATA[7];
    end

    // interrupt enables/status
    always @(posedge ACLK) begin
        if (ARESET) int_gie <= 1'b0;
        else if (ACLK_EN && w_hs && waddr == ADDR_GIE && WSTRB[0]) int_gie <= WDATA[0];
    end
    always @(posedge ACLK) begin
        if (ARESET) int_ier <= 2'b0;
        else if (ACLK_EN && w_hs && waddr == ADDR_IER && WSTRB[0]) int_ier <= WDATA[1:0];
    end
    always @(posedge ACLK) begin
        if (ARESET) int_isr <= 2'b0;
        else if (ACLK_EN) begin
            if (int_ier[0] & ap_done)  int_isr[0] <= 1'b1;
            else if (w_hs && waddr == ADDR_ISR && WSTRB[0]) int_isr[0] <= int_isr[0] ^ WDATA[0];
            if (int_ier[1] & ap_ready) int_isr[1] <= 1'b1;
            else if (w_hs && waddr == ADDR_ISR && WSTRB[0]) int_isr[1] <= int_isr[1] ^ WDATA[1];
        end
    end

    // argument registers
    always @(posedge ACLK) begin
        if (ARESET) begin
            int_out <= 64'd0; int_nrec <= 0; int_seed <= 0; int_itemp <= 0; int_smode <= 0;
        end else if (ACLK_EN && w_hs) begin
            case (waddr)
                ADDR_OUT_0: int_out[31:0]  <= (WDATA & wmask) | (int_out[31:0]  & ~wmask);
                ADDR_OUT_1: int_out[63:32] <= (WDATA & wmask) | (int_out[63:32] & ~wmask);
                ADDR_NREC:  int_nrec  <= (WDATA & wmask) | (int_nrec  & ~wmask);
                ADDR_SEED:  int_seed  <= (WDATA & wmask) | (int_seed  & ~wmask);
                ADDR_ITEMP: int_itemp <= (WDATA & wmask) | (int_itemp & ~wmask);
                ADDR_SMODE: int_smode <= (WDATA & wmask) | (int_smode & ~wmask);
                default: ;
            endcase
        end
    end
endmodule
`default_nettype wire
