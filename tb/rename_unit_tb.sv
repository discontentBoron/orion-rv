`timescale 1ns/1ps
import orion_pkg::*;
module rename_unit_tb;
    logic                       clk;
    logic                       rst_n;
    logic [REG_ADDR_WIDTH-1:0]  r_src1;
    logic [REG_ADDR_WIDTH-1:0]  r_src2;
    logic [REG_ADDR_WIDTH-1:0]  r_dst;
    logic [DATA_WIDTH-1:0]      pc;
    logic                       src1_valid;
    logic                       src2_valid;
    logic                       instr_valid;
    except_cause_e              cause;
    logic                       branch_mispredict;
    logic                       commit_valid;      
    logic [REG_ADDR_WIDTH-1:0]  commit_rd;      
    logic [TAG_WIDTH-1:0]       commit_pd;         
    logic [TAG_WIDTH-1:0]       commit_old_pd;     
    logic                       rename_stall;
    rename_dispatch_pkt_s       rename_dispatch_out;

    rename_unit rename_unit_dut (
        .clk(clk),
        .rst_n(rst_n),
        .r_src1(r_src1),
        .r_src2(r_src2),
        .r_dst(r_dst),
        .pc(pc),
        .src1_valid(src1_valid),
        .src2_valid(src2_valid),
        .instr_valid(instr_valid),
        .cause(cause),
        .branch_mispredict(branch_mispredict),
        .commit_valid(commit_valid),
        .commit_rd(commit_rd),
        .commit_pd(commit_pd),
        .commit_old_pd(commit_old_pd),
        .rename_stall(rename_stall),
        .rename_dispatch_out(rename_dispatch_out)
    );
    initial clk = 1'b0;
    always #10 clk = ~clk;

    task apply_reset();
        rst_n = 1'b0;
        r_src1 = 0;
        r_src2 = 0;
        r_dst  = 0;
        pc = 0;
        src1_valid = 0;
        src2_valid = 0;
        instr_valid = 0;
        cause = EXCEPT_NONE;
        branch_mispredict = 0;
        commit_valid = 0;
        commit_rd = 0;
        commit_pd = 0;
        commit_old_pd = 0;
        repeat(2) @(posedge clk);
        rst_n = 1;
        @(posedge clk);
    endtask

    task test_inputs(
        input   [REG_ADDR_WIDTH-1:0]  src1, src2, dst, 
        input   [DATA_WIDTH-1:0]  pc_val,
        input   s1_valid, s2_valid
    );
        r_src1  =   src1;
        r_src2  =   src2;
        r_dst   =   dst;
        pc      =   pc_val;
        src1_valid = s1_valid;
        src2_valid = s2_valid;
        instr_valid = 1;
        cause = EXCEPT_NONE;
        branch_mispredict = 0;
        commit_valid = 0;
        @(posedge clk); 
    endtask

    task idle_state();
        instr_valid = 0;
        commit_valid = 0;
        branch_mispredict = 0;
        @(posedge clk);
    endtask

    task commit_instr(      
        input[REG_ADDR_WIDTH-1:0]  rd,          
        input[TAG_WIDTH-1:0]       pd,          
        input[TAG_WIDTH-1:0]       old_pd
    );
        commit_valid = 1;
        commit_rd = rd;
        commit_pd = pd;
        commit_old_pd = old_pd;
        @(posedge clk); 
        commit_valid = 0;
    endtask
    task mispredict_trigger();
        branch_mispredict   = 1;
        instr_valid         = 0;
        commit_valid        = 0;
        @(posedge clk);
        branch_mispredict   = 0;
    endtask

    task basic_trace();
        $display("Basic Trace Test \n");
        apply_reset();
        test_inputs(5'd1, 5'd2, 5'd3, 32'h00000000,1, 1);
        test_inputs(5'd3, 5'd4, 5'd5, 32'h00000004,1, 1);
        test_inputs(5'd5, 5'd2, 5'd3, 32'h00000008,1, 1);
        test_inputs(5'd3, 5'd1, 5'd6, 32'h0000000C,1, 1);
        commit_instr(5'd3,6'd32,6'd3);
        mispredict_trigger();
        test_inputs(5'd1,5'd2,5'd7,32'h000000FA, 1,1);
    endtask

    initial begin
        $display("Beginning test sequence......");
        basic_trace();
        $display("TEST COMPLETE.");
        $finish;
    end
    

endmodule

