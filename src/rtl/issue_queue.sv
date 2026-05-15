`timescale 1ns/1ps
import orion_pkg::*;

module issue_queue(
    input   logic   clk,
    input   logic   rst_n,

    input   rename_dispatch_pkt_s   dispatch_in,
    input   logic [ROB_PTR-1:0]     dispatch_rob_tag,
    output  logic                   iq_full,

    input   logic                   cdb_valid,
    input   logic [TAG_WIDTH-1:0]   cdb_p_dest,

    input   logic                   branch_mispredict,
    input   logic                   exception_valid,

    output logic                    issue_valid,
    output rename_dispatch_pkt_s    issue_pkt,
    output logic [ROB_PTR-1:0]      issue_rob_tag
);

    iq_entry_s  iq_mem  [IQ_SIZE-1:0];
    logic   [IQ_AGE_WIDTH-1:0]  global_counter;

    logic   [IQ_SIZE-1:0]       valid_vec;
    always_comb begin
        for(int i=0; i<IQ_SIZE; i++)
            valid_vec[i] = iq_mem[i].valid;
    end
    assign iq_full = &valid_vec;    
    logic                       free_slot_valid;
    logic [$clog2(IQ_SIZE)-1:0] free_slot_idx;

    always_comb begin
    free_slot_valid = 1'b0;
    free_slot_idx   = '0;
    for (int i = IQ_SIZE-1; i >= 0; i--) begin
        if (!valid_vec[i]) begin
            free_slot_valid = 1'b1;
            free_slot_idx   = i[$clog2(IQ_SIZE)-1:0];
            end
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            global_counter <= '0;
            for (int i = 0; i < IQ_SIZE; i++)
                iq_mem[i].valid <= 1'b0;
        end else begin
            if (dispatch_in.valid && !iq_full && !branch_mispredict && !exception_valid) begin
                iq_mem[free_slot_idx].p_src1            <= dispatch_in.p_src1;
                iq_mem[free_slot_idx].p_src2            <= dispatch_in.p_src2;
                iq_mem[free_slot_idx].p_src1_ready      <= !dispatch_in.p_src1_valid | dispatch_in.p_src1_rdy;;
                iq_mem[free_slot_idx].p_src2_ready      <= !dispatch_in.p_src2_valid | dispatch_in.p_src2_rdy;
                iq_mem[free_slot_idx].p_dest            <= dispatch_in.p_dest;
                iq_mem[free_slot_idx].old_p_dest        <= dispatch_in.old_p_dest;
                iq_mem[free_slot_idx].rob_tag           <= dispatch_rob_tag;
                iq_mem[free_slot_idx].reg_we            <= dispatch_in.reg_we;
                iq_mem[free_slot_idx].instr_class       <= dispatch_in.instr_class;
                iq_mem[free_slot_idx].func_unit_type    <= dispatch_in.func_unit_type;
                iq_mem[free_slot_idx].exec_unit_uop     <= dispatch_in.exec_unit_uop;
                iq_mem[free_slot_idx].imm_val           <= dispatch_in.imm_val;
                iq_mem[free_slot_idx].pc                <= dispatch_in.pc;
                iq_mem[free_slot_idx].predicted_pc      <= dispatch_in.predicted_pc;
                iq_mem[free_slot_idx].valid             <= 1'b1;
                iq_mem[free_slot_idx].except            <= dispatch_in.except;        // added
                iq_mem[free_slot_idx].except_cause      <= dispatch_in.except_cause;
                iq_mem[free_slot_idx].age_tag           <= global_counter;
                global_counter                          <= global_counter + 1'b1;
            end
        end
    end
    
    
endmodule


