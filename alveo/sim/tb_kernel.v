// End-to-end self-test for the packaged kernel RTL: drives s_axi_control like XRT would
// (set args via the register map, write ap_start), models global memory as an AXI4 slave,
// and checks the exact 64-byte records the host will read back. Validates the control
// register OFFSETS (must match krnl_namegen.xml), the ap_ctrl_hs handshake, the AXI4 write
// master protocol, and the in-memory record layout.
//
//   iverilog -g2012 -o /tmp/tb_kernel -s tb_kernel alveo/sim/tb_kernel.v \
//     alveo/rtl/krnl_namegen.v alveo/rtl/krnl_namegen_control_s_axi.v \
//     alveo/rtl/namegen_farm.v alveo/rtl/axi_write_master.v alveo/rtl/record_fifo.v \
//     alveo/gen_src/*.v
//   vvp /tmp/tb_kernel
`timescale 1ns/1ps
module tb_kernel;
    localparam integer NUM_GEN = 2;
    localparam integer NREC    = 16;
    localparam [63:0]  BASE    = 64'h0000_0004_0000_0000;  // tests OUT_0 and OUT_1 regs

    // control reg offsets (mirror krnl_namegen.xml)
    localparam [11:0] A_CTRL=12'h00, A_OUT0=12'h10, A_OUT1=12'h14,
                      A_NREC=12'h1C, A_SEED=12'h24, A_ITEMP=12'h2C, A_SMODE=12'h34;

    reg clk = 0, rstn = 0;
    always #5 clk = ~clk;

    // ---- AXI4-Lite control ----
    reg  [11:0] s_AWADDR, s_ARADDR; reg [31:0] s_WDATA; reg [3:0] s_WSTRB;
    reg  s_AWVALID, s_WVALID, s_BREADY, s_ARVALID, s_RREADY;
    wire s_AWREADY, s_WREADY, s_BVALID, s_ARREADY, s_RVALID;
    wire [1:0] s_BRESP, s_RRESP; wire [31:0] s_RDATA; wire irq;

    // ---- AXI4 master (gmem) ----
    wire [0:0]   m_AWID, m_ARID;
    wire [63:0]  m_AWADDR, m_ARADDR;
    wire [7:0]   m_AWLEN, m_ARLEN;
    wire [2:0]   m_AWSIZE, m_ARSIZE;
    wire [1:0]   m_AWBURST, m_ARBURST, m_AWLOCK, m_ARLOCK;
    wire [3:0]   m_AWCACHE, m_ARCACHE, m_AWQOS, m_ARQOS, m_AWREGION, m_ARREGION;
    wire [2:0]   m_AWPROT, m_ARPROT;
    wire         m_AWVALID, m_WVALID, m_BREADY, m_ARVALID, m_RREADY;
    reg          m_AWREADY, m_WREADY, m_BVALID, m_ARREADY, m_RVALID;
    wire [511:0] m_WDATA; wire [63:0] m_WSTRB; wire m_WLAST;
    reg  [0:0]   m_BID; reg [1:0] m_BRESP;

    krnl_namegen #(.NUM_GEN(NUM_GEN)) dut (
        .ap_clk(clk), .ap_rst_n(rstn), .interrupt(irq),
        .s_axi_control_AWVALID(s_AWVALID), .s_axi_control_AWREADY(s_AWREADY), .s_axi_control_AWADDR(s_AWADDR),
        .s_axi_control_WVALID(s_WVALID), .s_axi_control_WREADY(s_WREADY), .s_axi_control_WDATA(s_WDATA), .s_axi_control_WSTRB(s_WSTRB),
        .s_axi_control_ARVALID(s_ARVALID), .s_axi_control_ARREADY(s_ARREADY), .s_axi_control_ARADDR(s_ARADDR),
        .s_axi_control_RVALID(s_RVALID), .s_axi_control_RREADY(s_RREADY), .s_axi_control_RDATA(s_RDATA), .s_axi_control_RRESP(s_RRESP),
        .s_axi_control_BVALID(s_BVALID), .s_axi_control_BREADY(s_BREADY), .s_axi_control_BRESP(s_BRESP),
        .m_axi_gmem_AWID(m_AWID), .m_axi_gmem_AWADDR(m_AWADDR), .m_axi_gmem_AWLEN(m_AWLEN),
        .m_axi_gmem_AWSIZE(m_AWSIZE), .m_axi_gmem_AWBURST(m_AWBURST), .m_axi_gmem_AWLOCK(m_AWLOCK),
        .m_axi_gmem_AWCACHE(m_AWCACHE), .m_axi_gmem_AWPROT(m_AWPROT), .m_axi_gmem_AWQOS(m_AWQOS),
        .m_axi_gmem_AWREGION(m_AWREGION), .m_axi_gmem_AWVALID(m_AWVALID), .m_axi_gmem_AWREADY(m_AWREADY),
        .m_axi_gmem_WDATA(m_WDATA), .m_axi_gmem_WSTRB(m_WSTRB), .m_axi_gmem_WLAST(m_WLAST),
        .m_axi_gmem_WVALID(m_WVALID), .m_axi_gmem_WREADY(m_WREADY),
        .m_axi_gmem_BID(m_BID), .m_axi_gmem_BRESP(m_BRESP), .m_axi_gmem_BVALID(m_BVALID), .m_axi_gmem_BREADY(m_BREADY),
        .m_axi_gmem_ARID(m_ARID), .m_axi_gmem_ARADDR(m_ARADDR), .m_axi_gmem_ARLEN(m_ARLEN),
        .m_axi_gmem_ARSIZE(m_ARSIZE), .m_axi_gmem_ARBURST(m_ARBURST), .m_axi_gmem_ARLOCK(m_ARLOCK),
        .m_axi_gmem_ARCACHE(m_ARCACHE), .m_axi_gmem_ARPROT(m_ARPROT), .m_axi_gmem_ARQOS(m_ARQOS),
        .m_axi_gmem_ARREGION(m_ARREGION), .m_axi_gmem_ARVALID(m_ARVALID), .m_axi_gmem_ARREADY(m_ARREADY),
        .m_axi_gmem_RID(1'b0), .m_axi_gmem_RDATA(512'd0), .m_axi_gmem_RRESP(2'd0),
        .m_axi_gmem_RLAST(1'b0), .m_axi_gmem_RVALID(1'b0), .m_axi_gmem_RREADY(m_RREADY));

    // ---- behavioral AXI4 write slave (single outstanding) ----
    reg [511:0] gmem [0:2047];
    reg [63:0]  aw_addr_q; reg aw_have, b_pend;
    integer     wbeats = 0;                 // total write beats (to catch spurious re-launch)
    always @(posedge clk) begin
        if (!rstn) begin aw_have<=0; b_pend<=0; m_AWREADY<=1; m_WREADY<=0; m_BVALID<=0; m_BRESP<=0; m_BID<=0; end
        else begin
            // AW
            if (m_AWVALID && m_AWREADY) begin aw_addr_q<=m_AWADDR; aw_have<=1; m_AWREADY<=0; end
            // W
            m_WREADY <= aw_have && !b_pend;
            if (m_WVALID && m_WREADY) begin
                gmem[(aw_addr_q - BASE) >> 6] <= m_WDATA;
                aw_have<=0; b_pend<=1; m_AWREADY<=1;
                wbeats = wbeats + 1;
            end
            // B
            m_BVALID <= b_pend;
            if (m_BVALID && m_BREADY) begin b_pend<=0; m_BVALID<=0; end
        end
    end
    // AR/R unused
    always @(*) begin m_ARREADY=0; m_RVALID=0; end

    // ---- AXI4-Lite master BFM ----
    task axil_write(input [11:0] a, input [31:0] d);
    begin
        @(posedge clk);
        s_AWADDR=a; s_AWVALID=1; s_WDATA=d; s_WSTRB=4'hf; s_WVALID=1; s_BREADY=1;
        wait (s_AWREADY); @(posedge clk); s_AWVALID=0;
        wait (s_WREADY);  @(posedge clk); s_WVALID=0;
        wait (s_BVALID);  @(posedge clk); s_BREADY=0;
    end endtask

    task axil_read(input [11:0] a, output [31:0] d);
    begin
        @(posedge clk);
        s_ARADDR=a; s_ARVALID=1; s_RREADY=1;
        wait (s_ARREADY); @(posedge clk); s_ARVALID=0;
        wait (s_RVALID);  d=s_RDATA; @(posedge clk); s_RREADY=0;
    end endtask

    // ---- decode + check ----
    integer i, k, fails, n_diff; reg [31:0] rd; reg [511:0] rec;
    reg [7:0] len, gid, ch; reg [15:0] magic; reg [31:0] seed; reg [63:0] seq;
    reg [8*16-1:0] str; reg [127:0] first_name;

    // program args + ap_start, then poll ap_done
    task do_launch(input [31:0] seed_v, input [31:0] smode);
    begin
        axil_write(A_OUT0,  BASE[31:0]);
        axil_write(A_OUT1,  BASE[63:32]);
        axil_write(A_NREC,  NREC);
        axil_write(A_SEED,  seed_v);
        axil_write(A_ITEMP, 32'd2926);     // 1/0.7 Q5.11
        axil_write(A_SMODE, smode);
        axil_write(A_CTRL,  32'd1);        // ap_start
        rd = 0;
        for (i = 0; i < 400000 && !rd[1]; i = i + 1) axil_read(A_CTRL, rd);
        if (!rd[1]) begin $display("KERNEL FAIL: ap_done never asserted"); $finish; end
    end endtask

    // verify the NREC records the launch wrote; greedy => all 'alaya'
    task check(input greedy);
    begin
        n_diff = 0;
        for (k = 0; k < NREC; k = k + 1) begin
            rec = gmem[k]; len = rec[7:0]; gid = rec[15:8];
            magic = rec[31:16]; seed = rec[63:32]; seq = rec[255:192];
            str = 0;
            for (i = 0; i < 16; i = i + 1) begin
                ch = rec[64 + i*8 +: 8];
                if (i < len) str[(15-i)*8 +: 8] = "a" + ch;
            end
            if (magic !== 16'h4E47)            fails = fails + 1;
            if (seq   !== k)                   fails = fails + 1;
            if (gid   >= NUM_GEN)              fails = fails + 1;
            if (len < 8'd1 || len > 8'd16)     fails = fails + 1;
            if (greedy) begin
                if (len !== 8'd5)              fails = fails + 1;
                if (rec[64+0*8 +:8]!==0 || rec[64+1*8 +:8]!==11 || rec[64+2*8 +:8]!==0 ||
                    rec[64+3*8 +:8]!==24 || rec[64+4*8 +:8]!==0) fails = fails + 1;
            end
            if (k == 0) first_name = rec[191:64];
            else if (rec[191:64] !== first_name) n_diff = n_diff + 1;
            if (k < 6) $display("  gmem[%0d] seq=%0d gid=%0d len=%0d magic=%04x seed=%08x name=%s",
                                k, seq, gid, len, magic, seed, str);
        end
        if (!greedy && n_diff == 0) begin
            $display("KERNEL FAIL: sampled launch produced no variety"); fails = fails + 1;
        end
    end endtask

    initial begin
        s_AWVALID=0; s_WVALID=0; s_BREADY=0; s_ARVALID=0; s_RREADY=0; s_WSTRB=0;
        s_AWADDR=0; s_ARADDR=0; s_WDATA=0; fails = 0;
        rstn=0; repeat (10) @(posedge clk); rstn=1; repeat (4) @(posedge clk);

        // launch 1: greedy
        $display("-- launch 1 (greedy) --");
        do_launch(32'h1234_5678, 32'd0);
        if (wbeats !== NREC) begin
            $display("KERNEL FAIL: launch wrote %0d beats, expected %0d (spurious re-trigger?)", wbeats, NREC);
            fails = fails + 1;
        end
        check(1'b1);

        // launch 2: sampled, re-arm with a new seed
        $display("-- launch 2 (sampled, re-arm) --");
        do_launch(32'hABCD_0001, 32'd1);
        if (wbeats !== 2*NREC) begin
            $display("KERNEL FAIL: after 2 launches wrote %0d beats, expected %0d", wbeats, 2*NREC);
            fails = fails + 1;
        end
        check(1'b0);

        if (fails == 0) $display("KERNEL PASS: 2 launches, %0d records each, offsets+handshake+re-arm OK", NREC);
        else            $display("KERNEL FAIL: %0d mismatches", fails);
        $finish;
    end

    initial begin #10_000_000; $display("KERNEL FAIL: global timeout"); $finish; end
endmodule
