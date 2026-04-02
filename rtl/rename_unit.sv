`timescale 1ns/1ps
import orion_pkg::*;
module rename_unit(
    input   logic                       clk,
    input   logic                       rst_n,
    input   logic [REG_ADDR_WIDTH-1:0]  r_src1,
    input   logic [REG_ADDR_WIDTH-1:0]  r_src2,
    input   logic [REG_ADDR_WIDTH-1:0]  r_dst,
    input   logic [DATA_WIDTH-1:0]      pc,
    input   logic                       src1_valid,
    input   logic                       src2_valid,
    input   logic                       instr_valid,
    input   except_cause_e              cause,
    input   logic                       branch_mispredict,
    input   logic                       commit_valid,       //Instruction retired by ROB
    input   logic [REG_ADDR_WIDTH-1:0]  commit_rd,          //The arch. register which should hold the arch. state
    input   logic [TAG_WIDTH-1:0]       commit_pd,          //The phy. register which actually holds the data
    input   logic [TAG_WIDTH-1:0]       commit_old_pd,      //The old phy. register before renaming, to release back to free list
    output  logic                       rename_stall,
    output  rename_dispatch_pkt_s       rename_dispatch_out 
);
    logic   [TAG_WIDTH-1:0] phy_dst;
    logic   [TAG_WIDTH-1:0] phy_src1;
    logic   [TAG_WIDTH-1:0] phy_src2;
    logic   [TAG_WIDTH-1:0] free_list   [PHY_REGS-1:0];
    logic   [TAG_WIDTH-1:0] spec_reg_map [ARCH_REGS-1:0];
    logic   [TAG_WIDTH-1:0] arch_reg_map [ARCH_REGS-1:0];
    logic   [TAG_WIDTH:0]   free_list_head;
    logic   [TAG_WIDTH:0]   free_list_head_arch;
    logic   [TAG_WIDTH:0]   free_list_tail; 
    logic   [REG_ADDR_WIDTH-1:0]    old_p_dest;
    logic   free_list_full;
    logic   free_list_empty;
    logic   r_dst_zero;
    assign  r_dst_zero = (r_dst == 0);
    assign  free_list_empty =   (free_list_head == free_list_tail);
    assign  free_list_full = (free_list_head[TAG_WIDTH] != free_list_tail[TAG_WIDTH]) && (free_list_head[TAG_WIDTH-1:0] == free_list_tail[TAG_WIDTH-1:0]);
    always_ff @(posedge clk) begin
        if (~rst_n) begin
            for (int i = 0; i <= ARCH_REGS - 1; i++) begin
                free_list[i] <= i + PHY_REGS/2;
            end
            free_list_head_arch <= 7'd0;
            free_list_head  <=  7'd0;
            free_list_tail  <=  7'd32;
            // Unity mapping
            for (int i = 0; i <= ARCH_REGS-1; i++) begin
                arch_reg_map[i] <= i;
                spec_reg_map[i] <= i;
            end
        end 
        else begin
            if (branch_mispredict) begin
                spec_reg_map    <=  arch_reg_map;
                free_list_head  <=  free_list_head_arch;
                rename_dispatch_out.old_p_dest  <= 'bx;
                rename_dispatch_out.valid   <= 1'b0;
                rename_dispatch_out.pc      <= 'bx;
                rename_dispatch_out.except  <= 1'b0;
                rename_dispatch_out.reg_we  <= 1'b0;
                rename_dispatch_out.cause   <= cause;
                rename_dispatch_out.p_dest  <= 'bx;
                rename_dispatch_out.p_src1_valid    <=  1'b0;
                rename_dispatch_out.p_src2_valid    <=  1'b0;
                rename_dispatch_out.p_src1  <=  'bx;
                rename_dispatch_out.p_src2  <=  'bx;
            end else if (instr_valid && (cause==EXCEPT_NONE) && ~free_list_empty) begin
                case(r_dst_zero)
                    1'b0: begin
                        spec_reg_map[r_dst]         <=  phy_dst;
                        free_list_head              <=  free_list_head + 1;
                        rename_dispatch_out.valid   <=  1'b1;
                        rename_dispatch_out.pc      <=  pc;
                        rename_dispatch_out.except  <=  1'b0;
                        rename_dispatch_out.reg_we  <=  1'b1;
                        rename_dispatch_out.cause   <=  cause;
                        rename_dispatch_out.p_dest  <=  phy_dst;
                        rename_dispatch_out.p_src1  <=  phy_src1;
                        rename_dispatch_out.p_src2  <=  phy_src2; 
                        rename_dispatch_out.p_src1_valid    <=  src1_valid;
                        rename_dispatch_out.p_src2_valid    <=  src2_valid;
                        rename_dispatch_out.old_p_dest      <=  old_p_dest; 
                    end
                    1'b1: begin
                        rename_dispatch_out.valid   <=  1'b1;
                        free_list_head              <=  free_list_head;
                        rename_dispatch_out.pc      <=  pc;
                        rename_dispatch_out.except  <=  1'b0;
                        rename_dispatch_out.reg_we  <=  1'b0;
                        rename_dispatch_out.cause   <=  cause;
                        rename_dispatch_out.p_dest  <=  'b0;
                        rename_dispatch_out.p_src1  <=  phy_src1;
                        rename_dispatch_out.p_src2  <=  phy_src2; 
                        rename_dispatch_out.p_src1_valid    <=  src1_valid;
                        rename_dispatch_out.p_src2_valid    <=  src2_valid;
                        rename_dispatch_out.old_p_dest      <=  'b0; 
                    end
                    default: begin
                        rename_dispatch_out.valid   <= 1'b0;
                        rename_dispatch_out.pc      <= pc;
                        rename_dispatch_out.except  <= 1'b1;
                        rename_dispatch_out.reg_we  <= 1'b0;
                        rename_dispatch_out.cause   <= cause;
                        rename_dispatch_out.p_dest  <= 32'bx;
                        rename_dispatch_out.p_src1_valid    <=  1'b0;
                        rename_dispatch_out.p_src2_valid    <=  1'b0;
                        rename_dispatch_out.old_p_dest      <=  'bx;
                        rename_dispatch_out.p_src1  <=  'bx;
                        rename_dispatch_out.p_src2  <=  'bx;
                    end
                endcase
                
            end else begin
                rename_dispatch_out.valid   <= 1'b0;
                rename_dispatch_out.pc      <= pc;
                rename_dispatch_out.except  <= 1'b0;
                rename_dispatch_out.reg_we  <= 1'b0;
                rename_dispatch_out.cause   <= cause;
                rename_dispatch_out.p_dest  <= 'bx;
                rename_dispatch_out.p_src1_valid    <=  1'b0;
                rename_dispatch_out.p_src2_valid    <=  1'b0;
                rename_dispatch_out.old_p_dest      <=  'bx;
                rename_dispatch_out.p_src1  <=  'bx;
                rename_dispatch_out.p_src2  <=  'bx;
            end
            if(commit_valid) begin
                arch_reg_map[commit_rd]         <=  commit_pd;
                free_list_tail                  <=  (commit_rd != 0) ? free_list_tail + 1:free_list_tail;
                free_list_head_arch             <=  (commit_rd != 0) ? free_list_head_arch + 1 : free_list_head_arch;
                free_list[free_list_tail[TAG_WIDTH-1:0]]    <=  commit_old_pd;
            end
        end
    end
    
    always_comb begin
        old_p_dest  =   spec_reg_map[r_dst];
        phy_dst = free_list[free_list_head[TAG_WIDTH-1:0]];
        case({src1_valid,src2_valid})
            2'b00: begin
                phy_src1 = 'x;
                phy_src2 = 'x;
            end
            2'b01: begin
                phy_src1 = 'x;
                phy_src2 = spec_reg_map[r_src2];
            end
            2'b10: begin
                phy_src1 = spec_reg_map[r_src1];
                phy_src2 = 'x;
            end
            2'b11: begin
                phy_src1 = spec_reg_map[r_src1];
                phy_src2 = spec_reg_map[r_src2];
            end
            default: begin
                phy_src1 = 'x;
                phy_src2 = 'x;
            end
        endcase
    end
    assign rename_stall = instr_valid & free_list_empty & ~r_dst_zero;
endmodule