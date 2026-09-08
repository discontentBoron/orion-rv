`timescale 1ns / 1ps
import orion_pkg::*;

module register_read (
    input   logic                    clk,
    input   logic                    rst_n,

    // From Issue Queue
    input  rename_dispatch_pkt_s    dispatch_in,

    // Flush from branch misprediction / exception
    input   logic                   flush,
    input   logic [ROB_PTR-1:0]     dispatch_rob_tag,
    // CDB (Common Data Bus) forwarding bypass — one port per execute unit
    input   logic [TAG_WIDTH-1:0]       cdb_tag [NUM_CDB_PORTS],
    input   logic [DATA_WIDTH-1:0]      cdb_data [NUM_CDB_PORTS],
    input   logic [NUM_CDB_PORTS-1:0]   cdb_valid,

    // Writeback port into PRF (from execution units)
    input   logic [NUM_CDB_PORTS-1:0]   wb_en,
    input   logic [TAG_WIDTH-1:0]       wb_tag [NUM_CDB_PORTS],
    input   logic [DATA_WIDTH-1:0]      wb_data [NUM_CDB_PORTS],

    // To Execute stage
    output regread_execute_pkt_s    execute_out
);
logic [DATA_WIDTH-1:0] prf [0:PHY_REGS-1];

always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        for (int i = 0; i < PHY_REGS; i++)
            prf[i] <= '0;
    end else begin
        for (int r = 1; r < PHY_REGS; r++) begin
            automatic logic [NUM_CDB_PORTS-1:0] hit;
            for (int p = 0; p < NUM_CDB_PORTS; p++)
                hit[p] = wb_en[p] && (wb_tag[p] == r[TAG_WIDTH-1:0]);

            if (|hit) begin
                unique case (1'b1)
                    hit[0]: prf[r] <= wb_data[0];
                    hit[1]: prf[r] <= wb_data[1];
                    hit[2]: prf[r] <= wb_data[2];
                    hit[3]: prf[r] <= wb_data[3];
                    hit[4]: prf[r] <= wb_data[4];
                endcase
            end
        end
    end
end
logic [DATA_WIDTH-1:0] prf_src1_raw, prf_src2_raw;
logic [DATA_WIDTH-1:0] src1_data_comb, src2_data_comb;

function automatic logic [NUM_CDB_PORTS-1:0] fwd_hit_vec(input logic [TAG_WIDTH-1:0] tag);
    for (int p = 0; p < NUM_CDB_PORTS; p++)
        fwd_hit_vec[p] = cdb_valid[p] && (cdb_tag[p] == tag);
endfunction

logic [NUM_CDB_PORTS-1:0] hit1, hit2;


// Raw PRF reads (combinational)
assign prf_src1_raw = prf[dispatch_in.p_src1];
assign prf_src2_raw = prf[dispatch_in.p_src2];

always_comb begin
    automatic logic [DATA_WIDTH-1:0] mux1, mux2;
    hit1 = fwd_hit_vec(dispatch_in.p_src1);
    hit2 = fwd_hit_vec(dispatch_in.p_src2);
    
    mux1 = (|hit1) ? '0 : prf_src1_raw;
    mux2 = (|hit2) ? '0 : prf_src2_raw;

    for (int p = 0; p < NUM_CDB_PORTS; p++) begin
        mux1 |= hit1[p] ? cdb_data[p] : '0;
        mux2 |= hit2[p] ? cdb_data[p] : '0;
    end

    src1_data_comb = (!dispatch_in.p_src1_valid || dispatch_in.p_src1 == '0) ? '0 : mux1;
    src2_data_comb = (!dispatch_in.p_src2_valid || dispatch_in.p_src2 == '0) ? '0 : mux2;
end
always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        execute_out <= '0;
    end else begin
        // Pass-through fields (no re-decode)
        execute_out.p_src1          <= dispatch_in.p_src1;
        execute_out.p_src2          <= dispatch_in.p_src2;
        execute_out.p_dest          <= dispatch_in.p_dest;
        execute_out.old_p_dest      <= dispatch_in.old_p_dest;
        execute_out.p_src1_valid    <= dispatch_in.p_src1_valid;
        execute_out.p_src2_valid    <= dispatch_in.p_src2_valid;
        execute_out.reg_we          <= dispatch_in.reg_we;
        execute_out.pc              <= dispatch_in.pc;
        execute_out.predicted_pc    <= dispatch_in.predicted_pc;
        execute_out.imm_val         <= dispatch_in.imm_val;
        execute_out.instr_class     <= dispatch_in.instr_class;
        execute_out.func_unit_type  <= dispatch_in.func_unit_type;
        execute_out.exec_unit_uop   <= dispatch_in.exec_unit_uop;
        execute_out.cause           <= dispatch_in.except_cause;
        execute_out.except          <= dispatch_in.except;

        // Computed data fields
        execute_out.src1_data       <= src1_data_comb;
        execute_out.src2_data       <= src2_data_comb;

        // valid — flush wins over everything
        execute_out.valid           <= dispatch_in.valid & ~flush;
        execute_out.rob_tag         <= dispatch_rob_tag;
    end
end

endmodule