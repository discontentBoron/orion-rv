import orion_pkg::*;

module register_read
(
    input logic clk,
    input logic rst_n,

    input rename_dispatch_pkt_s dispatch_in,

    input logic flush,

    input logic [TAG_WIDTH-1:0] cdb_tag,
    input logic [DATA_WIDTH-1:0] cdb_data,
    input logic cdb_valid,

    input logic wb_en,
    input logic [TAG_WIDTH-1:0] wb_tag,
    input logic [DATA_WIDTH-1:0] wb_data,

    output regread_execute_pkt_s execute_out
);

logic [DATA_WIDTH-1:0] prf [0:PHY_REGS-1];

logic [DATA_WIDTH-1:0] src1_data;
logic [DATA_WIDTH-1:0] src2_data;

logic forward_sel1;
logic forward_sel2;

assign forward_sel1 = 1'b0;
assign forward_sel2 = 1'b0;

always_ff @(posedge clk or negedge rst_n)
begin

    integer i;

    if(!rst_n)
    begin

        for(i=0;i<PHY_REGS;i=i+1)
            prf[i] <= 0;

    end

    else
    begin

        if(wb_en && wb_tag != 0)
            prf[wb_tag] <= wb_data;

    end

end

always_comb
begin

    src1_data = 0;
    src2_data = 0;

    if(dispatch_in.p_src1_valid)
    begin

        if(forward_sel1)
            src1_data = cdb_data;

        else if(dispatch_in.p_src1 == 0)
            src1_data = 0;

        else
            src1_data = prf[dispatch_in.p_src1];

    end

    if(dispatch_in.p_src2_valid)
    begin

        if(forward_sel2)
            src2_data = cdb_data;

        else if(dispatch_in.p_src2 == 0)
            src2_data = 0;

        else
            src2_data = prf[dispatch_in.p_src2];

    end

end

always_comb
begin

    execute_out = '0;

    execute_out.valid = dispatch_in.valid;

    execute_out.p_src1 = dispatch_in.p_src1;
    execute_out.p_src2 = dispatch_in.p_src2;
    execute_out.p_dest = dispatch_in.p_dest;
    execute_out.old_p_dest = dispatch_in.old_p_dest;

    execute_out.p_src1_valid = dispatch_in.p_src1_valid;
    execute_out.p_src2_valid = dispatch_in.p_src2_valid;

    execute_out.reg_we = dispatch_in.reg_we;

    execute_out.pc = dispatch_in.pc;
    execute_out.predicted_pc = dispatch_in.predicted_pc;
    execute_out.imm_val = dispatch_in.imm_val;

    execute_out.instr_class = dispatch_in.instr_class;
    execute_out.func_unit_type = dispatch_in.func_unit_type;
    execute_out.exec_unit_uop = dispatch_in.exec_unit_uop;

    execute_out.cause = dispatch_in.cause;
    execute_out.except = dispatch_in.except;

    execute_out.src1_data = src1_data;
    execute_out.src2_data = src2_data;

    if(flush)
        execute_out.valid = 0;

end

endmodule