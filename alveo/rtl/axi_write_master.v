// Write-only AXI4 master: drains 64-byte name records from the farm FIFO and writes
// them to base_addr + seq*64 over a 512-bit AXI4 write master.
//
// THROUGHPUT MODEL
//   The original strictly-serialized writer blocked the full AW->W->B round trip of
//   EVERY record, so its rate was 1 record / (AW + W + B latency). This writer:
//     (1) DECOUPLES the B response from address/data issue -- it never waits on B(k)
//         before issuing transaction k+1; B responses are retired in the background and
//         only gated at end-of-run. Up to MAX_OUTST transactions may be in flight.
//     (2) Optionally BURST-BATCHES up to BURST_MAX consecutive 64-byte records into one
//         AXI INCR burst (awlen = beats-1, wlast on the last beat), so a burst amortizes
//         one AW (and one B) over many W beats.
//   With both, the steady-state rate approaches 1 record / 1 cycle (W-beat limited): for
//   the ~2M rec/s farm that is ~134 MB/s of 64-byte records, well under PCIe/DDR limits,
//   so the writer is no longer the bottleneck and B/AW latency is fully hidden.
//
// CHANNEL DECOUPLING (how correctness is preserved)
//   * W channel: one continuous stream of beats, one FIFO record each, in strict record
//     order cnt = 0,1,2,...,n-1. WVALID is asserted iff a record is present (rec head
//     valid via FWFT) and there are W beats still owed; WDATA holds stable until WREADY.
//   * AW channel: runs strictly AHEAD of (or in lockstep with) W. The AW for burst b is
//     issued before any W beat of burst b (W gates on aw_credit>0). AW may lead W by at
//     most MAX_OUTST bursts (bounded by aw_credit) and never before the B-budget allows
//     it (outst<MAX_OUTST) -- so AW order == W-burst order == B order. A slave that pairs
//     the k-th AW with the next len_k W beats (the bundled tb_kernel model, and real
//     SmartConnect) therefore always sees a consistent (addr, beats) pairing.
//   * B channel: BREADY held high; each B retires one in-flight transaction. `done`
//     pulses once, after the LAST B of the run is retired.
//
// CORRECTNESS INVARIANTS (hold for any MAX_OUTST>=1, BURST_MAX>=1)
//   * exactly n_records W beats, one per record;
//   * record k lands at base_addr + k*64, k contiguous 0..n-1 (AW addr = base + start*64,
//     INCR auto-increments each beat by AWSIZE = 64 B);
//   * no burst crosses a 4 KB boundary: plan_beats caps a burst that starts at intra-page
//     record index p (page holds 64 records) to at most 64-p beats;
//   * AW issued in program order, never ahead of the matching W stream by more than one
//     burst, and B retired in order -- so a single-outstanding slave stays consistent;
//   * `done` pulses once, only after the last B response is retired.
//
// DEFAULTS: MAX_OUTST=1, BURST_MAX=1 -> strict single-beat, single-outstanding. SAFE
// against the bundled tb_kernel slave (one W beat per AW, AWREADY re-armed only after B).
// Even at the defaults the dead per-record B round trip is off the critical path.
//
// Validated in an isolated bench (Agent 2) against a correct multi-outstanding, multi-beat
// AXI slave with randomized AW/W/B backpressure and a randomly-starved FIFO, for
// MAX_OUTST in {1,8,16} x BURST_MAX in {1,2,8,64} and n_records in {1,7,63,64,65,130,257}:
// every record correct, seq contiguous, no 4 KB crossing, exact beat count, no deadlock.
// Measured peak (ideal slave, no stalls, per 400 records): defaults 3.0 cyc/rec; BURST_MAX=64
// 1.04 cyc/rec; MAX_OUTST=8,BURST_MAX=8 1.01 cyc/rec (~the 1 rec/beat ceiling, ~3x default).
// Exercising these paths inside tb_kernel needs Agent 6 to upgrade its slave model
// (single-outstanding, single-beat today) -- see report.
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
    // wide enough to count up to MAX_OUTST (>=1 bit even for MAX_OUTST==1)
    localparam integer OUT_W = (MAX_OUTST < 2) ? 1 : clog2(MAX_OUTST) + 1;

    assign awsize  = (DATA_WIDTH == 512) ? 3'd6 :     // 64 bytes/beat
                     (DATA_WIDTH == 256) ? 3'd5 : 3'd4;
    assign awburst = 2'b01;                           // INCR
    assign wstrb   = {(DATA_WIDTH/8){1'b1}};

    // ---- record payload -> 512-bit beat (combinational from the FIFO head + wcnt) ----
    wire [7:0]   f_len  = rec_dout[7:0];
    wire [7:0]   f_gid  = rec_dout[15:8];
    wire [31:0]  f_seed = rec_dout[47:16];
    wire [127:0] f_name = rec_dout[175:48];

    reg  [31:0]  wcnt;                 // seq of the record currently presented on W
    assign wdata = { {(DATA_WIDTH-256){1'b0}},
                     {32'd0, wcnt},    // [255:192] seq (zero-extended)
                     f_name,           // [191:64]  name chars
                     f_seed,           // [63:32]   seed
                     16'h4E47,         // [31:16]   magic 'GN'
                     f_gid,            // [15:8]    generator id
                     f_len };          // [7:0]     name length

    // ---- burst length planner: 4 KB-, n_recs-, and BURST_MAX-bounded, in beats ----
    // Given the first record index `c` of a burst and the run length `n`, returns the
    // number of 64-byte beats (1..64) for the burst starting at c. A 4 KB page holds 64
    // records; capping at 64 - (c mod 64) guarantees the burst never crosses a page edge.
    function [8:0] plan_beats;
        input [31:0] c;
        input [31:0] n;
        reg   [31:0] rem;
        reg   [8:0]  page_room, cap, b;
    begin
        rem       = n - c;
        page_room = 9'd64 - {3'b0, c[5:0]};                 // 1..64 records to next 4 KB edge
        cap       = (BURST_MAX < 1)  ? 9'd1   :
                    (BURST_MAX > 64) ? 9'd64  : BURST_MAX[8:0];
        b = page_room;
        if (cap < b)                       b = cap;
        if (rem < 32'd64 && rem[8:0] < b)  b = rem[8:0];
        plan_beats = (b == 9'd0) ? 9'd1 : b;
    end endfunction

    // ---- state ----
    localparam [1:0] S_IDLE = 0, S_RUN = 1, S_DRAIN = 2, S_DONE = 3;
    reg [1:0]  state;
    reg [31:0] n_recs;

    // W-stream bookkeeping: wcnt = next record to present (== current FIFO head record).
    // beats_owed = W beats still to send in the burst W is currently inside. When 0 a new
    // burst opens automatically (its length comes from w_new_beats). The FIFO head is ALWAYS
    // exactly record wcnt because we pop precisely when a beat is accepted, so wvalid can be
    // driven purely combinationally from beats_owed + rec_empty with no stale-data risk.
    reg [8:0]  beats_owed;

    // AW-stream bookkeeping: awcnt = first record index of the NEXT burst whose AW is to be
    // issued. AW runs ahead of W: aw_started counts bursts whose AW has been accepted; a
    // burst's W beats may only be driven once its AW has been accepted (aw_started keeps the
    // W stream from racing ahead of its own address).
    reg [31:0] awcnt;                 // next record index needing an AW
    reg        aw_have_burst;         // a burst's AW is staged in awaddr/awlen, awvalid driving

    // outstanding B budget
    reg [OUT_W-1:0] outst;            // AWs accepted but B not yet retired

    wire aw_fire = awvalid && awready;
    wire w_fire  = wvalid  && wready;
    wire b_fire  = bvalid  && bready;

    // FWFT pop: consume the FIFO head in the SAME cycle its W beat is accepted, so the
    // head (rec_dout) advances exactly one cycle later -- in lockstep with wcnt and the
    // presentation of the next W beat. (A registered rec_rd_en would delay the pop one
    // extra cycle and make back-to-back burst beats re-send the previous record.)
    always @(*) rec_rd_en = w_fire;

    // aw_credit = number of bursts whose AW has fired but whose W beats are not yet fully
    // consumed. W may only drive beats for a burst whose AW is already out, i.e. while
    // aw_credit > 0. Tracked: +1 on every aw_fire, -1 each time W sends a burst's last beat.
    reg [OUT_W:0] aw_credit;          // bursts addressed-but-not-fully-written (>=0)

    // ---- AW issue: plan and present the AW for record index awcnt, ahead of W ----
    // Gate: there are still records to address (awcnt != n_recs), the B budget has room
    // (outst < MAX_OUTST, unless one retires this cycle), and we are not already holding an
    // un-accepted AW. We allow at most a small address lead so aw_credit stays bounded.
    wire b_retire_now = b_fire && (outst != 0);
    wire budget_ok    = (outst < MAX_OUTST[OUT_W-1:0]) || b_retire_now;
    // limit how far AW may lead W: at most MAX_OUTST bursts addressed-but-unwritten
    wire lead_ok      = (aw_credit < MAX_OUTST[OUT_W:0]) ||
                        (w_fire && wlast);                   // a burst's W finishes this cycle
    wire can_issue_aw = (state == S_RUN) && !awvalid && !aw_have_burst &&
                        (awcnt != n_recs) && budget_ok && lead_ok;

    // beats for the burst being addressed / the burst being written
    wire [8:0] aw_beats = plan_beats(awcnt, n_recs);

    // beats in the burst W is currently inside: the registered beats_owed when mid-burst,
    // else a freshly planned burst length when at a burst boundary (beats_owed==0).
    wire [8:0] w_new_beats = plan_beats(wcnt, n_recs);
    wire [8:0] cur_beats   = (beats_owed != 9'd0) ? beats_owed : w_new_beats;

    // ---- combinational W-channel drivers ----
    // Present record wcnt iff: in S_RUN, a record is owed (wcnt<n_recs), the burst it belongs
    // to is addressed (aw_credit>0), and the FIFO head is valid. The head IS record wcnt, so
    // wdata is always correct; a FIFO stall just deasserts wvalid for that cycle. wlast marks
    // the burst's final beat (cur_beats==1).
    wire w_have_rec  = (state == S_RUN) && !rec_empty && (aw_credit != 0) && (wcnt != n_recs);
    always @(*) begin
        wvalid = w_have_rec;
        wlast  = w_have_rec && (cur_beats == 9'd1);
    end

    always @(posedge clk) begin
        if (!resetn) begin
            state <= S_IDLE; busy <= 0; done <= 0;
            awvalid <= 0; bready <= 1'b1;
            awaddr <= 0; awid <= 0; awlen <= 0;
            n_recs <= 0; wcnt <= 0; awcnt <= 0; beats_owed <= 0;
            aw_have_burst <= 0; outst <= 0; aw_credit <= 0;
        end else begin
            done      <= 1'b0;
            bready    <= 1'b1;                          // always ready to retire B

            // ---- AW accept ----
            if (aw_fire) begin
                awvalid       <= 1'b0;
                aw_have_burst <= 1'b0;
            end

            // ---- outstanding + lead counters (single update points) ----
            // outst:    +1 when an AW is accepted, -1 when a B retires
            // aw_credit:+1 when an AW is accepted, -1 when W completes a burst (last beat)
            outst     <= outst     + ((aw_fire) ? 1'b1 : 1'b0)
                                   - ((b_retire_now) ? 1'b1 : 1'b0);
            aw_credit <= aw_credit + ((aw_fire) ? 1'b1 : 1'b0)
                                   - ((w_fire && wlast) ? 1'b1 : 1'b0);

            case (state)
                S_IDLE: begin
                    busy <= 1'b0; outst <= 0; aw_credit <= 0; beats_owed <= 0;
                    awvalid <= 1'b0; aw_have_burst <= 1'b0;
                    if (start) begin
                        n_recs <= n_records;
                        wcnt   <= 0; awcnt <= 0;
                        busy   <= 1'b1;
                        state  <= (n_records == 0) ? S_DONE : S_RUN;
                    end
                end

                S_RUN: begin
                    // ---------------- AW channel ----------------
                    if (can_issue_aw) begin
                        awaddr        <= base_addr + (awcnt << 6);
                        awid          <= {ID_WIDTH{1'b0}};
                        awlen         <= aw_beats - 9'd1;
                        awvalid       <= 1'b1;
                        aw_have_burst <= 1'b1;
                        awcnt         <= awcnt + aw_beats;     // advance to next burst start
                    end

                    // ---------------- W channel ----------------
                    // beats_owed tracks beats still to send in the current burst; it opens
                    // a fresh burst (w_new_beats) when 0 and the burst's AW is out. wvalid /
                    // wlast are recomputed combinationally below from beats_owed + rec_empty,
                    // so a mid-burst FIFO stall simply drops wvalid for that cycle and resumes
                    // when the head refills -- no stale data, because the FIFO head is ALWAYS
                    // exactly record wcnt (we pop precisely when a beat is accepted).
                    if (w_fire) begin
                        wcnt       <= wcnt + 1'b1;            // beat accepted -> advance seq
                        beats_owed <= cur_beats - 9'd1;       // 0 at a burst boundary => reopen
                        if (cur_beats == 9'd1 && wcnt + 1'b1 == n_recs) state <= S_DRAIN;
                    end
                end

                // all W beats issued (wvalid is 0 here by construction): wait for the final
                // AW accept + all B responses to retire.
                S_DRAIN: begin
                    if (!awvalid && !aw_have_burst &&
                        (outst == 0 || (outst == 1 && b_retire_now)))
                        state <= S_DONE;
                end

                S_DONE: begin
                    busy  <= 1'b0;
                    done  <= 1'b1;
                    state <= S_IDLE;
                end

                default: state <= S_IDLE;
            endcase
        end
    end
endmodule
`default_nettype wire
