`timescale 1ns / 1ps
import orion_pkg::*;

// Resolves LB/LH/LW/LBU/LHU/SB/SH/SW.
//
// Memory model: a ready/valid handshake rather than fixed latency, so a
// cache (not yet built) can sit behind this interface later without any
// change here. Requests are posted one at a time -- this unit supports a
// single outstanding memory transaction, matching every other functional
// unit in this design being single-issue.
//
// Store timing: stores are assumed to only ever be issued to this unit
// once they are the oldest (commit-eligible) in-flight instruction --
// enforced upstream by the issue queue, not by this module. That lets a
// store's memory write happen immediately on execute, with no store
// buffer needed here. (See design discussion: this is "Option A" --
// simpler than a real store queue, revisit alongside the cache.)
//
// Misaligned accesses are not detected or specially handled: a load/store
// is assumed to stay within a single aligned 32-bit word. Address bits
// [1:0] select the byte lane; anything crossing a word boundary is
// unsupported, by design choice, not yet an exception.
//
// Flush: once mem_req_valid has been asserted for a request, it is held
// asserted with a stable payload until memory accepts it -- standard
// ready/valid convention forbids withdrawing a request early, since real
// memory/cache logic may already be acting on having seen valid=1 even
// before it asserts ready. So a flush at any point (whether the request
// has been accepted yet or not) never cancels the transaction outright;
// it only marks the eventual result for discard (wb valid suppressed)
// once the transaction completes normally. Per the note above, a store
// should never legitimately need to be flushed at all (by the time it
// reaches this unit it is already the oldest in-flight instruction), but
// the same discard-not-cancel handling applies to it too, defensively.
module lsu (
    input   logic   clk,
    input   logic   rst_n,
    input   logic   flush,

    input regread_execute_pkt_s regread_in,
    output logic                lsu_ready,

    output execute_wb_pkt_s lsu_wb_out,

    // --- Memory interface ---
    output logic                  mem_req_valid,
    output logic                  mem_req_we,
    output logic [DATA_WIDTH-1:0] mem_req_addr,
    output logic [DATA_WIDTH-1:0] mem_req_wdata,
    output logic [3:0]            mem_req_wstrb,
    input  logic                  mem_req_ready,
    input  logic                  mem_resp_valid,
    input  logic [DATA_WIDTH-1:0] mem_resp_rdata
);

    typedef enum logic [1:0] {
        LSU_IDLE,
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
    logic [DATA_WIDTH-1:0] l_wdata;
    logic [3:0]            l_wstrb;
    logic                  l_is_store;
    logic                  l_squashed;   // flushed while a request was already in flight
    logic [DATA_WIDTH-1:0] l_rdata;      // latched response data (valid only alongside mem_resp_valid)

    logic [DATA_WIDTH-1:0] addr_sum_comb;
    logic [1:0]            byte_off;
    assign addr_sum_comb = regread_in.src1_data + regread_in.imm_val;
    assign byte_off      = addr_sum_comb[1:0];

    logic accept;
    assign lsu_ready = (state == LSU_IDLE);
    assign accept    = lsu_ready & regread_in.valid & ~flush;

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
            l_wdata        <= '0;
            l_wstrb        <= '0;
            l_is_store     <= 1'b0;
            l_squashed     <= 1'b0;
            l_rdata        <= '0;
            lsu_wb_out     <= '0;

            mem_req_valid  <= 1'b0;
            mem_req_we     <= 1'b0;
            mem_req_addr   <= '0;
            mem_req_wdata  <= '0;
            mem_req_wstrb  <= '0;
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
                    end else begin
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
                        l_wdata        <= wdata_comb;
                        l_wstrb        <= wstrb_comb;
                        l_is_store     <= (regread_in.instr_class == INSTR_STORE);
                        l_squashed     <= 1'b0;

                        mem_req_valid  <= 1'b1;
                        mem_req_we     <= (regread_in.instr_class == INSTR_STORE);
                        mem_req_addr   <= addr_sum_comb;
                        mem_req_wdata  <= wdata_comb;
                        mem_req_wstrb  <= wstrb_comb;
                        state          <= LSU_REQ;
                    end
                end
            end

            LSU_REQ: begin
                if (flush) l_squashed <= 1'b1;

                if (mem_req_ready) begin
                    // Request accepted by memory.
                    if (l_is_store) begin
                        state <= LSU_DONE;   // posted write, complete now
                    end else if (mem_resp_valid) begin
                        // Some memories (e.g. a simple synchronous SRAM)
                        // deliver read data the same cycle they accept the
                        // request. Don't move to LSU_WAIT_RESP and wait an
                        // extra cycle for a response that has already
                        // arrived -- it would go unseen (single-cycle
                        // pulse) and the FSM would hang forever.
                        l_rdata <= mem_resp_rdata;
                        state   <= LSU_DONE;
                    end else begin
                        state <= LSU_WAIT_RESP;
                    end
                end else begin
                    // Keep re-asserting the request, with stable payload,
                    // until memory accepts it -- standard ready/valid
                    // convention forbids dropping VALID before READY once
                    // asserted, so a flush here only marks the eventual
                    // result for discard (l_squashed above); it does not
                    // withdraw the request early.
                    mem_req_valid <= 1'b1;
                    mem_req_we    <= l_is_store;
                    mem_req_addr  <= l_addr;
                    mem_req_wdata <= l_wdata;
                    mem_req_wstrb <= l_wstrb;
                end
            end

            LSU_WAIT_RESP: begin
                if (flush) l_squashed <= 1'b1;
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
                default: load_result = '0;  // store: result unused (reg_we is 0)
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