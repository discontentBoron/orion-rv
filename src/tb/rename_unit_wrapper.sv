`timescale 1ns/1ps
import orion_pkg::*;

// ------------------------------------------------------------
// GLS wrapper for rename_unit
// Bridges struct-based testbench ports to the flat
// port names produced by Genus synthesis.
// ------------------------------------------------------------

module rename_unit_wrapper (
    input  logic                        clk,
    input  logic                        rst_n,
    input  var decode_rename_pkt_s      decode_rename_in,
    input  logic                        branch_mispredict,
    input  logic                        commit_valid,
    input  logic [REG_ADDR_WIDTH-1:0]   commit_rd,
    input  logic [TAG_WIDTH-1:0]        commit_pd,
    input  logic [TAG_WIDTH-1:0]        commit_old_pd,
    output logic                        rename_stall,
    output rename_dispatch_pkt_s        rename_dispatch_out
);

    rename_unit u_rename (
        // Clock and reset
        .clk                                    (clk),
        .rst_n                                  (rst_n),

        // Scalar inputs
        .branch_mispredict                      (branch_mispredict),
        .commit_valid                           (commit_valid),
        .commit_rd                              (commit_rd),
        .commit_pd                              (commit_pd),
        .commit_old_pd                          (commit_old_pd),

        // decode_rename_pkt_s fields -- input struct unpacked
        .\decode_rename_in[src1_valid]          (decode_rename_in.src1_valid),
        .\decode_rename_in[src2_valid]          (decode_rename_in.src2_valid),
        .\decode_rename_in[valid]               (decode_rename_in.valid),
        .\decode_rename_in[pc]                  (decode_rename_in.pc),
        .\decode_rename_in[predicted_pc]        (decode_rename_in.predicted_pc),
        .\decode_rename_in[imm_val]             (decode_rename_in.imm_val),
        .\decode_rename_in[r_dst]               (decode_rename_in.r_dst),
        .\decode_rename_in[r_src1]              (decode_rename_in.r_src1),
        .\decode_rename_in[r_src2]              (decode_rename_in.r_src2),
        .\decode_rename_in[cause]               (decode_rename_in.cause),
        .\decode_rename_in[instr_class]         (decode_rename_in.instr_class),
        .\decode_rename_in[func_unit_type]      (decode_rename_in.func_unit_type),
        .\decode_rename_in[exec_unit_uop]       (decode_rename_in.exec_unit_uop),
        .\decode_rename_in[except]              (decode_rename_in.except),

        // rename_dispatch_pkt_s fields -- output struct repacked
        .\rename_dispatch_out[old_p_dest]       (rename_dispatch_out.old_p_dest),
        .\rename_dispatch_out[p_dest]           (rename_dispatch_out.p_dest),
        .\rename_dispatch_out[p_src1]           (rename_dispatch_out.p_src1),
        .\rename_dispatch_out[p_src2]           (rename_dispatch_out.p_src2),
        .\rename_dispatch_out[p_src1_valid]     (rename_dispatch_out.p_src1_valid),
        .\rename_dispatch_out[p_src2_valid]     (rename_dispatch_out.p_src2_valid),
        .\rename_dispatch_out[valid]            (rename_dispatch_out.valid),
        .\rename_dispatch_out[reg_we]           (rename_dispatch_out.reg_we),
        .\rename_dispatch_out[except]           (rename_dispatch_out.except),
        .\rename_dispatch_out[pc]               (rename_dispatch_out.pc),
        .\rename_dispatch_out[imm_val]          (rename_dispatch_out.imm_val),
        .\rename_dispatch_out[predicted_pc]     (rename_dispatch_out.predicted_pc),
        .\rename_dispatch_out[cause]            (rename_dispatch_out.cause),
        .\rename_dispatch_out[instr_class]      (rename_dispatch_out.instr_class),
        .\rename_dispatch_out[func_unit_type]   (rename_dispatch_out.func_unit_type),
        .\rename_dispatch_out[exec_unit_uop]    (rename_dispatch_out.exec_unit_uop),

        // Scalar output
        .rename_stall                           (rename_stall)
    );

endmodule
