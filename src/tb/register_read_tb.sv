`timescale 1ns / 1ps
module register_read_tb;
    import orion_pkg::*;

    // ---------------- Clock / reset ----------------
    logic clk = 0;
    logic rst_n;
    always #5 clk = ~clk;

    // ---------------- DUT I/O ----------------
    rename_dispatch_pkt_s      dispatch_in;
    logic                      flush;
    logic [ROB_PTR-1:0]        dispatch_rob_tag;

    logic [TAG_WIDTH-1:0]      cdb_tag   [NUM_CDB_PORTS];
    logic [DATA_WIDTH-1:0]     cdb_data  [NUM_CDB_PORTS];
    logic [NUM_CDB_PORTS-1:0]  cdb_valid;

    logic [NUM_CDB_PORTS-1:0]  wb_en;
    logic [TAG_WIDTH-1:0]      wb_tag  [NUM_CDB_PORTS];
    logic [DATA_WIDTH-1:0]     wb_data [NUM_CDB_PORTS];

    regread_execute_pkt_s      execute_out;

    int errors = 0;
    int checks = 0;

    register_read dut (
        .clk               (clk),
        .rst_n             (rst_n),
        .dispatch_in       (dispatch_in),
        .flush             (flush),
        .dispatch_rob_tag  (dispatch_rob_tag),
        .cdb_tag           (cdb_tag),
        .cdb_data          (cdb_data),
        .cdb_valid         (cdb_valid),
        .wb_en             (wb_en),
        .wb_tag            (wb_tag),
        .wb_data           (wb_data),
        .execute_out       (execute_out)
    );

    // ---------------- Helpers ----------------
    task automatic clear_inputs();
        dispatch_in      = '0;
        flush            = 0;
        dispatch_rob_tag = '0;
        cdb_valid        = '0;
        wb_en            = '0;
        for (int p = 0; p < NUM_CDB_PORTS; p++) begin
            cdb_tag[p]  = '0;
            cdb_data[p] = '0;
            wb_tag[p]   = '0;
            wb_data[p]  = '0;
        end
    endtask

    task automatic check(input string name,
                          input logic [DATA_WIDTH-1:0] actual,
                          input logic [DATA_WIDTH-1:0] expected);
        checks++;
        if (actual !== expected) begin
            errors++;
            $display("[FAIL] %0s : expected=0x%0h actual=0x%0h", name, expected, actual);
        end else begin
            $display("[PASS] %0s : 0x%0h", name, actual);
        end
    endtask

    task automatic check_bit(input string name, input logic actual, input logic expected);
        checks++;
        if (actual !== expected) begin
            errors++;
            $display("[FAIL] %0s : expected=%0b actual=%0b", name, expected, actual);
        end else begin
            $display("[PASS] %0s : %0b", name, actual);
        end
    endtask

    // Drive a single write-back into the PRF via port `port`, one cycle wide.
    task automatic prf_write(input logic [TAG_WIDTH-1:0] tag,
                              input logic [DATA_WIDTH-1:0] data,
                              input int port = 0);
        @(negedge clk);
        wb_en[port]   = 1;
        wb_tag[port]  = tag;
        wb_data[port] = data;
        @(posedge clk);
        #1;
        wb_en[port] = 0;
    endtask

    // Set up a dispatch packet's source operands; caller advances the clock.
    task automatic drive_dispatch(input logic [TAG_WIDTH-1:0] src1, input logic src1_valid,
                                   input logic [TAG_WIDTH-1:0] src2, input logic src2_valid);
        @(negedge clk);
        dispatch_in.p_src1       = src1;
        dispatch_in.p_src1_valid = src1_valid;
        dispatch_in.p_src2       = src2;
        dispatch_in.p_src2_valid = src2_valid;
        dispatch_in.valid        = 1;
    endtask

    // ---------------- Test sequence ----------------
    initial begin
        clear_inputs();
        rst_n = 0;
        repeat (3) @(posedge clk);
        #1 rst_n = 1;

        // T1: reset clears execute_out.valid
        check_bit("T1 reset: execute_out.valid", execute_out.valid, 1'b0);

        // T2: plain PRF read-after-write, no forwarding in flight
        prf_write(6'd5, 32'hAAAA_0001);
        drive_dispatch(6'd5, 1, 6'd0, 0);
        @(posedge clk); #1; // @suppress "Multiple statements on this line. Split the statements over multiple lines to improve readability."
        check_bit("T2 execute_out.valid", execute_out.valid, 1'b1);
        check("T2 src1 PRF read-after-write", execute_out.src1_data, 32'hAAAA_0001);

        // T3: x0 (tag 0) always reads zero, even if a write to it is attempted
        prf_write(6'd0, 32'hDEAD_BEEF); // write to tag 0 must be silently dropped
        drive_dispatch(6'd0, 1, 6'd0, 0);
        @(posedge clk); #1; // @suppress "Multiple statements on this line. Split the statements over multiple lines to improve readability."
        check("T3 x0 reads as zero", execute_out.src1_data, 32'h0000_0000);

        // T4: src_valid=0 forces zero regardless of PRF content at that tag
        drive_dispatch(6'd5, 0, 6'd0, 0); // tag 5 holds 0xAAAA0001 from T2, but not valid
        @(posedge clk); #1; // @suppress "Multiple statements on this line. Split the statements over multiple lines to improve readability."
        check("T4 src1_valid=0 forces zero", execute_out.src1_data, 32'h0000_0000);

        // T5: CDB forward on src1 takes priority over a stale PRF value on src2
        @(negedge clk);
        cdb_valid[2] = 1;
        cdb_tag[2]   = 6'd9;
        cdb_data[2]  = 32'h1234_5678;
        drive_dispatch(6'd9, 1, 6'd5, 1); // src2=5 should still read PRF (0xAAAA0001)
        @(posedge clk); #1; // @suppress "Multiple statements on this line. Split the statements over multiple lines to improve readability."
        check("T5 src1 CDB forward",   execute_out.src1_data, 32'h1234_5678);
        check("T5 src2 PRF (no fwd)",  execute_out.src2_data, 32'hAAAA_0001);
        cdb_valid[2] = 0;

        // T6: src1 and src2 forwarded simultaneously from two different CDB ports
        @(negedge clk);
        cdb_valid[0] = 1; cdb_tag[0] = 6'd10; cdb_data[0] = 32'hCAFE_0001; // @suppress "Multiple statements on this line. Split the statements over multiple lines to improve readability."
        cdb_valid[4] = 1; cdb_tag[4] = 6'd11; cdb_data[4] = 32'hCAFE_0002; // @suppress "Multiple statements on this line. Split the statements over multiple lines to improve readability."
        drive_dispatch(6'd10, 1, 6'd11, 1);
        @(posedge clk); #1; // @suppress "Multiple statements on this line. Split the statements over multiple lines to improve readability."
        check("T6 src1 CDB port0 forward", execute_out.src1_data, 32'hCAFE_0001);
        check("T6 src2 CDB port4 forward", execute_out.src2_data, 32'hCAFE_0002);
        cdb_valid = '0;

        // T7: flush forces valid=0, and data fields must still latch cleanly (no X)
        @(negedge clk);
        drive_dispatch(6'd10, 1, 6'd11, 1);
        flush = 1;
        @(posedge clk); #1; // @suppress "Multiple statements on this line. Split the statements over multiple lines to improve readability."
        check_bit("T7 flush forces valid=0", execute_out.valid, 1'b0);
        checks++;
        if ($isunknown(execute_out.src1_data) || $isunknown(execute_out.src2_data)) begin
            errors++;
            $display("[FAIL] T7 flush: data fields contain X");
        end else begin
            $display("[PASS] T7 flush: data fields are clean (no X)");
        end
        flush = 0;

        // T8: three simultaneous write-backs on different ports to different tags
        @(negedge clk);
        wb_en[0] = 1; wb_tag[0] = 6'd20; wb_data[0] = 32'h1111_1111; // @suppress "Multiple statements on this line. Split the statements over multiple lines to improve readability."
        wb_en[1] = 1; wb_tag[1] = 6'd21; wb_data[1] = 32'h2222_2222; // @suppress "Multiple statements on this line. Split the statements over multiple lines to improve readability."
        wb_en[3] = 1; wb_tag[3] = 6'd22; wb_data[3] = 32'h3333_3333; // @suppress "Multiple statements on this line. Split the statements over multiple lines to improve readability."
        @(posedge clk); #1; // @suppress "Multiple statements on this line. Split the statements over multiple lines to improve readability."
        wb_en = '0;
        drive_dispatch(6'd20, 1, 6'd21, 1);
        @(posedge clk); #1; // @suppress "Multiple statements on this line. Split the statements over multiple lines to improve readability."
        check("T8 multi-port write tag20", execute_out.src1_data, 32'h1111_1111);
        check("T8 multi-port write tag21", execute_out.src2_data, 32'h2222_2222);
        drive_dispatch(6'd22, 1, 6'd0, 0);
        @(posedge clk); #1; // @suppress "Multiple statements on this line. Split the statements over multiple lines to improve readability."
        check("T8 multi-port write tag22", execute_out.src1_data, 32'h3333_3333);

        // T9: pass-through fields survive the pipeline register untouched
        @(negedge clk);
        dispatch_in.pc   = 32'h8000_0100;
        dispatch_rob_tag = 6'd17;
        @(posedge clk); #1; // @suppress "Multiple statements on this line. Split the statements over multiple lines to improve readability."
        check("T9 passthrough pc",      execute_out.pc, 32'h8000_0100);
        checks++;
        if (execute_out.rob_tag !== 6'd17) begin
            errors++;
            $display("[FAIL] T9 passthrough rob_tag: expected=17 actual=%0d", execute_out.rob_tag);
        end else begin
            $display("[PASS] T9 passthrough rob_tag: %0d", execute_out.rob_tag);
        end

        // ---------------- Summary ----------------
        $display("--------------------------------------------------");
        if (errors == 0)
            $display("ALL %0d CHECKS PASSED", checks);
        else
            $display("%0d / %0d CHECKS FAILED", errors, checks);
        $display("--------------------------------------------------");

        $finish;
    end

endmodule