import orion_pkg::*;
module regread_demux(
    input regread_execute_pkt_s execute_in,

    output regread_execute_pkt_s regread_alu_out,
    output regread_execute_pkt_s regread_mul_out,
    output regread_execute_pkt_s regread_div_out,
    output regread_execute_pkt_s regread_branch_out,
    output regread_execute_pkt_s regread_lsu_out

);
    logic is_mul_op, is_div_op;
    assign is_mul_op = execute_in.exec_unit_uop inside {MUL, MULH, MULHSU, MULHU};
    assign is_div_op = execute_in.exec_unit_uop inside {DIV, DIVU, REM, REMU};

    logic sel_alu, sel_mul, sel_div, sel_branch, sel_lsu;
    assign sel_alu    = (execute_in.func_unit_type == FU_ALU);
    assign sel_branch = (execute_in.func_unit_type == FU_BRANCH);
    assign sel_lsu    = (execute_in.func_unit_type == FU_LSU);
    assign sel_mul    = (execute_in.func_unit_type == FU_MULDIV) && is_mul_op;
    assign sel_div    = (execute_in.func_unit_type == FU_MULDIV) && is_div_op;

    always_comb begin
        regread_alu_out           = execute_in;
        regread_alu_out.valid     = execute_in.valid & sel_alu;
 
        regread_mul_out           = execute_in;
        regread_mul_out.valid     = execute_in.valid & sel_mul;
 
        regread_div_out           = execute_in;
        regread_div_out.valid     = execute_in.valid & sel_div;
 
        regread_branch_out        = execute_in;
        regread_branch_out.valid  = execute_in.valid & sel_branch;
 
        regread_lsu_out           = execute_in;
        regread_lsu_out.valid     = execute_in.valid & sel_lsu;
    end

    
endmodule
