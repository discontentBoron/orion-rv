package orion_pkg;
    parameter PROJECT_NAME      =   "orion_rv";
    parameter ARCH_REGS         =   32;
    parameter PHY_REGS          =   64;
    parameter REG_ADDR_WIDTH    =   $clog2(ARCH_REGS);
    parameter TAG_WIDTH         =   $clog2(PHY_REGS);
    parameter DATA_WIDTH        =   32;

    typedef enum logic [1:0]{
        EXCEPT_NONE         = 2'b00,
        EXCEPT_ILLEGAL_INST = 2'b10
    }   except_cause_e;

    typedef enum logic[2:0]{
        U_TYPE  =   3'b000,
        J_TYPE  =   3'b001,
        R_TYPE  =   3'b010,
        I_TYPE  =   3'b011,
        S_TYPE  =   3'b100,
        B_TYPE  =   3'b101
    }   instr_type_e;
    typedef enum logic[1:0]{
        FU_ALU,
        FU_MULDIV,
        FU_BRANCH,
        FU_LSU
    }   func_unit_type_e;
    typedef enum logic[5:0]{
        LUI,
        AUIPC,
        JAL,
        JALR,
        BEQ,
        BNE,
        BLT,
        BGE,
        BLTU,
        BGEU,
        LB,
        LH,
        LW,
        LBU,
        LHU,
        SB,
        SH,
        SW,
        ADD, 
        SUB,
        SLL,
        SLT,
        SLTU,
        XOR,
        SRL,
        SRA,
        OR, 
        AND,
        MUL,
        MULH,
        MULHSU,
        MULHU,
        DIV,
        DIVU,
        REM, 
        REMU
    }   exec_unit_opcode_e;

    typedef enum logic[2:0]{
        INSTR_ALU   =   3'b000,
        INSTR_LOAD  =   3'b001,
        INSTR_STORE =   3'b010,
        INSTR_JUMP  =   3'b011,
        INSTR_CSR   =   3'b101,
        INSTR_NOP   =   3'b110,
        INSTR_BRANCH    =   3'b100
    }   instr_class_e;

    typedef struct packed{
        logic                       src1_valid;
        logic                       src2_valid;
        logic                       valid;
        logic   [DATA_WIDTH-1:0]    pc;
        logic   [DATA_WIDTH-1:0]    predicted_pc;
        logic   [DATA_WIDTH-1:0]    imm_val;
        logic   [REG_ADDR_WIDTH-1:0]    r_dst;
        logic   [REG_ADDR_WIDTH-1:0]    r_src1;
        logic   [REG_ADDR_WIDTH-1:0]    r_src2;
        logic                       except;
        except_cause_e              cause;
        instr_class_e               instr_class;
        func_unit_type_e            func_unit_type;
        exec_unit_opcode_e          exec_unit_uop;
    }   decode_rename_pkt_s;

    typedef struct packed {
        logic [TAG_WIDTH-1:0]   old_p_dest;
        logic [TAG_WIDTH-1:0]   p_dest;
        logic [TAG_WIDTH-1:0]   p_src1;
        logic [TAG_WIDTH-1:0]   p_src2;
        logic                   p_src1_valid;
        logic                   p_src2_valid;
        logic                   valid;
        logic                   reg_we;
        logic                   except;
        logic   [DATA_WIDTH-1:0]    pc;
        logic   [DATA_WIDTH-1:0]    imm_val;
        logic   [DATA_WIDTH-1:0]    predicted_pc;
        except_cause_e              cause;
        instr_class_e               instr_class;
        func_unit_type_e            func_unit_type;
        exec_unit_opcode_e          exec_unit_uop;
    }   rename_dispatch_pkt_s;
endpackage
