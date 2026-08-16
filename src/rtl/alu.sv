`timescale 1ns / 1ps
import orion_pkg::*;

module alu (
    input   logic   clk,
    input   logic   rst_n,
    input   logic   flush,

    input regread_execute_pkt_s regread_in,

    output execute_wb_pkt_s alu_wb_out
);

    logic                   ex1_valid;
    logic [TAG_WIDTH-1:0]   ex1_p_dest;
    logic [TAG_WIDTH-1:0]   ex1_old_p_dest;
    logic [ROB_PTR-1:0]     ex1_rob_tag;
    logic                   ex1_reg_we;
    logic [DATA_WIDTH-1:0]  ex1_pc;
    instr_class_e           ex1_instr_class;
    except_cause_e          ex1_except_cause;
    exec_unit_opcode_e      ex1_uop;
    logic                   ex1_except;
    logic [DATA_WIDTH-1:0]  ex1_op1;
    logic [DATA_WIDTH-1:0]  ex1_op2;
    logic [DATA_WIDTH-1:0]  ex1_imm_val;

    logic [DATA_WIDTH-1:0]  operand2_comb;
    assign operand2_comb = regread_in.p_src2_valid ? regread_in.src2_data 
                            : regread_in.imm_val;
    always_ff @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin 
            ex1_valid        <= 1'b0;
            ex1_p_dest        <= '0;
            ex1_old_p_dest    <= '0;
            ex1_rob_tag       <= '0;
            ex1_reg_we        <= 1'b0;
            ex1_pc            <= '0;
            ex1_instr_class   <= INSTR_NOP;
            ex1_except_cause  <= EXCEPT_NONE;
            ex1_except        <= 1'b0;
            ex1_uop           <= ADD;
            ex1_op1           <= '0;
            ex1_op2           <= '0;
            ex1_imm_val       <= '0;
        end else begin
            ex1_valid        <= regread_in.valid & ~flush;
            ex1_p_dest        <= regread_in.p_dest;
            ex1_old_p_dest    <= regread_in.old_p_dest;
            ex1_rob_tag       <= regread_in.rob_tag;
            ex1_reg_we        <= regread_in.reg_we;
            ex1_pc            <= regread_in.pc;
            ex1_instr_class   <= regread_in.instr_class;
            ex1_except_cause  <= regread_in.cause;
            ex1_except        <= regread_in.except;
            ex1_uop           <= regread_in.exec_unit_uop;
            ex1_op1           <= regread_in.src1_data;
            ex1_op2           <= operand2_comb;
            ex1_imm_val       <= regread_in.imm_val;
        end
    end

    logic [DATA_WIDTH-1:0] alu_result_comb;
    logic [4:0]             shamt;
    assign shamt = ex1_op2[4:0];  // RV32: shift amount is always the low 5 bits

    always_comb begin
        unique case (ex1_uop)
        LUI:    alu_result_comb = ex1_imm_val;
        AUIPC:  alu_result_comb = ex1_pc + ex1_imm_val;
        ADD:    alu_result_comb = ex1_op1 + ex1_op2;
        SUB:    alu_result_comb = ex1_op1 - ex1_op2;
        SLL:    alu_result_comb = ex1_op1 << shamt;
        SLT:    alu_result_comb = {31'b0, ($signed(ex1_op1) < $signed(ex1_op2))};
        SLTU:   alu_result_comb = {31'b0, (ex1_op1 < ex1_op2)};
        XOR:    alu_result_comb = ex1_op1 ^ ex1_op2;
        SRL:    alu_result_comb = ex1_op1 >> shamt;
        SRA:    alu_result_comb = $signed(ex1_op1) >>> shamt;
        OR:     alu_result_comb = ex1_op1 | ex1_op2;
        AND:    alu_result_comb = ex1_op1 & ex1_op2;
        default: alu_result_comb = 'x;  // not an ALU op
        endcase
    end
    
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            alu_wb_out <= '0;
        end else begin
            alu_wb_out.valid        <= ex1_valid & ~flush;
            alu_wb_out.p_dest       <= ex1_p_dest;
            alu_wb_out.old_p_dest   <= ex1_old_p_dest;
            alu_wb_out.rob_tag      <= ex1_rob_tag;
            alu_wb_out.reg_we       <= ex1_reg_we;
            alu_wb_out.result       <= alu_result_comb;
            alu_wb_out.pc           <= ex1_pc;
            alu_wb_out.instr_class  <= ex1_instr_class;
            alu_wb_out.except_cause <= ex1_except_cause;
            alu_wb_out.except       <= ex1_except;
        end
    end

endmodule