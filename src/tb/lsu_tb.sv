`timescale 1ns/1ps
import orion_pkg::*;

// =============================================================================
// Testbench for lsu.sv
//
// Drives a small behavioral memory model behind the LSU's ready/valid
// interface. The model's request-accept delay and response delay are both
// independently configurable per-transaction (cfg_req_delay / cfg_resp_delay),
// so the same test bench can exercise:
//   - a same-cycle "hit" (req_ready and resp_valid together) -- the exact
//     race the LSU's LSU_REQ state was fixed to handle correctly
//   - a delayed "miss"-style response (resp_valid several cycles later)
//   - a busy bus that delays even accepting the request
//
// Coverage:
//   1. Reset
//   2. LB/LBU/LH/LHU/LW correctness across byte offsets 0/2/3, verifying
//      both byte-lane selection and sign/zero extension
//   3. SB/SH/SW correctness verified by peeking the backing memory array
//      directly (byte-enable masking must leave untouched bytes alone)
//   4. Store-then-load round trip through the DUT itself
//   5. Exception passthrough (no memory access at all)
//   6. Latency: same-cycle hit vs multi-cycle miss vs delayed bus accept
//   7. Flush before the request is accepted by memory -- must still fully
//      drain (standard ready/valid convention forbids withdrawing VALID
//      early), discarding the result once it completes
//   8. Flush after acceptance, while waiting on a delayed response
//      (must drain the transaction, discard the result, ready recovers
//      only once drained -- not immediately)
//   9. Back-to-back exception passthroughs (the only "fast path" here)
// =============================================================================

module lsu_tb;

    logic clk;
    logic rst_n;
    logic flush;

    regread_execute_pkt_s regread_in;
    execute_wb_pkt_s      lsu_wb_out;
    logic                 lsu_ready;

    logic                  mem_req_valid;
    logic                  mem_req_we;
    logic [DATA_WIDTH-1:0] mem_req_addr;
    logic [DATA_WIDTH-1:0] mem_req_wdata;
    logic [3:0]            mem_req_wstrb;
    logic                  mem_req_ready;
    logic                  mem_resp_valid;
    logic [DATA_WIDTH-1:0] mem_resp_rdata;

    integer errors = 0;
    integer checks = 0;

    lsu dut (
        .clk            (clk),
        .rst_n          (rst_n),
        .flush          (flush),
        .regread_in     (regread_in),
        .lsu_ready      (lsu_ready),
        .lsu_wb_out     (lsu_wb_out),
        .mem_req_valid  (mem_req_valid),
        .mem_req_we     (mem_req_we),
        .mem_req_addr   (mem_req_addr),
        .mem_req_wdata  (mem_req_wdata),
        .mem_req_wstrb  (mem_req_wstrb),
        .mem_req_ready  (mem_req_ready),
        .mem_resp_valid (mem_resp_valid),
        .mem_resp_rdata (mem_resp_rdata)
    );

    initial clk = 1'b0;
    always #5 clk = ~clk;

    initial begin
        rst_n      = 1'b0;
        flush      = 1'b0;
        regread_in = '0;
        repeat (3) @(posedge clk);
        rst_n = 1'b1;
    end

    // -------------------------------------------------------------------
    // Behavioral memory model: word-addressable array behind a ready/valid
    // handshake with independently configurable accept/response delay.
    // -------------------------------------------------------------------
    localparam int MEM_WORDS = 1024;
    logic [31:0] mem_array [0:MEM_WORDS-1];

    logic [3:0] cfg_req_delay;   // cycles of not-ready before accepting (0 = same cycle)
    logic [3:0] cfg_resp_delay;  // cycles after accept before resp_valid (0 = same cycle as accept)

    typedef enum logic [1:0] {M_IDLE, M_WAIT_ACCEPT, M_WAIT_RESP} mem_state_e;
    mem_state_e  mstate;
    logic [3:0]  mcnt;
    logic [31:0] pending_read_addr;

    // Backdoor preload/poke port. mem_array must have exactly one driving
    // process (this always_ff) -- routing test-bench preloads through this
    // synchronous port, rather than a second `initial`-block assignment
    // straight into mem_array, avoids a multiple-driver error.
    logic        mem_poke_valid;
    logic [31:0] mem_poke_addr;
    logic [31:0] mem_poke_data;

    initial begin
        mem_poke_valid = 1'b0;
        mem_poke_addr  = '0;
        mem_poke_data  = '0;
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            mstate             <= M_IDLE;
            mem_req_ready      <= 1'b0;
            mem_resp_valid     <= 1'b0;
            mem_resp_rdata     <= '0;
            mcnt               <= '0;
            pending_read_addr  <= '0;
        end else begin
            mem_req_ready  <= 1'b0;
            mem_resp_valid <= 1'b0;

            if (mem_poke_valid) begin
                mem_array[mem_poke_addr[31:2]] <= mem_poke_data;
            end

            unique case (mstate)

            M_IDLE: begin
                if (mem_req_valid) begin
                    if (cfg_req_delay == 4'd0) begin
                        mem_req_ready <= 1'b1;
                        if (mem_req_we) begin
                            for (int b = 0; b < 4; b++)
                                if (mem_req_wstrb[b])
                                    mem_array[mem_req_addr[31:2]][8*b +: 8] <= mem_req_wdata[8*b +: 8];
                        end else if (cfg_resp_delay == 4'd0) begin
                            mem_resp_valid <= 1'b1;
                            mem_resp_rdata <= mem_array[mem_req_addr[31:2]];
                        end else begin
                            pending_read_addr <= mem_req_addr;
                            mcnt              <= cfg_resp_delay;
                            mstate            <= M_WAIT_RESP;
                        end
                    end else begin
                        mcnt   <= cfg_req_delay;
                        mstate <= M_WAIT_ACCEPT;
                    end
                end
            end

            M_WAIT_ACCEPT: begin
                if (mcnt == 4'd1) begin
                    mem_req_ready <= 1'b1;
                    if (mem_req_we) begin
                        for (int b = 0; b < 4; b++)
                            if (mem_req_wstrb[b])
                                mem_array[mem_req_addr[31:2]][8*b +: 8] <= mem_req_wdata[8*b +: 8];
                        mstate <= M_IDLE;
                    end else if (cfg_resp_delay == 4'd0) begin
                        mem_resp_valid <= 1'b1;
                        mem_resp_rdata <= mem_array[mem_req_addr[31:2]];
                        mstate         <= M_IDLE;
                    end else begin
                        pending_read_addr <= mem_req_addr;
                        mcnt              <= cfg_resp_delay;
                        mstate            <= M_WAIT_RESP;
                    end
                end else begin
                    mcnt <= mcnt - 4'd1;
                end
            end

            M_WAIT_RESP: begin
                if (mcnt == 4'd1) begin
                    mem_resp_valid <= 1'b1;
                    mem_resp_rdata <= mem_array[pending_read_addr[31:2]];
                    mstate         <= M_IDLE;
                end else begin
                    mcnt <= mcnt - 4'd1;
                end
            end

            default: mstate <= M_IDLE;

            endcase
        end
    end

    // -------------------------------------------------------------------
    // Backdoor preload: writes mem_array through the memory model's own
    // always_ff process (via mem_poke_valid/addr/data) so there is exactly
    // one driver for mem_array, rather than assigning into it directly
    // from this initial block.
    // -------------------------------------------------------------------
    task automatic mem_poke(input logic [31:0] addr, input logic [31:0] data);
        @(negedge clk);
        mem_poke_valid = 1'b1;
        mem_poke_addr  = addr;
        mem_poke_data  = data;
        @(posedge clk);
        #1;
        @(negedge clk);
        mem_poke_valid = 1'b0;
    endtask

    // -------------------------------------------------------------------
    // Reset check
    // -------------------------------------------------------------------
    task automatic check_reset;
        checks++;
        if (lsu_ready !== 1'b1) begin
            errors++;
            $error("[RESET] expected lsu_ready=1 out of reset, got %b", lsu_ready);
        end else if (lsu_wb_out.valid !== 1'b0) begin
            errors++;
            $error("[RESET] expected lsu_wb_out.valid=0 out of reset, got %b", lsu_wb_out.valid);
        end else begin
            $display("[%0t] RESET          PASS  lsu_ready=1, lsu_wb_out.valid=0", $time);
        end
    endtask

    // -------------------------------------------------------------------
    // Directed op test: drives one load/store/exception into regread_in and
    // polls lsu_wb_out.valid (latency varies with cfg_req_delay/cfg_resp_delay,
    // which the caller is expected to have set beforehand). Returns the
    // number of polling iterations taken.
    // -------------------------------------------------------------------
    task automatic run_op(
        input exec_unit_opcode_e   uop,
        input instr_class_e        iclass,
        input logic [31:0]         src1,       // base
        input logic [31:0]         src2,       // store data (ignored for loads)
        input logic [31:0]         imm_val,    // offset
        input logic [31:0]         pc_in,
        input logic [TAG_WIDTH-1:0] p_dest,
        input logic [TAG_WIDTH-1:0] old_p_dest,
        input logic [ROB_PTR-1:0]   rob_tag,
        input logic                 reg_we,
        input logic                 except_in,
        input logic [31:0]          expected_result,
        input logic                 check_result,   // false for stores (no result to check)
        input string                name,
        output int                  cycles
    );
        int timeout;

        wait (lsu_ready === 1'b1);
        @(negedge clk);
        regread_in.valid         = 1'b1;
        regread_in.exec_unit_uop = uop;
        regread_in.func_unit_type= FU_LSU;
        regread_in.instr_class   = iclass;
        regread_in.src1_data     = src1;
        regread_in.src2_data     = src2;
        regread_in.p_src1_valid  = 1'b1;
        regread_in.p_src2_valid  = 1'b1;
        regread_in.imm_val       = imm_val;
        regread_in.pc            = pc_in;
        regread_in.p_dest        = p_dest;
        regread_in.old_p_dest    = old_p_dest;
        regread_in.rob_tag       = rob_tag;
        regread_in.reg_we        = reg_we;
        regread_in.except        = except_in;
        regread_in.cause         = except_in ? EXCEPT_ILLEGAL_INST : EXCEPT_NONE;

        @(posedge clk);   // accept sampled here
        #1;
        @(negedge clk);
        regread_in.valid = 1'b0;

        timeout = 0;
        while (lsu_wb_out.valid !== 1'b1 && timeout < 60) begin
            @(posedge clk);
            #1;
            timeout++;
        end
        cycles = timeout;

        checks++;
        if (timeout >= 60) begin
            errors++;
            $error("[%s] TIMEOUT waiting for lsu_wb_out.valid", name);
        end else begin
            if (check_result && lsu_wb_out.result !== expected_result) begin
                errors++;
                $error("[%s] result mismatch: expected 0x%08h, got 0x%08h",
                       name, expected_result, lsu_wb_out.result);
            end
            if (lsu_wb_out.p_dest !== p_dest) begin
                errors++;
                $error("[%s] p_dest mismatch: expected %0d, got %0d", name, p_dest, lsu_wb_out.p_dest);
            end
            if (lsu_wb_out.rob_tag !== rob_tag) begin
                errors++;
                $error("[%s] rob_tag mismatch: expected %0d, got %0d", name, rob_tag, lsu_wb_out.rob_tag);
            end
            if (lsu_wb_out.reg_we !== (except_in ? 1'b0 : reg_we)) begin
                errors++;
                $error("[%s] reg_we mismatch: expected %b, got %b",
                       name, (except_in ? 1'b0 : reg_we), lsu_wb_out.reg_we);
            end
            if (lsu_wb_out.except !== except_in) begin
                errors++;
                $error("[%s] except mismatch: expected %b, got %b", name, except_in, lsu_wb_out.except);
            end

            if (errors == 0)
                $display("[%0t] %-18s PASS  result=0x%08h rob_tag=%0d cycles=%0d",
                          $time, name, lsu_wb_out.result, lsu_wb_out.rob_tag, cycles);
        end

        @(negedge clk);
        regread_in = '0;
    endtask

    task automatic run_simple(
        input exec_unit_opcode_e   uop,
        input instr_class_e        iclass,
        input logic [31:0]         src1,
        input logic [31:0]         src2,
        input logic [31:0]         imm_val,
        input logic [31:0]         pc_in,
        input logic [TAG_WIDTH-1:0] p_dest,
        input logic [TAG_WIDTH-1:0] old_p_dest,
        input logic [ROB_PTR-1:0]   rob_tag,
        input logic                 reg_we,
        input logic [31:0]          expected_result,
        input logic                 check_result,
        input string                name
    );
        int unused_cycles;
        run_op(uop, iclass, src1, src2, imm_val, pc_in, p_dest, old_p_dest, rob_tag,
               reg_we, 1'b0, expected_result, check_result, name, unused_cycles);
    endtask

    initial begin
        @(posedge rst_n);
        cfg_req_delay  = 4'd0;
        cfg_resp_delay = 4'd0;
        check_reset();
        @(negedge clk);

        // =================================================================
        // 1. Preload a known word at 0x100 = 0x81828384 and exercise every
        //    load op across byte offsets 0/2/3, checking both byte-lane
        //    selection and sign/zero extension. (byte0=0x84 @0x100,
        //    byte1=0x83 @0x101, byte2=0x82 @0x102, byte3=0x81 @0x103)
        // =================================================================
        mem_poke(32'h100, 32'h8182_8384);

        run_simple(LB,  INSTR_LOAD, 32'h0, 32'd0, 32'h100, 32'h1000, 6'd10, 6'd1, 5'd1,
                   1'b1, 32'hFFFF_FF84, 1'b1, "LB_off0_neg");
        run_simple(LBU, INSTR_LOAD, 32'h0, 32'd0, 32'h100, 32'h1004, 6'd11, 6'd2, 5'd2,
                   1'b1, 32'h0000_0084, 1'b1, "LBU_off0");
        run_simple(LB,  INSTR_LOAD, 32'h0, 32'd0, 32'h103, 32'h1008, 6'd12, 6'd3, 5'd3,
                   1'b1, 32'hFFFF_FF81, 1'b1, "LB_off3_neg");
        run_simple(LH,  INSTR_LOAD, 32'h0, 32'd0, 32'h100, 32'h100C, 6'd13, 6'd4, 5'd4,
                   1'b1, 32'hFFFF_8384, 1'b1, "LH_off0_neg");
        run_simple(LHU, INSTR_LOAD, 32'h0, 32'd0, 32'h100, 32'h1010, 6'd14, 6'd5, 5'd5,
                   1'b1, 32'h0000_8384, 1'b1, "LHU_off0");
        run_simple(LH,  INSTR_LOAD, 32'h0, 32'd0, 32'h102, 32'h1014, 6'd15, 6'd6, 5'd6,
                   1'b1, 32'hFFFF_8182, 1'b1, "LH_off2_neg");
        run_simple(LW,  INSTR_LOAD, 32'h0, 32'd0, 32'h100, 32'h1018, 6'd16, 6'd7, 5'd7,
                   1'b1, 32'h8182_8384, 1'b1, "LW_off0");

        // Base+offset split across two nonzero operands, to confirm the
        // address adder itself (not just imm_val) feeds correctly.
        run_simple(LW,  INSTR_LOAD, 32'h0F0, 32'd0, 32'h10, 32'h101C, 6'd17, 6'd8, 5'd8,
                   1'b1, 32'h8182_8384, 1'b1, "LW_base_plus_offset");

        // =================================================================
        // 2. Stores: verify byte-enable masking by peeking mem_array
        //    directly. Each sub-test resets its target word to a known
        //    baseline first so effects aren't cumulative across sub-tests.
        // =================================================================
        begin
            mem_poke(32'h200, 32'hAAAA_AAAA);
            run_simple(SB, INSTR_STORE, 32'h200, 32'hDEAD_BE7A, 32'h0, 32'h2000, 6'd0, 6'd0, 5'd9,
                       1'b0, 32'd0, 1'b0, "SB_off0");
            checks++;
            if (mem_array[32'h200 >> 2] !== 32'hAAAA_AA7A) begin
                errors++;
                $error("[SB_off0] memory mismatch: expected 0xAAAAAA7A, got 0x%08h", mem_array[32'h200 >> 2]);
            end else $display("[%0t] SB_off0_MEMCHK    PASS  mem[0x200]=0x%08h", $time, mem_array[32'h200 >> 2]);

            mem_poke(32'h204, 32'hAAAA_AAAA);
            run_simple(SH, INSTR_STORE, 32'h206, 32'h0000_BEEF, 32'h0, 32'h2004, 6'd0, 6'd0, 5'd10,
                       1'b0, 32'd0, 1'b0, "SH_off2");
            checks++;
            if (mem_array[32'h204 >> 2] !== 32'hBEEF_AAAA) begin
                errors++;
                $error("[SH_off2] memory mismatch: expected 0xBEEFAAAA, got 0x%08h", mem_array[32'h204 >> 2]);
            end else $display("[%0t] SH_off2_MEMCHK    PASS  mem[0x204]=0x%08h", $time, mem_array[32'h204 >> 2]);

            mem_poke(32'h300, 32'h0000_0000);
            run_simple(SW, INSTR_STORE, 32'h300, 32'hCAFE_BABE, 32'h0, 32'h2008, 6'd0, 6'd0, 5'd11,
                       1'b0, 32'd0, 1'b0, "SW_full");
            checks++;
            if (mem_array[32'h300 >> 2] !== 32'hCAFE_BABE) begin
                errors++;
                $error("[SW_full] memory mismatch: expected 0xCAFEBABE, got 0x%08h", mem_array[32'h300 >> 2]);
            end else $display("[%0t] SW_full_MEMCHK    PASS  mem[0x300]=0x%08h", $time, mem_array[32'h300 >> 2]);
        end

        // =================================================================
        // 3. Round trip: SW then LW same address through the DUT itself.
        // =================================================================
        run_simple(SW, INSTR_STORE, 32'h400, 32'h1234_5678, 32'h0, 32'h3000, 6'd0, 6'd0, 5'd12,
                   1'b0, 32'd0, 1'b0, "ROUNDTRIP_SW");
        run_simple(LW, INSTR_LOAD,  32'h400, 32'd0,        32'h0, 32'h3004, 6'd20, 6'd9, 5'd13,
                   1'b1, 32'h1234_5678, 1'b1, "ROUNDTRIP_LW");

        // =================================================================
        // 4. Exception passthrough
        // =================================================================
        begin
            int unused_cycles;
            run_op(LW, INSTR_LOAD, 32'h500, 32'd0, 32'h0, 32'h4000, 6'd30, 6'd10, 5'd14,
                   1'b1, 1'b1, 32'd0, 1'b1, "EXCEPT_PASSTHRU", unused_cycles);
        end

        // =================================================================
        // 5. Latency: same-cycle hit vs delayed-bus-accept vs delayed-resp
        // =================================================================
        begin
            int cyc;

            cfg_req_delay  = 4'd0;
            cfg_resp_delay = 4'd0;
            run_op(LW, INSTR_LOAD, 32'h100, 32'd0, 32'h0, 32'h5000, 6'd40, 6'd11, 5'd15,
                   1'b1, 1'b0, 32'h8182_8384, 1'b1, "LATENCY_HIT", cyc);
            checks++;
            if (cyc > 3) begin
                errors++;
                $error("[LATENCY_HIT] expected a short latency (same-cycle req_ready+resp_valid), got %0d cycles", cyc);
            end else $display("[%0t] LATENCY_HIT       PASS  %0d cycles", $time, cyc);

            cfg_req_delay  = 4'd0;
            cfg_resp_delay = 4'd6;
            run_op(LW, INSTR_LOAD, 32'h100, 32'd0, 32'h0, 32'h5004, 6'd41, 6'd12, 5'd16,
                   1'b1, 1'b0, 32'h8182_8384, 1'b1, "LATENCY_MISS", cyc);
            checks++;
            if (cyc < 6) begin
                errors++;
                $error("[LATENCY_MISS] expected latency to reflect the 6-cycle resp delay, got %0d cycles", cyc);
            end else $display("[%0t] LATENCY_MISS      PASS  %0d cycles", $time, cyc);

            cfg_req_delay  = 4'd4;
            cfg_resp_delay = 4'd0;
            run_op(LW, INSTR_LOAD, 32'h100, 32'd0, 32'h0, 32'h5008, 6'd42, 6'd13, 5'd17,
                   1'b1, 1'b0, 32'h8182_8384, 1'b1, "LATENCY_BUSY_BUS", cyc);
            checks++;
            if (cyc < 4) begin
                errors++;
                $error("[LATENCY_BUSY_BUS] expected latency to reflect the 4-cycle accept delay, got %0d cycles", cyc);
            end else $display("[%0t] LATENCY_BUSY_BUS  PASS  %0d cycles", $time, cyc);

            cfg_req_delay  = 4'd0;
            cfg_resp_delay = 4'd0;
        end

        // =================================================================
        // 6. Flush while still waiting for memory to even accept the
        //    request (before mem_req_ready). Standard ready/valid
        //    convention forbids withdrawing VALID early, so this must
        //    still fully drain (through the configured accept delay)
        //    before lsu_ready recovers -- it does NOT abandon immediately.
        //    The result must never reach writeback.
        // =================================================================
        begin
            logic saw_bad_valid;
            saw_bad_valid = 1'b0;
            cfg_req_delay  = 4'd5;  // ensure we have time to flush before accept
            cfg_resp_delay = 4'd0;

            wait (lsu_ready === 1'b1);
            @(negedge clk);
            regread_in.valid         = 1'b1;
            regread_in.exec_unit_uop = LW;
            regread_in.func_unit_type= FU_LSU;
            regread_in.instr_class   = INSTR_LOAD;
            regread_in.src1_data     = 32'h100;
            regread_in.p_src1_valid  = 1'b1;
            regread_in.p_src2_valid  = 1'b1;
            regread_in.imm_val       = 32'h0;
            regread_in.p_dest        = 6'd45;
            regread_in.reg_we        = 1'b1;
            regread_in.rob_tag       = 5'd18;

            @(posedge clk);   // accepted into the LSU (not yet by memory)
            #1;
            @(negedge clk);
            regread_in.valid = 1'b0;

            @(negedge clk);
            flush = 1'b1;
            @(posedge clk);   // flush sampled while still in LSU_REQ, pre-accept
            #1;
            checks++;
            if (lsu_ready !== 1'b0) begin
                errors++;
                $error("[FLUSH_PRE_ACCEPT] expected lsu_ready=0 right after flush (must still drain), got %b", lsu_ready);
            end
            @(negedge clk);
            flush = 1'b0;

            for (int f = 0; f < 20; f++) begin
                @(posedge clk);
                #1;
                checks++;
                if (lsu_wb_out.valid === 1'b1 && lsu_wb_out.rob_tag === 5'd18) begin
                    saw_bad_valid = 1'b1;
                    errors++;
                    $error("[FLUSH_PRE_ACCEPT] flushed load (rob_tag=18) incorrectly reached writeback with valid=1");
                end
                @(negedge clk);
            end

            checks++;
            if (lsu_ready !== 1'b1) begin
                errors++;
                $error("[FLUSH_PRE_ACCEPT] expected lsu_ready=1 after the drained transaction completed, got %b", lsu_ready);
            end

            if (!saw_bad_valid && errors == 0)
                $display("[%0t] FLUSH_PRE_ACCEPT  PASS  drained through the accept delay, result discarded, ready recovered after drain", $time);

            cfg_req_delay = 4'd0;
        end

        // =================================================================
        // 7. Flush after acceptance, mid-response-wait: must drain to
        //    completion (protocol lock-step with memory) before lsu_ready
        //    returns, and the result must never reach writeback.
        // =================================================================
        begin
            logic saw_bad_valid;
            saw_bad_valid = 1'b0;
            cfg_req_delay  = 4'd0;
            cfg_resp_delay = 4'd8;

            wait (lsu_ready === 1'b1);
            @(negedge clk);
            regread_in.valid         = 1'b1;
            regread_in.exec_unit_uop = LW;
            regread_in.func_unit_type= FU_LSU;
            regread_in.instr_class   = INSTR_LOAD;
            regread_in.src1_data     = 32'h100;
            regread_in.p_src1_valid  = 1'b1;
            regread_in.p_src2_valid  = 1'b1;
            regread_in.imm_val       = 32'h0;
            regread_in.p_dest        = 6'd50;
            regread_in.reg_we        = 1'b1;
            regread_in.rob_tag       = 5'd19;

            @(posedge clk);   // accepted by the LSU
            #1;
            @(negedge clk);
            regread_in.valid = 1'b0;

            repeat (2) @(posedge clk);  // let it get into LSU_WAIT_RESP
            #1;
            checks++;
            if (lsu_ready !== 1'b0) begin
                errors++;
                $error("[FLUSH_MID_RESP] expected lsu_ready=0 mid-transaction before flush, got %b", lsu_ready);
            end

            @(negedge clk);
            flush = 1'b1;
            @(posedge clk);
            #1;
            @(negedge clk);
            flush = 1'b0;

            // Ready should NOT have recovered yet -- the response (6 more
            // cycles) hasn't arrived, and the transaction can't be abandoned
            // once accepted.
            checks++;
            if (lsu_ready !== 1'b0) begin
                errors++;
                $error("[FLUSH_MID_RESP] expected lsu_ready=0 right after flush (must drain), got %b", lsu_ready);
            end

            for (int f = 0; f < 20; f++) begin
                @(posedge clk);
                #1;
                checks++;
                if (lsu_wb_out.valid === 1'b1 && lsu_wb_out.rob_tag === 5'd19) begin
                    saw_bad_valid = 1'b1;
                    errors++;
                    $error("[FLUSH_MID_RESP] flushed load (rob_tag=19) incorrectly reached writeback with valid=1");
                end
                @(negedge clk);
            end

            checks++;
            if (lsu_ready !== 1'b1) begin
                errors++;
                $error("[FLUSH_MID_RESP] expected lsu_ready=1 after the drained transaction completed, got %b", lsu_ready);
            end

            if (!saw_bad_valid && errors == 0)
                $display("[%0t] FLUSH_MID_RESP    PASS  drained in lock-step, result discarded, ready recovered after drain", $time);

            cfg_resp_delay = 4'd0;
        end

        // =================================================================
        // 8. Back-to-back exception passthroughs: the only fast path here,
        //    lsu_ready must never drop and results must appear one cycle
        //    after each request, in order.
        // =================================================================
        begin
            logic [TAG_WIDTH-1:0] exp_pdest [0:2];
            logic [ROB_PTR-1:0]   exp_robtag[0:2];
            int i;

            exp_pdest[0] = 6'd25; exp_robtag[0] = 5'd22; // @suppress "Multiple statements on this line. Split the statements over multiple lines to improve readability."
            exp_pdest[1] = 6'd26; exp_robtag[1] = 5'd23; // @suppress "Multiple statements on this line. Split the statements over multiple lines to improve readability."
            exp_pdest[2] = 6'd27; exp_robtag[2] = 5'd24; // @suppress "Multiple statements on this line. Split the statements over multiple lines to improve readability."

            wait (lsu_ready === 1'b1);
            @(negedge clk);
            for (i = 0; i < 3; i++) begin
                checks++;
                if (lsu_ready !== 1'b1) begin
                    errors++;
                    $error("[EXCEPT_THROUGHPUT %0d] expected lsu_ready=1 on the exception fast path, got %b", i, lsu_ready);
                end

                regread_in.valid         = 1'b1;
                regread_in.exec_unit_uop = LW;
                regread_in.func_unit_type= FU_LSU;
                regread_in.instr_class   = INSTR_LOAD;
                regread_in.src1_data     = 32'd0;
                regread_in.imm_val       = 32'd0;
                regread_in.p_src1_valid  = 1'b1;
                regread_in.p_src2_valid  = 1'b1;
                regread_in.pc            = 32'h6000 + 4*i;
                regread_in.p_dest        = exp_pdest[i];
                regread_in.rob_tag       = exp_robtag[i];
                regread_in.reg_we        = 1'b1;
                regread_in.except        = 1'b1;
                regread_in.cause         = EXCEPT_ILLEGAL_INST;

                @(posedge clk);
                #1;

                checks++;
                if (lsu_wb_out.valid !== 1'b1 || lsu_wb_out.except !== 1'b1 ||
                    lsu_wb_out.p_dest !== exp_pdest[i] || lsu_wb_out.rob_tag !== exp_robtag[i]) begin
                    errors++;
                    $error("[EXCEPT_THROUGHPUT %0d] expected valid=1 except=1 p_dest=%0d rob_tag=%0d, got valid=%b except=%b p_dest=%0d rob_tag=%0d",
                        i, exp_pdest[i], exp_robtag[i],
                        lsu_wb_out.valid, lsu_wb_out.except, lsu_wb_out.p_dest, lsu_wb_out.rob_tag);
                end else begin
                    $display("[%0t] EXCEPT_THROUGHPUT[%0d]  PASS  rob_tag=%0d (back-to-back, fast path)",
                            $time, i, lsu_wb_out.rob_tag);
                end
                @(negedge clk);
            end
            regread_in = '0;
        end

        $display("\n=====================================================");
        if (errors == 0)
            $display("PASS: lsu : %0d checks, 0 errors.", checks);
        else
            $display("FAIL: lsu : %0d checks, %0d errors.", checks, errors);
        $display("=====================================================");
        $finish;
    end

endmodule