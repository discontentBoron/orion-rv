`timescale 1ns / 1ps
import orion_pkg::*;

module lsu (
    input   logic   clk,
    input   logic   rst_n,
    input   logic   flush,

    input regread_execute_pkt_s regread_in,
    output logic                lsu_ready,

    output execute_wb_pkt_s lsu_wb_out,
    // --- Store buffer: enqueue (stores) ---
    output logic                  sb_enq_valid,
    output logic [DATA_WIDTH-1:0] sb_enq_addr,
    output logic [DATA_WIDTH-1:0] sb_enq_wdata,
    output logic [3:0]            sb_enq_wstrb,

    // --- Store buffer: lookup (loads) ---
    output logic [DATA_WIDTH-1:0] sb_ld_addr,
    output logic [3:0]            sb_ld_mask,
    input  logic                  sb_ld_hit,
    input  logic                  sb_ld_fwd_ok,
    input  logic [DATA_WIDTH-1:0] sb_ld_fwd_data,

    // --- Memory interface ---
    output logic                  mem_req_valid,
    output logic [DATA_WIDTH-1:0] mem_req_addr,
    input  logic                  mem_req_ready,
    input  logic                  mem_resp_valid,
    input  logic [DATA_WIDTH-1:0] mem_resp_rdata
);

    typedef enum logic [2:0] {
        LSU_IDLE,
        LSU_SB_WAIT,
        LSU_REQ,
        LSU_WAIT_RESP,
        LSU_DONE
    } lsu_state_e;

    lsu_state_e state;

    // Latched request
    logic [TAG_WIDTH-1:0]  l_p_dest;
    logic [TAG_WIDTH-1:0]  l_old_p_dest;
    logic [ROB_PTR-1:0]    l_rob_tag;
    logic                  l_reg_we;
    logic [DATA_WIDTH-1:0] l_pc;
    instr_class_e          l_instr_class;
    except_cause_e         l_except_cause;
    logic                  l_except;
    exec_unit_opcode_e     l_uop;
    logic [DATA_WIDTH-1:0] l_addr;
    logic                  l_squashed;   // flushed while a request was already in flight
    logic [DATA_WIDTH-1:0] l_rdata;      // latched response data (valid only alongside mem_resp_valid)

    logic [DATA_WIDTH-1:0] addr_sum_comb;
    logic [1:0]            byte_off;
    assign addr_sum_comb = regread_in.src1_data + regread_in.imm_val;
    assign byte_off      = addr_sum_comb[1:0];

    logic accept, is_store_in;
    assign lsu_ready = (state == LSU_IDLE);
    assign accept    = lsu_ready & regread_in.valid & ~flush;
    assign is_store_in = (regread_in.instr_class == INSTR_STORE);
    // --- Byte-lane encode for stores (combinational, using un-latched regread_in) ---
    logic [DATA_WIDTH-1:0] wdata_comb;
    logic [3:0]            wstrb_comb;
    always_comb begin
        unique case (regread_in.exec_unit_uop)
        SB:      wstrb_comb = 4'b0001 << byte_off;
        SH:      wstrb_comb = 4'b0011 << byte_off;
        SW:      wstrb_comb = 4'b1111;
        default: wstrb_comb = 4'b0000;  // loads don't write
        endcase
        wdata_comb = regread_in.src2_data << (byte_off * 8);
    end
    assign sb_enq_valid = accept & is_store_in & ~regread_in.except;
    assign sb_enq_addr  = addr_sum_comb;
    assign sb_enq_wdata = wdata_comb;
    assign sb_enq_wstrb = wstrb_comb;

    // --- Store-buffer lookup for loads ---
    // In IDLE the lookup uses the incoming (un-latched) request; while parked
    // in LSU_SB_WAIT it re-uses the latched one.
    function automatic logic [3:0] load_mask(input exec_unit_opcode_e u, input logic [1:0] off);
        unique case (u)
        LB, LBU: load_mask = 4'b0001 << off;
        LH, LHU: load_mask = 4'b0011 << off;
        default: load_mask = 4'b1111;
        endcase
    endfunction

    assign sb_ld_addr = (state == LSU_IDLE) ? addr_sum_comb : l_addr;
    assign sb_ld_mask = (state == LSU_IDLE) ? load_mask(regread_in.exec_unit_uop, byte_off)
                                            : load_mask(l_uop, l_addr[1:0]);
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state          <= LSU_IDLE;
            l_p_dest       <= '0;
            l_old_p_dest   <= '0;
            l_rob_tag      <= '0;
            l_reg_we       <= 1'b0;
            l_pc           <= '0;
            l_instr_class  <= INSTR_NOP;
            l_except_cause <= EXCEPT_NONE;
            l_except       <= 1'b0;
            l_uop          <= LW;
            l_addr         <= '0;
            l_squashed     <= 1'b0;
            l_rdata        <= '0;
            lsu_wb_out     <= '0;

            mem_req_valid  <= 1'b0;
            mem_req_addr   <= '0;
        end else begin
            lsu_wb_out.valid <= 1'b0;  // default: pulse for exactly one cycle
            mem_req_valid    <= 1'b0;  // default: pulse for exactly one cycle

            unique case (state)

            LSU_IDLE: begin
                if (accept) begin
                    if (regread_in.except) begin
                        // Exception passthrough: fast path, same cycle, no
                        // memory access at all.
                        lsu_wb_out.valid        <= 1'b1;
                        lsu_wb_out.p_dest       <= regread_in.p_dest;
                        lsu_wb_out.old_p_dest   <= regread_in.old_p_dest;
                        lsu_wb_out.rob_tag      <= regread_in.rob_tag;
                        lsu_wb_out.reg_we       <= 1'b0;
                        lsu_wb_out.result       <= '0;
                        lsu_wb_out.pc           <= regread_in.pc;
                        lsu_wb_out.instr_class  <= regread_in.instr_class;
                        lsu_wb_out.except_cause <= regread_in.cause;
                        lsu_wb_out.except       <= 1'b1;
                    end else if (is_store_in) begin
                        // Store: already enqueued into the store buffer this
                        // cycle (sb_enq_*). Report completion to the ROB now.
                        // State stays IDLE.
                        lsu_wb_out.valid        <= 1'b1;
                        lsu_wb_out.p_dest       <= regread_in.p_dest;
                        lsu_wb_out.old_p_dest   <= regread_in.old_p_dest;
                        lsu_wb_out.rob_tag      <= regread_in.rob_tag;
                        lsu_wb_out.reg_we       <= 1'b0;
                        lsu_wb_out.result       <= '0;
                        lsu_wb_out.pc           <= regread_in.pc;
                        lsu_wb_out.instr_class  <= regread_in.instr_class;
                        lsu_wb_out.except_cause <= regread_in.cause;
                        lsu_wb_out.except       <= 1'b0;
                    end else begin
                        // Load
                        l_p_dest       <= regread_in.p_dest;
                        l_old_p_dest   <= regread_in.old_p_dest;
                        l_rob_tag      <= regread_in.rob_tag;
                        l_reg_we       <= regread_in.reg_we;
                        l_pc           <= regread_in.pc;
                        l_instr_class  <= regread_in.instr_class;
                        l_except_cause <= regread_in.cause;
                        l_except       <= 1'b0;
                        l_uop          <= regread_in.exec_unit_uop;
                        l_addr         <= addr_sum_comb;
                        l_squashed     <= 1'b0;

                        if (!sb_ld_hit) begin
                            mem_req_valid  <= 1'b1;
                            mem_req_addr   <= addr_sum_comb;
                            state          <= LSU_REQ;
                        end else if (sb_ld_fwd_ok) begin
                            l_rdata        <= sb_ld_fwd_data;
                            state          <= LSU_DONE;
                        end else begin
                            state          <= LSU_SB_WAIT;
                        end
                    end
                end
            end

            LSU_SB_WAIT: begin
                // Partial overlap with an in-flight store: wait for it to
                // drain. Nothing has been presented to memory yet, so on a
                // flush the load can simply be dropped.
                if (flush) begin
                    l_squashed <= 1'b1;
                    state      <= LSU_DONE;
                end else if (!sb_ld_hit) begin
                    mem_req_valid <= 1'b1;
                    mem_req_addr  <= l_addr;
                    state         <= LSU_REQ;
                end else if (sb_ld_fwd_ok) begin
                    l_rdata <= sb_ld_fwd_data;
                    state   <= LSU_DONE;
                end
            end

            LSU_REQ: begin
                if (flush) l_squashed <= 1'b1;

                if (mem_req_ready) begin
                    // Request accepted by memory.
                    if (mem_resp_valid) begin
                        l_rdata <= mem_resp_rdata;
                        state   <= LSU_DONE;
                    end else begin
                        state <= LSU_WAIT_RESP;
                    end
                end else begin
                    mem_req_valid <= 1'b1;
                    mem_req_addr  <= l_addr;
                end
            end

            LSU_WAIT_RESP: begin
                if (flush) 
                    l_squashed <= 1'b1;
                if (mem_resp_valid) begin
                    l_rdata <= mem_resp_rdata;
                    state   <= LSU_DONE;
                end
            end

            LSU_DONE: begin
                automatic logic [1:0]  l_byte_off    = l_addr[1:0];
                automatic logic [31:0] shifted_rdata = l_rdata >> (l_byte_off * 8);
                automatic logic [31:0] load_result;
                unique case (l_uop)
                LB:      load_result = {{24{shifted_rdata[7]}},  shifted_rdata[7:0]};
                LBU:     load_result = {24'b0,                    shifted_rdata[7:0]};
                LH:      load_result = {{16{shifted_rdata[15]}}, shifted_rdata[15:0]};
                LHU:     load_result = {16'b0,                    shifted_rdata[15:0]};
                LW:      load_result = l_rdata;
                default: load_result = '0;
                endcase

                lsu_wb_out.valid        <= ~l_squashed;
                lsu_wb_out.p_dest       <= l_p_dest;
                lsu_wb_out.old_p_dest   <= l_old_p_dest;
                lsu_wb_out.rob_tag      <= l_rob_tag;
                lsu_wb_out.reg_we       <= l_reg_we;
                lsu_wb_out.result       <= load_result;
                lsu_wb_out.pc           <= l_pc;
                lsu_wb_out.instr_class  <= l_instr_class;
                lsu_wb_out.except_cause <= l_except_cause;
                lsu_wb_out.except       <= l_except;

                state <= LSU_IDLE;
            end

            default: state <= LSU_IDLE;

            endcase
        end
    end

endmodule