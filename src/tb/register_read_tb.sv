`timescale 1ns/1ps

import orion_pkg::*;

module register_read_tb;

    logic clk;
    logic rst_n;

    rename_dispatch_pkt_s dispatch_in;

    logic flush;

    logic [TAG_WIDTH-1:0] cdb_tag;
    logic [DATA_WIDTH-1:0] cdb_data;
    logic cdb_valid;

    logic wb_en;
    logic [TAG_WIDTH-1:0] wb_tag;
    logic [DATA_WIDTH-1:0] wb_data;

    regread_execute_pkt_s execute_out;

    int error_count;
    int test_count;

    register_read dut(
        .clk(clk),
        .rst_n(rst_n),
        .dispatch_in(dispatch_in),
        .flush(flush),
        .cdb_tag(cdb_tag),
        .cdb_data(cdb_data),
        .cdb_valid(cdb_valid),
        .wb_en(wb_en),
        .wb_tag(wb_tag),
        .wb_data(wb_data),
        .execute_out(execute_out)
    );

    initial clk = 0;
    always #5 clk = ~clk;

    task automatic report_error(input string msg);

        $error("[FAIL] %s", msg);

        error_count++;

    endtask

    task automatic report_pass(input string msg);

        $display("[PASS] %s", msg);

        test_count++;

    endtask

    task automatic check_data(
        input logic [DATA_WIDTH-1:0] got,
        input logic [DATA_WIDTH-1:0] expected,
        input string label
    );

        if(got !== expected)

            report_error(
                $sformatf("%s expected=%h got=%h",
                label,
                expected,
                got)
            );

        else
            report_pass(label);

    endtask

    task automatic apply_reset();

        rst_n = 0;

        dispatch_in = '0;

        flush = 0;

        wb_en = 0;
        wb_tag = 0;
        wb_data = 0;

        cdb_tag = 0;
        cdb_data = 0;
        cdb_valid = 0;

        repeat(2) @(posedge clk);

        rst_n = 1;

        @(posedge clk);

    endtask

    task automatic write_prf(
        input logic [TAG_WIDTH-1:0] tag,
        input logic [DATA_WIDTH-1:0] data
    );

        wb_en = 1;
        wb_tag = tag;
        wb_data = data;

        @(posedge clk);

        wb_en = 0;

    endtask

    task automatic drive_instr(
        input logic [TAG_WIDTH-1:0] src1,
        input logic [TAG_WIDTH-1:0] src2,
        input logic src1_valid,
        input logic src2_valid
    );

        dispatch_in.valid = 1;

        dispatch_in.p_src1 = src1;
        dispatch_in.p_src2 = src2;

        dispatch_in.p_src1_valid = src1_valid;
        dispatch_in.p_src2_valid = src2_valid;

        @(posedge clk);

    endtask

    task automatic test_basic_read();

        $display("\n=== TEST 1 ===");

        apply_reset();

        write_prf(6'd5, 32'h12345678);

        drive_instr(6'd5, 6'd0, 1, 0);

        @(negedge clk);

        check_data(
            execute_out.src1_data,
            32'h12345678,
            "TEST1 src1 read"
        );

    endtask

    task automatic test_x0();

        $display("\n=== TEST 2 ===");

        apply_reset();

        write_prf(6'd0, 32'hFFFFFFFF);

        drive_instr(6'd0, 6'd0, 1, 0);

        @(negedge clk);

        check_data(
            execute_out.src1_data,
            32'h00000000,
            "TEST2 x0"
        );

    endtask

    task automatic test_flush();

        $display("\n=== TEST 3 ===");

        apply_reset();

        dispatch_in.valid = 1;

        flush = 1;

        @(posedge clk);
        @(negedge clk);

        if(execute_out.valid == 0)
            report_pass("TEST3 flush");

        else
            report_error("TEST3 flush");

    endtask

    initial begin

        error_count = 0;
        test_count = 0;

        $display("=================================");
        $display(" REGISTER READ TESTBENCH ");
        $display("=================================");

        test_basic_read();

        test_x0();

        test_flush();

        $display("\n=================================");

        $display("TOTAL  : %0d", test_count + error_count);

        $display("PASSED : %0d", test_count);

        $display("FAILED : %0d", error_count);

        if(error_count == 0)
            $display("RESULT : PASS");

        else
            $display("RESULT : FAIL");

        $display("=================================");

        $finish;

    end

endmodule