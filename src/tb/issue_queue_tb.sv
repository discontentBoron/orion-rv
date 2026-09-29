`timescale 1ns / 1ps
import orion_pkg::*;

module issue_queue_tb;

  // -----------------------------------------------------------------------
  // DUT signals
  // -----------------------------------------------------------------------
  logic                                 clk;
  logic                                 rst_n;
  rename_dispatch_pkt_s                 dispatch_in;
  logic                 [  ROB_PTR-1:0] dispatch_rob_tag;
  logic                                 iq_full;
  logic                                 rob_full;
  logic          [NUM_CDB_PORTS-1:0]    cdb_valid;
  logic [TAG_WIDTH-1:0]                 cdb_p_dest    [NUM_CDB_PORTS];
  logic                                 branch_mispredict;
  logic                                 exception_valid;
  logic                                 div_ready;
  logic                                 lsu_ready;
  logic                                 issue_valid;
  rename_dispatch_pkt_s                 issue_pkt;
  logic                 [  ROB_PTR-1:0] issue_rob_tag;

  // -----------------------------------------------------------------------
  // DUT instantiation
  // -----------------------------------------------------------------------
  issue_queue dut (
      .clk              (clk),
      .rst_n            (rst_n),
      .dispatch_in      (dispatch_in),
      .dispatch_rob_tag (dispatch_rob_tag),
      .iq_full          (iq_full),
      .rob_full         (rob_full),
      .cdb_valid        (cdb_valid),
      .cdb_p_dest       (cdb_p_dest),
      .branch_mispredict(branch_mispredict),
      .exception_valid  (exception_valid),
      .div_ready        (div_ready),
      .lsu_ready        (lsu_ready),
      .issue_valid      (issue_valid),
      .issue_pkt        (issue_pkt),
      .issue_rob_tag    (issue_rob_tag)
  );

  // -----------------------------------------------------------------------
  // Clock : 10ns period
  // -----------------------------------------------------------------------
  initial clk = 0;
  always #5 clk = ~clk;

  // -----------------------------------------------------------------------
  // Test bookkeeping
  // -----------------------------------------------------------------------
  int pass_count = 0;
  int fail_count = 0;

  task automatic check(input string test_name, input logic condition);
    if (condition) begin
      $display("  PASS: %s", test_name);
      pass_count++;
    end else begin
      $display("  FAIL: %s", test_name);
      fail_count++;
    end
  endtask

  // -----------------------------------------------------------------------
  // Timing model : READ THIS BEFORE WRITING MORE TESTS
  //
  // issue_valid / issue_pkt are COMBINATIONAL. The instant any_ready goes
  // high, they reflect it : no clock edge needed. The entry is consumed
  // (invalidated) at the NEXT posedge after any_ready went high, whether
  // or not the testbench ever samples it in between.
  //
  // Consequence: after any action that makes an entry valid+ready visible
  // (i.e. right after the @(negedge clk) that follows the triggering
  // posedge), check issue_valid IMMEDIATELY : do not add another
  // @(negedge clk) first, or you will sample after the entry has already
  // been issued and swept away.
  //
  // A second consequence: if entry X is already ready and entry Y is
  // dispatched (or woken) on some later cycle, X gets consumed on that
  // SAME posedge, concurrently with Y's write. Ready entries do not
  // "wait around" for you to get to them.
  //
  // CDB is now NUM_CDB_PORTS-wide (was a single scalar port). drive_cdb()
  // takes an optional port index (default 0) so every pre-existing call
  // below still compiles and behaves exactly as before -- it's just
  // always exercising port 0 unless a test says otherwise. div_ready and
  // lsu_ready are new busy/idle inputs from the DIV and LSU execution
  // units; they default to 1 (idle) in reset_dut() so none of the
  // pre-existing tests are affected by their addition.
  // -----------------------------------------------------------------------

  // -----------------------------------------------------------------------
  // Helpers
  // -----------------------------------------------------------------------
  task automatic reset_dut();
    rst_n             = 0;
    dispatch_in       = '0;
    dispatch_rob_tag  = '0;
    cdb_valid         = '0;
    cdb_p_dest        = '{default: '0};
    branch_mispredict = 0;
    exception_valid   = 0;
    rob_full          = 0;
    div_ready         = 1;
    lsu_ready         = 1;
    @(negedge clk);
    @(negedge clk);
    rst_n = 1;
    @(negedge clk);
  endtask

  // Drive a dispatch packet. Sources not ready by default.
  task automatic drive_dispatch(
      input logic [TAG_WIDTH-1:0] p_src1, input logic [TAG_WIDTH-1:0] p_src2,
      input logic src1_valid, input logic src2_valid, input logic src1_rdy, input logic src2_rdy,
      input logic [TAG_WIDTH-1:0] p_dest, input logic [TAG_WIDTH-1:0] old_p_dest,
      input logic [ROB_PTR-1:0] rob_tag);
    dispatch_in.valid          = 1'b1;
    dispatch_in.p_src1         = p_src1;
    dispatch_in.p_src2         = p_src2;
    dispatch_in.p_src1_valid   = src1_valid;
    dispatch_in.p_src2_valid   = src2_valid;
    dispatch_in.p_src1_rdy     = src1_rdy;
    dispatch_in.p_src2_rdy     = src2_rdy;
    dispatch_in.p_dest         = p_dest;
    dispatch_in.old_p_dest     = old_p_dest;
    dispatch_in.reg_we         = 1'b1;
    dispatch_in.except         = 1'b0;
    dispatch_in.except_cause   = EXCEPT_NONE;
    dispatch_in.instr_class    = INSTR_ALU;
    dispatch_in.func_unit_type = FU_ALU;
    dispatch_in.exec_unit_uop  = ADD;
    dispatch_in.imm_val        = 32'h0;
    dispatch_in.pc             = 32'h1000;
    dispatch_in.predicted_pc   = 32'h1004;
    dispatch_rob_tag           = rob_tag;
  endtask

  task automatic clear_dispatch();
    dispatch_in      = '0;
    dispatch_rob_tag = '0;
  endtask

  // port defaults to 0 so every pre-existing call site is unchanged.
  task automatic drive_cdb(input logic [TAG_WIDTH-1:0] p_dest, input int port = 0);
    cdb_valid[port]  = 1;
    cdb_p_dest[port] = p_dest;
  endtask

  task automatic clear_cdb();
    cdb_valid  = '0;
    cdb_p_dest = '{default: '0};
  endtask

  // -----------------------------------------------------------------------
  // TEST 1:  Reset state
  // -----------------------------------------------------------------------
  task automatic test_reset();
    $display("\nTEST 1: Reset state");
    reset_dut();
    check("iq_full=0 after reset", iq_full == 1'b0);
    check("issue_valid=0 after reset", issue_valid == 1'b0);
  endtask

  // -----------------------------------------------------------------------
  // TEST 2: Dispatch with both sources ready, issue is immediate
  // (combinational) the cycle the entry becomes visible
  // -----------------------------------------------------------------------
  task automatic test_dispatch_ready_issue();
    $display("\nTEST 2: Dispatch sources ready, issue same cycle entry is visible");
    reset_dut();

    drive_dispatch(.p_src1(6'd10), .p_src2(6'd11), .src1_valid(1), .src2_valid(1), .src1_rdy(1),
                   .src2_rdy(1), .p_dest(6'd33), .old_p_dest(6'd5), .rob_tag(5'd0));
    @(negedge clk);  // posedge: entry written into iq_mem, now valid+ready
    clear_dispatch();

    // Check NOW, issue_valid is combinational, already reflects the entry
    check("issue_valid=1 when sources ready", issue_valid == 1'b1);
    check("issue_pkt.p_dest correct", issue_pkt.p_dest == 6'd33);
    check("issue_rob_tag correct", issue_rob_tag == 5'd0);

    @(negedge clk);  // posedge: entry consumed (invalidated) here
    check("issue_valid=0 after slot consumed", issue_valid == 1'b0);
  endtask

  // -----------------------------------------------------------------------
  // TEST 3: Sources not ready-> CDB wakeup->issue
  // -----------------------------------------------------------------------
  task automatic test_cdb_wakeup();
    $display("\nTEST 3: CDB wakeup");
    reset_dut();

    drive_dispatch(.p_src1(6'd20), .p_src2(6'd21), .src1_valid(1), .src2_valid(1), .src1_rdy(0),
                   .src2_rdy(0), .p_dest(6'd34), .old_p_dest(6'd6), .rob_tag(5'd1));
    @(negedge clk);
    clear_dispatch();
    check("issue_valid=0 before wakeup", issue_valid == 1'b0);

    // CDB fires for p_src1 (port 0)
    drive_cdb(6'd20);
    @(negedge clk);
    clear_cdb();
    check("issue_valid=0 after partial wakeup", issue_valid == 1'b0);

    // CDB fires for p_src2 : check immediately, don't add an extra cycle
    drive_cdb(6'd21);
    @(negedge clk);
    clear_cdb();
    check("issue_valid=1 after full wakeup", issue_valid == 1'b1);
    check("issue_pkt.p_dest correct", issue_pkt.p_dest == 6'd34);
  endtask

  // -----------------------------------------------------------------------
  // TEST 3b: CDB wakeup arriving on a NON-ZERO port
  //
  // The pre-existing tests only ever drive port 0. This is the one that
  // actually exercises the widened cdb_hit() OR-reduce across all
  // NUM_CDB_PORTS -- if the port array wiring were swapped or truncated,
  // this is the test that would catch it.
  // -----------------------------------------------------------------------
  task automatic test_cdb_wakeup_nonzero_port();
    $display("\nTEST 3b: CDB wakeup on a non-zero port");
    reset_dut();

    drive_dispatch(.p_src1(6'd22), .p_src2(6'd23), .src1_valid(1), .src2_valid(1), .src1_rdy(0),
                   .src2_rdy(0), .p_dest(6'd36), .old_p_dest(6'd0), .rob_tag(5'd2));
    @(negedge clk);
    clear_dispatch();
    check("issue_valid=0 before wakeup", issue_valid == 1'b0);

    // Wake p_src1 on port NUM_CDB_PORTS-1 (the last port), p_src2 on port 2.
    // Ports 0/1 stay idle throughout to prove they aren't silently doing
    // the work instead.
    drive_cdb(6'd22, NUM_CDB_PORTS - 1);
    @(negedge clk);
    clear_cdb();
    check("issue_valid=0 after partial wakeup (last port)", issue_valid == 1'b0);

    drive_cdb(6'd23, 2);
    @(negedge clk);
    clear_cdb();
    check("issue_valid=1 after full wakeup via non-zero ports", issue_valid == 1'b1);
    check("issue_pkt.p_dest correct", issue_pkt.p_dest == 6'd36);
  endtask

  // -----------------------------------------------------------------------
  // TEST 3c: Two DIFFERENT entries woken simultaneously by two DIFFERENT
  // CDB ports in the same cycle.
  //
  // This is the scenario the single-port design couldn't handle at all --
  // two execution units completing in the same cycle. Both entries need
  // only one source each so a single wakeup pulse fully readies them,
  // and we use distinct dest tags so oldest-first ordering (already
  // covered in TEST 5) decides which issues first.
  // -----------------------------------------------------------------------
  task automatic test_cdb_dual_port_wakeup();
    $display("\nTEST 3c: Two entries woken by two different CDB ports, same cycle");
    reset_dut();

    drive_dispatch(.p_src1(6'd24), .p_src2(6'd0), .src1_valid(1), .src2_valid(0), .src1_rdy(0),
                   .src2_rdy(0), .p_dest(6'd37), .old_p_dest(6'd0), .rob_tag(5'd3));
    @(negedge clk);  // older entry, age_tag = N

    drive_dispatch(.p_src1(6'd25), .p_src2(6'd0), .src1_valid(1), .src2_valid(0), .src1_rdy(0),
                   .src2_rdy(0), .p_dest(6'd38), .old_p_dest(6'd0), .rob_tag(5'd4));
    @(negedge clk);  // younger entry, age_tag = N+1
    clear_dispatch();

    // Port 0 wakes the younger entry's source, port 1 wakes the older
    // entry's source, both in the same cycle.
    drive_cdb(6'd25, 0);
    drive_cdb(6'd24, 1);
    @(negedge clk);
    clear_cdb();

    check("Older entry (p_dest=37) wins despite port-1 wakeup",
          issue_valid && issue_pkt.p_dest == 6'd37);

    @(negedge clk);  // older consumed; younger remains, already ready
    check("Younger entry (p_dest=38) issues next",
          issue_valid && issue_pkt.p_dest == 6'd38);
  endtask

  // -----------------------------------------------------------------------
  // TEST 4: iq_full backpressure
  // -----------------------------------------------------------------------
  task automatic test_iq_full();
    $display("\nTEST 4: iq_full backpressure");
    reset_dut();

    for (int i = 0; i < IQ_SIZE; i++) begin
      drive_dispatch(.p_src1(6'(i + 1)), .p_src2(6'(i + 2)), .src1_valid(1), .src2_valid(1),
                     .src1_rdy(0), .src2_rdy(0), .p_dest(6'(i + 33)), .old_p_dest(6'd0),
                     .rob_tag(5'(i)));
      @(negedge clk);
    end
    clear_dispatch();
    check("iq_full=1 after 16 dispatches", iq_full == 1'b1);

    drive_dispatch(.p_src1(6'd1), .p_src2(6'd2), .src1_valid(1), .src2_valid(1), .src1_rdy(0),
                   .src2_rdy(0), .p_dest(6'd63), .old_p_dest(6'd0), .rob_tag(5'd31));
    @(negedge clk);
    clear_dispatch();
    check("iq_full still=1, extra dispatch dropped", iq_full == 1'b1);
  endtask

  // -----------------------------------------------------------------------
  // TEST 5: Oldest-first selection
  //
  // A/B/C all wait on the SAME physical source tag, so a single CDB pulse
  // makes all three ready in the same cycle. This is the only way to
  // actually exercise the age comparator : waking them on separate cycles
  // (as an earlier version of this test did) means only one entry is ever
  // ready at a time, and the comparator's tie-break logic never fires.
  //
  // This now also exercises the binary-tree oldest-select reduction
  // (replacing the old all-pairs matrix) with 3 simultaneously-ready
  // entries -- same observable behavior is required either way.
  // -----------------------------------------------------------------------
  task automatic test_oldest_first();
    $display("\nTEST 5: Oldest-first selection (simultaneous ready)");
    reset_dut();

    drive_dispatch(.p_src1(6'd50), .p_src2(6'd0), .src1_valid(1), .src2_valid(0), .src1_rdy(0),
                   .src2_rdy(0), .p_dest(6'd40), .old_p_dest(6'd0), .rob_tag(5'd0));
    @(negedge clk);  // A written, age_tag = N

    drive_dispatch(.p_src1(6'd50), .p_src2(6'd0), .src1_valid(1), .src2_valid(0), .src1_rdy(0),
                   .src2_rdy(0), .p_dest(6'd41), .old_p_dest(6'd0), .rob_tag(5'd1));
    @(negedge clk);  // B written, age_tag = N+1

    drive_dispatch(.p_src1(6'd50), .p_src2(6'd0), .src1_valid(1), .src2_valid(0), .src1_rdy(0),
                   .src2_rdy(0), .p_dest(6'd42), .old_p_dest(6'd0), .rob_tag(5'd2));
    @(negedge clk);  // C written, age_tag = N+2
    clear_dispatch();

    // Single CDB pulse wakes all three simultaneously
    drive_cdb(6'd50);
    @(negedge clk);
    clear_cdb();

    // All three ready_vec=1 this same cycle : oldest (A) must win
    check("Oldest (A) issues first - p_dest=40", issue_valid && issue_pkt.p_dest == 6'd40);

    @(negedge clk);  // A consumed; B is now oldest among the remaining
    check("Second (B) issues - p_dest=41", issue_valid && issue_pkt.p_dest == 6'd41);

    @(negedge clk);  // B consumed; C remains
    check("Third (C) issues - p_dest=42", issue_valid && issue_pkt.p_dest == 6'd42);
  endtask

  // -----------------------------------------------------------------------
  // TEST 6:  Flush on branch mispredict
  // -----------------------------------------------------------------------
  task automatic test_flush_mispredict();
    $display("\nTEST 6: Flush on branch mispredict");
    reset_dut();

    for (int i = 0; i < 4; i++) begin
      drive_dispatch(.p_src1(6'(i + 1)), .p_src2(6'(i + 5)), .src1_valid(1), .src2_valid(1),
                     .src1_rdy(0), .src2_rdy(0), .p_dest(6'(i + 33)), .old_p_dest(6'd0),
                     .rob_tag(5'(i)));
      @(negedge clk);
    end
    clear_dispatch();

    branch_mispredict = 1;
    @(negedge clk);
    branch_mispredict = 0;

    check("iq_full=0 after mispredict flush", iq_full == 1'b0);
    check("issue_valid=0 after mispredict flush", issue_valid == 1'b0);
  endtask

  // -----------------------------------------------------------------------
  // TEST 7: Flush on exception
  // -----------------------------------------------------------------------
  task automatic test_flush_exception();
    $display("\nTEST 7: Flush on exception");
    reset_dut();

    for (int i = 0; i < 4; i++) begin
      drive_dispatch(.p_src1(6'(i + 1)), .p_src2(6'(i + 5)), .src1_valid(1), .src2_valid(1),
                     .src1_rdy(0), .src2_rdy(0), .p_dest(6'(i + 33)), .old_p_dest(6'd0),
                     .rob_tag(5'(i)));
      @(negedge clk);
    end
    clear_dispatch();

    exception_valid = 1;
    @(negedge clk);
    exception_valid = 0;

    check("iq_full=0 after exception flush", iq_full == 1'b0);
    check("issue_valid=0 after exception flush", issue_valid == 1'b0);
  endtask

  // -----------------------------------------------------------------------
  // TEST 8: Dispatch suppressed during flush
  // -----------------------------------------------------------------------
  task automatic test_dispatch_suppressed_on_flush();
    $display("\nTEST 8: Dispatch suppressed during flush");
    reset_dut();

    for (int i = 0; i < 2; i++) begin
      drive_dispatch(.p_src1(6'(i + 1)), .p_src2(6'(i + 3)), .src1_valid(1), .src2_valid(1),
                     .src1_rdy(0), .src2_rdy(0), .p_dest(6'(i + 33)), .old_p_dest(6'd0),
                     .rob_tag(5'(i)));
      @(negedge clk);
    end

    // Same cycle: assert mispredict AND a new valid dispatch
    branch_mispredict = 1;
    drive_dispatch(.p_src1(6'd10), .p_src2(6'd11), .src1_valid(1), .src2_valid(1), .src1_rdy(1),
                   .src2_rdy(1), .p_dest(6'd50), .old_p_dest(6'd0), .rob_tag(5'd5));
    @(negedge clk);
    branch_mispredict = 0;
    clear_dispatch();

    check("IQ empty after flush+dispatch same cycle", iq_full == 1'b0);
    check("issue_valid=0 : suppressed entry not present", issue_valid == 1'b0);
  endtask

  // -----------------------------------------------------------------------
  // TEST 9: CDB same cycle as dispatch (one-cycle penalty)
  //
  // The CDB pulse that lands on the SAME edge as the dispatch write is
  // missed : the wakeup loop that cycle runs against the pre-edge iq_mem,
  // which doesn't contain the new entry yet. To confirm the mechanism
  // recovers, we re-drive CDB for the same tag on the following cycle.
  // (Re-broadcasting the same tag twice isn't physically realistic : a
  // register is written once by its producer : but it's a clean way to
  // isolate and confirm the wakeup path works once a genuine pulse
  // arrives after the miss.)
  // -----------------------------------------------------------------------
  task automatic test_cdb_dispatch_same_cycle();
    $display("\nTEST 9: CDB same cycle as dispatch - one-cycle wakeup penalty");
    reset_dut();

    drive_dispatch(.p_src1(6'd30), .p_src2(6'd0), .src1_valid(1), .src2_valid(0), .src1_rdy(0),
                   .src2_rdy(0), .p_dest(6'd35), .old_p_dest(6'd0), .rob_tag(5'd0));
    drive_cdb(6'd30);  // same cycle as dispatch : will be missed
    @(negedge clk);
    clear_dispatch();
    clear_cdb();

    check("issue_valid=0 same cycle as dispatch+CDB (missed)", issue_valid == 1'b0);

    // Re-drive CDB for the same tag : the mechanism should catch it now
    drive_cdb(6'd30);
    @(negedge clk);
    clear_cdb();

    check("issue_valid=1 one cycle after wakeup", issue_valid == 1'b1);
    check("p_dest correct after delayed wakeup", issue_pkt.p_dest == 6'd35);
  endtask

  // -----------------------------------------------------------------------
  // TEST 10:  Fill, flush, refill
  // -----------------------------------------------------------------------
  task automatic test_fill_flush_refill();
    $display("\nTEST 10: Fill, flush, refill");
    reset_dut();

    for (int i = 0; i < IQ_SIZE; i++) begin
      drive_dispatch(.p_src1(6'(i + 1)), .p_src2(6'(i + 2)), .src1_valid(1), .src2_valid(1),
                     .src1_rdy(0), .src2_rdy(0), .p_dest(6'(i + 33)), .old_p_dest(6'd0),
                     .rob_tag(5'(i)));
      @(negedge clk);
    end
    clear_dispatch();
    check("iq_full=1 before flush", iq_full == 1'b1);

    branch_mispredict = 1;
    @(negedge clk);
    branch_mispredict = 0;
    check("iq_full=0 after flush", iq_full == 1'b0);

    drive_dispatch(.p_src1(6'd1), .p_src2(6'd2), .src1_valid(1), .src2_valid(1), .src1_rdy(1),
                   .src2_rdy(1), .p_dest(6'd40), .old_p_dest(6'd0), .rob_tag(5'd0));
    @(negedge clk);
    clear_dispatch();

    check("issue_valid=1 after refill", issue_valid == 1'b1);
    check("p_dest=40 after refill", issue_pkt.p_dest == 6'd40);
  endtask

  // -----------------------------------------------------------------------
  // TEST 11: DIV busy-gating
  //
  // A DIV op with both sources ready is dispatched while div_ready=0
  // (unit busy). It must NOT issue -- fu_available() must be gating
  // ready_vec even though p_src1_ready/p_src2_ready are both set. Once
  // div_ready=1, it must issue on the very next cycle with no re-dispatch
  // needed (the entry was parked the whole time, just not selectable).
  // -----------------------------------------------------------------------
  task automatic test_div_busy_gating();
    $display("\nTEST 11: DIV busy-gating (div_ready)");
    reset_dut();

    div_ready = 0;  // divider mid-operation
    drive_dispatch(.p_src1(6'd10), .p_src2(6'd11), .src1_valid(1), .src2_valid(1), .src1_rdy(1),
                   .src2_rdy(1), .p_dest(6'd60), .old_p_dest(6'd0), .rob_tag(5'd0));
    dispatch_in.func_unit_type = FU_MULDIV;
    dispatch_in.exec_unit_uop  = DIV;
    @(negedge clk);
    clear_dispatch();

    check("DIV with ready operands does NOT issue while div_ready=0",
          issue_valid == 1'b0);

    // Still not issuing several cycles later, still busy
    @(negedge clk);
    @(negedge clk);
    check("DIV still held while div busy (not dropped, not issued)",
          issue_valid == 1'b0);

    div_ready = 1;  // divider frees up
    #0;
    // Check immediately: issue_valid is combinational
    check("DIV issues as soon as div_ready=1, same cycle it's asserted",
          issue_valid == 1'b1 && issue_pkt.p_dest == 6'd60);

    @(negedge clk);  // consumed
    div_ready = 1;
    check("DIV entry consumed after issuing", issue_valid == 1'b0);
  endtask

  // -----------------------------------------------------------------------
  // TEST 12: LSU busy-gating, plus an independent ALU issuing behind it
  //
  // Mirrors TEST 11 for lsu_ready, and additionally proves an unrelated
  // ready ALU op still issues while the LSU-bound entry is held (busy-
  // gating one entry must not stall the rest of the queue).
  // -----------------------------------------------------------------------
  task automatic test_lsu_busy_gating();
    $display("\nTEST 12: LSU busy-gating (lsu_ready) + independent ALU behind it");
    reset_dut();

    lsu_ready = 0;  // LSU mid-operation
    drive_dispatch(.p_src1(6'd10), .p_src2(6'd11), .src1_valid(1), .src2_valid(1), .src1_rdy(1),
                   .src2_rdy(1), .p_dest(6'd61), .old_p_dest(6'd0), .rob_tag(5'd0));
    dispatch_in.func_unit_type = FU_LSU;
    @(negedge clk);  // LSU entry parked, not selectable

    // Independent ALU, ready, dispatched after (younger)
    drive_dispatch(.p_src1(6'd12), .p_src2(6'd13), .src1_valid(1), .src2_valid(1), .src1_rdy(1),
                   .src2_rdy(1), .p_dest(6'd62), .old_p_dest(6'd0), .rob_tag(5'd1));
    @(negedge clk);
    clear_dispatch();

    check("Ready ALU issues despite older LSU held busy",
          issue_valid == 1'b1 && issue_pkt.p_dest == 6'd62);

    @(negedge clk);  // ALU consumed; LSU still busy
    check("LSU still held while lsu busy", issue_valid == 1'b0);

    lsu_ready = 1;  // LSU frees up
    #0;
    check("LSU issues as soon as lsu_ready=1",
          issue_valid == 1'b1 && issue_pkt.p_dest == 6'd61);
  endtask

  // -----------------------------------------------------------------------
  // INTEGRATED  RAW dependency chain A -> B -> C
  //
  // A needs no sources, so it's ready the instant it's written and gets
  // consumed on the VERY NEXT posedge : which is B's dispatch edge if we
  // dispatch back-to-back. So we check A immediately after its own write,
  // before dispatching B, rather than batching all three dispatches first.
  // -----------------------------------------------------------------------
  task automatic test_raw_chain();
    $display("\nINTEGRATED: RAW dependency chain A->B->C");
    reset_dut();

    // A: no sources, ready immediately
    drive_dispatch(.p_src1(6'd0), .p_src2(6'd0), .src1_valid(0), .src2_valid(0), .src1_rdy(0),
                   .src2_rdy(0), .p_dest(6'd33), .old_p_dest(6'd0), .rob_tag(5'd0));
    @(negedge clk);
    clear_dispatch();
    check("A issues first", issue_valid && issue_pkt.p_dest == 6'd33);

    // B: depends on A's p_dest=33. Dispatch it now : A gets consumed on
    // this same edge (it was already ready), B is written on this edge.
    drive_dispatch(.p_src1(6'd33), .p_src2(6'd0), .src1_valid(1), .src2_valid(0), .src1_rdy(0),
                   .src2_rdy(0), .p_dest(6'd34), .old_p_dest(6'd0), .rob_tag(5'd1));
    @(negedge clk);
    clear_dispatch();
    check("A consumed, B not yet ready", issue_valid == 1'b0);

    // CDB: A "writes back" p_dest=33 -> wakes B
    drive_cdb(6'd33);
    @(negedge clk);
    clear_cdb();
    check("B issues after A writeback", issue_valid && issue_pkt.p_dest == 6'd34);

    // C: depends on B's p_dest=34. B gets consumed this same edge.
    drive_dispatch(.p_src1(6'd34), .p_src2(6'd0), .src1_valid(1), .src2_valid(0), .src1_rdy(0),
                   .src2_rdy(0), .p_dest(6'd35), .old_p_dest(6'd0), .rob_tag(5'd2));
    @(negedge clk);
    clear_dispatch();
    check("B consumed, C not yet ready", issue_valid == 1'b0);

    drive_cdb(6'd34);
    @(negedge clk);
    clear_cdb();
    check("C issues after B writeback", issue_valid && issue_pkt.p_dest == 6'd35);
  endtask

  // -----------------------------------------------------------------------
  // INTEGRATED  Independent ALU issues behind a stalled MUL
  //
  // MUL is not gated by div_ready (only the DIV-family opcodes are), so
  // this deliberately leaves div_ready/lsu_ready at their reset default
  // of 1 throughout -- it is purely a ready-operand stall, unrelated to
  // FU busy-gating (that's TEST 11/12 above).
  // -----------------------------------------------------------------------
  task automatic test_independent_issue_behind_muldiv();
    $display("\nINTEGRATED: Independent ALU issues behind stalled MUL");
    reset_dut();

    // MUL: not ready, oldest in queue
    drive_dispatch(.p_src1(6'd10), .p_src2(6'd11), .src1_valid(1), .src2_valid(1), .src1_rdy(0),
                   .src2_rdy(0), .p_dest(6'd40), .old_p_dest(6'd0), .rob_tag(5'd0));
    dispatch_in.func_unit_type = FU_MULDIV;
    dispatch_in.exec_unit_uop  = MUL;
    @(negedge clk);  // MUL written, not ready : parked, nothing consumed

    // ALU: sources already ready, dispatched after MUL (younger)
    drive_dispatch(.p_src1(6'd12), .p_src2(6'd13), .src1_valid(1), .src2_valid(1), .src1_rdy(1),
                   .src2_rdy(1), .p_dest(6'd41), .old_p_dest(6'd0), .rob_tag(5'd1));
    @(negedge clk);  // ALU written; MUL still not ready pre-edge, so
                     // nothing was consumed at this edge either
    clear_dispatch();

    // Check now : ALU is the only ready entry, must issue despite
    // being younger than the still-blocked MUL
    check("Ready ALU issues despite older MUL blocked",
          issue_valid == 1'b1 && issue_pkt.p_dest == 6'd41);

    @(negedge clk);  // ALU consumed this edge; MUL still not ready
    check("MUL still waiting : issue_valid=0", issue_valid == 1'b0);

    drive_cdb(6'd10);
    @(negedge clk);
    clear_cdb();
    drive_cdb(6'd11);
    @(negedge clk);
    clear_cdb();
    check("MUL issues after wakeup", issue_valid == 1'b1 && issue_pkt.p_dest == 6'd40);
  endtask

  // -----------------------------------------------------------------------
  // Main
  // -----------------------------------------------------------------------
  initial begin
    $dumpfile("issue_queue_tb.vcd");
    $dumpvars(0, issue_queue_tb);

    test_reset();
    test_dispatch_ready_issue();
    test_cdb_wakeup();
    test_cdb_wakeup_nonzero_port();
    test_cdb_dual_port_wakeup();
    test_iq_full();
    test_oldest_first();
    test_flush_mispredict();
    test_flush_exception();
    test_dispatch_suppressed_on_flush();
    test_cdb_dispatch_same_cycle();
    test_fill_flush_refill();
    test_div_busy_gating();
    test_lsu_busy_gating();
    test_raw_chain();
    test_independent_issue_behind_muldiv();

    $display("\n========================================");
    $display("  PASSED: %0d / %0d", pass_count, pass_count + fail_count);
    $display("  FAILED: %0d / %0d", fail_count, pass_count + fail_count);
    $display("========================================\n");

    $finish;
  end

endmodule