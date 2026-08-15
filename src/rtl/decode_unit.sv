// =============================================================================
// decode_unit.sv — Orion OOO RISC-V Processor
// Decode Stage (Stage 2 of 8)
//
// Purely combinational RV32IM decoder. Sits between Fetch and Rename;
// its output is registered inside rename_unit on the next clock edge
// (consistent with how register_read registers its own output rather
// than decode registering here).
//
// Scope note:
//   - Covers RV32I base integer + M extension (mul/div).
//   - FENCE / FENCE.I decoded as INSTR_NOP (no memory ordering model yet).
//   - SYSTEM opcode (ECALL/EBREAK/CSR) decoded as illegal-instruction
//     exception for now — no CSR file or trap handling exists yet, so
//     rather than silently no-op a CSR access, this stage flags it and
//     lets the ROB's existing exception path drain it. Revisit when
//     CSR support is scoped.
//   - Any unrecognized opcode/funct3/funct7 combination -> illegal
//     instruction exception (except = 1, except_cause = EXCEPT_ILLEGAL_INST).
// =============================================================================

import orion_pkg::*;

module decode_unit (
    input  logic [DATA_WIDTH-1:0]   fetch_pc,
    input  logic [DATA_WIDTH-1:0]   fetch_instr,
    input  logic                    fetch_valid,

    output decode_rename_pkt_s      decode_out
);

    logic [6:0] opcode;
    logic [2:0] funct3;
    logic [6:0] funct7;
    logic [4:0] rd, rs1, rs2;

    assign opcode = fetch_instr[6:0];
    assign funct3 = fetch_instr[14:12];
    assign funct7 = fetch_instr[31:25];
    assign rd     = fetch_instr[11:7];
    assign rs1    = fetch_instr[19:15];
    assign rs2    = fetch_instr[24:20];

    // Immediate variants
    logic [DATA_WIDTH-1:0] imm_i, imm_s, imm_b, imm_u, imm_j;
    assign imm_i = {{20{fetch_instr[31]}}, fetch_instr[31:20]};
    assign imm_s = {{20{fetch_instr[31]}}, fetch_instr[31:25], fetch_instr[11:7]};
    assign imm_b = {{19{fetch_instr[31]}}, fetch_instr[31], fetch_instr[7],
                     fetch_instr[30:25], fetch_instr[11:8], 1'b0};
    assign imm_u = {fetch_instr[31:12], 12'b0};
    assign imm_j = {{11{fetch_instr[31]}}, fetch_instr[31], fetch_instr[19:12],
                     fetch_instr[20], fetch_instr[30:21], 1'b0};

    localparam logic [6:0] OP_LUI    = 7'b0110111;
    localparam logic [6:0] OP_AUIPC  = 7'b0010111;
    localparam logic [6:0] OP_JAL    = 7'b1101111;
    localparam logic [6:0] OP_JALR   = 7'b1100111;
    localparam logic [6:0] OP_BRANCH = 7'b1100011;
    localparam logic [6:0] OP_LOAD   = 7'b0000011;
    localparam logic [6:0] OP_STORE  = 7'b0100011;
    localparam logic [6:0] OP_IMM    = 7'b0010011;
    localparam logic [6:0] OP_REG    = 7'b0110011;
    localparam logic [6:0] OP_FENCE  = 7'b0001111;
    localparam logic [6:0] OP_SYSTEM = 7'b1110011;

    always_comb begin
        // Defaults — safe/inert values, overridden per-opcode below
        decode_out             = '0;
        decode_out.valid       = fetch_valid;
        decode_out.pc          = fetch_pc;
        decode_out.predicted_pc = fetch_pc + 32'd4;  // no predictor: always fall-through
        decode_out.r_dst       = '0;
        decode_out.r_src1      = '0;
        decode_out.r_src2      = '0;
        decode_out.src1_valid  = 1'b0;
        decode_out.src2_valid  = 1'b0;
        decode_out.imm_val     = '0;
        decode_out.except      = 1'b0;
        decode_out.except_cause = EXCEPT_NONE;
        decode_out.instr_class = INSTR_NOP;
        decode_out.func_unit_type = FU_ALU;
        decode_out.exec_unit_uop  = ADD;

        unique case (opcode)

            OP_LUI: begin
                decode_out.r_dst       = rd;
                decode_out.imm_val     = imm_u;
                decode_out.instr_class = INSTR_ALU;
                decode_out.func_unit_type = FU_ALU;
                decode_out.exec_unit_uop  = LUI;
            end

            OP_AUIPC: begin
                decode_out.r_dst       = rd;
                decode_out.imm_val     = imm_u;
                decode_out.instr_class = INSTR_ALU;
                decode_out.func_unit_type = FU_ALU;
                decode_out.exec_unit_uop  = AUIPC;
            end

            OP_JAL: begin
                decode_out.r_dst       = rd;
                decode_out.imm_val     = imm_j;
                decode_out.instr_class = INSTR_JUMP;
                decode_out.func_unit_type = FU_BRANCH;
                decode_out.exec_unit_uop  = JAL;
            end

            OP_JALR: begin
                decode_out.r_dst       = rd;
                decode_out.r_src1      = rs1;
                decode_out.src1_valid  = 1'b1;
                decode_out.imm_val     = imm_i;
                decode_out.instr_class = INSTR_JUMP;
                decode_out.func_unit_type = FU_BRANCH;
                decode_out.exec_unit_uop  = JALR;
                if (funct3 != 3'b000) begin
                    decode_out.except       = 1'b1;
                    decode_out.except_cause = EXCEPT_ILLEGAL_INST;
                end
            end

            OP_BRANCH: begin
                decode_out.r_src1      = rs1;
                decode_out.r_src2      = rs2;
                decode_out.src1_valid  = 1'b1;
                decode_out.src2_valid  = 1'b1;
                decode_out.imm_val     = imm_b;
                decode_out.instr_class = INSTR_BRANCH;
                decode_out.func_unit_type = FU_BRANCH;
                case (funct3)
                    3'b000:  decode_out.exec_unit_uop = BEQ;
                    3'b001:  decode_out.exec_unit_uop = BNE;
                    3'b100:  decode_out.exec_unit_uop = BLT;
                    3'b101:  decode_out.exec_unit_uop = BGE;
                    3'b110:  decode_out.exec_unit_uop = BLTU;
                    3'b111:  decode_out.exec_unit_uop = BGEU;
                    default: begin
                        decode_out.except       = 1'b1;
                        decode_out.except_cause = EXCEPT_ILLEGAL_INST;
                    end
                endcase
            end

            OP_LOAD: begin
                decode_out.r_dst       = rd;
                decode_out.r_src1      = rs1;
                decode_out.src1_valid  = 1'b1;
                decode_out.imm_val     = imm_i;
                decode_out.instr_class = INSTR_LOAD;
                decode_out.func_unit_type = FU_LSU;
                case (funct3)
                    3'b000:  decode_out.exec_unit_uop = LB;
                    3'b001:  decode_out.exec_unit_uop = LH;
                    3'b010:  decode_out.exec_unit_uop = LW;
                    3'b100:  decode_out.exec_unit_uop = LBU;
                    3'b101:  decode_out.exec_unit_uop = LHU;
                    default: begin
                        decode_out.except       = 1'b1;
                        decode_out.except_cause = EXCEPT_ILLEGAL_INST;
                    end
                endcase
            end

            OP_STORE: begin
                decode_out.r_src1      = rs1;
                decode_out.r_src2      = rs2;
                decode_out.src1_valid  = 1'b1;
                decode_out.src2_valid  = 1'b1;
                decode_out.imm_val     = imm_s;
                decode_out.instr_class = INSTR_STORE;
                decode_out.func_unit_type = FU_LSU;
                case (funct3)
                    3'b000:  decode_out.exec_unit_uop = SB;
                    3'b001:  decode_out.exec_unit_uop = SH;
                    3'b010:  decode_out.exec_unit_uop = SW;
                    default: begin
                        decode_out.except       = 1'b1;
                        decode_out.except_cause = EXCEPT_ILLEGAL_INST;
                    end
                endcase
            end

            OP_IMM: begin
                decode_out.r_dst       = rd;
                decode_out.r_src1      = rs1;
                decode_out.src1_valid  = 1'b1;
                decode_out.imm_val     = imm_i;
                decode_out.instr_class = INSTR_ALU;
                decode_out.func_unit_type = FU_ALU;
                case (funct3)
                    3'b000:  decode_out.exec_unit_uop = ADD;   // ADDI
                    3'b010:  decode_out.exec_unit_uop = SLT;   // SLTI
                    3'b011:  decode_out.exec_unit_uop = SLTU;  // SLTIU
                    3'b100:  decode_out.exec_unit_uop = XOR;   // XORI
                    3'b110:  decode_out.exec_unit_uop = OR;    // ORI
                    3'b111:  decode_out.exec_unit_uop = AND;   // ANDI
                    3'b001: begin                              // SLLI
                        decode_out.exec_unit_uop = SLL;
                        if (funct7 != 7'b0000000) begin
                            decode_out.except       = 1'b1;
                            decode_out.except_cause = EXCEPT_ILLEGAL_INST;
                        end
                    end
                    3'b101: begin                              // SRLI / SRAI
                        decode_out.exec_unit_uop = funct7[5] ? SRA : SRL;
                        if (funct7 != 7'b0000000 && funct7 != 7'b0100000) begin
                            decode_out.except       = 1'b1;
                            decode_out.except_cause = EXCEPT_ILLEGAL_INST;
                        end
                    end
                    default: begin
                        decode_out.except       = 1'b1;
                        decode_out.except_cause = EXCEPT_ILLEGAL_INST;
                    end
                endcase
            end

            OP_REG: begin
                decode_out.r_dst       = rd;
                decode_out.r_src1      = rs1;
                decode_out.r_src2      = rs2;
                decode_out.src1_valid  = 1'b1;
                decode_out.src2_valid  = 1'b1;
                decode_out.instr_class = INSTR_ALU;
                if (funct7 == 7'b0000001) begin
                    // M extension
                    decode_out.func_unit_type = FU_MULDIV;
                    case (funct3)
                        3'b000:  decode_out.exec_unit_uop = MUL;
                        3'b001:  decode_out.exec_unit_uop = MULH;
                        3'b010:  decode_out.exec_unit_uop = MULHSU;
                        3'b011:  decode_out.exec_unit_uop = MULHU;
                        3'b100:  decode_out.exec_unit_uop = DIV;
                        3'b101:  decode_out.exec_unit_uop = DIVU;
                        3'b110:  decode_out.exec_unit_uop = REM;
                        3'b111:  decode_out.exec_unit_uop = REMU;
                        default: begin
                            decode_out.except       = 1'b1;
                            decode_out.except_cause = EXCEPT_ILLEGAL_INST;
                        end
                    endcase
                end else begin
                    decode_out.func_unit_type = FU_ALU;
                    case (funct3)
                        3'b000:  decode_out.exec_unit_uop = funct7[5] ? SUB : ADD;
                        3'b001:  decode_out.exec_unit_uop = SLL;
                        3'b010:  decode_out.exec_unit_uop = SLT;
                        3'b011:  decode_out.exec_unit_uop = SLTU;
                        3'b100:  decode_out.exec_unit_uop = XOR;
                        3'b101:  decode_out.exec_unit_uop = funct7[5] ? SRA : SRL;
                        3'b110:  decode_out.exec_unit_uop = OR;
                        3'b111:  decode_out.exec_unit_uop = AND;
                        default: begin
                            decode_out.except       = 1'b1;
                            decode_out.except_cause = EXCEPT_ILLEGAL_INST;
                        end
                    endcase
                    if (funct7 != 7'b0000000 && funct7 != 7'b0100000) begin
                        decode_out.except       = 1'b1;
                        decode_out.except_cause = EXCEPT_ILLEGAL_INST;
                    end
                end
            end

            OP_FENCE: begin
                // No memory ordering model yet — treat as architectural NOP
                decode_out.instr_class = INSTR_NOP;
                decode_out.func_unit_type = FU_ALU;
                decode_out.exec_unit_uop  = ADD;
            end

            OP_SYSTEM: begin
                // No CSR file / trap handling yet — flag as illegal rather
                // than silently dropping ECALL/EBREAK/CSR accesses.
                decode_out.instr_class  = INSTR_CSR;
                decode_out.except       = 1'b1;
                decode_out.except_cause = EXCEPT_ILLEGAL_INST;
            end

            default: begin
                decode_out.except       = 1'b1;
                decode_out.except_cause = EXCEPT_ILLEGAL_INST;
            end
        endcase

        // valid must gate except too — a bubble should never look like a
        // real illegal-instruction fault
        if (!fetch_valid) begin
            decode_out.except       = 1'b0;
            decode_out.except_cause = EXCEPT_NONE;
        end
    end

endmodule
