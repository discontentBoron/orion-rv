`timescale 1ns / 1ps
import orion_pkg::*;

module branch (
    input   logic   clk,
    input   logic   rst_n,
    input   logic   flush,

    input regread_execute_pkt_s regread_in,

    output branch_wb_pkt_s branch_wb_out
);

    logic                   ex1_valid;
    logic [TAG_WIDTH-1:0]   ex1_p_dest;
    logic [TAG_WIDTH-1:0]   ex1_old_p_dest;
    logic [ROB_PTR-1:0]     ex1_rob_tag;
    logic                   ex1_reg_we;
    logic [DATA_WIDTH-1:0]  ex1_pc;
    logic [DATA_WIDTH-1:0]  ex1_predicted_pc;
    instr_class_e           ex1_instr_class;
    except_cause_e          ex1_except_cause;
    exec_unit_opcode_e      ex1_uop;
    logic                   ex1_except;
    logic [DATA_WIDTH-1:0]  ex1_op1;        // src1_data: compare LHS / JALR base
    logic [DATA_WIDTH-1:0]  ex1_op2;        // src2_data: compare RHS (branches only)
    logic [DATA_WIDTH-1:0]  ex1_imm_val;    // branch/jump offset or JALR displacement

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            ex1_valid        <= 1'b0;
            ex1_p_dest       <= '0;
            ex1_old_p_dest   <= '0;
            ex1_rob_tag      <= '0;
            ex1_reg_we       <= 1'b0;
            ex1_pc           <= '0;
            ex1_predicted_pc <= '0;
            ex1_instr_class  <= INSTR_NOP;
            ex1_except_cause <= EXCEPT_NONE;
            ex1_except       <= 1'b0;
            ex1_uop          <= BEQ;
            ex1_op1          <= '0;
            ex1_op2          <= '0;
            ex1_imm_val      <= '0;
        end else begin
            ex1_valid        <= regread_in.valid & ~flush;
            ex1_p_dest       <= regread_in.p_dest;
            ex1_old_p_dest   <= regread_in.old_p_dest;
            ex1_rob_tag      <= regread_in.rob_tag;
            ex1_reg_we       <= regread_in.reg_we;
            ex1_pc           <= regread_in.pc;
            ex1_predicted_pc <= regread_in.predicted_pc;
            ex1_instr_class  <= regread_in.instr_class;
            ex1_except_cause <= regread_in.cause;
            ex1_except       <= regread_in.except;
            ex1_uop          <= regread_in.exec_unit_uop;
            ex1_op1          <= regread_in.src1_data;
            ex1_op2          <= regread_in.src2_data;
            ex1_imm_val      <= regread_in.imm_val;
        end
    end

    logic taken_comb;
    always_comb begin
        unique case (ex1_uop)
        BEQ:        taken_comb = (ex1_op1 == ex1_op2);
        BNE:        taken_comb = (ex1_op1 != ex1_op2);
        BLT:        taken_comb = ($signed(ex1_op1) <  $signed(ex1_op2));
        BGE:        taken_comb = ($signed(ex1_op1) >= $signed(ex1_op2));
        BLTU:       taken_comb = (ex1_op1 < ex1_op2);
        BGEU:       taken_comb = (ex1_op1 >= ex1_op2);
        JAL, JALR:  taken_comb = 1'b1;
        default:    taken_comb = 1'b0;  // not a branch op
        endcase
    end

    logic [DATA_WIDTH-1:0] fallthrough_comb;
    logic [DATA_WIDTH-1:0] branch_target_comb;
    logic [DATA_WIDTH-1:0] jalr_target_comb;
    logic [DATA_WIDTH-1:0] resolved_target_comb;

    assign fallthrough_comb   = ex1_pc + 32'd4;
    assign branch_target_comb = ex1_pc + ex1_imm_val;                  // BEQ/BNE/BLT/BGE/BLTU/BGEU/JAL
    assign jalr_target_comb   = (ex1_op1 + ex1_imm_val) & ~32'h1;      // JALR clears bit 0 per spec

    always_comb begin
        if (!taken_comb)          resolved_target_comb = fallthrough_comb;
        else if (ex1_uop == JALR) resolved_target_comb = jalr_target_comb;
        else                      resolved_target_comb = branch_target_comb;
    end

    logic                  mispredict_comb;
    logic [DATA_WIDTH-1:0] link_result_comb;

    assign mispredict_comb  = ex1_except ? 1'b0 : (resolved_target_comb != ex1_predicted_pc);
    assign link_result_comb = fallthrough_comb;  // pc+4; only committed when reg_we (JAL/JALR)

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            branch_wb_out <= '0;
        end else begin
            branch_wb_out.valid        <= ex1_valid & ~flush;
            branch_wb_out.p_dest       <= ex1_p_dest;
            branch_wb_out.old_p_dest   <= ex1_old_p_dest;
            branch_wb_out.rob_tag      <= ex1_rob_tag;
            branch_wb_out.reg_we       <= ex1_reg_we;
            branch_wb_out.result       <= link_result_comb;
            branch_wb_out.pc           <= ex1_pc;
            branch_wb_out.instr_class  <= ex1_instr_class;
            branch_wb_out.except_cause <= ex1_except_cause;
            branch_wb_out.except       <= ex1_except;
            branch_wb_out.mispredict   <= mispredict_comb;
            branch_wb_out.target_pc    <= resolved_target_comb;
            branch_wb_out.taken        <= taken_comb;
        end
    end

endmodule