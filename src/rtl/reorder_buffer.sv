`timescale 1ns/1ps
import orion_pkg::*;
module reorder_buffer(
    input   logic                           clk,
    input   logic                           rst_n,

    input   rename_dispatch_pkt_s           dispatch_in,
    input   logic                           iq_full,
    output  logic   [ROB_PTR-1:0]           rob_tag_out,
    output  logic                           rob_full,

    input   logic   [NUM_CDB_PORTS-1:0]     cdb_valid,
    input   logic   [ROB_PTR-1:0]           cdb_rob_tag [NUM_CDB_PORTS],
    input   logic   [NUM_CDB_PORTS-1:0]     cdb_mispredict,
    input   logic   [DATA_WIDTH-1:0]        cdb_target_pc [NUM_CDB_PORTS],
    input   logic   [NUM_CDB_PORTS-1:0]     cdb_exception,
    input   except_cause_e                  cdb_cause [NUM_CDB_PORTS],

    output  logic                           commit_valid,
    output  logic [REG_ADDR_WIDTH-1:0]      commit_rd,
    output  logic [TAG_WIDTH-1:0]           commit_pd,
    output  logic [TAG_WIDTH-1:0]           commit_old_pd,

    output  logic                           commit_fire,
    output  logic [REG_ADDR_WIDTH-1:0]      commit_rd_e,
    output  logic [TAG_WIDTH-1:0]           commit_pd_e,
    output  logic [TAG_WIDTH-1:0]           commit_old_pd_e,
    output  logic                           store_commit,
    output  logic [ROB_PTR-1:0]             rob_head_tag,

    output  logic                           branch_mispredict,
    output  logic                           exception_valid,
    output  logic [DATA_WIDTH-1:0]          redirect_pc,
    output  except_cause_e                  exception_cause,
    output  logic [DATA_WIDTH-1:0]          exception_pc

);

    rob_entry_s         rob_mem[ROB_SIZE-1:0];
    rob_entry_s         head_entry;
    logic rob_empty;
    logic [ROB_PTR:0]   head, tail;
    logic flushing;
    assign flushing     = head_entry.done && !rob_empty && (head_entry.except || head_entry.mispredict);
    assign rob_tag_out  = tail[ROB_PTR-1:0];
    assign rob_empty    = (head == tail);
    assign rob_full     = (head[ROB_PTR] != tail[ROB_PTR]) && (head[ROB_PTR-1:0] == tail[ROB_PTR-1:0]);
    assign head_entry   = rob_mem[head[ROB_PTR-1:0]];
    assign commit_fire     = !rob_empty && head_entry.done && !head_entry.except && head_entry.reg_we;
    assign commit_rd_e     = head_entry.r_dst;
    assign commit_pd_e     = head_entry.p_dest;
    assign commit_old_pd_e = head_entry.old_p_dest;
    assign rob_head_tag     = head[ROB_PTR-1:0];
    function automatic logic tag_in_window(input logic [ROB_PTR-1:0] tag);
        logic [ROB_PTR-1:0] h, t;
        h = head[ROB_PTR-1:0];
        t = tail[ROB_PTR-1:0];
        if (rob_empty)
            tag_in_window = 1'b0;
        else if (head[ROB_PTR] == tail[ROB_PTR]) 
            tag_in_window = (tag >= h) && (tag < t);
        else
            tag_in_window = (tag >= h) || (tag < t);
    endfunction
    // Dispatch and Allocation
    always_ff @(posedge clk) begin
        if (~rst_n) begin
            head                <= '0;
            tail                <= '0;
            commit_valid        <= 1'b0;
            commit_rd           <= '0;
            commit_pd           <= '0;
            commit_old_pd       <= '0;
            store_commit        <= 1'b0;
            branch_mispredict   <= 1'b0;
            exception_valid     <= 1'b0;
            exception_cause     <= EXCEPT_NONE;
            redirect_pc         <= DEFAULT_EXCEPT_PC;
            exception_pc        <= '0;
            for(int i = 0; i < ROB_SIZE; i++) begin
                rob_mem[i] <= 'b0;
            end
        end else begin
            commit_valid      <= 1'b0;
            commit_rd         <= '0;
            commit_pd         <= '0;
            commit_old_pd     <= '0;
            store_commit      <= 1'b0;
            branch_mispredict <= 1'b0;
            exception_valid   <= 1'b0;
            exception_cause   <= EXCEPT_NONE;
            exception_pc      <= '0;
            redirect_pc       <= DEFAULT_EXCEPT_PC;
            // Exception Occured, HIGHEST PRIORITY
            if (!rob_empty && head_entry.done && head_entry.except) begin
                exception_valid     <= 1'b1;
                exception_cause     <= head_entry.except_cause;
                exception_pc        <= head_entry.pc;
                // Flush the ROB: drain everything after head
                head                <= head + 1;
                tail                <= head + 1;
            // Mispredict and Commit
            end else if (!rob_empty && head_entry.done && head_entry.mispredict && !head_entry.except) begin
                branch_mispredict <= 1'b1;
                redirect_pc   <= head_entry.target_pc;
                // JAL/JALR write rd still commit the register result
                if (head_entry.reg_we) begin
                    commit_valid  <= 1'b1;
                    commit_rd     <= head_entry.r_dst;
                    commit_pd     <= head_entry.p_dest;
                    commit_old_pd <= head_entry.old_p_dest;
                end
                head <= head + 1;
                // Flush everything after this instruction
                tail <= head + 1;
            // Normal Commit
            end else if (!rob_empty && head_entry.done && !head_entry.except && !head_entry.mispredict) begin
                if (head_entry.reg_we) begin
                    commit_valid  <= 1'b1;
                    commit_rd     <= head_entry.r_dst;
                    commit_pd     <= head_entry.p_dest;
                    commit_old_pd <= head_entry.old_p_dest;
                end
                if (head_entry.instr_class == INSTR_STORE) store_commit  <= 1'b1;
                head <= head + 1;
            end
            // Dispatch 
            if (!flushing && !branch_mispredict && !exception_valid && dispatch_in.valid && !rob_full && !iq_full) begin
                rob_mem[rob_tag_out].r_dst          <= dispatch_in.r_dst;
                rob_mem[rob_tag_out].p_dest         <= dispatch_in.p_dest;
                rob_mem[rob_tag_out].old_p_dest     <= dispatch_in.old_p_dest;
                rob_mem[rob_tag_out].reg_we         <= dispatch_in.reg_we;
                rob_mem[rob_tag_out].pc             <= dispatch_in.pc;
                rob_mem[rob_tag_out].predicted_pc   <= dispatch_in.predicted_pc;
                rob_mem[rob_tag_out].instr_class    <= dispatch_in.instr_class;
                rob_mem[rob_tag_out].except         <= dispatch_in.except;
                rob_mem[rob_tag_out].except_cause   <= dispatch_in.except_cause;
                rob_mem[rob_tag_out].done           <= dispatch_in.except ? 1'b1 : 1'b0;;
                rob_mem[rob_tag_out].mispredict     <= 1'b0;
                tail                                <= tail + 1;
            end
            // CDB Writeback
            for (int p = 0; p < NUM_CDB_PORTS; p++) begin
                if (cdb_valid[p] && tag_in_window(cdb_rob_tag[p])) begin
                    rob_mem[cdb_rob_tag[p]].done         <= 1'b1;
                    rob_mem[cdb_rob_tag[p]].mispredict   <= cdb_mispredict[p];
                    rob_mem[cdb_rob_tag[p]].except       <= cdb_exception[p];
                    rob_mem[cdb_rob_tag[p]].except_cause <= cdb_cause[p];
                    rob_mem[cdb_rob_tag[p]].target_pc    <= cdb_target_pc[p];
                end
            end
            // `ifdef DEBUG
            //     if (rob_full) $display("ROB FULL at time %t", $time);
            //     if (iq_full)  $display("ROB dispatch blocked by IQ FULL at time %t", $time);
            // `endif
            
        end
    end
endmodule
