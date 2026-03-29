import orion_pkg::*;
module rename_unit(
    input   logic                       clk,
    input   logic                       rst_n,
    input   logic [REG_ADDR_WIDTH-1:0]  r_src1,
    input   logic [REG_ADDR_WIDTH-1:0]  r_src2,
    input   logic [REG_ADDR_WIDTH-1:0]  r_dst,
    input   logic [DATA_WIDTH-1:0]      pc,
    input   logic                       instr_valid,
    input   except_cause_e              cause,
    input   logic                       branch_mispredict,
    input   logic                       commit_valid,       //Instruction retired by ROB
    input   logic [REG_ADDR_WIDTH-1:0]  commit_rd,          //The arch. register which should hold the arch. state
    input   logic [TAG_WIDTH-1:0]       commit_pd,          //The phy. register which actually holds the data
    input   logic [TAG_WIDTH-1:0]       commit_old_pd,      //The old phy. register before renaming, to release back to free list
    output  rename_dispatch_pkt_s       rename_dispatch_out 

);

    logic   [PHY_REGS-1:0]  free_list_arch;  
    logic   [PHY_REGS-1:0]  free_list_phy;
    logic   [TAG_WIDTH-1:0] spec_reg_map [ARCH_REGS-1:0];
    logic   [TAG_WIDTH-1:0] arch_reg_map [ARCH_REGS-1:0];


endmodule
