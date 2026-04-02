`timescale 1ns/1ps
import orion_pkg::*;

module rename_unit_tb;

    // Clock and reset
    logic                       clk;
    logic                       rst_n;

    // DUT inputs
    decode_rename_pkt_s         decode_rename_in;
    logic                       branch_mispredict;
    logic                       commit_valid;
    logic [REG_ADDR_WIDTH-1:0]  commit_rd;
    logic [TAG_WIDTH-1:0]       commit_pd;
    logic [TAG_WIDTH-1:0]       commit_old_pd;

    // DUT outputs
    logic                       rename_stall;
    rename_dispatch_pkt_s       rename_dispatch_out;

    // Global test tracking
    int                         error_count;

    // DUT instantiation
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

    // Clock generation: 10ns period
    initial clk = 0;
    always #5 clk = ~clk;

    // Helper task: apply reset
    task apply_reset();
        rst_n           = 0;
        decode_rename_in.r_src1         = 0;
        decode_rename_in.r_src2         = 0;
        decode_rename_in.r_dst          = 0;
        decode_rename_in.pc             = 0;
        decode_rename_in.src1_valid     = 0;
        decode_rename_in.src2_valid     = 0;
        decode_rename_in.valid          = 0;
        decode_rename_in.cause          = EXCEPT_NONE;
        branch_mispredict               = 0;
        commit_valid    = 0;
        commit_rd       = 0;
        commit_pd       = 0;
        commit_old_pd   = 0;
        repeat(2) @(posedge clk);
        rst_n = 1;
        @(posedge clk);
    endtask

    // Helper task: log error and increment counter
    task report_error(input string msg);
        $error(msg);
        error_count++;
    endtask

    // Helper task: drive an instruction
    task drive_instr(
        input [REG_ADDR_WIDTH-1:0] src1, src2, dst,
        input [DATA_WIDTH-1:0]     ipc,
        input                      s1v, s2v
    );
        decode_rename_in.r_src1      = src1;
        decode_rename_in.r_src2      = src2;
        decode_rename_in.r_dst       = dst;
        decode_rename_in.pc          = ipc;
        decode_rename_in.src1_valid  = s1v;
        decode_rename_in.src2_valid  = s2v;
        decode_rename_in.valid = 1;
        decode_rename_in.cause       = EXCEPT_NONE;
        branch_mispredict = 0;
        commit_valid = 0;
        @(posedge clk);
    endtask

    // Helper task: drive idle cycle
    task drive_idle();
        decode_rename_in.valid       = 0;
        branch_mispredict = 0;
        commit_valid      = 0;
        @(posedge clk);
    endtask

    // Helper task: drive commit
    task drive_commit(
        input [REG_ADDR_WIDTH-1:0] rd,
        input [TAG_WIDTH-1:0]      pd,
        input [TAG_WIDTH-1:0]      old_pd
    );
        commit_valid    = 1;
        commit_rd       = rd;
        commit_pd       = pd;
        commit_old_pd   = old_pd;
        decode_rename_in.valid     = 0;
        branch_mispredict = 0;
        @(posedge clk);
        commit_valid    = 0;
    endtask

    // Helper task: drive mispredict
    task drive_mispredict();
        branch_mispredict = 1;
        decode_rename_in.valid       = 0;
        commit_valid      = 0;
        @(posedge clk);
        branch_mispredict = 0;
    endtask

    // -------------------------------------------------------
    // Test 1: Basic rename trace
    // -------------------------------------------------------
    task test_basic_rename_trace();
        $display("\n=== TEST 1: Basic rename trace ===");
        apply_reset();

        // Cycle 1: ADD x3, x1, x2
        drive_instr(5'd1, 5'd2, 5'd3, 64'h100, 1, 1);
        @(negedge clk);
        if (rename_dispatch_out.valid !== 1'b1) report_error("C1: valid should be 1");
        if (rename_dispatch_out.p_dest !== 6'd32) report_error($sformatf("C1: p_dest expected p32, got %0d", rename_dispatch_out.p_dest));
        if (rename_dispatch_out.p_src1 !== 6'd1) report_error($sformatf("C1: p_src1 expected p1, got %0d", rename_dispatch_out.p_src1));
        if (rename_dispatch_out.p_src2 !== 6'd2) report_error($sformatf("C1: p_src2 expected p2, got %0d", rename_dispatch_out.p_src2));

        // Cycle 2: SUB x5, x3, x4
        drive_instr(5'd3, 5'd4, 5'd5, 64'h104, 1, 1);
        @(negedge clk);
        if (rename_dispatch_out.p_dest !== 6'd33) report_error($sformatf("C2: p_dest expected p33, got %0d", rename_dispatch_out.p_dest));
        if (rename_dispatch_out.p_src1 !== 6'd32) report_error($sformatf("C2: p_src1 expected p32 (RAW), got %0d", rename_dispatch_out.p_src1));

        // Cycle 3: Commit ADD
        drive_commit(5'd3, 6'd32, 6'd3);

        // Cycle 4: Mispredict
        drive_mispredict();
        @(negedge clk);
        if (rename_dispatch_out.valid !== 1'b0) report_error("C4: valid should be 0 during mispredict");

        $display("TEST 1 COMPLETE");
    endtask

    // -------------------------------------------------------
    // Test 2: x0 Rename Skip Verification
    // -------------------------------------------------------
    task test_x0_rename_skip();
        $display("\n=== TEST 2: x0 Rename Skip ===");
        apply_reset();

        // Step 1: Write to x0 (e.g., ADD x0, x1, x2)
        // Should not consume a physical register from the free list
        drive_instr(5'd1, 5'd2, 5'd0, 64'h200, 1, 1);
        @(negedge clk);
        if (rename_dispatch_out.valid !== 1'b1) report_error("x0_Write: valid should be 1");
        if (rename_dispatch_out.p_dest !== 6'd0) report_error($sformatf("x0_Write: p_dest expected 0, got %0d", rename_dispatch_out.p_dest));
        if (rename_dispatch_out.old_p_dest !== 6'd0) report_error($sformatf("x0_Write: old_p_dest expected 0, got %0d", rename_dispatch_out.old_p_dest));
        
        // Step 2: Write to a normal register immediately after
        // This should get the FIRST free list entry (p32) because x0 skipped allocation
        drive_instr(5'd3, 5'd4, 5'd5, 64'h204, 1, 1);
        @(negedge clk);
        if (rename_dispatch_out.valid !== 1'b1) report_error("x0_NextWrite: valid should be 1");
        if (rename_dispatch_out.p_dest !== 6'd32) report_error($sformatf("x0_NextWrite: p_dest expected p32 (free list head was not advanced by x0), got %0d", rename_dispatch_out.p_dest));

        // Step 3: Read from x0 (e.g., ADD x6, x0, x5)
        // Ensure x0 maps back to physical register 0
        drive_instr(5'd0, 5'd5, 5'd6, 64'h208, 1, 1);
        @(negedge clk);
        if (rename_dispatch_out.valid !== 1'b1) report_error("x0_Read: valid should be 1");
        if (rename_dispatch_out.p_src1 !== 6'd0) report_error($sformatf("x0_Read: p_src1 mapped to x0 expected 0, got %0d", rename_dispatch_out.p_src1));
        if (rename_dispatch_out.p_src2 !== 6'd32) report_error($sformatf("x0_Read: p_src2 mapped to x5 expected 32, got %0d", rename_dispatch_out.p_src2));

        $display("TEST 2 COMPLETE");
    endtask

    // -------------------------------------------------------
    // Test 3: Stall when free list exhausted
    // -------------------------------------------------------
    task test_stall();
        $display("\n=== TEST 3: Stall on free list exhaustion ===");
        apply_reset();

        // Fill up all 32 free physical registers
        repeat(32) begin
            drive_instr(5'd1, 5'd2, 5'd3, 64'h0, 1, 1);
        end

        // Next instruction should stall
        drive_instr(5'd1, 5'd2, 5'd4, 64'h0, 1, 1);
        @(negedge clk);
        if (rename_stall !== 1'b1) report_error("STALL: rename_stall should be asserted when free list empty");
        if (rename_dispatch_out.valid !== 1'b0) report_error("STALL: valid should be 0 when stalling");

        $display("TEST 3 COMPLETE");
    endtask

    // -------------------------------------------------------
    // Test 4: src_valid gating
    // -------------------------------------------------------
    task test_src_valid();
        $display("\n=== TEST 4: src_valid gating ===");
        apply_reset();

        // LUI-style
        drive_instr(5'd1, 5'd2, 5'd3, 64'h0, 0, 0);
        @(negedge clk);
        if (rename_dispatch_out.p_src1_valid !== 1'b0) report_error("SRC: p_src1_valid should be 0");
        if (rename_dispatch_out.p_src2_valid !== 1'b0) report_error("SRC: p_src2_valid should be 0");

        // JALR-style
        drive_instr(5'd1, 5'd2, 5'd4, 64'h4, 1, 0);
        @(negedge clk);
        if (rename_dispatch_out.p_src1_valid !== 1'b1) report_error("SRC: p_src1_valid should be 1");
        if (rename_dispatch_out.p_src2_valid !== 1'b0) report_error("SRC: p_src2_valid should be 0");

        $display("TEST 4 COMPLETE");
    endtask

    // -------------------------------------------------------
    // Main execution block
    // -------------------------------------------------------
    initial begin
        error_count = 0;
        
        $display("======================================");
        $display("  STARTING RENAME UNIT TESTBENCH");
        $display("======================================");

        test_basic_rename_trace();
        test_x0_rename_skip();
        test_stall();
        test_src_valid();

        $display("\n======================================");
        if (error_count == 0) begin
            $display("  SIMULATION PASSED: 0 ERRORS");
        end else begin
            $display("  SIMULATION FAILED: %0d ERRORS FOUND", error_count);
        end
        $display("======================================");
        $finish;
    end

    // Timeout watchdog
    initial begin
        #100000;
        $error("TIMEOUT: simulation exceeded time limit");
        $finish;
    end

endmodule