    `timescale 1ns/1ps
import orion_pkg::*;
module reorder_buffer(
    input   logic                           clk,
    input   logic                           rst_n,
    input   logic [REG_ADDR_WIDTH-1:0]      dispatch_r_dst,
    input   rename_dispatch_pkt_s           dispatch_in,
    output  logic   [ROB_PTR-1:0]           rob_tag_out,
    output  logic                           rob_full,

    input   logic                           cdb_valid,
    input   logic   [ROB_PTR-1:0]           cdb_rob_tag,
    input   logic                           cdb_mispredict,
    input   logic                           cdb_exception,
    input   except_cause_e                  cdb_cause,
    output  logic                           commit_valid,
    output  logic [REG_ADDR_WIDTH-1:0]      commit_rd,
    output  logic [TAG_WIDTH-1:0]           commit_pd,
    output  logic [TAG_WIDTH-1:0]           commit_old_pd,

    output  logic                           branch_mispredict,
    output  logic                           exception_valid,
    output  except_cause_e                  exception_cause,
    output  logic [DATA_WIDTH-1:0]          exception_pc

);

    logic   [ROB_PTR:0]    head, tail;
    rob_entry_s                     rob_mem[ROB_SIZE-1:0];
    assign rob_tag_out = tail[ROB_PTR-1:0];
    assign rob_full = (head[ROB_PTR] != tail[ROB_PTR]) && (head[ROB_PTR-1:0] == tail[ROB_PTR-1:0]);;
    
    // Dispatch and Allocation
    always_ff @(posedge clk) begin
        if (~rst_n) begin
            head <= 'b0;
            tail <= 'b0;
            for(int i = 0; i < ROB_SIZE; i++) begin
                rob_mem[i] <= 'b0;
            end
        end else begin
            if (dispatch_in.valid && ~rob_full) begin
                rob_mem[rob_tag_out].r_dst          <= dispatch_r_dst;
                rob_mem[rob_tag_out].p_dest         <= dispatch_in.p_dest;
                rob_mem[rob_tag_out].old_p_dest     <= dispatch_in.old_p_dest;
                rob_mem[rob_tag_out].reg_we         <= dispatch_in.reg_we;
                rob_mem[rob_tag_out].pc             <= dispatch_in.pc;
                rob_mem[rob_tag_out].predicted_pc   <= dispatch_in.predicted_pc;
                rob_mem[rob_tag_out].instr_class    <= dispatch_in.instr_class;
                rob_mem[rob_tag_out].except         <= dispatch_in.except;
                rob_mem[rob_tag_out].except_cause   <= dispatch_in.except_cause;
                rob_mem[rob_tag_out].done           <= 1'b0;
                rob_mem[rob_tag_out].mispredict     <= 1'b0;
                tail                                <= tail + 1;
            end
            // CDB Writeback
            if (cdb_valid) begin
                rob_mem[cdb_rob_tag].done           <=  1'b1;
                rob_mem[cdb_rob_tag].mispredict     <=  cdb_mispredict;
                rob_mem[cdb_rob_tag].except         <=  cdb_exception;
                rob_mem[cdb_rob_tag].except_cause   <=  cdb_cause;
            end
        end
    end
endmodule
