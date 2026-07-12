// =============================================================================
// register_read.sv  —  Orion OOO RISC-V Processor
// Register Read Stage (Stage 6 of 8)
//
// Sits between Issue Queue and Execute.
// Responsibilities:
//   1. Write incoming wb_en writeback data into the Physical Register File (PRF)
//   2. Read PRF[p_src1] and PRF[p_src2] combinationally
//   3. Enforce x0 == 0 invariant (physical reg 0 always reads as zero)
//   4. Register the full output packet on the rising edge
//   5. On flush: register a bubble (valid=0) so downstream sees a clean NOP
//   6. CDB ports are wired in and mux structure is present for easy forwarding
//      addition later — currently forward_sel is tied to 0
//
// Design notes
//   • PRF is flip-flop based (not SRAM) → read is purely combinational.
//   • Writeback write and PRF read happen in the same always block:
//     write is clocked, read is combinational → a wb_en on cycle N is visible
//     to a read on cycle N+1. The Issue Queue guarantees operands are ready
//     before issuing, so this is always correct.
//   • flush takes priority over everything — it gates valid to 0 before
//     the register stage so the bubble propagates correctly.
// =============================================================================

import orion_pkg::*;

module register_read (
    input  logic                    clk,
    input  logic                    rst_n,

    // From Issue Queue
    input  rename_dispatch_pkt_s    dispatch_in,

    // Flush from branch misprediction / exception
    input  logic                    flush,

    // CDB (Common Data Bus) — for future forwarding; unused mux input tied 0
    input  logic [TAG_WIDTH-1:0]    cdb_tag,
    input  logic [DATA_WIDTH-1:0]   cdb_data,
    input  logic                    cdb_valid,

    // Writeback port into PRF (from execution units)
    input  logic                    wb_en,
    input  logic [TAG_WIDTH-1:0]    wb_tag,
    input  logic [DATA_WIDTH-1:0]   wb_data,

    // To Execute stage
    output regread_execute_pkt_s    execute_out
);

// ---------------------------------------------------------------------------
// Physical Register File — 64 × 32-bit flip-flops
// Physical register 0 is permanently 0 (x0 in RISC-V).
// Writes to tag 0 are silently dropped.
// ---------------------------------------------------------------------------
logic [DATA_WIDTH-1:0] prf [0:PHY_REGS-1];

always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        for (int i = 0; i < PHY_REGS; i++)
            prf[i] <= '0;
    end else begin
        // Write port — ignore writes to physical register 0
        if (wb_en && (wb_tag != '0))
            prf[wb_tag] <= wb_data;
    end
end

// ---------------------------------------------------------------------------
// Combinational PRF read with x0 enforcement
//
// Forward mux structure (stub for later):
//   src_data = forward_sel ? cdb_data : prf_read_val
//   forward_sel = (cdb_tag == p_src) && cdb_valid && p_src_valid  [tied 0 now]
//
// x0 rule applied AFTER mux so a forwarded value for p_src==0 also zeroes out.
// ---------------------------------------------------------------------------
logic [DATA_WIDTH-1:0] prf_src1_raw, prf_src2_raw;
logic [DATA_WIDTH-1:0] src1_data_comb, src2_data_comb;

// Suppressing unused-variable warnings: forward_sel intentionally wired to 0
/* verilator lint_off UNUSED */
logic forward_sel1, forward_sel2;
/* verilator lint_on  UNUSED */

// --- CDB comparators (wired to 0 until forwarding is enabled) ---
assign forward_sel1 = 1'b0;  // (cdb_tag == dispatch_in.p_src1) && cdb_valid && dispatch_in.p_src1_valid;
assign forward_sel2 = 1'b0;  // (cdb_tag == dispatch_in.p_src2) && cdb_valid && dispatch_in.p_src2_valid;

// Raw PRF reads (combinational)
assign prf_src1_raw = prf[dispatch_in.p_src1];
assign prf_src2_raw = prf[dispatch_in.p_src2];

always_comb begin
    // --- src1 ---
    if (!dispatch_in.p_src1_valid) begin
        src1_data_comb = '0;                          // unused operand → 0
    end else if (dispatch_in.p_src1 == '0) begin
        src1_data_comb = '0;                          // x0 hardwired to 0
    end else begin
        src1_data_comb = forward_sel1 ? cdb_data : prf_src1_raw;
    end

    // --- src2 ---
    if (!dispatch_in.p_src2_valid) begin
        src2_data_comb = '0;
    end else if (dispatch_in.p_src2 == '0) begin
        src2_data_comb = '0;
    end else begin
        src2_data_comb = forward_sel2 ? cdb_data : prf_src2_raw;
    end
end

// ---------------------------------------------------------------------------
// Output register — latch the full packet on the rising edge.
// On flush: override valid to 0 (bubble), all data fields still registered
// cleanly so there is no X-propagation issue downstream.
// ---------------------------------------------------------------------------
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
        execute_out.cause           <= dispatch_in.cause;
        execute_out.except          <= dispatch_in.except;

        // Computed data fields
        execute_out.src1_data       <= src1_data_comb;
        execute_out.src2_data       <= src2_data_comb;

        // valid — flush wins over everything
        execute_out.valid           <= dispatch_in.valid & ~flush;
    end
end

endmodule