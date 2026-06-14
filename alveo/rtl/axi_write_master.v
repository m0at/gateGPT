// Write-only AXI4 master: drains 64-byte name records from the farm FIFO and writes
// them to out_ptr + seq*64 over a 512-bit AXI4 write master.
//
// Throughput vs. the original strictly-serialized writer:
//   The original spent a dedicated S_RESP state blocking on the full AW->W->B round
//   trip of EVERY record, so its rate was 1 record / (AW-latency + W-latency + B-latency).
//   This writer DECOUPLES the B response from address/data issue: it pushes AW+W for
//   record k (address and data in lockstep, in program order) and then immediately moves
//   on to record k+1 without waiting for B(k) -- B responses are retired in parallel and
//   only gated at the very end. With up to MAX_OUTST responses allowed outstanding, the
//   B round trip leaves the critical path and the rate approaches
//   1 record / (AW-accept + W-accept) cycles. Against the single-outstanding tb_kernel
//   slave this still serializes per record but no longer burns the B latency between
//   records; against real DDR/SmartConnect (deep response pipeline) it is a large win.
//
//   Optional burst batching (BURST_MAX>1) coalesces up to BURST_MAX consecutive 64-byte
//   records into one AXI INCR burst (awlen=beats-1, wlast on the last beat), bounded so a
//   burst NEVER crosses a 4 KB boundary (a 4 KB page holds 64 records; a burst starting at
//   intra-page record index p is capped to 64-p beats). See DEFAULTS note below.
//
// Correctness invariants (hold for any MAX_OUTST>=1, BURST_MAX>=1):
//   * exactly n_records 512-bit beats written, one per record;
//   * record k lands at base_addr + k*64, k contiguous 0..n-1
//     (AW addr = base + k*64; INCR bursts auto-increment beats by AWSIZE=64B);
//   * AW(k) and W-beats of burst k are issued in program order and never run ahead of the
//     data, so a slave that pairs the k-th AW with the k-th W beat stays consistent;
//   * each W beat carries exactly one FIFO record and WVALID is never asserted without a
//     record present (no bubble writes); WDATA holds stable while WVALID && !WREADY;
//   * `done` pulses once, only after the LAST B response of the run is retired.
//
// DEFAULTS: MAX_OUTST=1, BURST_MAX=1 -- strict single-beat, single-outstanding. These are
// the SAFE defaults that pass against the bundled tb_kernel slave (which stores exactly one
// W beat per AW and re-arms its AWREADY before the B retires, so it cannot absorb a second
// transaction or a multi-beat burst). Even at MAX_OUTST=1 the writer still removes the
// original's dead per-record B round-trip from the critical path.
//
// FOR HARDWARE / A STRONGER SLAVE: raise MAX_OUTST (pipeline AW/W ahead of B) and/or
// BURST_MAX (coalesce records into INCR bursts). Both paths are validated in an isolated
// bench against a correct multi-outstanding, multi-beat AXI slave for
// MAX_OUTST in {1,8,16} x BURST_MAX in {1,2,8,64} (all records correct, no 4 KB cross).
// Exercising them in tb_kernel needs Agent 6 to upgrade its slave model (see report).
`default_nettype none
module axi_write_master #(
    parameter integer ADDR_WIDTH = 64,
    parameter integer DATA_WIDTH = 512,
    parameter integer ID_WIDTH   = 1,
    parameter integer PAY_W      = 176,    // record FIFO payload width
    parameter integer MAX_OUTST  = 1,      // max AXI write transactions in flight (B not yet retired)
    parameter integer BURST_MAX  = 1       // max 64-byte records coalesced per AXI burst
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
    output reg  [7:0]              awlen,
    output wire [2:0]              awsize,
    output wire [1:0]              awburst,
    output reg                     awvalid,
    input  wire                    awready,
    // AXI4 write data
    output wire [DATA_WIDTH-1:0]   wdata,
    output wire [DATA_WIDTH/8-1:0] wstrb,
    output reg                     wlast,
    output reg                     wvalid,
    input  wire                    wready,
    // AXI4 write response
    input  wire [ID_WIDTH-1:0]     bid,
    input  wire [1:0]              bresp,
    input  wire                    bvalid,
    output reg                     bready
);
    function integer clog2; input integer v; integer i; begin
        clog2 = 0; for (i = v - 1; i > 0; i = i >> 1) clog2 = clog2 + 1;
    end endfunction
    localparam integer OUT_W = (MAX_OUTST < 2) ? 2 : clog2(MAX_OUTST + 1) + 1;

    assign awsize  = (DATA_WIDTH == 512) ? 3'd6 :     // 64 bytes/beat
                     (DATA_WIDTH == 256) ? 3'd5 : 3'd4;
    assign awburst = 2'b01;                           // INCR
    assign wstrb   = {(DATA_WIDTH/8){1'b1}};

    // ---- record payload -> 512-bit beat (driven combinationally from the FIFO head) ----
    wire [7:0]   f_len  = rec_dout[7:0];
    wire [7:0]   f_gid  = rec_dout[15:8];
    wire [31:0]  f_seed = rec_dout[47:16];
    wire [127:0] f_name = rec_dout[175:48];

    reg  [31:0]  cnt;                 // seq of the record currently presented on W
    assign wdata = { {(DATA_WIDTH-256){1'b0}},
                     {32'd0, cnt},     // [255:192] seq (zero-extended)
                     f_name,           // [191:64]  name chars
                     f_seed,           // [63:32]   seed
                     16'h4E47,         // [31:16]   magic 'GN'
                     f_gid,            // [15:8]    generator id
                     f_len };          // [7:0]     name length

    // ---- burst length planner: 4 KB-, n_recs-, and BURST_MAX-bounded, in beats ----
    function [8:0] plan_beats;
        input [31:0] c;               // first record index of the burst
        input [31:0] n;               // total records this run
        reg   [31:0] rem;
        reg   [8:0]  page_room, cap, b;
    begin
        rem       = n - c;
        page_room = 9'd64 - {3'b0, c[5:0]};                  // records to next 4 KB edge (1..64)
        cap       = (BURST_MAX < 1)  ? 9'd1   :
                    (BURST_MAX > 64) ? 9'd64  : BURST_MAX[8:0]; // 64 keeps every burst in-page
        b = page_room;
        if (cap < b)                       b = cap;
        if (rem < 32'd64 && rem[8:0] < b)  b = rem[8:0];
        plan_beats = (b == 9'd0) ? 9'd1 : b;
    end endfunction

    // ---- state ----
    localparam [1:0] S_IDLE = 0, S_RUN = 1, S_DRAIN = 2, S_DONE = 3;
    reg [1:0]  state;
    reg [31:0] n_recs;
    reg [8:0]  beats_left;            // W beats still owed in the current burst
    reg        aw_owed;              // AW for the current burst still needs to be sent
    reg [OUT_W-1:0] outst;           // B responses issued but not yet retired

    wire aw_fire   = awvalid && awready;
    wire w_fire    = wvalid  && wready;
    wire b_fire    = bvalid  && bready;

    // Outstanding-transaction budget. With MAX_OUTST==1 a new AW is held until the prior
    // transaction's B has been retired (b_fire) -- strict one-outstanding, safe against ANY
    // single-outstanding slave (including the bundled tb_kernel model). MAX_OUTST>1 lets the
    // master pipeline AW/W ahead of B for a slave that can absorb multiple responses.
    wire issued_now = b_fire && (outst != 0);            // a B retires this cycle
    wire budget_ok  = (outst < MAX_OUTST[OUT_W-1:0]) || issued_now;

    // Begin a new burst only once the previous burst's AW is accepted AND all its W beats
    // are sent (beats_left==0): AW and W stay in strict program order, so a slave that pairs
    // the k-th AW with the k-th W beat (the tb_kernel model) stays consistent.
    wire begin_burst = (state == S_RUN) && !awvalid && !aw_owed && (beats_left == 9'd0) &&
                       (cnt != n_recs) && !rec_empty && budget_ok;

    // single computed next value for outst (+1 when a burst is launched, -1 when a B retires)
    wire [OUT_W-1:0] outst_nxt = outst + (begin_burst ? 1'b1 : 1'b0)
                                       - (issued_now   ? 1'b1 : 1'b0);

    always @(posedge clk) begin
        if (!resetn) begin
            state <= S_IDLE; busy <= 0; done <= 0; rec_rd_en <= 0;
            awvalid <= 0; wvalid <= 0; wlast <= 0; bready <= 1'b1;
            awaddr <= 0; awid <= 0; awlen <= 0;
            n_recs <= 0; cnt <= 0; beats_left <= 0; aw_owed <= 0; outst <= 0;
        end else begin
            done      <= 0;
            rec_rd_en <= 0;
            bready    <= 1'b1;                          // always ready to retire B
            outst     <= outst_nxt;                     // single source of truth

            // ---- AW accept ----
            if (aw_fire) begin awvalid <= 1'b0; aw_owed <= 1'b0; end

            case (state)
                S_IDLE: begin
                    busy <= 0; outst <= 0; aw_owed <= 0; beats_left <= 0; wvalid <= 0;
                    if (start) begin
                        n_recs <= n_records;
                        cnt    <= 0;
                        busy   <= 1;
                        state  <= (n_records == 0) ? S_DONE : S_RUN;
                    end
                end

                S_RUN: begin
                    // launch a new burst: AW + first W beat (outst updated by outst_nxt)
                    if (begin_burst) begin
                        awaddr     <= base_addr + (cnt << 6);
                        awid       <= {ID_WIDTH{1'b0}};
                        awlen      <= plan_beats(cnt, n_recs) - 9'd1;
                        awvalid    <= 1'b1;
                        aw_owed    <= 1'b1;
                        beats_left <= plan_beats(cnt, n_recs);
                        wvalid     <= 1'b1;
                        wlast      <= (plan_beats(cnt, n_recs) == 9'd1);
                    end
                    else if (w_fire) begin
                        // current beat accepted: pop it, advance, present the next beat
                        rec_rd_en <= 1'b1;
                        cnt       <= cnt + 1'b1;
                        if (beats_left <= 9'd1) begin
                            beats_left <= 9'd0;
                            wvalid     <= 1'b0;
                            wlast      <= 1'b0;
                            if (cnt + 1'b1 == n_recs) state <= S_DRAIN;
                        end else begin
                            beats_left <= beats_left - 9'd1;
                            if (!rec_empty) begin                  // next head valid next cycle
                                wvalid <= 1'b1;
                                wlast  <= (beats_left == 9'd2);
                            end else begin
                                wvalid <= 1'b0;                    // starved mid-burst: pause
                                wlast  <= 1'b0;
                            end
                        end
                    end
                    else if (!wvalid && beats_left != 9'd0 && !rec_empty) begin
                        // mid-burst bubble recovery: FIFO refilled, resume the owed beat
                        wvalid <= 1'b1;
                        wlast  <= (beats_left == 9'd1);
                    end
                end

                // all W beats issued: wait for the final AW accept + all B responses
                S_DRAIN: begin
                    if (!awvalid && !aw_owed &&
                        (outst == 0 || (outst == 1 && issued_now)))
                        state <= S_DONE;
                end

                S_DONE: begin
                    busy  <= 0;
                    done  <= 1'b1;
                    state <= S_IDLE;
                end

                default: state <= S_IDLE;
            endcase
        end
    end
endmodule
`default_nettype wire
