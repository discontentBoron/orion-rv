import orion_pkg::*;
module div(
    input  logic                  clk,
    input  logic                  rst_n,
    input  logic                  flush,

    input  regread_execute_pkt_s  regread_in,

    output execute_wb_pkt_s       div_wb_out,
    output logic                  div_ready
);
    typedef enum logic [1:0] {
        DIV_IDLE,
        DIV_BUSY,
        DIV_DONE
    } div_state_e;

    div_state_e state;
    logic [5:0] bit_cnt;
    regread_execute_pkt_s latched;
    logic [32:0] rem;        // 33-bit remainder (supports overflow during shift)
    logic [31:0] quot;       // quotient
    logic [31:0] divisor;    // absolute value of divisor

    // Sign handling
    logic        result_neg;     // quotient sign = src1 ^ src2
    logic        rem_neg;
    assign div_ready = (state == DIV_IDLE);
    wire   accept   = div_ready && regread_in.valid;
    
    always_ff @(posedge clk  or negedge rst_n) begin
        if (!rst_n) begin
            state      <= DIV_IDLE;
            bit_cnt    <= '0;
            rem        <= '0;
            quot       <= '0;
            divisor    <= '0;
            latched    <= '0;
            div_wb_out <= '0;
        end else if (flush) begin
            // Flush: abort current operation and clear output
            state      <= DIV_IDLE;
            bit_cnt    <= '0;
            rem        <= '0;
            quot       <= '0;
            divisor    <= '0;
            latched    <= '0;
            div_wb_out.valid <= 1'b0;
        end else begin
            div_wb_out.valid <= 1'b0;
            case(state)
                DIV_IDLE:begin
                    if (accept) begin
                        latched <= regread_in;
                        if (regread_in.except) begin
                            // Pass exception through
                            div_wb_out.valid        <= 1'b1;
                            div_wb_out.p_dest       <= regread_in.p_dest;
                            div_wb_out.old_p_dest   <= regread_in.old_p_dest;
                            div_wb_out.rob_tag      <= regread_in.rob_tag;
                            div_wb_out.reg_we       <= regread_in.reg_we;
                            div_wb_out.result       <= '0;
                            div_wb_out.pc           <= regread_in.pc;
                            div_wb_out.instr_class  <= regread_in.instr_class;
                            div_wb_out.except_cause <= regread_in.cause;
                            div_wb_out.except       <= regread_in.except;
                            // stay in IDLE (ready for next)
                        end else begin
                            // Special case: INT_MIN / -1 
                            automatic logic is_rem = (regread_in.exec_unit_uop inside {REM, REMU});
                            automatic logic is_signed = (regread_in.exec_unit_uop inside {DIV, REM});
                            if (is_signed &&
                                regread_in.src1_data == 32'h80000000 &&
                                regread_in.src2_data == 32'hFFFFFFFF) begin
                                // RISC‑V mandated result: DIV -> 0x80000000, REM -> 0
                                div_wb_out.valid        <= 1'b1;
                                div_wb_out.p_dest       <= regread_in.p_dest;
                                div_wb_out.old_p_dest   <= regread_in.old_p_dest;
                                div_wb_out.rob_tag      <= regread_in.rob_tag;
                                div_wb_out.reg_we       <= regread_in.reg_we;
                                div_wb_out.result       <= is_rem ? 32'd0 : 32'h80000000;
                                div_wb_out.pc           <= regread_in.pc;
                                div_wb_out.instr_class  <= regread_in.instr_class;
                                div_wb_out.except_cause <= EXCEPT_NONE;
                                div_wb_out.except       <= 1'b0;
                                // stay in IDLE
                            end else begin
                                // ---- 4. Prepare operands ----
                                automatic logic [31:0] a = regread_in.src1_data;
                                automatic logic [31:0] b = regread_in.src2_data;
                                automatic logic src1_neg = is_signed & a[31];
                                automatic logic src2_neg = is_signed & b[31];

                                // Absolute values (for signed, INT_MIN stays 0x80000000)
                                automatic logic [31:0] a_abs = src1_neg ? (~a + 1) : a;
                                automatic logic [31:0] b_abs = src2_neg ? (~b + 1) : b;

                                // Sign of quotient = src1_sign ^ src2_sign; remainder sign = src1_sign
                                result_neg = src1_neg ^ src2_neg;
                                rem_neg    = src1_neg;

                                // ---- 5. Divide‑by‑zero ----
                                if (b_abs == 32'd0) begin
                                    // RISC‑V spec: DIV[U] by 0 -> all 1s; REM[U] by 0 -> dividend
                                    automatic logic [31:0] div_result = (is_rem) ? a : 32'hFFFFFFFF;
                                    div_wb_out.valid        <= 1'b1;
                                    div_wb_out.p_dest       <= regread_in.p_dest;
                                    div_wb_out.old_p_dest   <= regread_in.old_p_dest;
                                    div_wb_out.rob_tag      <= regread_in.rob_tag;
                                    div_wb_out.reg_we       <= regread_in.reg_we;
                                    div_wb_out.result       <= div_result;
                                    div_wb_out.pc           <= regread_in.pc;
                                    div_wb_out.instr_class  <= regread_in.instr_class;
                                    div_wb_out.except_cause <= EXCEPT_NONE;
                                    div_wb_out.except       <= 1'b0;
                                    // stay in IDLE
                                end else begin
                                    // ---- 6. Start unsigned division ----
                                    rem      <= 33'd0;
                                    quot     <= a_abs;
                                    divisor  <= b_abs;
                                    bit_cnt  <= 6'd32;
                                    state    <= DIV_BUSY;
                                    // output remains invalid
                                end
                            end
                        end
                    end
                end
                DIV_BUSY: begin
                    automatic logic [32:0] rem_shifted = (rem << 1) | {32'd0, quot[31]};
                    automatic logic [31:0] quot_shifted = {quot[30:0], 1'b0};

                    if (rem_shifted >= {1'b0, divisor}) begin
                        rem  <= rem_shifted - {1'b0, divisor};
                        quot <= quot_shifted | 32'd1;
                    end else begin
                        rem  <= rem_shifted;
                        quot <= quot_shifted;
                    end

                    bit_cnt <= bit_cnt - 1'b1;

                    if (bit_cnt == 6'd1) begin
                        // Last iteration completed
                        state <= DIV_DONE;
                    end
                end
                DIV_DONE: begin
                    automatic logic [31:0] final_quot = (result_neg && (quot != 32'd0)) ? (~quot + 1) : quot;
                    automatic logic [31:0] final_rem  = (rem_neg    && (rem  != 32'd0)) ? (~rem[31:0] + 1) : rem[31:0];

                    automatic logic [31:0] result_out;
                    if (latched.exec_unit_uop inside {DIV, DIVU})
                        result_out = final_quot;
                    else // REM, REMU
                        result_out = final_rem;

                    div_wb_out.valid        <= 1'b1;
                    div_wb_out.p_dest       <= latched.p_dest;
                    div_wb_out.old_p_dest   <= latched.old_p_dest;
                    div_wb_out.rob_tag      <= latched.rob_tag;
                    div_wb_out.reg_we       <= latched.reg_we;
                    div_wb_out.result       <= result_out;
                    div_wb_out.pc           <= latched.pc;
                    div_wb_out.instr_class  <= latched.instr_class;
                    div_wb_out.except_cause <= EXCEPT_NONE;
                    div_wb_out.except       <= 1'b0;

                    state <= DIV_IDLE;
                end
                default: state <= DIV_IDLE;
            endcase
        end
    end
    

endmodule
