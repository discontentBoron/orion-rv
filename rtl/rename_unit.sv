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

    logic   [PHY_REGS-1:0]  free_list_arch;  
    logic   [PHY_REGS-1:0]  free_list_phy;
    logic   [TAG_WIDTH-1:0] spec_reg_map [ARCH_REGS-1:0];
    logic   [TAG_WIDTH-1:0] arch_reg_map [ARCH_REGS-1:0];
    logic   free_list_empty;
    assign  free_list_empty     = ~|(free_list_phy);
    always_ff @(posedge clk) begin
        if (~rst_n) begin
            // Set initial mask for free list
            for (int i = 0; i <= ARCH_REGS-1; i++) begin
                free_list_arch[i] <= 1'b0;
                free_list_phy[i]  <= 1'b0;
                free_list_arch[i+ARCH_REGS] <= 1'b1;
                free_list_phy[i+ARCH_REGS] <= 1'b1;
            end
            // Unity mapping
            for (int i = 0; i<= ARCH_REGS-1; i++) begin
                arch_reg_map[i] <= i;
                spec_reg_map[i] <= i;
            end
        end 
        else begin
            if (branch_mispredict) begin
                spec_reg_map    <=  arch_reg_map;
                free_list_phy   <=  free_list_arch;
                rename_dispatch_out.valid   <= 1'b0;
                rename_dispatch_out.pc      <= pc;
                rename_dispatch_out.except  <= 1'b0;
                rename_dispatch_out.reg_we  <= 1'b0;
                rename_dispatch_out.cause   <= cause;
                rename_dispatch_out.p_dest  <= 32'bx;
                rename_dispatch_out.p_src1_valid    <=  1'b0;
                rename_dispatch_out.p_src2_valid    <=  1'b0;
                rename_dispatch_out.p_src1  <=  32'bx;
                rename_dispatch_out.p_src2  <=  32'bx;
            end else if (instr_valid && (cause==EXCEPT_NONE) && ~free_list_empty) begin
                spec_reg_map[r_dst]         <=  phy_dst;
                free_list_phy[phy_dst]      <=  1'b0;
                rename_dispatch_out.valid   <=  1'b1;
                rename_dispatch_out.pc      <=  pc;
                rename_dispatch_out.except  <=  1'b0;
                rename_dispatch_out.reg_we  <=  1'b1;
                rename_dispatch_out.cause   <=  cause;
                rename_dispatch_out.p_dest  <=  phy_dst;
                rename_dispatch_out.p_src1  <=  phy_src1;
                rename_dispatch_out.p_src2  <=  phy_src2; 
                rename_dispatch_out.p_src1_valid  <=  src1_valid;
                rename_dispatch_out.p_src2_valid  <=  src2_valid;
            end else begin
                rename_dispatch_out.valid   <= 1'b0;
                rename_dispatch_out.pc      <= pc;
                rename_dispatch_out.except  <= 1'b1;
                rename_dispatch_out.reg_we  <= 1'b0;
                rename_dispatch_out.cause   <= cause;
                rename_dispatch_out.p_dest  <= 32'bx;
                rename_dispatch_out.p_src1_valid    <=  1'b0;
                rename_dispatch_out.p_src2_valid    <=  1'b0;
                rename_dispatch_out.p_src1  <=  32'bx;
                rename_dispatch_out.p_src2  <=  32'bx;
            end
            if(commit_valid) begin
                arch_reg_map[commit_rd]         <=  commit_pd;
                free_list_arch[commit_pd]       <=  1'b0;
                free_list_phy[commit_old_pd]    <=  1'b1;
                free_list_arch[commit_old_pd]   <=  1'b1;
            end
        end
    end
    logic [TAG_WIDTH-1:0]phy_dst;
    logic [TAG_WIDTH-1:0]phy_src1;
    logic [TAG_WIDTH-1:0]phy_src2;
    always_comb begin
        phy_dst = 32'bx;
        for (int i = 0; i <= PHY_REGS-1; i++) begin
            if (free_list_phy[i] == 1'b1) begin
                phy_dst = i;
                break; 
            end  
        end
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
    assign rename_stall = instr_valid & free_list_empty;
endmodule