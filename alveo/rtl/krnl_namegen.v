// krnl_namegen — Vitis RTL kernel top (ap_ctrl_hs).
// A farm of NUM_GEN microGPT name generators streams 64-byte name records to global
// memory (m_axi_gmem) under control of the AXI4-Lite slave (s_axi_control).
//
// Args (see krnl_namegen.xml / SPEC.md):
//   out (m_axi pointer), n_records, base_seed, inv_temp (Q5.11 signed), sample_mode.
`timescale 1ns/1ps
`default_nettype none
module krnl_namegen #(
    parameter integer NUM_GEN              = 32,
    parameter integer C_S_AXI_CONTROL_ADDR_WIDTH = 12,
    parameter integer C_S_AXI_CONTROL_DATA_WIDTH = 32,
    parameter integer C_M_AXI_GMEM_ADDR_WIDTH    = 64,
    parameter integer C_M_AXI_GMEM_DATA_WIDTH    = 512,
    parameter integer C_M_AXI_GMEM_ID_WIDTH      = 1
) (
    // platform clock/reset
    input  wire                                       ap_clk,
    input  wire                                       ap_rst_n,
    output wire                                       interrupt,

    // AXI4-Lite control
    input  wire                                       s_axi_control_AWVALID,
    output wire                                       s_axi_control_AWREADY,
    input  wire [C_S_AXI_CONTROL_ADDR_WIDTH-1:0]      s_axi_control_AWADDR,
    input  wire                                       s_axi_control_WVALID,
    output wire                                       s_axi_control_WREADY,
    input  wire [C_S_AXI_CONTROL_DATA_WIDTH-1:0]      s_axi_control_WDATA,
    input  wire [C_S_AXI_CONTROL_DATA_WIDTH/8-1:0]    s_axi_control_WSTRB,
    input  wire                                       s_axi_control_ARVALID,
    output wire                                       s_axi_control_ARREADY,
    input  wire [C_S_AXI_CONTROL_ADDR_WIDTH-1:0]      s_axi_control_ARADDR,
    output wire                                       s_axi_control_RVALID,
    input  wire                                       s_axi_control_RREADY,
    output wire [C_S_AXI_CONTROL_DATA_WIDTH-1:0]      s_axi_control_RDATA,
    output wire [1:0]                                 s_axi_control_RRESP,
    output wire                                       s_axi_control_BVALID,
    input  wire                                       s_axi_control_BREADY,
    output wire [1:0]                                 s_axi_control_BRESP,

    // AXI4 master to global memory (write-only used; read channel tied off)
    output wire [C_M_AXI_GMEM_ID_WIDTH-1:0]           m_axi_gmem_AWID,
    output wire [C_M_AXI_GMEM_ADDR_WIDTH-1:0]         m_axi_gmem_AWADDR,
    output wire [7:0]                                 m_axi_gmem_AWLEN,
    output wire [2:0]                                 m_axi_gmem_AWSIZE,
    output wire [1:0]                                 m_axi_gmem_AWBURST,
    output wire [1:0]                                 m_axi_gmem_AWLOCK,
    output wire [3:0]                                 m_axi_gmem_AWCACHE,
    output wire [2:0]                                 m_axi_gmem_AWPROT,
    output wire [3:0]                                 m_axi_gmem_AWQOS,
    output wire [3:0]                                 m_axi_gmem_AWREGION,
    output wire                                       m_axi_gmem_AWVALID,
    input  wire                                       m_axi_gmem_AWREADY,
    output wire [C_M_AXI_GMEM_DATA_WIDTH-1:0]         m_axi_gmem_WDATA,
    output wire [C_M_AXI_GMEM_DATA_WIDTH/8-1:0]       m_axi_gmem_WSTRB,
    output wire                                       m_axi_gmem_WLAST,
    output wire                                       m_axi_gmem_WVALID,
    input  wire                                       m_axi_gmem_WREADY,
    input  wire [C_M_AXI_GMEM_ID_WIDTH-1:0]           m_axi_gmem_BID,
    input  wire [1:0]                                 m_axi_gmem_BRESP,
    input  wire                                       m_axi_gmem_BVALID,
    output wire                                       m_axi_gmem_BREADY,
    output wire [C_M_AXI_GMEM_ID_WIDTH-1:0]           m_axi_gmem_ARID,
    output wire [C_M_AXI_GMEM_ADDR_WIDTH-1:0]         m_axi_gmem_ARADDR,
    output wire [7:0]                                 m_axi_gmem_ARLEN,
    output wire [2:0]                                 m_axi_gmem_ARSIZE,
    output wire [1:0]                                 m_axi_gmem_ARBURST,
    output wire [1:0]                                 m_axi_gmem_ARLOCK,
    output wire [3:0]                                 m_axi_gmem_ARCACHE,
    output wire [2:0]                                 m_axi_gmem_ARPROT,
    output wire [3:0]                                 m_axi_gmem_ARQOS,
    output wire [3:0]                                 m_axi_gmem_ARREGION,
    output wire                                       m_axi_gmem_ARVALID,
    input  wire                                       m_axi_gmem_ARREADY,
    input  wire [C_M_AXI_GMEM_ID_WIDTH-1:0]           m_axi_gmem_RID,
    input  wire [C_M_AXI_GMEM_DATA_WIDTH-1:0]         m_axi_gmem_RDATA,
    input  wire [1:0]                                 m_axi_gmem_RRESP,
    input  wire                                       m_axi_gmem_RLAST,
    input  wire                                       m_axi_gmem_RVALID,
    output wire                                       m_axi_gmem_RREADY
);
    wire areset = ~ap_rst_n;

    // ---------------- control slave ----------------
    wire        ap_start, ap_done, ap_ready, ap_idle;
    wire [63:0] arg_out;
    wire [31:0] arg_nrec, arg_seed, arg_itemp, arg_smode;

    krnl_namegen_control_s_axi #(
        .C_S_AXI_ADDR_WIDTH(C_S_AXI_CONTROL_ADDR_WIDTH),
        .C_S_AXI_DATA_WIDTH(C_S_AXI_CONTROL_DATA_WIDTH)
    ) u_ctrl (
        .ACLK(ap_clk), .ARESET(areset), .ACLK_EN(1'b1),
        .AWADDR(s_axi_control_AWADDR), .AWVALID(s_axi_control_AWVALID), .AWREADY(s_axi_control_AWREADY),
        .WDATA(s_axi_control_WDATA), .WSTRB(s_axi_control_WSTRB),
        .WVALID(s_axi_control_WVALID), .WREADY(s_axi_control_WREADY),
        .BRESP(s_axi_control_BRESP), .BVALID(s_axi_control_BVALID), .BREADY(s_axi_control_BREADY),
        .ARADDR(s_axi_control_ARADDR), .ARVALID(s_axi_control_ARVALID), .ARREADY(s_axi_control_ARREADY),
        .RDATA(s_axi_control_RDATA), .RRESP(s_axi_control_RRESP),
        .RVALID(s_axi_control_RVALID), .RREADY(s_axi_control_RREADY),
        .interrupt(interrupt),
        .ap_start(ap_start), .ap_done(ap_done), .ap_ready(ap_ready), .ap_idle(ap_idle),
        .out_r(arg_out), .n_records(arg_nrec), .base_seed(arg_seed),
        .inv_temp(arg_itemp), .sample_mode(arg_smode));

    // ---------------- top control FSM ----------------
    // ap_ctrl_hs: a launch begins when ap_start is sampled high while idle; the run
    // ends with a 1-cycle ap_done/ap_ready pulse. The control slave clears its ap_start
    // register on ap_ready UNLESS auto-restart is set, in which case ap_start stays high
    // and the kernel must immediately re-launch (canonical Vitis behavior). We cannot see
    // int_auto_restart directly (it is internal to the control slave and not on its port
    // list), so we infer the decision from ap_start: after the ready pulse the slave has a
    // fixed, bounded window to update its start register; once it has settled, ap_start
    // still being high means "auto-restart -> re-launch", low means "single launch -> idle".
    localparam [2:0] S_IDLE = 3'd0, S_PREP = 3'd1, S_RUN = 3'd2, S_FIN = 3'd3, S_SETTLE = 3'd4;
    reg  [2:0]  state;
    reg         srst, wstart, run_en, done_p;
    reg  [1:0]  fin_wait;          // settle counter for the ap_start clear window
    reg  [63:0] r_out;
    reg  [31:0] r_nrec, r_seed, r_itemp, r_smode;
    wire        writer_done, writer_busy;

    // idle is only asserted between runs; during the post-done settle window the CU is
    // still "running" from XRT's perspective (ap_start has not yet been retired), so we
    // must NOT report idle there or a host could observe done+idle simultaneously.
    assign ap_idle  = (state == S_IDLE);
    assign ap_done  = done_p;
    assign ap_ready = done_p;

    // A launch is requested when ap_start is high in IDLE (fresh host launch) or still
    // high in FIN after the settle window (auto-restart held it). Plain combinational
    // decode -> unambiguously synthesizable (no task in the always block).
    wire launch_req = ((state == S_IDLE) || (state == S_FIN)) && ap_start;

    always @(posedge ap_clk) begin
        if (areset) begin
            state <= S_IDLE; srst <= 0; wstart <= 0; run_en <= 0; done_p <= 0;
            fin_wait <= 0;
            r_out <= 0; r_nrec <= 0; r_seed <= 0; r_itemp <= 0; r_smode <= 0;
        end else begin
            srst <= 0; wstart <= 0; done_p <= 0;
            case (state)
                S_IDLE: begin
                    if (launch_req) begin
                        r_out   <= arg_out;   r_nrec  <= arg_nrec;  r_seed <= arg_seed;
                        r_itemp <= arg_itemp; r_smode <= arg_smode;
                        srst    <= 1'b1;      // flush farm + FIFO, re-seed
                        run_en  <= 1'b1;
                        state   <= S_PREP;
                    end
                end
                S_PREP: begin
                    wstart <= 1'b1;       // start writer one cycle after srst
                    state  <= S_RUN;
                end
                S_RUN: if (writer_done) begin
                    done_p   <= 1'b1;     // -> ap_done/ap_ready pulse
                    run_en   <= 1'b0;
                    fin_wait <= 2'd3;     // let the control slave register ap_ready + update ap_start
                    state    <= S_SETTLE;
                end
                // Wait a fixed, bounded window for the control slave to retire (or hold,
                // under auto-restart) its ap_start register, then decide.
                S_SETTLE: if (fin_wait != 0) fin_wait <= fin_wait - 2'd1;
                          else               state    <= S_FIN;
                // ap_start low  => normal single launch complete -> idle.
                // ap_start high => auto-restart latched it -> re-launch immediately.
                S_FIN: begin
                    if (launch_req) begin
                        r_out   <= arg_out;   r_nrec  <= arg_nrec;  r_seed <= arg_seed;
                        r_itemp <= arg_itemp; r_smode <= arg_smode;
                        srst    <= 1'b1;
                        run_en  <= 1'b1;
                        state   <= S_PREP;
                    end else begin
                        state <= S_IDLE;
                    end
                end
                default: state <= S_IDLE;
            endcase
        end
    end

    // ---------------- farm + writer ----------------
    wire [175:0] rec_dout;
    wire         rec_empty, rec_rd_en;

    namegen_farm #(.NUM_GEN(NUM_GEN), .MAX_LEN(16), .FIFO_AW(6), .PAY_W(176)) u_farm (
        .clk(ap_clk), .resetn(ap_rst_n), .srst(srst), .run_en(run_en),
        .base_seed(r_seed), .inv_temp(r_itemp[15:0]), .sample_mode(r_smode[0]),
        .rec_dout(rec_dout), .rec_empty(rec_empty), .rec_rd_en(rec_rd_en));

    axi_write_master #(
        .ADDR_WIDTH(C_M_AXI_GMEM_ADDR_WIDTH), .DATA_WIDTH(C_M_AXI_GMEM_DATA_WIDTH),
        .ID_WIDTH(C_M_AXI_GMEM_ID_WIDTH), .PAY_W(176)
    ) u_writer (
        .clk(ap_clk), .resetn(ap_rst_n),
        .start(wstart), .base_addr(r_out), .n_records(r_nrec),
        .busy(writer_busy), .done(writer_done),
        .rec_dout(rec_dout), .rec_empty(rec_empty), .rec_rd_en(rec_rd_en),
        .awid(m_axi_gmem_AWID), .awaddr(m_axi_gmem_AWADDR), .awlen(m_axi_gmem_AWLEN),
        .awsize(m_axi_gmem_AWSIZE), .awburst(m_axi_gmem_AWBURST),
        .awvalid(m_axi_gmem_AWVALID), .awready(m_axi_gmem_AWREADY),
        .wdata(m_axi_gmem_WDATA), .wstrb(m_axi_gmem_WSTRB), .wlast(m_axi_gmem_WLAST),
        .wvalid(m_axi_gmem_WVALID), .wready(m_axi_gmem_WREADY),
        .bid(m_axi_gmem_BID), .bresp(m_axi_gmem_BRESP),
        .bvalid(m_axi_gmem_BVALID), .bready(m_axi_gmem_BREADY));

    // unused AW attributes + entire read channel tied off
    assign m_axi_gmem_AWLOCK   = 2'b00;
    assign m_axi_gmem_AWCACHE  = 4'b0011;   // normal non-cacheable bufferable
    assign m_axi_gmem_AWPROT   = 3'b000;
    assign m_axi_gmem_AWQOS    = 4'b0000;
    assign m_axi_gmem_AWREGION = 4'b0000;
    assign m_axi_gmem_ARID     = {C_M_AXI_GMEM_ID_WIDTH{1'b0}};
    assign m_axi_gmem_ARADDR   = {C_M_AXI_GMEM_ADDR_WIDTH{1'b0}};
    assign m_axi_gmem_ARLEN    = 8'd0;
    assign m_axi_gmem_ARSIZE   = 3'd0;
    assign m_axi_gmem_ARBURST  = 2'b01;
    assign m_axi_gmem_ARLOCK   = 2'b00;
    assign m_axi_gmem_ARCACHE  = 4'b0011;
    assign m_axi_gmem_ARPROT   = 3'b000;
    assign m_axi_gmem_ARQOS    = 4'b0000;
    assign m_axi_gmem_ARREGION = 4'b0000;
    assign m_axi_gmem_ARVALID  = 1'b0;
    assign m_axi_gmem_RREADY   = 1'b0;
endmodule
`default_nettype wire
