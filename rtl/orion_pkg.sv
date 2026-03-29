package orion_pkg;
    parameter PROJECT_NAME      =   "orion_rv";
    parameter ARCH_REGS         =   32;
    parameter PHY_REGS          =   64;
    parameter REG_ADDR_WIDTH    =   $clog2(ARCH_REGS);
    parameter TAG_WIDTH         =   $clog2(PHY_REGS);
    parameter DATA_WIDTH        =   32;

    typedef enum logic [1:0]{
        EXCEPT_NONE         = 2'b00,
        EXCEPT_ILLEGAL_INST = 2'b01
    }   except_cause_e;
    typedef struct packed {
        logic [TAG_WIDTH-1:0]   p_dest;
        logic [TAG_WIDTH-1:0]   p_src1;
        logic [TAG_WIDTH-1:0]   p_src2;
        logic                   p_src1_valid;
        logic                   p_src2_valid;
        logic                   reg_we;
        logic                   except;
        except_cause_e          cause;
        logic [DATA_WIDTH-1:0]  pc;
    }   rename_dispatch_pkt_s;
endpackage
