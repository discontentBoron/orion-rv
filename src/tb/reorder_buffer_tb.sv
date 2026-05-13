`timescale 1ns/1ps
import orion_pkg::*;

module reorder_buffer_tb;

    // ---------------------------------------------------------------
    // DUT signals
    // ---------------------------------------------------------------
    logic                       clk;
    logic                       rst_n;

    logic [REG_ADDR_WIDTH-1:0]  dispatch_r_dst;
    rename_dispatch_pkt_s       dispatch_in;
    logic [ROB_PTR-1:0]         rob_tag_out;
    logic                       rob_full;

    logic                       cdb_valid;
    logic [ROB_PTR-1:0]         cdb_rob_tag;
    logic                       cdb_mispredict;
    logic                       cdb_exception;
    except_cause_e              cdb_cause;

    logic                       commit_valid;
    logic [REG_ADDR_WIDTH-1:0]  commit_rd;
    logic [TAG_WIDTH-1:0]       commit_pd;
    logic [TAG_WIDTH-1:0]       commit_old_pd;
    logic                       store_commit;
    logic                       branch_mispredict;
    logic                       exception_valid;
    except_cause_e              exception_cause;
    logic [DATA_WIDTH-1:0]      exception_pc;

    // ---------------------------------------------------------------
    // DUT instantiation
    // ---------------------------------------------------------------
    reorder_buffer dut (
        .clk              (clk),
        .rst_n            (rst_n),
        .dispatch_r_dst   (dispatch_r_dst),
        .dispatch_in      (dispatch_in),
        .rob_tag_out      (rob_tag_out),
        .rob_full         (rob_full),
        .cdb_valid        (cdb_valid),
        .cdb_rob_tag      (cdb_rob_tag),
        .cdb_mispredict   (cdb_mispredict),
        .cdb_exception    (cdb_exception),
        .cdb_cause        (cdb_cause),
        .commit_valid     (commit_valid),
        .commit_rd        (commit_rd),
        .commit_pd        (commit_pd),
        .commit_old_pd    (commit_old_pd),
        .store_commit     (store_commit),
        .branch_mispredict(branch_mispredict),
        .exception_valid  (exception_valid),
        .exception_cause  (exception_cause),
        .exception_pc     (exception_pc)
    );

    // ---------------------------------------------------------------
    // Clock
    // ---------------------------------------------------------------
    initial clk = 0;
    always #5 clk = ~clk;  // 100 MHz

    // ---------------------------------------------------------------
    // Test tracking
    // ---------------------------------------------------------------
    int pass_count = 0;
    int fail_count = 0;

    task automatic check(
        input string  test_name,
        input logic   condition
    );
        if (condition) begin
            $display("[PASS] %s", test_name);
            pass_count++;
        end else begin
            $display("[FAIL] %s  -- time=%0t", test_name, $time);
            fail_count++;
        end
    endtask

    // ---------------------------------------------------------------
    // Helpers
    // ---------------------------------------------------------------

    // Drive a dispatch packet with sane defaults; caller overrides fields
    task automatic drive_dispatch(
        input logic [REG_ADDR_WIDTH-1:0] r_dst,
        input logic [TAG_WIDTH-1:0]      p_dest,
        input logic [TAG_WIDTH-1:0]      old_p_dest,
        input logic                      reg_we,
        input logic [DATA_WIDTH-1:0]     pc,
        input logic [DATA_WIDTH-1:0]     predicted_pc,
        input instr_class_e              instr_class,
        input logic                      except,
        input except_cause_e             except_cause
    );
        dispatch_r_dst          = r_dst;
        dispatch_in.p_dest      = p_dest;
        dispatch_in.old_p_dest  = old_p_dest;
        dispatch_in.reg_we      = reg_we;
        dispatch_in.pc          = pc;
        dispatch_in.predicted_pc= predicted_pc;
        dispatch_in.instr_class = instr_class;
        dispatch_in.except      = except;
        dispatch_in.except_cause= except_cause;
        dispatch_in.valid       = 1'b1;
        // Fields not used by ROB — tie off
        dispatch_in.p_src1      = '0;
        dispatch_in.p_src2      = '0;
        dispatch_in.p_src1_valid= 1'b0;
        dispatch_in.p_src2_valid= 1'b0;
        dispatch_in.imm_val     = '0;
        dispatch_in.func_unit_type  = func_unit_type_e'(0);
        dispatch_in.exec_unit_uop   = exec_unit_opcode_e'(0);
    endtask

    task automatic clear_dispatch();
        dispatch_in         = '0;
        dispatch_r_dst      = '0;
    endtask

    task automatic clear_cdb();
        cdb_valid       = 1'b0;
        cdb_rob_tag     = '0;
        cdb_mispredict  = 1'b0;
        cdb_exception   = 1'b0;
        cdb_cause       = EXCEPT_NONE;
    endtask

    task automatic do_reset();
        rst_n = 0;
        clear_dispatch();
        clear_cdb();
        @(posedge clk);
        #1;
        @(posedge clk); 
        #1;
        rst_n = 1;
        @(posedge clk); 
        #1;
    endtask

    // Wait N cycles
    task automatic wait_cycles(input int n);
        repeat(n) @(posedge clk);
        #1;
    endtask

    // ---------------------------------------------------------------
    // TEST 1: Reset state
    // ---------------------------------------------------------------
    task automatic test_reset();
        $display("\n--- TEST 1: Reset state ---");
        do_reset();
        check("rob_full deasserted after reset",    rob_full    == 1'b0);
        check("commit_valid deasserted after reset", commit_valid == 1'b0);
        check("exception_valid deasserted after reset", exception_valid == 1'b0);
        check("branch_mispredict deasserted after reset", branch_mispredict == 1'b0);
        check("store_commit deasserted after reset", store_commit == 1'b0);
    endtask

    // ---------------------------------------------------------------
    // TEST 2: Single dispatch → CDB writeback → normal commit
    // ---------------------------------------------------------------
    task automatic test_single_normal_commit();
        logic [ROB_PTR-1:0] captured_tag;
        $display("\n--- TEST 2: Single dispatch → CDB → normal commit ---");
        do_reset();

        // Dispatch one ALU instruction
        drive_dispatch(
            .r_dst(5'd3), .p_dest(6'd10), .old_p_dest(6'd5),
            .reg_we(1'b1), .pc(32'hDEAD_0000), .predicted_pc(32'hDEAD_0004),
            .instr_class(INSTR_ALU), .except(1'b0), .except_cause(EXCEPT_NONE)
        );
        captured_tag = rob_tag_out;
        @(posedge clk); 
        #1;
        clear_dispatch();

        check("rob_tag_out was 0 at dispatch", captured_tag == '0);

        // CDB writeback — mark done
        cdb_valid      = 1'b1;
        cdb_rob_tag    = captured_tag;
        cdb_mispredict = 1'b0;
        cdb_exception  = 1'b0;
        cdb_cause      = EXCEPT_NONE;
        @(posedge clk); 
        #1;
        clear_cdb();

        // One cycle later: commit should fire
        @(posedge clk); 
        #1;
        check("commit_valid asserted",    commit_valid  == 1'b1);
        check("commit_rd correct",        commit_rd     == 5'd3);
        check("commit_pd correct",        commit_pd     == 6'd10);
        check("commit_old_pd correct",    commit_old_pd == 6'd5);
        check("store_commit not asserted", store_commit == 1'b0);

        // Next cycle: commit_valid must deassert (ROB empty)
        @(posedge clk); 
        #1;
        check("commit_valid deasserted after drain", commit_valid == 1'b0);
    endtask

    // ---------------------------------------------------------------
    // TEST 3: rob_full assertion
    // ---------------------------------------------------------------
    task automatic test_rob_full();
        $display("\n--- TEST 3: ROB full ---");
        do_reset();

        // Fill all ROB_SIZE slots
        for (int i = 0; i < ROB_SIZE; i++) begin
            drive_dispatch(
                .r_dst(5'd1), .p_dest(6'(i+1)), .old_p_dest(6'(i)),
                .reg_we(1'b1), .pc(32'(i*4)), .predicted_pc(32'(i*4+4)),
                .instr_class(INSTR_ALU), .except(1'b0), .except_cause(EXCEPT_NONE)
            );
            @(posedge clk); 
            #1;
        end
        clear_dispatch();

        check("rob_full asserted after filling", rob_full == 1'b1);

        // Try to dispatch one more — should be blocked
        drive_dispatch(
            .r_dst(5'd2), .p_dest(6'd63), .old_p_dest(6'd62),
            .reg_we(1'b1), .pc(32'hFFFF_0000), .predicted_pc(32'hFFFF_0004),
            .instr_class(INSTR_ALU), .except(1'b0), .except_cause(EXCEPT_NONE)
        );
        @(posedge clk); 
        #1;
        clear_dispatch();
        // ROB should still be full (tail didn't advance)
        check("rob_full still asserted — dispatch blocked", rob_full == 1'b1);
    endtask

    // ---------------------------------------------------------------
    // TEST 4: store_commit
    // ---------------------------------------------------------------
    task automatic test_store_commit();
        logic [ROB_PTR-1:0] tag;
        $display("\n--- TEST 4: store_commit ---");
        do_reset();

        drive_dispatch(
            .r_dst(5'd0), .p_dest(6'd0), .old_p_dest(6'd0),
            .reg_we(1'b0), .pc(32'hAAAA_0000), .predicted_pc(32'hAAAA_0004),
            .instr_class(INSTR_STORE), .except(1'b0), .except_cause(EXCEPT_NONE)
        );
        tag = rob_tag_out;
        @(posedge clk); 
        #1;
        clear_dispatch();

        cdb_valid   = 1'b1;
        cdb_rob_tag = tag;
        @(posedge clk); 
        #1;
        clear_cdb();

        @(posedge clk); 
        #1;
        check("store_commit asserted",     store_commit  == 1'b1);
        check("commit_valid NOT asserted for store (reg_we=0)", commit_valid == 1'b0);
    endtask

    // ---------------------------------------------------------------
    // TEST 5: Decode-time exception (no CDB writeback)
    // ---------------------------------------------------------------
    task automatic test_decode_exception_no_cdb();
        $display("\n--- TEST 5: Decode-time exception, no CDB ---");
        do_reset();

        drive_dispatch(
            .r_dst(5'd0), .p_dest(6'd0), .old_p_dest(6'd0),
            .reg_we(1'b0), .pc(32'hBAD0_0000), .predicted_pc(32'hBAD0_0004),
            .instr_class(INSTR_NOP), .except(1'b1),
            .except_cause(EXCEPT_ILLEGAL_INST)
        );
        @(posedge clk); 
        #1;
        clear_dispatch();

        // No CDB — exception should fire because done=1 was set at dispatch
        // Outputs are registered: need one more cycle
        @(posedge clk); 
        #1;
        check("exception_valid asserted without CDB",
              exception_valid == 1'b1);
        check("exception_pc correct",
              exception_pc == 32'hBAD0_0000);
        check("exception_cause correct",
              exception_cause == EXCEPT_ILLEGAL_INST);
        check("commit_valid NOT asserted on exception",
              commit_valid == 1'b0);

        // exception_valid must deassert next cycle (ROB empty, entry consumed)
        @(posedge clk); 
        #1;
        check("exception_valid deasserted — no repeat fire",
              exception_valid == 1'b0);
    endtask

    // ---------------------------------------------------------------
    // TEST 6: Fill ROB completely, drain via normal commits
    // ---------------------------------------------------------------
    task automatic test_fill_and_drain();
        logic [ROB_PTR-1:0] tags [ROB_SIZE-1:0];
        $display("\n--- TEST 6: Fill and drain ROB ---");
        do_reset();

        // Dispatch ROB_SIZE instructions
        for (int i = 0; i < ROB_SIZE; i++) begin
            drive_dispatch(
                .r_dst(5'(i % 32)), .p_dest(6'(i+1)), .old_p_dest(6'(i)),
                .reg_we(1'b1), .pc(32'(i*4)), .predicted_pc(32'(i*4+4)),
                .instr_class(INSTR_ALU), .except(1'b0), .except_cause(EXCEPT_NONE)
            );
            tags[i] = rob_tag_out;
            @(posedge clk); 
            #1;
        end
        clear_dispatch();
        check("ROB full after filling", rob_full == 1'b1);

        // Write back in-order via CDB
        for (int i = 0; i < ROB_SIZE; i++) begin
            cdb_valid   = 1'b1;
            cdb_rob_tag = tags[i];
            @(posedge clk); 
            #1;
            clear_cdb();
            // One cycle after CDB, commit fires
            @(posedge clk); 
            #1;
            check($sformatf("commit_valid slot %0d", i), commit_valid == 1'b1);
        end

        // ROB should now be empty
        @(posedge clk); 
        #1;
        check("ROB empty after full drain", rob_full == 1'b0);
        check("commit_valid deasserted after drain", commit_valid == 1'b0);
    endtask

    // ---------------------------------------------------------------
    // TEST 7: Exception commit — single pulse, ROB empty after
    // ---------------------------------------------------------------
    task automatic test_exception_commit();
        logic [ROB_PTR-1:0] tag0, tag1, tag2;
        $display("\n--- TEST 7: Exception commit, flush, no repeat ---");
        do_reset();

        // Dispatch 3 instructions; middle one will raise exception via CDB
        drive_dispatch(
            .r_dst(5'd1), .p_dest(6'd10), .old_p_dest(6'd5),
            .reg_we(1'b1), .pc(32'h1000), .predicted_pc(32'h1004),
            .instr_class(INSTR_ALU), .except(1'b0), .except_cause(EXCEPT_NONE)
        );
        tag0 = rob_tag_out;
        @(posedge clk); 
        #1;

        drive_dispatch(
            .r_dst(5'd2), .p_dest(6'd11), .old_p_dest(6'd6),
            .reg_we(1'b1), .pc(32'h1004), .predicted_pc(32'h1008),
            .instr_class(INSTR_ALU), .except(1'b0), .except_cause(EXCEPT_NONE)
        );
        tag1 = rob_tag_out;
        @(posedge clk); 
        #1;

        drive_dispatch(
            .r_dst(5'd3), .p_dest(6'd12), .old_p_dest(6'd7),
            .reg_we(1'b1), .pc(32'h1008), .predicted_pc(32'h100C),
            .instr_class(INSTR_ALU), .except(1'b0), .except_cause(EXCEPT_NONE)
        );
        tag2 = rob_tag_out;
        @(posedge clk); 
        #1;
        clear_dispatch();

        // Complete tag0 normally first
        cdb_valid   = 1'b1;
        cdb_rob_tag = tag0;
        @(posedge clk); 
        #1;
        clear_cdb();
        @(posedge clk); 
        #1;  // commit fires for tag0
        check("tag0 commits normally before exception", commit_valid == 1'b1);

        // Now tag1 completes with exception
        cdb_valid     = 1'b1;
        cdb_rob_tag   = tag1;
        cdb_exception = 1'b1;
        cdb_cause     = EXCEPT_ILLEGAL_INST;
        @(posedge clk); 
        #1;
        clear_cdb();

        @(posedge clk); 
        #1;
        check("exception_valid asserted",          exception_valid  == 1'b1);
        check("exception_pc correct (tag1 pc)",    exception_pc     == 32'h1004);
        check("exception_cause correct",           exception_cause  == EXCEPT_ILLEGAL_INST);
        check("commit_valid NOT asserted",         commit_valid     == 1'b0);
        check("rob_full deasserted — flushed",     rob_full         == 1'b0);

        // Must not repeat
        @(posedge clk); 
        #1;
        check("exception_valid deasserted next cycle", exception_valid == 1'b0);
    endtask

    // ---------------------------------------------------------------
    // TEST 8: Mispredict commit — flush, single pulse, ROB empty
    // ---------------------------------------------------------------
    task automatic test_mispredict_commit();
        logic [ROB_PTR-1:0] tag0, tag1, tag2;
        $display("\n--- TEST 8: Mispredict commit ---");
        do_reset();

        // Dispatch: branch (tag0), then two speculative instructions
        drive_dispatch(
            .r_dst(5'd1), .p_dest(6'd10), .old_p_dest(6'd5),
            .reg_we(1'b1), .pc(32'h2000), .predicted_pc(32'h2010),
            .instr_class(INSTR_BRANCH), .except(1'b0), .except_cause(EXCEPT_NONE)
        );
        tag0 = rob_tag_out;
        @(posedge clk); 
        #1;

        drive_dispatch(
            .r_dst(5'd2), .p_dest(6'd11), .old_p_dest(6'd6),
            .reg_we(1'b1), .pc(32'h2004), .predicted_pc(32'h2008),
            .instr_class(INSTR_ALU), .except(1'b0), .except_cause(EXCEPT_NONE)
        );
        tag1 = rob_tag_out;
        @(posedge clk); 
        #1;

        drive_dispatch(
            .r_dst(5'd3), .p_dest(6'd12), .old_p_dest(6'd7),
            .reg_we(1'b1), .pc(32'h2008), .predicted_pc(32'h200C),
            .instr_class(INSTR_ALU), .except(1'b0), .except_cause(EXCEPT_NONE)
        );
        tag2 = rob_tag_out;
        @(posedge clk); 
        #1;
        clear_dispatch();

        // Branch completes with mispredict
        cdb_valid      = 1'b1;
        cdb_rob_tag    = tag0;
        cdb_mispredict = 1'b1;
        @(posedge clk); 
        #1;
        clear_cdb();

        @(posedge clk); 
        #1;
        check("branch_mispredict asserted",       branch_mispredict == 1'b1);
        // reg_we=1 on branch (JALR-style) — commit_valid should fire
        check("commit_valid asserted (reg_we=1)", commit_valid      == 1'b1);
        check("ROB empty after flush",            rob_full          == 1'b0);

        @(posedge clk); 
        #1;
        check("branch_mispredict deasserted next cycle", branch_mispredict == 1'b0);
        check("commit_valid deasserted next cycle",      commit_valid      == 1'b0);
    endtask

    // ---------------------------------------------------------------
    // TEST 9: Out-of-order CDB writeback, in-order commit
    // ---------------------------------------------------------------
    task automatic test_ooo_writeback_inorder_commit();
        logic [ROB_PTR-1:0] tag0, tag1, tag2;
        $display("\n--- TEST 9: OOO writeback, in-order commit ---");
        do_reset();

        drive_dispatch(
            .r_dst(5'd1), .p_dest(6'd10), .old_p_dest(6'd5),
            .reg_we(1'b1), .pc(32'h3000), .predicted_pc(32'h3004),
            .instr_class(INSTR_ALU), .except(1'b0), .except_cause(EXCEPT_NONE)
        );
        tag0 = rob_tag_out;
        @(posedge clk); 
        #1;

        drive_dispatch(
            .r_dst(5'd2), .p_dest(6'd11), .old_p_dest(6'd6),
            .reg_we(1'b1), .pc(32'h3004), .predicted_pc(32'h3008),
            .instr_class(INSTR_ALU), .except(1'b0), .except_cause(EXCEPT_NONE)
        );
        tag1 = rob_tag_out;
        @(posedge clk); 
        #1;

        drive_dispatch(
            .r_dst(5'd3), .p_dest(6'd12), .old_p_dest(6'd7),
            .reg_we(1'b1), .pc(32'h3008), .predicted_pc(32'h300C),
            .instr_class(INSTR_ALU), .except(1'b0), .except_cause(EXCEPT_NONE)
        );
        tag2 = rob_tag_out;
        @(posedge clk); 
        #1;
        clear_dispatch();

        // Complete out-of-order: tag2, tag1, tag0
        cdb_valid = 1'b1; 
        cdb_rob_tag = tag2;
        @(posedge clk); 
        #1; 
        clear_cdb();
        cdb_valid = 1'b1; 
        cdb_rob_tag = tag1; 
        @(posedge clk); 
        #1; 
        clear_cdb();
        // Nothing should have committed yet — tag0 still pending
        @(posedge clk); 
        #1;
        check("No commit while head (tag0) not done", commit_valid == 1'b0);

        // Now complete tag0
        cdb_valid = 1'b1; 
        cdb_rob_tag = tag0; 
        @(posedge clk); 
        #1; 
        clear_cdb();

        // tag0 commits first
        @(posedge clk); 
        #1;
        check("tag0 commits first (in-order)",  commit_valid == 1'b1);
        check("commit_rd is tag0's rd",         commit_rd    == 5'd1);

        // tag1 commits next cycle (already done)
        @(posedge clk); 
        #1;
        check("tag1 commits second", commit_valid == 1'b1);
        check("commit_rd is tag1's rd", commit_rd == 5'd2);

        // tag2 commits next cycle
        @(posedge clk); 
        #1;
        check("tag2 commits third", commit_valid == 1'b1);
        check("commit_rd is tag2's rd", commit_rd == 5'd3);

        @(posedge clk); 
        #1;
        check("ROB empty after drain", commit_valid == 1'b0);
    endtask

    // ---------------------------------------------------------------
    // TEST 10: Dispatch gated during flush (mispredict same cycle)
    // ---------------------------------------------------------------
    task automatic test_dispatch_gated_on_flush();
        logic [ROB_PTR-1:0] tag0;
        $display("\n--- TEST 10: Dispatch gated during flush ---");
        do_reset();

        drive_dispatch(
            .r_dst(5'd1), .p_dest(6'd10), .old_p_dest(6'd5),
            .reg_we(1'b0), .pc(32'h4000), .predicted_pc(32'h4010),
            .instr_class(INSTR_BRANCH), .except(1'b0), .except_cause(EXCEPT_NONE)
        );
        tag0 = rob_tag_out;
        @(posedge clk); 
        #1;
        clear_dispatch();

        // Mark branch done+mispredict via CDB
        cdb_valid = 1'b1; 
        cdb_rob_tag = tag0; 
        cdb_mispredict = 1'b1;
        @(posedge clk); 
        #1;
        clear_cdb();

        // On the SAME cycle that mispredict commit fires,
        // attempt a new dispatch — it must be blocked
        drive_dispatch(
            .r_dst(5'd2), .p_dest(6'd20), .old_p_dest(6'd15),
            .reg_we(1'b1), .pc(32'hDEAD_BEEF), .predicted_pc(32'hDEAD_BEF4),
            .instr_class(INSTR_ALU), .except(1'b0), .except_cause(EXCEPT_NONE)
        );
        @(posedge clk); 
        #1;
        clear_dispatch();

        // branch_mispredict should have fired this cycle
        check("branch_mispredict fired",  branch_mispredict == 1'b1);
        // ROB must be empty — if dispatch wasn't gated, rob_full or a stale
        // entry would indicate corruption
        check("ROB empty — dispatch was gated", rob_full == 1'b0);

        @(posedge clk); 
        #1;
        // After flush, a fresh dispatch should work fine
        drive_dispatch(
            .r_dst(5'd3), .p_dest(6'd21), .old_p_dest(6'd16),
            .reg_we(1'b1), .pc(32'h5000), .predicted_pc(32'h5004),
            .instr_class(INSTR_ALU), .except(1'b0), .except_cause(EXCEPT_NONE)
        );
        @(posedge clk); 
        #1;
        clear_dispatch();
        check("Dispatch resumes after flush", rob_full == 1'b0);
    endtask

    // ---------------------------------------------------------------
    // MAIN
    // ---------------------------------------------------------------
    initial begin
        $display("========================================");
        $display("  reorder_buffer_tb — orion_rv");
        $display("========================================");

        test_reset();
        test_single_normal_commit();
        test_rob_full();
        test_store_commit();
        test_decode_exception_no_cdb();
        test_fill_and_drain();
        test_exception_commit();
        test_mispredict_commit();
        test_ooo_writeback_inorder_commit();
        test_dispatch_gated_on_flush();

        $display("\n========================================");
        $display("  Results: %0d passed, %0d failed", pass_count, fail_count);
        $display("========================================\n");

        if (fail_count == 0)
            $display("ALL TESTS PASSED");
        else
            $display("FAILURES DETECTED — see above");

        $finish;
    end

    // ---------------------------------------------------------------
    // Timeout watchdog
    // ---------------------------------------------------------------
    initial begin
        #100000;
        $display("[TIMEOUT] Simulation exceeded 100us!");
        $finish;
    end

    // ---------------------------------------------------------------
    // Optional: waveform dump
    // ---------------------------------------------------------------
    initial begin
        $dumpfile("reorder_buffer_tb.vcd");
        $dumpvars(0, reorder_buffer_tb);
    end

endmodule