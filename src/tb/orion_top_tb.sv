`timescale 1ns/1ps
import orion_pkg::*;

module orion_top_tb;
    logic clk;
    logic rst_n;

    logic [DATA_WIDTH-1:0]  fetch_pc;
    logic [DATA_WIDTH-1:0]  fetch_instr;
    logic fetch_valid;
    logic rename_stall;
    logic rob_full;
    logic iq_full;
    logic issue_valid;
    logic branch_mispredict;
    logic [DATA_WIDTH-1:0] redirect_pc;
    logic exception_valid;
    logic commit_valid;
    logic [REG_ADDR_WIDTH-1:0]  commit_rd;
    logic [TAG_WIDTH-1:0]   commit_pd;
    logic [TAG_WIDTH-1:0]   commit_old_pd;

    logic mem_req_valid;
    logic mem_req_we;
    logic [DATA_WIDTH-1:0]  mem_req_addr;
    logic [DATA_WIDTH-1:0]  mem_req_wdata;
    logic [3:0] mem_req_wstrb;
    logic mem_req_ready;
    logic mem_resp_valid;
    logic [DATA_WIDTH-1:0]  mem_resp_rdata;

    logic [31:0]    dmem [0:255];
    logic   pending_load;
    logic [31:0]    pending_rdata;

    int pass_count  = 0;
    int fail_count  = 0;
    int branch_mispredict_count = 0;
    int cdb_alu_count   = 0;
    int cdb_mul_count   = 0;
    int cdb_div_count   = 0;
    int cdb_branch_count    = 0;
    int cdb_lsu_count = 0;
    logic [DATA_WIDTH-1:0] branch_cdb_target_seen = 32'h0;
    logic [DATA_WIDTH-1:0] rob_redirect_target_seen = 32'h0;

    //Performance counters
    longint unsigned perf_cycle_count          = 0;
    longint unsigned perf_retire_count         = 0;   // true architectural retirements (incl. non-reg-writing ops)
    longint unsigned perf_retire_branch_count  = 0;
    longint unsigned perf_retire_load_count    = 0;
    longint unsigned perf_retire_store_count   = 0;
    longint unsigned perf_dispatch_count       = 0;   // successful rename->ROB/IQ dispatch
    longint unsigned perf_issue_count          = 0;   // issue_valid pulses
    longint unsigned perf_fetch_count          = 0;   // fetch_valid pulses (incl. wrong-path)
    longint unsigned perf_redirect_count       = 0;   // mispredict + exception flush events

    longint unsigned perf_stall_cycles         = 0;   // rename_stall asserted
    longint unsigned perf_stall_rob_full       = 0;
    longint unsigned perf_stall_iq_full        = 0;
    longint unsigned perf_stall_freelist       = 0;
    longint unsigned perf_stall_other          = 0;

    longint unsigned perf_rob_occ_sum          = 0;
    longint unsigned perf_iq_occ_sum           = 0;
    wire perf_retire_fire = !dut.u_rob.rob_empty && dut.u_rob.head_entry.done && !dut.u_rob.head_entry.except;
    wire perf_dispatch_fire = !dut.u_rob.flushing && !dut.branch_mispredict && !dut.exception_valid && dut.rename_dispatch_out.valid && !dut.rob_full && !dut.iq_full;
    logic [$bits(dut.u_rob.tail)-1:0] perf_rob_occ_now;
    always @(posedge clk) begin
        if (rst_n) begin
            perf_cycle_count++;

            if (perf_retire_fire) begin
                perf_retire_count++;
                case (dut.u_rob.head_entry.instr_class)
                    INSTR_BRANCH: perf_retire_branch_count++;
                    INSTR_LOAD:   perf_retire_load_count++;
                    INSTR_STORE:  perf_retire_store_count++;
                    default: /* */;
                endcase
            end

            if (perf_dispatch_fire) perf_dispatch_count++;
            if (issue_valid)        perf_issue_count++;
            if (fetch_valid && !rename_stall)        perf_fetch_count++;
            if (branch_mispredict || exception_valid) perf_redirect_count++;

            if (rename_stall) begin
                perf_stall_cycles++;
                if (rob_full)                        perf_stall_rob_full++;
                else if (iq_full)                    perf_stall_iq_full++;
                else if (dut.u_rename.free_list_empty) perf_stall_freelist++;
                else                                  perf_stall_other++;
            end
            perf_rob_occ_now = dut.u_rob.tail - dut.u_rob.head;
            perf_rob_occ_sum += perf_rob_occ_now;
            perf_iq_occ_sum  += $countones(dut.u_issue.valid_vec);
        end
    end
    
    task automatic print_perf_report;
        real ipc, cpi, mispred_rate, stall_pct, fetch_eff;
        real rob_util_pct, iq_util_pct;
        ipc = (perf_cycle_count > 0) ? real'(perf_retire_count) / real'(perf_cycle_count) : 0.0;
        cpi = (perf_retire_count > 0) ? real'(perf_cycle_count) / real'(perf_retire_count) : 0.0;
        mispred_rate = (perf_retire_branch_count > 0) ?
            100.0 * real'(branch_mispredict_count) / real'(perf_retire_branch_count) : 0.0;
        stall_pct = (perf_cycle_count > 0) ? 100.0 * real'(perf_stall_cycles) / real'(perf_cycle_count) : 0.0;
        fetch_eff = (perf_fetch_count > 0) ? 100.0 * real'(perf_retire_count) / real'(perf_fetch_count) : 0.0;
        rob_util_pct = (perf_cycle_count > 0) ? 100.0 * real'(perf_rob_occ_sum) / real'(perf_cycle_count) / real'(ROB_SIZE) : 0.0;
        iq_util_pct  = (perf_cycle_count > 0) ? 100.0 * real'(perf_iq_occ_sum)  / real'(perf_cycle_count) / real'(IQ_SIZE)  : 0.0;

        $display("\n===================== PERFORMANCE REPORT =====================");
        $display("Cycles                    : %0d", perf_cycle_count);
        $display("Instructions retired       : %0d", perf_retire_count);
        $display("IPC                        : %0.3f", ipc);
        $display("CPI                        : %0.3f", cpi);
        $display("----------------------------------------------------------------");
        $display("Fetched (incl. wrong-path) : %0d  (fetch efficiency: %0.1f%%)", perf_fetch_count, fetch_eff);
        $display("Dispatched (rename->ROB/IQ): %0d", perf_dispatch_count);
        $display("Issued                     : %0d", perf_issue_count);
        $display("Redirects (mispred+except) : %0d", perf_redirect_count);
        $display("----------------------------------------------------------------");
        $display("Branches retired           : %0d", perf_retire_branch_count);
        $display("Branch mispredicts         : %0d", branch_mispredict_count);
        $display("Mispredict rate            : %0.2f%%", mispred_rate);
        $display("Loads retired / Stores retired: %0d / %0d", perf_retire_load_count, perf_retire_store_count);
        $display("----------------------------------------------------------------");
        $display("FU issue counts  ALU=%0d MUL=%0d DIV=%0d BRANCH=%0d LSU=%0d",
                  cdb_alu_count, cdb_mul_count, cdb_div_count, cdb_branch_count, cdb_lsu_count);
        $display("----------------------------------------------------------------");
        $display("Stall cycles               : %0d (%0.1f%% of all cycles)", perf_stall_cycles, stall_pct);
        $display("  - caused by ROB full     : %0d", perf_stall_rob_full);
        $display("  - caused by IQ full      : %0d", perf_stall_iq_full);
        $display("  - caused by free-list    : %0d", perf_stall_freelist);
        $display("  - other                  : %0d", perf_stall_other);
        $display("----------------------------------------------------------------");
        $display("Avg ROB occupancy          : %0.2f / %0d (%0.1f%% util)",
                  real'(perf_rob_occ_sum) / real'(perf_cycle_count), ROB_SIZE, rob_util_pct);
        $display("Avg IQ occupancy           : %0.2f / %0d (%0.1f%% util)",
                  real'(perf_iq_occ_sum) / real'(perf_cycle_count), IQ_SIZE, iq_util_pct);
        $display("================================================================\n");
    endtask
    //===========================================================
    orion_top dut (
        .clk(clk), 
        .rst_n(rst_n),
        .fetch_pc(fetch_pc), 
        .fetch_instr(fetch_instr), 
        .fetch_valid(fetch_valid),
        .rename_stall(rename_stall), 
        .rob_full(rob_full), 
        .iq_full(iq_full),
        .issue_valid(issue_valid), 
        .branch_mispredict(branch_mispredict),
        .redirect_pc(redirect_pc), 
        .exception_valid(exception_valid),
        .commit_valid(commit_valid),
        .commit_rd(commit_rd),
        .commit_pd(commit_pd),
        .commit_old_pd(commit_old_pd),
        .mem_req_valid(mem_req_valid),
        .mem_req_we(mem_req_we),
        .mem_req_addr(mem_req_addr),
        .mem_req_wdata(mem_req_wdata),
        .mem_req_wstrb(mem_req_wstrb),
        .mem_req_ready(mem_req_ready),
        .mem_resp_valid(mem_resp_valid),
        .mem_resp_rdata(mem_resp_rdata)
    );

    initial clk = 1'b0;
    always #5 clk = ~clk;

    //Instruction Encodings
    //---------------------------------------------------------------
    function automatic [31:0] enc_r(
        input [6:0] funct7, input [4:0] rs2, input [4:0] rs1,
        input [2:0] funct3, input [4:0] rd
    );
        enc_r = {funct7, rs2, rs1, funct3, rd, 7'b0110011};
    endfunction

    function automatic [31:0] enc_i(
        input signed [11:0] imm, input [4:0] rs1,
        input [2:0] funct3, input [4:0] rd, input [6:0] opcode
    );
        enc_i = {imm[11:0], rs1, funct3, rd, opcode};
    endfunction

    function automatic [31:0] enc_s(
        input signed [11:0] imm, input [4:0] rs2, input [4:0] rs1,
        input [2:0] funct3
    );
        enc_s = {imm[11:5], rs2, rs1, funct3, imm[4:0], 7'b0100011};
    endfunction

    function automatic [31:0] enc_b(
        input signed [12:0] imm, input [4:0] rs2, input [4:0] rs1,
        input [2:0] funct3
    );
       enc_b = {imm[12], imm[10:5], rs2, rs1, funct3, imm[4:1], imm[11], 7'b1100011};
    endfunction

    function automatic [31:0] enc_addi(input [4:0] rd, input [4:0] rs1, input integer imm);
        enc_addi = enc_i(imm[11:0], rs1, 3'b000, rd, 7'b0010011);
    endfunction

    function automatic [31:0] enc_add(input [4:0] rd, input [4:0] rs1, input [4:0] rs2);
        enc_add = enc_r(7'b0000000, rs2, rs1, 3'b000, rd);
    endfunction

    function automatic [31:0] enc_mul(input [4:0] rd, input [4:0] rs1, input [4:0] rs2);
        enc_mul = enc_r(7'b0000001, rs2, rs1, 3'b000, rd);
    endfunction

    function automatic [31:0] enc_div(input [4:0] rd, input [4:0] rs1, input [4:0] rs2);
        enc_div = enc_r(7'b0000001, rs2, rs1, 3'b100, rd);
    endfunction

    function automatic [31:0] enc_lw(input [4:0] rd, input [4:0] rs1, input integer imm);
        enc_lw = enc_i(imm[11:0], rs1, 3'b010, rd, 7'b0000011);
    endfunction

    function automatic [31:0] enc_sw(input [4:0] rs2, input [4:0] rs1, input integer imm);
        enc_sw = enc_s(imm[11:0], rs2, rs1, 3'b010);
    endfunction

    function automatic [31:0] enc_beq(input [4:0] rs1, input [4:0] rs2, input integer imm);
        enc_beq = enc_b(imm[12:0], rs2, rs1, 3'b000);
    endfunction

    function automatic [31:0] enc_bne(input [4:0] rs1, input [4:0] rs2, input integer imm);
        enc_bne = enc_b(imm[12:0], rs2, rs1, 3'b001);
    endfunction
    //-----------------------------------------------------------------------------------------
    //-----------------------------------------------------------------------------------------

    

    task automatic load_program;
        for (int i = 0; i < 256; i++) begin
            dut.u_fetch.imem[i] = 32'h00000013; // ADDI x0,x0,0
            dmem[i] = 32'd0;
        end
        dut.u_fetch.imem[8'h00 >> 2] = enc_addi(5'd1, 5'd0, 6);
        dut.u_fetch.imem[8'h04 >> 2] = enc_addi(5'd2, 5'd0, 7);
        dut.u_fetch.imem[8'h08 >> 2] = enc_mul (5'd3, 5'd1, 5'd2);
        dut.u_fetch.imem[8'h0c >> 2] = enc_addi(5'd4, 5'd3, 8);
        dut.u_fetch.imem[8'h10 >> 2] = enc_div (5'd5, 5'd4, 5'd1);
        dut.u_fetch.imem[8'h14 >> 2] = enc_addi(5'd6, 5'd0, 64);
        dut.u_fetch.imem[8'h18 >> 2] = enc_sw  (5'd5, 5'd6, 4);
        dut.u_fetch.imem[8'h1c >> 2] = enc_lw  (5'd7, 5'd6, 4);
        dut.u_fetch.imem[8'h20 >> 2] = enc_add (5'd8, 5'd7, 5'd5);
        dut.u_fetch.imem[8'h24 >> 2] = enc_beq(5'd8, 5'd8, 8);
        dut.u_fetch.imem[8'h28 >> 2] = enc_sw(5'd1, 5'd6, 16);
        dut.u_fetch.imem[8'h2c >> 2] = enc_add (5'd10, 5'd8, 5'd5);
        dmem[32'h40 >> 2] = 32'd10;
    endtask

    logic   slow_test;
    logic   div_busy_at_flush = 1'b0;
    logic   lsu_busy_at_flush = 1'b0;
    int     x15_commit_count  = 0;
    task automatic load_program_slow;
        for (int i = 0; i < 256; i++) begin
            dut.u_fetch.imem[i] = 32'h00000013;
            dmem[i] = 32'd0;
        end
        dut.u_fetch.imem[8'h00 >> 2] = enc_addi(5'd1, 5'd0, 6);
        dut.u_fetch.imem[8'h04 >> 2] = enc_addi(5'd2, 5'd0, 7);
        dut.u_fetch.imem[8'h08 >> 2] = enc_mul (5'd3, 5'd1, 5'd2);
        dut.u_fetch.imem[8'h0c >> 2] = enc_addi(5'd4, 5'd3, 8);
        dut.u_fetch.imem[8'h10 >> 2] = enc_div (5'd5, 5'd4, 5'd1);   // x5 = 8, slow
        dut.u_fetch.imem[8'h14 >> 2] = enc_addi(5'd6, 5'd0, 64);
        dut.u_fetch.imem[8'h18 >> 2] = enc_beq (5'd5, 5'd5, 40);     // taken -> 0x40, resolves after the div
        // wrong path
        dut.u_fetch.imem[8'h1c >> 2] = enc_div (5'd12, 5'd5, 5'd1);
        dut.u_fetch.imem[8'h20 >> 2] = enc_mul (5'd13, 5'd5, 5'd1);
        dut.u_fetch.imem[8'h24 >> 2] = enc_lw  (5'd14, 5'd5, 0);
        dut.u_fetch.imem[8'h28 >> 2] = enc_sw  (5'd5,  5'd6, 32);
        dut.u_fetch.imem[8'h2c >> 2] = enc_addi(5'd15, 5'd5, 85);
        // correct path
        dut.u_fetch.imem[8'h40 >> 2] = enc_div (5'd12, 5'd4, 5'd5);
        dut.u_fetch.imem[8'h44 >> 2] = enc_mul (5'd13, 5'd2, 5'd5);
        dut.u_fetch.imem[8'h48 >> 2] = enc_lw  (5'd14, 5'd6, 4);
        dut.u_fetch.imem[8'h4c >> 2] = enc_add (5'd16, 5'd12, 5'd13);
        dut.u_fetch.imem[8'h50 >> 2] = enc_add (5'd10, 5'd16, 5'd14);
        dmem[32'h08 >> 2] = 32'h0000BAD1;   // wrong-path load data
        dmem[32'h44 >> 2] = 32'd77;
    endtask

    logic fib_test;
    task automatic load_prog_fib;
        for (int i = 0; i < 256; i++) begin 
            dut.u_fetch.imem[i] = 32'h00000013;
            dmem[i] = 0; 
        end
        dut.u_fetch.imem[8'h00>>2] = enc_addi(5'd1, 5'd0, 0);       // a = 0
        dut.u_fetch.imem[8'h04>>2] = enc_addi(5'd2, 5'd0, 1);       // b = 1
        dut.u_fetch.imem[8'h08>>2] = enc_addi(5'd3, 5'd0, 128);     // ptr = 0x80
        dut.u_fetch.imem[8'h0c>>2] = enc_addi(5'd4, 5'd0, 168);     // end = 0x80 + 40
        dut.u_fetch.imem[8'h10>>2] = enc_sw  (5'd1, 5'd3, 0);       // loop: store a
        dut.u_fetch.imem[8'h14>>2] = enc_add (5'd5, 5'd1, 5'd2);    // next = a + b
        dut.u_fetch.imem[8'h18>>2] = enc_addi(5'd1, 5'd2, 0);       // a = b
        dut.u_fetch.imem[8'h1c>>2] = enc_addi(5'd2, 5'd5, 0);       // b = next
        dut.u_fetch.imem[8'h20>>2] = enc_addi(5'd3, 5'd3, 4);
        dut.u_fetch.imem[8'h24>>2] = enc_bne (5'd3, 5'd4, -20);     // -> 0x10
        dut.u_fetch.imem[8'h28>>2] = enc_lw  (5'd10, 5'd3, -4);     // x10 = last stored
    endtask

    // Synthetic sum-of-squares loop: exercises ALU, MUL, DIV, BRANCH and LSU
    // every iteration, for enough dynamic instructions (~185) to reach
    // steady-state pipeline behavior rather than being dominated by fill/drain.
    //   x1 = i (0..30), x2 = n = 30, x3 = running sum, x6 = store pointer
    //   loop: i++; x4 = i*i; sum += x4; store sum @ [x6]; x6 += 4; loop while i != n
    //   after loop: x5 = sum / n ; x10 = x5 + 1   (x10 commit is the completion marker)
    logic perf_test;
    task automatic load_prog_perf;
        for (int i = 0; i < 256; i++) begin
            dut.u_fetch.imem[i] = 32'h00000013; // ADDI x0,x0,0 (NOP)
            dmem[i] = 32'd0;
        end
        dut.u_fetch.imem[8'h00 >> 2] = enc_addi(5'd1, 5'd0, 0);     // i = 0
        dut.u_fetch.imem[8'h04 >> 2] = enc_addi(5'd2, 5'd0, 30);    // n = 30
        dut.u_fetch.imem[8'h08 >> 2] = enc_addi(5'd3, 5'd0, 0);     // sum = 0
        dut.u_fetch.imem[8'h0c >> 2] = enc_addi(5'd6, 5'd0, 100);   // store ptr = 0x64
        dut.u_fetch.imem[8'h10 >> 2] = enc_addi(5'd1, 5'd1, 1);     // loop: i++
        dut.u_fetch.imem[8'h14 >> 2] = enc_mul (5'd4, 5'd1, 5'd1);  // x4 = i*i
        dut.u_fetch.imem[8'h18 >> 2] = enc_add (5'd3, 5'd3, 5'd4);  // sum += x4
        dut.u_fetch.imem[8'h1c >> 2] = enc_sw  (5'd3, 5'd6, 0);     // store sum
        dut.u_fetch.imem[8'h20 >> 2] = enc_addi(5'd6, 5'd6, 4);     // ptr += 4
        dut.u_fetch.imem[8'h24 >> 2] = enc_bne (5'd1, 5'd2, -20);   // -> 0x10 while i != n
        dut.u_fetch.imem[8'h28 >> 2] = enc_div (5'd5, 5'd3, 5'd2);  // x5 = sum / n
        dut.u_fetch.imem[8'h2c >> 2] = enc_addi(5'd10, 5'd5, 1);    // x10 = x5 + 1  (completion marker)
    endtask


    task automatic check(input logic cond, input string msg);
        if (cond) begin
            pass_count++;
            $display("[PASS] %s", msg);
        end else begin
            fail_count++;
            $display("[FAIL] %s", msg);
        end
    endtask


    always @(posedge clk) if (rst_n) begin
        if (branch_mispredict && !dut.div_ready) 
            div_busy_at_flush <= 1'b1;
        if (branch_mispredict && !dut.lsu_ready)
            lsu_busy_at_flush <= 1'b1;
        if (commit_valid && commit_rd == 5'd15)
            x15_commit_count++;
    end
    
    
    task automatic reset_dut;
        rst_n = 1'b0;
        mem_resp_valid = 1'b0;
        mem_resp_rdata = '0;
        pending_load = 1'b0;
        pending_rdata = '0;
        repeat (3) @(posedge clk);
        rst_n = 1'b1;
        @(posedge clk);
    endtask

    // Simple one-entry memory response model. A request is accepted whenever
    // LSU presents it; a load response becomes valid for the following edge.
    always_comb begin
        mem_req_ready = 1'b1;
        mem_resp_valid = pending_load;
        mem_resp_rdata = pending_rdata;
    end

    always @(posedge clk) begin
        if (!rst_n) begin
            pending_load <= 1'b0;
            pending_rdata <= '0;
        end else begin
            if (pending_load)
                pending_load <= 1'b0;
            if (mem_req_valid && mem_req_ready) begin
                if (mem_req_we) begin
                    for (int b = 0; b < 4; b++)
                        if (mem_req_wstrb[b])
                            dmem[mem_req_addr[31:2]][8*b +: 8] <= mem_req_wdata[8*b +: 8];
                end else begin
                    pending_load <= 1'b1;
                    pending_rdata <= dmem[mem_req_addr[31:2]];
                end
            end
        end
    end

    // CDB visibility monitor. These are the REAL internal CDB signals generated
    // by the five execution units, not testbench-injected completions.
    always @(posedge clk) begin
        if (rst_n) begin
            if (dut.cdb_valid_i[CDB_PORT_ALU])    cdb_alu_count++;
            if (dut.cdb_valid_i[CDB_PORT_MUL])    cdb_mul_count++;
            if (dut.cdb_valid_i[CDB_PORT_DIV])    cdb_div_count++;
            if (dut.cdb_valid_i[CDB_PORT_BRANCH]) cdb_branch_count++;
            if (dut.cdb_valid_i[CDB_PORT_LSU])    cdb_lsu_count++;

            if (dut.cdb_valid_i[CDB_PORT_BRANCH] && dut.cdb_mispredict_i[CDB_PORT_BRANCH]) begin
                branch_mispredict_count++;
                branch_cdb_target_seen = dut.cdb_target_pc_i[CDB_PORT_BRANCH];
                $display("BRANCH CDB: rob=%0d target=%08h mispredict=%0b",
                         dut.cdb_rob_tag_i[CDB_PORT_BRANCH],
                         dut.cdb_target_pc_i[CDB_PORT_BRANCH],
                         dut.cdb_mispredict_i[CDB_PORT_BRANCH]);
            end

            if (branch_mispredict)
                rob_redirect_target_seen = redirect_pc;

            if (commit_valid)
                $display("COMMIT: rd=x%0d pd=%0d value=%08h old_pd=%0d",
                         commit_rd, commit_pd, dut.u_regread.prf[commit_pd], commit_old_pd);
        end
    end

    int pred_taken_count = 0;
    always @(posedge clk)
        if (rst_n && dut.u_fetch.pred_taken && !dut.rename_stall && !branch_mispredict)
            pred_taken_count++;
    logic   loop_pred_test;
    task automatic load_program_loop;
        for (int i = 0; i < 256; i++) begin
            dut.u_fetch.imem[i] = 32'h00000013;
            dmem[i] = 32'd0;
        end
        dut.u_fetch.imem[8'h00 >> 2] = enc_addi(5'd1, 5'd0, 0);    // i = 0
        dut.u_fetch.imem[8'h04 >> 2] = enc_addi(5'd2, 5'd0, 8);    // n = 8
        dut.u_fetch.imem[8'h08 >> 2] = enc_addi(5'd1, 5'd1, 1);    // loop: i++
        dut.u_fetch.imem[8'h0c >> 2] = enc_bne (5'd1, 5'd2, -4);   // taken 7 times, then falls through
        dut.u_fetch.imem[8'h10 >> 2] = enc_addi(5'd3, 5'd1, 100);  // x3 = 108
    endtask

    always @(posedge clk) begin
    if (dut.execute_out.valid) begin
            $display(
                "EXEC: pc=%08h uop=%0d fu=%0d rob=%0d s1=%08h s2=%08h",
                dut.execute_out.pc,
                dut.execute_out.exec_unit_uop,
                dut.execute_out.func_unit_type,
                dut.execute_out.rob_tag,
                dut.execute_out.src1_data,
                dut.execute_out.src2_data
            );
        end
    end

    always @(posedge clk) 
        if (rst_n && dut.regread_lsu_in.valid && !dut.lsu_ready)
            $error("LSU DROP: pc=%08h rob=%0d", dut.regread_lsu_in.pc, dut.execute_out.rob_tag);
    always @(posedge clk) 
        if (rst_n && dut.regread_div_in.valid && !dut.div_ready)
            $error("DIV DROP: pc=%08h rob=%0d", dut.regread_div_in.pc, dut.regread_div_in.rob_tag);
    always @(posedge clk) if (rst_n) begin
        for (int p = 0; p < NUM_CDB_PORTS; p++) begin
            if (dut.cdb_valid_i[p] && dut.u_rob.tag_in_window(dut.cdb_rob_tag_i[p])) begin
                automatic int t = dut.cdb_rob_tag_i[p];
                if (dut.u_rob.rob_mem[t].done)
                    $error("CDB port %0d completes already-done ROB entry %0d", p, t);
                if (dut.cdb_reg_we_i[p] && dut.u_rob.rob_mem[t].p_dest !== dut.cdb_p_dest_i[p])
                    $error("CDB port %0d p_dest %0d != ROB entry %0d p_dest %0d",
                    p, dut.cdb_p_dest_i[p], t, dut.u_rob.rob_mem[t].p_dest);
            end
        end
    end
    
    initial begin : main
        slow_test       = $test$plusargs("SLOW");
        loop_pred_test  = $test$plusargs("LOOP");
        fib_test        = $test$plusargs("FIB");
        perf_test       = $test$plusargs("PERF");
        if (perf_test) begin
            load_prog_perf();
            $display("++++++++++++++++++++++BEGINNING PERFORMANCE BENCHMARK++++++++++++++++++++++");
        end else if (fib_test) begin
            load_prog_fib();
            $display("++++++++++++++++++++++BEGINNING FIBONACCI DEMO++++++++++++++++++++++");
        end else if (slow_test) begin
            load_program_slow();
            $display("++++++++++++++++++++++BEGINNING SLOW BRANCH TEST++++++++++++++++++++++");
        end else if(loop_pred_test) begin
            load_program_loop();
            $display("++++++++++++++++++++++BEGINNING LOOP PREDICTOR TEST++++++++++++++++++++++");
        end else
            load_program();
        reset_dut();

        
        // Wait for the last instruction of the selected program to commit.
        if (loop_pred_test) 
            wait (commit_valid === 1'b1 && commit_rd === 5'd3);    // addi x3, x1, 100
        else
            wait (commit_valid === 1'b1 && commit_rd === 5'd10);   // basic + slow tests
        wait (dut.u_sb.empty);
        repeat (3) @(posedge clk);
        if (perf_test) begin : perf_checks
            check(dut.u_regread.prf[dut.u_rename.arch_reg_map[3]] === 32'd9455,
                  "x3 sum-of-squares(1..30) = 9455");
            check(dut.u_regread.prf[dut.u_rename.arch_reg_map[5]] === 32'd315,
                  "x5 = sum/n = 315");
        end else if (fib_test) begin : fib_checks
            int expected [10] = '{0, 1, 1, 2, 3, 5, 8, 13, 21, 34};
            for (int k = 0; k < 10; k++)
                check(dmem[32+k] === expected[k],
                      $sformatf("fib[%0d] = %0d (got %0d)", k, expected[k], dmem[32+k]));
                check(dut.u_regread.prf[dut.u_rename.arch_reg_map[10]] === 32'd34,
                  "x10 = 34 (load read back the last stored value)");
                $display("Branch mispredicts: %0d", branch_mispredict_count);
        end else if (loop_pred_test) begin
            check(dut.u_regread.prf[dut.u_rename.arch_reg_map[1]] === 32'd8,   "x1 = 8");
            check(dut.u_regread.prf[dut.u_rename.arch_reg_map[2]] === 32'd8,   "x2 = 8");
            check(dut.u_regread.prf[dut.u_rename.arch_reg_map[3]] === 32'd108, "x3 = 108");
            check(branch_mispredict_count == 2,
                  $sformatf("2 mispredicts: cold first iteration + loop exit (got %0d)", branch_mispredict_count));
            check(pred_taken_count >= 6, $sformatf("predictor predicted taken >= 6 times (got %0d)", pred_taken_count));
        end else if(slow_test)begin
            // ---- slow-branch checks ----
            check(branch_mispredict_count == 1, $sformatf("exactly one mispredict (got %0d)", branch_mispredict_count));
            check(branch_cdb_target_seen    === 32'h40, "branch resolved target is 0x40");
            check(rob_redirect_target_seen  === 32'h40, "ROB redirect target is 0x40");

            // coverage: proves the test did what it claims
            check(div_busy_at_flush, "COVERAGE: wrong-path DIV was in flight at flush");
            check(lsu_busy_at_flush, "COVERAGE: wrong-path LSU op was in flight at flush");

            // correct-path results survive the flush
            check(dut.u_regread.prf[dut.u_rename.arch_reg_map[5]]  === 32'd8,   "x5  = 8");
            check(dut.u_regread.prf[dut.u_rename.arch_reg_map[12]] === 32'd6,   "x12 = 6   (correct-path DIV, not wrong-path 1)");
            check(dut.u_regread.prf[dut.u_rename.arch_reg_map[13]] === 32'd56,  "x13 = 56  (correct-path MUL, not wrong-path 48)");
            check(dut.u_regread.prf[dut.u_rename.arch_reg_map[14]] === 32'd77,  "x14 = 77  (correct-path LW, not wrong-path 0xBAD1)");
            check(dut.u_regread.prf[dut.u_rename.arch_reg_map[16]] === 32'd62,  "x16 = 62");
            check(dut.u_regread.prf[dut.u_rename.arch_reg_map[10]] === 32'd139, "x10 = 139");

            // wrong-path side effects
            check(dut.u_rename.arch_reg_map[15] === 5'd15 && x15_commit_count == 0, "wrong-path x15 never committed");
            check(dmem[32'h60 >> 2] === 32'd0,  "wrong-path store did not modify memory");
            check(dmem[32'h44 >> 2] === 32'd77, "mem[0x44] untouched");
        end else begin
            check(cdb_alu_count > 0,    "real ALU CDB activity observed");
            check(cdb_mul_count > 0,    "real MUL CDB activity observed");
            check(cdb_div_count > 0,    "real DIV CDB activity observed");
            check(cdb_lsu_count > 0,    "real LSU CDB activity observed");
            check(cdb_branch_count > 0, "real BRANCH CDB activity observed");

            check(branch_mispredict_count == 1,
                  $sformatf("exactly one real branch mispredict CDB observed (got %0d)",
                            branch_mispredict_count));
            check(branch_cdb_target_seen === 32'h0000002c,
                  "real branch CDB resolved target is 0x2c");
            check(rob_redirect_target_seen === 32'h0000002c,
                  "ROB redirect target propagated as 0x2c");

            check(dut.u_rename.arch_reg_map[1] != 5'd1 &&
                  dut.u_rename.arch_reg_map[2] != 5'd2 &&
                  dut.u_rename.arch_reg_map[3] != 5'd3,
                  "older register-writing instructions committed new physical mappings");
            check(dut.u_rename.arch_reg_map[9] === 5'd9,
                  "wrong-path x9 instruction never changed architectural mapping");

            check(dut.u_regread.prf[dut.u_rename.arch_reg_map[1]] === 32'd6,
                  "x1 architectural value = 6");
            check(dut.u_regread.prf[dut.u_rename.arch_reg_map[2]] === 32'd7,
                  "x2 architectural value = 7");
            check(dut.u_regread.prf[dut.u_rename.arch_reg_map[3]] === 32'd42,
                  "x3 MUL value = 42");
            check(dut.u_regread.prf[dut.u_rename.arch_reg_map[4]] === 32'd50,
                  "x4 dependent ADDI value = 50");
            check(dut.u_regread.prf[dut.u_rename.arch_reg_map[5]] === 32'd8,
                  "x5 DIV value = 8");
            check(dmem[32'h44 >> 2] === 32'd8,
                  "real LSU store wrote memory[0x44] = 8");
            check(dut.u_regread.prf[dut.u_rename.arch_reg_map[7]] === 32'd8,
                  "x7 load value = 8");
            check(dut.u_regread.prf[dut.u_rename.arch_reg_map[8]] === 32'd16,
                  "x8 dependent ADD value = 16");
            check(dut.u_regread.prf[dut.u_rename.arch_reg_map[10]] === 32'd24,
                  "x10 corrected-path ADD value = 24");
            check(dmem[32'h50 >> 2] === 32'd0, "wrong-path store did not modify memory");
        end
        print_perf_report();
        $display("\n===== INTEGRATION TEST SUMMARY: %0d passed, %0d failed =====",
                 pass_count, fail_count);
        if (fail_count == 0)
            $display("ALL INTEGRATION CHECKS PASSED");
        else
            $display("INTEGRATION CHECKS FAILED");
        $finish;
    end
    initial begin : watchdog
        #200000;
        $display("\n*** WATCHDOG TIMEOUT ***");
        $display("SUMMARY SO FAR: %0d passed, %0d failed", pass_count, fail_count);
        $finish;
    end
endmodule
