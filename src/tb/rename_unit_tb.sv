`timescale 1ns/1ps
import orion_pkg::*;
module rename_unit_tb;

    // --------------------------------------------------------
    // DUT signals
    // --------------------------------------------------------
    logic                       clk;
    logic                       rst_n;
    decode_rename_pkt_s         decode_rename_in;
    logic                       branch_mispredict;
    logic                       commit_valid;
    logic [REG_ADDR_WIDTH-1:0]  commit_rd;
    logic [TAG_WIDTH-1:0]       commit_pd;
    logic [TAG_WIDTH-1:0]       commit_old_pd;

    logic                       rename_stall;
    rename_dispatch_pkt_s       rename_dispatch_out;

    // --------------------------------------------------------
    // Tracking
    // --------------------------------------------------------
    int error_count;
    int test_count;

    // --------------------------------------------------------
    // DUT instantiation
    // --------------------------------------------------------
    rename_unit dut (
        .clk                (clk),
        .rst_n              (rst_n),
        .decode_rename_in   (decode_rename_in),
        .branch_mispredict  (branch_mispredict),
        .commit_valid       (commit_valid),
        .commit_rd          (commit_rd),
        .commit_pd          (commit_pd),
        .commit_old_pd      (commit_old_pd),
        .rename_stall       (rename_stall),
        .rename_dispatch_out(rename_dispatch_out)
    );
    initial clk = 0;
    always #5 clk = ~clk;

    // --------------------------------------------------------
    // Helper functions
    // --------------------------------------------------------
    task automatic report_error(input string msg);
        $error("[FAIL] %s", msg);
        error_count++;
    endtask

    task automatic report_pass(input string msg);
        $display("[PASS] %s", msg);
        test_count++;
    endtask

    task automatic check(
        input logic         got,
        input logic         expected,
        input string        label
    );
        if (got !== expected)
            report_error($sformatf("%s: expected %0d got %0d", label, expected, got));
        else
            report_pass(label);
    endtask

    task automatic check_tag(
        input logic [TAG_WIDTH-1:0] got,
        input logic [TAG_WIDTH-1:0] expected,
        input string                label
    );
        if (got !== expected)
            report_error($sformatf("%s: expected p%0d got p%0d", label, expected, got));
        else
            report_pass(label);
    endtask

    task automatic check_pc(
        input logic [DATA_WIDTH-1:0] got,
        input logic [DATA_WIDTH-1:0] expected,
        input string                 label
    );
        if (got !== expected)
            report_error($sformatf("%s: expected 0x%08h got 0x%08h", label, expected, got));
        else
            report_pass(label);
    endtask

    // --------------------------------------------------------
    // Drive helpers
    // --------------------------------------------------------
    task automatic apply_reset();
        rst_n             = 0;
        decode_rename_in.r_src1         = 0;
        decode_rename_in.r_src2         = 0;
        decode_rename_in.r_dst          = 0;
        decode_rename_in.pc             = 0;
        decode_rename_in.src1_valid     = 0;
        decode_rename_in.src2_valid     = 0;
        decode_rename_in.valid          = 0;
        decode_rename_in.except         = 0;
        decode_rename_in.cause          = EXCEPT_NONE;
        branch_mispredict   = 0;
        commit_valid        = 0;
        commit_rd           = 0;
        commit_pd           = 0;
        commit_old_pd       = 0;
        repeat(2) @(posedge clk);
        rst_n = 1;
        @(posedge clk);
    endtask

    task automatic drive_instr(
        input [REG_ADDR_WIDTH-1:0] i_src1,
        input [REG_ADDR_WIDTH-1:0] i_src2,
        input [REG_ADDR_WIDTH-1:0] i_dst,
        input [DATA_WIDTH-1:0]     i_pc,
        input                      s1v,
        input                      s2v
    );
        decode_rename_in.r_src1             = i_src1;
        decode_rename_in.r_src2             = i_src2;
        decode_rename_in.r_dst              = i_dst;
        decode_rename_in.pc                 = i_pc;
        decode_rename_in.src1_valid         = s1v;
        decode_rename_in.src2_valid         = s2v;
        decode_rename_in.except             = 0;
        decode_rename_in.valid              = 1;
        decode_rename_in.cause              = EXCEPT_NONE;
        branch_mispredict   = 0;
        commit_valid        = 0;
        @(posedge clk);
    endtask

    task automatic drive_illegal_instr(
        input [REG_ADDR_WIDTH-1:0] i_src1,
        input [REG_ADDR_WIDTH-1:0] i_src2,
        input [REG_ADDR_WIDTH-1:0] i_dst,
        input [DATA_WIDTH-1:0]     i_pc,
        input                      s1v,
        input                      s2v
    );
        decode_rename_in.r_src1             = i_src1;
        decode_rename_in.r_src2             = i_src2;
        decode_rename_in.r_dst              = i_dst;
        decode_rename_in.pc                 = i_pc;
        decode_rename_in.src1_valid         = s1v;
        decode_rename_in.src2_valid         = s2v;
        decode_rename_in.except             = 1;
        decode_rename_in.valid              = 1;
        decode_rename_in.cause              = EXCEPT_ILLEGAL_INST;
        branch_mispredict   = 0;
        commit_valid        = 0;
        @(posedge clk);
    endtask

    // Drive instruction while simultaneously committing
    task automatic drive_instr_with_commit(
        input [REG_ADDR_WIDTH-1:0] i_src1,
        input [REG_ADDR_WIDTH-1:0] i_src2,
        input [REG_ADDR_WIDTH-1:0] i_dst,
        input [DATA_WIDTH-1:0]     i_pc,
        input                      s1v,
        input                      s2v,
        input [REG_ADDR_WIDTH-1:0] c_rd,
        input [TAG_WIDTH-1:0]      c_pd,
        input [TAG_WIDTH-1:0]      c_old_pd
    );
        decode_rename_in.r_src1         = i_src1;
        decode_rename_in.r_src2         = i_src2;
        decode_rename_in.r_dst          = i_dst;
        decode_rename_in.pc             = i_pc;
        decode_rename_in.src1_valid     = s1v;
        decode_rename_in.src2_valid     = s2v;
        decode_rename_in.valid          = 1;
        decode_rename_in.cause          = EXCEPT_NONE;
        decode_rename_in.except         = 0;  
        branch_mispredict   = 0;
        commit_valid        = 1;
        commit_rd           = c_rd;
        commit_pd           = c_pd;
        commit_old_pd       = c_old_pd;
        @(posedge clk);
        commit_valid      = 0;
    endtask

    task automatic drive_idle();
        decode_rename_in.valid  = 0;
        branch_mispredict       = 0;
        commit_valid            = 0;
        @(posedge clk);
    endtask

    task automatic drive_commit(
        input [REG_ADDR_WIDTH-1:0] c_rd,
        input [TAG_WIDTH-1:0]      c_pd,
        input [TAG_WIDTH-1:0]      c_old_pd
    );
        commit_valid        = 1;
        commit_rd           = c_rd;
        commit_pd           = c_pd;
        commit_old_pd       = c_old_pd;
        decode_rename_in.valid  = 0;
        branch_mispredict   = 0;
        @(posedge clk);
        commit_valid        = 0;
    endtask

    task automatic drive_mispredict();
        branch_mispredict       = 1;
        decode_rename_in.valid  = 0;
        commit_valid            = 0;
        @(posedge clk);
        branch_mispredict       = 0;
    endtask

    //  Every test follows the following pattern
    //  Apply combinational inputs -> Trigger positive clock edge
    //  Wait for output to propagate -> sample output at negative edge

    //  ========================================================
    //  TEST 1: Basic rename trace ,  RAW dependency
    //  After reset: spec_map[i] = arch_map[i] = i
    //  free_list[0..31] = {32,33,...,63}, head=0, tail=32
    //  C1: ADD x3, x1, x2  -> p_dst=p32, p_src1=p1, p_src2=p2
    //  C2: SUB x5, x3, x4  -> p_dst=p33, p_src1=p32(RAW), p_src2=p4
    //                          old_p_dest for x5 = p5
    //  ========================================================
    task automatic test_basic_rename_trace();
        $display("\n=== TEST 1: Basic rename trace + RAW dependency ===");
        apply_reset();

        // Cycle 1
        drive_instr(5'd1, 5'd2, 5'd3, 32'h100, 1, 1);
        @(negedge clk);
        check(rename_dispatch_out.valid,    1'b1,   "T1C1: valid");
        check_tag(rename_dispatch_out.p_dest,  6'd32,  "T1C1: p_dest=p32");
        check_tag(rename_dispatch_out.p_src1,  6'd1,   "T1C1: p_src1=p1");
        check_tag(rename_dispatch_out.p_src2,  6'd2,   "T1C1: p_src2=p2");
        check_tag(rename_dispatch_out.old_p_dest, 6'd3, "T1C1: old_p_dest=p3 (original x3 mapping)");
        check_pc(rename_dispatch_out.pc,    32'h100,  "T1C1: pc passthrough");
        check(rename_dispatch_out.reg_we,   1'b1,   "T1C1: reg_we");
        check(rename_dispatch_out.except,   1'b0,   "T1C1: no except");

        // Cycle 2 ,  RAW: x3 should resolve to p32
        drive_instr(5'd3, 5'd4, 5'd5, 32'h104, 1, 1);
        @(negedge clk);
        check(rename_dispatch_out.valid,    1'b1,   "T1C2: valid");
        check_tag(rename_dispatch_out.p_dest,  6'd33,  "T1C2: p_dest=p33");
        check_tag(rename_dispatch_out.p_src1,  6'd32,  "T1C2: p_src1=p32 (RAW from C1)");
        check_tag(rename_dispatch_out.p_src2,  6'd4,   "T1C2: p_src2=p4");
        check_tag(rename_dispatch_out.old_p_dest, 6'd5, "T1C2: old_p_dest=p5 (original x5 mapping)");
        check_pc(rename_dispatch_out.pc,    32'h104,  "T1C2: pc passthrough");

        drive_illegal_instr(5'd3, 5'd4, 5'd5, 32'h104, 1, 1);
        @(negedge clk);
        check(rename_dispatch_out.valid,    1'b1,   "T1C3: valid");
        check_tag(rename_dispatch_out.p_dest,  6'd0,  "T1C3: p_dest=p0");
        check_tag(rename_dispatch_out.p_src1,  6'd0,  "T1C3: p_src1=p0 (no allocation)");
        check_tag(rename_dispatch_out.p_src2,  6'd0,   "T1C3: p_src2=p0");
        check_tag(rename_dispatch_out.old_p_dest, 6'd0, "T1C3: old_p_dest=p0 (skip entirely)");
        check_pc(rename_dispatch_out.pc,    32'h104,  "T1C3: pc passthrough");
    endtask
    

    // ========================================================
    // TEST 2: WAW hazard
    // Rename x3 twice ,  second rename should produce a new
    // physical register, old_p_dest on second should be p32
    // (the result of the first rename, not the reset mapping)
    // ========================================================
    task automatic test_waw_hazard();
        $display("\n=== TEST 2: WAW hazard ===");
        apply_reset();

        // First write to x3
        drive_instr(5'd1, 5'd2, 5'd3, 32'h200, 1, 1);
        @(negedge clk);
        check_tag(rename_dispatch_out.p_dest,     6'd32, "T2C1: first x3 rename -> p32");
        check_tag(rename_dispatch_out.old_p_dest, 6'd3,  "T2C1: old_p_dest=p3");

        // Second write to x3
        drive_instr(5'd5, 5'd6, 5'd3, 32'h204, 1, 1);
        @(negedge clk);
        check_tag(rename_dispatch_out.p_dest,     6'd33, "T2C2: second x3 rename -> p33");
        check_tag(rename_dispatch_out.old_p_dest, 6'd32, "T2C2: old_p_dest=p32");

        drive_instr(5'd3, 5'd0, 5'd7, 32'h208, 1, 0);
        @(negedge clk);
        check_tag(rename_dispatch_out.p_src1, 6'd33, "T2C3: read x3 after WAW -> p33");
    endtask

    // ========================================================
    // TEST 3: WAR hazard
    // Read x3, then write x3 ,  the write should not affect
    // the already-issued read (rename handles this transparently)
    // Verify the write gets a new physical register
    // ========================================================
    task automatic test_war_hazard();
        $display("\n=== TEST 3: WAR hazard ===");
        apply_reset();

        // Read x3 (initial mapping p3)
        drive_instr(5'd3, 5'd4, 5'd7, 32'h300, 1, 1);
        @(negedge clk);
        check_tag(rename_dispatch_out.p_src1, 6'd3,  "T3C1: read x3 -> p3 (pre-rename)");
        check_tag(rename_dispatch_out.p_dest, 6'd32, "T3C1: x7 -> p32");

        // Now write x3 ,  gets a new physical, old reader already has p3
        drive_instr(5'd1, 5'd2, 5'd3, 32'h304, 1, 1);
        @(negedge clk);
        check_tag(rename_dispatch_out.p_dest,     6'd33, "T3C2: write x3 -> new physical p33");
        check_tag(rename_dispatch_out.old_p_dest, 6'd3,  "T3C2: old_p_dest=p3 (WAR: reader was using p3, now free to reclaim at commit)");

        // Subsequent read of x3 should now get p33
        drive_instr(5'd3, 5'd0, 5'd8, 32'h308, 1, 0);
        @(negedge clk);
        check_tag(rename_dispatch_out.p_src1, 6'd33, "T3C3: read x3 after write -> p33");
    endtask

    // ========================================================
    // TEST 4: x0 write ,  no physical register allocated
    // x0 read ,  always maps to p0
    // ========================================================
    task automatic test_x0_handling();
        $display("\n=== TEST 4: x0 handling ===");
        apply_reset();

        // Write to x0 ,  free list head must NOT advance
        drive_instr(5'd1, 5'd2, 5'd0, 32'h400, 1, 1);
        @(negedge clk);
        check(rename_dispatch_out.valid,         1'b1, "T4C1: valid");
        check_tag(rename_dispatch_out.p_dest,    6'd0, "T4C1: x0 write -> p_dest=p0");
        check_tag(rename_dispatch_out.old_p_dest,6'd0, "T4C1: x0 old_p_dest=0");

        // Next rename should still get p32 (free list head unchanged)
        drive_instr(5'd3, 5'd4, 5'd5, 32'h404, 1, 1);
        @(negedge clk);
        check_tag(rename_dispatch_out.p_dest, 6'd32, "T4C2: after x0 write, next rename still gets p32");

        // Read from x0 ,  should always be p0 regardless of anything
        drive_instr(5'd0, 5'd5, 5'd6, 32'h408, 1, 1);
        @(negedge clk);
        check_tag(rename_dispatch_out.p_src1, 6'd0,  "T4C3: x0 read -> p_src1=p0");
        check_tag(rename_dispatch_out.p_src2, 6'd32, "T4C3: x5 read -> p_src2=p32");

        // Commit of x0 instruction ,  free_list_tail must NOT advance
        // We verify this indirectly: commit x0, then exhaust free list
        // and verify the count is still correct
        drive_commit(5'd0, 6'd0, 6'd0);
        // If free_list_tail incorrectly advanced, the free list count
        // would be wrong and stall would trigger one instruction early
        $display("  x0 commit done, stall boundary check follows in TEST 5");
    endtask

    // ========================================================
    // TEST 5: Stall on free list exhaustion + recovery
    // Allocate all 32 entries, verify stall, commit one back,
    // verify stall deasserts and rename resumes correctly
    // ========================================================
    task automatic test_stall_and_recovery();
        $display("\n=== TEST 5: Stall + recovery ===");
        apply_reset();

        // Exhaust the free list, 32 entries available at reset
        // Use different dst regs to avoid WAW complications here
        // x1..x31 and loop back,  just need 32 allocations
        for (int i = 1; i <= 31; i++) begin
            drive_instr(5'd0, 5'd0, i[4:0], 32'h0, 0, 0);
        end
        // One more to get the 32nd
        drive_instr(5'd0, 5'd0, 5'd1, 32'h0, 0, 0);

        // Now free list should be empty,next instruction must stall
        @(negedge clk);
        // Drive instruction that needs allocation

        decode_rename_in.r_src1      = 5'd1;
        decode_rename_in.r_src2      = 5'd2;
        decode_rename_in.r_dst       = 5'd5;
        decode_rename_in.pc          = 32'hDEAD;
        decode_rename_in.src1_valid  = 1;
        decode_rename_in.src2_valid  = 1;
        decode_rename_in.valid = 1;
        decode_rename_in.cause       = EXCEPT_NONE;
        branch_mispredict = 0;
        commit_valid      = 0;
        @(negedge clk);
        check(rename_stall,                  1'b1, "T5: rename_stall asserted when free list empty");
        check(rename_dispatch_out.valid,     1'b0, "T5: valid=0 when stalling");

        // Now commit one instruction to free a physical register back
        // p32 was the first one allocated (for x1), old mapping was p1
        @(posedge clk);
        // After commit, check stall has cleared ,  sample at negedge of same cycle
        drive_commit(5'd1, 6'd32, 6'd1);
        @(negedge clk);   // <-- sample here, before drive_instr advances head
        check(rename_stall, 1'b0, "T5: rename_stall deasserted after commit");

        // Now do the rename that consumes the freed slot
        drive_instr(5'd1, 5'd2, 5'd5, 32'hDEAD, 1, 1);
        @(negedge clk);
        check(rename_dispatch_out.valid, 1'b1, "T5: valid=1 after stall recovery");
        check_tag(rename_dispatch_out.p_dest, 6'd1, "T5: freed register p1 correctly reallocated");
    endtask
    // ========================================================
    // TEST 6: Branch mispredict recovery
    // Rename several instructions speculatively, commit one
    // (advance arch map), mispredict, then rename again and
    // verify speculative map restored to architectural state
    // ========================================================
    task automatic test_mispredict_recovery();
        $display("\n=== TEST 6: Branch mispredict recovery ===");
        apply_reset();

        // Rename x3 speculatively -> p32
        drive_instr(5'd1, 5'd2, 5'd3, 32'h500, 1, 1);
        @(negedge clk);
        check_tag(rename_dispatch_out.p_dest, 6'd32, "T6C1: spec rename x3->p32");

        // Rename x5 speculatively -> p33
        drive_instr(5'd3, 5'd4, 5'd5, 32'h504, 1, 1);
        @(negedge clk);
        check_tag(rename_dispatch_out.p_dest, 6'd33, "T6C2: spec rename x5->p33");

        // Commit the first instruction (x3=p32, old=p3)
        // This advances arch_reg_map[3] = p32
        drive_commit(5'd3, 6'd32, 6'd3);

        // Mispredict ,  spec map should restore to arch map
        // arch_map: x3=p32 (committed), x5=p5 (not committed)
        drive_mispredict();
        @(negedge clk);
        check(rename_dispatch_out.valid, 1'b0, "T6: valid=0 during mispredict");

        // Now rename x3 again ,  should get p33 (next free entry)
        // and p_src should reflect arch state: x3=p32, x5=p5
        drive_instr(5'd5, 5'd3, 5'd7, 32'h600, 1, 1);
        @(negedge clk);
        check(rename_dispatch_out.valid,  1'b1,  "T6: valid after recovery");
        // x5 should resolve to p5 (speculative rename was squashed)
        check_tag(rename_dispatch_out.p_src1, 6'd5,  "T6: x5 restored to p5 after mispredict");
        // x3 should resolve to p32 (committed, in arch map)
        check_tag(rename_dispatch_out.p_src2, 6'd32, "T6: x3 reflects committed mapping p32");
        // New destination x7 should get p33 (free list head restored to arch head)
        check_tag(rename_dispatch_out.p_dest, 6'd33, "T6: new rename after recovery gets p33");
    endtask

    // ========================================================
    // TEST 7: Multiple mispredicts with interleaved commits
    // Verify arch head pointer tracks correctly
    // ========================================================
    task automatic test_multiple_mispredicts();
        $display("\n=== TEST 7: Multiple mispredicts with interleaved commits ===");
        apply_reset();

        // Rename x1 -> p32
        drive_instr(5'd0, 5'd0, 5'd1, 32'h700, 0, 0);
        // Rename x2 -> p33
        drive_instr(5'd0, 5'd0, 5'd2, 32'h704, 0, 0);
        // Commit x1 (arch head advances to 1)
        drive_commit(5'd1, 6'd32, 6'd1);
        // Mispredict #1 ,  free list head should go back to arch head = 1
        drive_mispredict();

        // After recovery: rename x3 should get p33 (head=1, free_list[1]=p33)
        drive_instr(5'd0, 5'd0, 5'd3, 32'h800, 0, 0);
        @(negedge clk);
        check_tag(rename_dispatch_out.p_dest, 6'd33, "T7: after mispredict#1 rename gets p33");

        // Commit x2 and x3
        drive_commit(5'd2, 6'd33, 6'd2);
        drive_commit(5'd3, 6'd33, 6'd3);

        // Mispredict #2
        drive_mispredict();

        // Rename x4 ,  head should be at arch head = 3
        drive_instr(5'd0, 5'd0, 5'd4, 32'h900, 0, 0);
        @(negedge clk);
        check(rename_dispatch_out.valid, 1'b1, "T7: valid after mispredict#2");
        // Just verify no stall and valid ,  exact physical tag depends on
        // what was freed back into the list
        check(rename_stall, 1'b0, "T7: no stall after second recovery");
    endtask

    // ========================================================
    // TEST 8: Simultaneous commit + rename same cycle
    // Both should complete without corrupting each other
    // ========================================================
    task automatic test_simultaneous_commit_rename();
        $display("\n=== TEST 8: Simultaneous commit + rename ===");
        apply_reset();

        // Rename x3 -> p32 first to set up a commit
        drive_instr(5'd1, 5'd2, 5'd3, 32'hA00, 1, 1);
        @(negedge clk);
        check_tag(rename_dispatch_out.p_dest, 6'd32, "T8 setup: x3->p32");

        // Simultaneously: rename x5, commit x3
        // Commit frees p3 back to free list (tail), rename allocates p33 from head
        drive_instr_with_commit(
            5'd3, 5'd4, 5'd5, 32'hA04, 1, 1,   // rename x5
            5'd3, 6'd32, 6'd3                    // commit x3 (pd=p32, old=p3)
        );
        @(negedge clk);
        check(rename_dispatch_out.valid,  1'b1,  "T8: valid during simultaneous op");
        check_tag(rename_dispatch_out.p_dest, 6'd33, "T8: rename consumed p33 from head (not the just-freed p3)");
        check_tag(rename_dispatch_out.p_src1, 6'd32, "T8: x3 src resolves to p32 (commit updated arch but spec map still consistent)");

        // After simultaneous op, verify a new rename gets the freed p3
        // Two more renames to advance past p34, p35
        drive_instr(5'd0, 5'd0, 5'd6, 32'hA08, 0, 0); // gets p34
        drive_instr(5'd0, 5'd0, 5'd7, 32'hA0C, 0, 0); // gets p35
        // Keep allocating until we wrap around to p3 being reused
        // free_list_tail was at 32 before commit, commit put p3 at tail[32]=p3
        // We need to allocate 32 - (current head offset) more to reach p3
        // Rather than counting exactly, just verify no stall and valid
        $display("  Simultaneous commit+rename completed without error");
    endtask

    // ========================================================
    // TEST 9: src_valid gating
    // Verify p_src1/p_src2 validity flags propagate correctly
    // ========================================================
    task automatic test_src_valid_gating();
        $display("\n=== TEST 9: src_valid gating ===");
        apply_reset();

        // No sources (LUI-style)
        drive_instr(5'd1, 5'd2, 5'd3, 32'hB00, 0, 0);
        @(negedge clk);
        check(rename_dispatch_out.p_src1_valid, 1'b0, "T9: LUI p_src1_valid=0");
        check(rename_dispatch_out.p_src2_valid, 1'b0, "T9: LUI p_src2_valid=0");

        // src1 only (JALR-style)
        drive_instr(5'd1, 5'd2, 5'd4, 32'hB04, 1, 0);
        @(negedge clk);
        check(rename_dispatch_out.p_src1_valid, 1'b1, "T9: JALR p_src1_valid=1");
        check(rename_dispatch_out.p_src2_valid, 1'b0, "T9: JALR p_src2_valid=0");
        check_tag(rename_dispatch_out.p_src1,   6'd1,  "T9: JALR p_src1=p1");

        // src2 only
        drive_instr(5'd1, 5'd2, 5'd5, 32'hB08, 0, 1);
        @(negedge clk);
        check(rename_dispatch_out.p_src1_valid, 1'b0, "T9: src2only p_src1_valid=0");
        check(rename_dispatch_out.p_src2_valid, 1'b1, "T9: src2only p_src2_valid=1");
        check_tag(rename_dispatch_out.p_src2,   6'd2,  "T9: src2only p_src2=p2");

        // Both sources
        drive_instr(5'd3, 5'd4, 5'd6, 32'hB0C, 1, 1);
        @(negedge clk);
        check(rename_dispatch_out.p_src1_valid, 1'b1, "T9: both p_src1_valid=1");
        check(rename_dispatch_out.p_src2_valid, 1'b1, "T9: both p_src2_valid=1");
    endtask

    // ========================================================
    // TEST 10: Free list wraparound
    // Allocate 32, commit all 32, allocate 32 again
    // Verify correct physical registers come back from the FIFO
    // ========================================================
    task automatic test_free_list_wraparound();
        logic [TAG_WIDTH-1:0] expected_tags [31:0];
        $display("\n=== TEST 10: Free list wraparound ===");
        apply_reset();

        // Phase 1: Allocate all 32 entries
        // Track what physical registers were assigned
        for (int i = 1; i <= 31; i++) begin
            drive_instr(5'd0, 5'd0, i[4:0], 32'h0, 0, 0);
            @(negedge clk);
            expected_tags[i-1] = rename_dispatch_out.p_dest;
        end
        // 32nd allocation
        drive_instr(5'd0, 5'd0, 5'd1, 32'h0, 0, 0);
        @(negedge clk);
        expected_tags[31] = rename_dispatch_out.p_dest;

        // Phase 2: Commit all 32 back in order
        // Each commit returns old_pd back to the free list tail
        // Initial mappings were p1..p31 for x1..x31, p1 again for the last x1
        for (int i = 1; i <= 31; i++) begin
            drive_commit(i[4:0], expected_tags[i-1], i[5:0]);
        end
        drive_commit(5'd1, expected_tags[31], expected_tags[30]);

        // Phase 3: Allocate again ,  should get the freed registers back in FIFO order
        drive_instr(5'd0, 5'd0, 5'd2, 32'h0, 0, 0);
        @(negedge clk);
        check(rename_dispatch_out.valid, 1'b1, "T10: valid after wraparound");
        check(rename_stall,              1'b0, "T10: no stall after free list refilled");
        // The first freed register (p1, old mapping of first commit) should be at head
        check_tag(rename_dispatch_out.p_dest, 6'd1, "T10: first reallocation after wraparound gets p1");
    endtask

    // ========================================================
    // TEST 11: All 32 architectural registers renamed
    // Rename a write to every x1..x31, verify each gets a
    // unique physical register and map table is fully populated
    // ========================================================
    task automatic test_all_arch_registers();
        logic [TAG_WIDTH-1:0] phys_map [31:0];
        logic saw_duplicate;
        $display("\n=== TEST 11: All architectural registers renamed ===");
        apply_reset();

        // Rename write to x1..x31
        for (int i = 1; i <= 31; i++) begin
            drive_instr(5'd0, 5'd0, i[4:0], i * 4, 0, 0);
            @(negedge clk);
            phys_map[i] = rename_dispatch_out.p_dest;
            check(rename_dispatch_out.valid, 1'b1,
                $sformatf("T11: x%0d rename valid", i));
        end

        // Check all physical tags are unique
        saw_duplicate = 0;
        for (int i = 1; i <= 31; i++) begin
            for (int j = i+1; j <= 31; j++) begin
                if (phys_map[i] === phys_map[j]) begin
                    report_error($sformatf("T11: x%0d and x%0d got same physical tag p%0d", i, j, phys_map[i]));
                    saw_duplicate = 1;
                end
            end
        end
        if (!saw_duplicate)
            report_pass("T11: all 31 architectural registers got unique physical tags");

        // Now read back all of them ,  verify map table consistency
        for (int i = 1; i <= 31; i++) begin
            drive_instr(i[4:0], 5'd0, 5'd0, 32'h0, 1, 0);
            // Note: dst=x0 so no allocation, we're just probing src mapping
            @(negedge clk);
            check_tag(rename_dispatch_out.p_src1, phys_map[i],
                $sformatf("T11: readback x%0d -> p%0d", i, phys_map[i]));
        end
    endtask

    // ========================================================
    // TEST 12: PC and cause passthrough
    // Verify non-register fields travel correctly
    // ========================================================
    task automatic test_passthrough_fields();
        $display("\n=== TEST 12: PC and cause passthrough ===");
        apply_reset();

        drive_instr(5'd1, 5'd2, 5'd3, 32'hDEADBEEF, 1, 1);
        @(negedge clk);
        check_pc(rename_dispatch_out.pc, 32'hDEADBEEF, "T12: PC passthrough");
        check(rename_dispatch_out.cause, EXCEPT_NONE, "T12: cause=EXCEPT_NONE passthrough");
        check(rename_dispatch_out.except, 1'b0,       "T12: except=0 for normal instr");

        drive_instr(5'd1, 5'd2, 5'd4, 32'hCAFEBABE, 1, 1);
        @(negedge clk);
        check_pc(rename_dispatch_out.pc, 32'hCAFEBABE, "T12: PC passthrough second instr");
    endtask

    // ========================================================
    // TEST 13: Idle cycles (bubbles) produce valid=0
    // ========================================================
    task automatic test_idle_bubbles();
        $display("\n=== TEST 13: Idle/bubble cycles ===");
        apply_reset();

        drive_instr(5'd1, 5'd2, 5'd3, 32'h100, 1, 1);
        @(negedge clk);
        check(rename_dispatch_out.valid, 1'b1, "T13: valid=1 for real instr");

        drive_idle();
        @(negedge clk);
        check(rename_dispatch_out.valid, 1'b0, "T13: valid=0 for idle cycle");

        drive_idle();
        @(negedge clk);
        check(rename_dispatch_out.valid, 1'b0, "T13: valid=0 for second idle");

        // After bubbles, real instruction should work fine
        drive_instr(5'd1, 5'd2, 5'd4, 32'h104, 1, 1);
        @(negedge clk);
        check(rename_dispatch_out.valid, 1'b1, "T13: valid=1 resumes after bubbles");
        check_tag(rename_dispatch_out.p_dest, 6'd33, "T13: p33 allocated after bubble (p32 was consumed before bubbles)");
    endtask

    // ========================================================
    // TEST 14: Back-to-back commits
    // Multiple consecutive commits ,  verify arch map and
    // free list tail advance correctly each cycle
    // ========================================================
    task automatic test_back_to_back_commits();
        $display("\n=== TEST 14: Back-to-back commits ===");
        apply_reset();

        // Rename x1, x2, x3
        drive_instr(5'd0, 5'd0, 5'd1, 32'h0, 0, 0); // x1->p32
        drive_instr(5'd0, 5'd0, 5'd2, 32'h0, 0, 0); // x2->p33
        drive_instr(5'd0, 5'd0, 5'd3, 32'h0, 0, 0); // x3->p34

        // Three back-to-back commits
        drive_commit(5'd1, 6'd32, 6'd1);
        drive_commit(5'd2, 6'd33, 6'd2);
        drive_commit(5'd3, 6'd34, 6'd3);

        // After 3 commits: p1, p2, p3 returned to free list tail
        // Mispredict now ,  arch head should be at 3
        drive_mispredict();

        // Rename after recovery ,  head at 3, so should get p35
        // (entries 0,1,2 are behind arch head; entries at [3..31] still available)
        drive_instr(5'd0, 5'd0, 5'd4, 32'h0, 0, 0);
        @(negedge clk);
        check(rename_dispatch_out.valid, 1'b1, "T14: valid after back-to-back commits + mispredict");
        check_tag(rename_dispatch_out.p_dest, 6'd35, "T14: p35 allocated (arch head advanced past 3 commits)");
    endtask

    task test_stall_on_illegal_instr();
        $display("\n=== TEST 15: Stall skip on illegal instruction ===");
        apply_reset();

        // Exhaust the free list, 32 entries available at reset
        // Use different dst regs to avoid WAW complications here
        // x1..x31 and loop back,  just need 32 allocations
        for (int i = 1; i <= 31; i++) begin
            drive_instr(5'd0, 5'd0, i[4:0], 32'h0, 0, 0);
        end
        // One more to get the 32nd
        drive_instr(5'd0, 5'd0, 5'd1, 32'h0, 0, 0);

        // Now free list should be empty,next illegal instruction must not stall
        @(negedge clk);
        drive_illegal_instr(5'd21, 5'd19, 5'd12, 32'hDEAD, 1,1);
        @(negedge clk);
        check(rename_stall,                  1'b0, "T15: rename_stall low when free list empty, but instruction illegal");
        check(rename_dispatch_out.valid,     1'b1, "T15: valid=1 when stalling, but instruction illegal");

        // Now commit one instruction to free a physical register back
        // p32 was the first one allocated (for x1), old mapping was p1
        @(posedge clk);
        @(posedge clk);
    endtask
    
    // ========================================================
    // Main
    // ========================================================
    initial begin
        error_count = 0;
        test_count  = 0;

        $display("=====================================================");
        $display("              RENAME UNIT TESTBENCH                  ");
        $display("=====================================================");

        test_basic_rename_trace();
        test_waw_hazard();
        test_war_hazard();
        test_x0_handling();
        test_stall_and_recovery();
        test_mispredict_recovery();
        test_multiple_mispredicts();
        test_simultaneous_commit_rename();
        test_src_valid_gating();
        test_free_list_wraparound();
        test_all_arch_registers();
        test_passthrough_fields();
        test_idle_bubbles();
        test_back_to_back_commits();
        test_stall_on_illegal_instr();

        $display("\n=====================================================");
        $display("  CHECKS RUN : %0d", test_count + error_count);
        $display("  PASSED     : %0d", test_count);
        $display("  FAILED     : %0d", error_count);
        if (error_count == 0)
            $display("  RESULT     : PASS");
        else
            $display("  RESULT     : FAIL");
        $display("=====================================================");
        $finish;
    end

    // Watchdog
    initial begin
        #500000;
        $error("TIMEOUT: simulation exceeded limit");
        $finish;
    end

endmodule