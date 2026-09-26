import orion_pkg::*;

module mul (
    input  logic                  clk,
    input  logic                  rst_n,
    input  logic                  flush,

    input  regread_execute_pkt_s  regread_in,

    output execute_wb_pkt_s       mul_wb_out
);
    // Stage 1: partial product generation and corrections
    logic [15:0] a_lo_comb, a_hi_comb, b_lo_comb, b_hi_comb;
    assign a_lo_comb = regread_in.src1_data[15:0];
    assign a_hi_comb = regread_in.src1_data[31:16];
    assign b_lo_comb = regread_in.src2_data[15:0];
    assign b_hi_comb = regread_in.src2_data[31:16];

    logic [31:0] p0_comb, p1_comb, p2_comb, p3_comb;
    assign p0_comb = a_lo_comb * b_lo_comb;
    assign p1_comb = a_hi_comb * b_lo_comb;
    assign p2_comb = a_lo_comb * b_hi_comb;
    assign p3_comb = a_hi_comb * b_hi_comb;

    logic [32:0]  p12_comb, total_corr_comb;
    logic a_neg_comb, b_neg_comb;
    logic [31:0] a_corr_val_comb, b_corr_val_comb;

    assign a_neg_comb = regread_in.src1_data[31];
    assign b_neg_comb = regread_in.src2_data[31];
    assign  p12_comb = p1_comb + p2_comb;
    assign a_corr_val_comb = (a_neg_comb && (regread_in.exec_unit_uop == MULH | regread_in.exec_unit_uop == MULHSU)) ? regread_in.src2_data : 32'd0;
    assign b_corr_val_comb = (b_neg_comb && (regread_in.exec_unit_uop == MULH)) ? regread_in.src1_data : 32'd0;
    assign total_corr_comb = a_corr_val_comb + b_corr_val_comb;

    logic                    ms1_valid;
    logic [TAG_WIDTH-1:0]    ms1_p_dest;
    logic [TAG_WIDTH-1:0]    ms1_old_p_dest;
    logic [ROB_PTR-1:0]      ms1_rob_tag;
    logic                    ms1_reg_we;
    logic [DATA_WIDTH-1:0]   ms1_pc;
    instr_class_e            ms1_instr_class;
    except_cause_e           ms1_except_cause;
    logic                    ms1_except;
    exec_unit_opcode_e       ms1_uop;
    logic [31:0]             ms1_p0, ms1_p3;
    logic [32:0]             ms1_p12;
    logic [32:0]             ms1_total_corr;

    always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        ms1_valid        <= 1'b0;
        ms1_p_dest        <= '0;
        ms1_old_p_dest    <= '0;
        ms1_rob_tag       <= '0;
        ms1_reg_we        <= 1'b0;
        ms1_pc            <= '0;
        ms1_instr_class   <= INSTR_NOP;
        ms1_except_cause  <= EXCEPT_NONE;
        ms1_except        <= 1'b0;
        ms1_uop           <= MUL;
        ms1_p0            <= '0;
        ms1_p3            <= '0;
        ms1_p12           <= '0;
        ms1_total_corr    <= '0;
    end else begin
        ms1_valid         <= regread_in.valid & ~flush;
        ms1_p_dest        <= regread_in.p_dest;
        ms1_old_p_dest    <= regread_in.old_p_dest;
        ms1_rob_tag       <= regread_in.rob_tag;
        ms1_reg_we        <= regread_in.reg_we;
        ms1_pc            <= regread_in.pc;
        ms1_instr_class   <= regread_in.instr_class;
        ms1_except_cause  <= regread_in.cause;
        ms1_except        <= regread_in.except;
        ms1_uop           <= regread_in.exec_unit_uop;
        ms1_p0            <= p0_comb;
        ms1_p3            <= p3_comb;
        ms1_p12           <= p12_comb;
        ms1_total_corr    <= total_corr_comb;
    end
  end
 
  //Stage 2: Final sum
  logic [63:0] unsigned_product_comb;
  assign unsigned_product_comb = {32'd0, ms1_p0}
                                + ({31'd0, ms1_p12} << 16)
                                + ({32'd0, ms1_p3} << 32);
  logic [63:0] signed_product_comb;
  assign signed_product_comb = unsigned_product_comb - (64'(ms1_total_corr) << 32);
  logic [DATA_WIDTH-1:0] mul_result_comb;
 
  always_comb begin
    unique case (ms1_uop)
        MUL:     mul_result_comb = unsigned_product_comb[31:0];
        MULH:    mul_result_comb = signed_product_comb[63:32];
        MULHSU:  mul_result_comb = signed_product_comb[63:32];
        MULHU:   mul_result_comb = unsigned_product_comb[63:32];
        default: mul_result_comb = 'x;
    endcase
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      mul_wb_out <= '0;
    end else begin
      mul_wb_out.valid        <= ms1_valid & ~flush;
      mul_wb_out.p_dest       <= ms1_p_dest;
      mul_wb_out.old_p_dest   <= ms1_old_p_dest;
      mul_wb_out.rob_tag      <= ms1_rob_tag;
      mul_wb_out.reg_we       <= ms1_reg_we;
      mul_wb_out.result       <= mul_result_comb;
      mul_wb_out.pc           <= ms1_pc;
      mul_wb_out.instr_class  <= ms1_instr_class;
      mul_wb_out.except_cause <= ms1_except_cause;
      mul_wb_out.except       <= ms1_except;
    end
  end
endmodule