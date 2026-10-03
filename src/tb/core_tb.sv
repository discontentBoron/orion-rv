`timescale 1ns/1ps
import orion_pkg::*;

module core_tb;
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
    localparam int IMEM_DEPTH = 256;
    logic                   imem_req_valid;
    logic                   imem_req_ready;
    logic [DATA_WIDTH-1:0]  imem_req_addr;
    logic                   imem_resp_valid;
    logic [DATA_WIDTH-1:0]  imem_resp_data;
    logic                   imem_resp_last;

    logic dmem_req_valid;
    logic dmem_req_we;
    logic [DATA_WIDTH-1:0]  dmem_req_addr;
    logic [DATA_WIDTH-1:0]  dmem_req_wdata;
    logic [3:0] dmem_req_wstrb;
    logic dmem_req_ready;
    logic dmem_resp_valid;
    logic [DATA_WIDTH-1:0]  dmem_resp_rdata;

    logic [31:0]    dmem [0:8191];
    // logic   pending_load;
    // logic [31:0]    pending_rdata;

    // completion signals
    logic        perf_bench_done;
    logic [31:0] perf_bench_result;

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
    longint unsigned perf_retire_count         = 0;   // true architectural retirements
    longint unsigned perf_retire_branch_count  = 0;
    longint unsigned perf_retire_load_count    = 0;
    longint unsigned perf_retire_store_count   = 0;
    longint unsigned perf_dispatch_count       = 0;   // successful rename->ROB/IQ dispatch
    longint unsigned perf_issue_count          = 0;   // issue_valid pulses
    longint unsigned perf_fetch_count          = 0;   // fetch_valid pulses (including wrong-path)
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
    orion_core dut (
        .clk            (clk),
        .rst_n          (rst_n),
        .imem_req_valid (imem_req_valid),
        .imem_req_ready (imem_req_ready),
        .imem_req_addr  (imem_req_addr),
        .imem_resp_valid(imem_resp_valid),
        .imem_resp_data (imem_resp_data),
        .imem_resp_last (imem_resp_last),
        .dmem_req_valid (dmem_req_valid),
        .dmem_req_we    (dmem_req_we),
        .dmem_req_addr  (dmem_req_addr),
        .dmem_req_wdata (dmem_req_wdata),
        .dmem_req_wstrb (dmem_req_wstrb),
        .dmem_req_ready (dmem_req_ready),
        .dmem_resp_valid(dmem_resp_valid),
        .dmem_resp_rdata(dmem_resp_rdata)
    );


    // core no longer exports observability ports; tap the internal signals
    // hierarchically so the rest of the testbench is unchanged.
    assign fetch_pc          = dut.fetch_pc;
    assign fetch_instr       = dut.fetch_instr;
    assign fetch_valid       = dut.fetch_valid;
    assign rename_stall      = dut.rename_stall;
    assign rob_full          = dut.rob_full;
    assign iq_full           = dut.iq_full;
    assign issue_valid       = dut.issue_valid;
    assign branch_mispredict = dut.branch_mispredict;
    assign redirect_pc       = dut.redirect_pc;
    assign exception_valid   = dut.exception_valid;
    assign commit_valid      = dut.u_rob.commit_valid;
    assign commit_rd         = dut.u_rob.commit_rd;
    assign commit_pd         = dut.u_rob.commit_pd;
    assign commit_old_pd     = dut.u_rob.commit_old_pd;

    imem_model #(
        .DEPTH(IMEM_DEPTH)
    ) imem_model_instance (
        .clk        (clk),
        .rst_n      (rst_n),
        .req_valid  (imem_req_valid),
        .req_ready  (imem_req_ready),
        .req_addr   (imem_req_addr),
        .resp_valid (imem_resp_valid),
        .resp_data  (imem_resp_data),
        .resp_last  (imem_resp_last)
    );
    initial begin
        int il;
        if ($value$plusargs("IMEM_LAT=%d", il)) begin
            imem_model_instance.lat_min = il;
            imem_model_instance.lat_max = il;
        end else if ($test$plusargs("IMEM_RANDLAT")) begin
            imem_model_instance.lat_min = 1;
            imem_model_instance.lat_max = 25;
            imem_model_instance.gap_pct = 25;
        end
    end

    initial clk = 1'b0;
    always #2 clk = ~clk;

    task automatic load_program;
        for (int i = 0; i < 256; i++) begin
            imem_model_instance.mem[i] = 32'h00000013; // ADDI x0,x0,0
            dmem[i] = 32'd0;
        end
        $readmemh("../build/bench/sum.hex", imem_model_instance.mem);
        dmem[32'h40 >> 2] = 32'd2000;
    endtask

    logic   slow_test;
    logic   div_busy_at_flush = 1'b0;
    logic   lsu_busy_at_flush = 1'b0;
    int     x15_commit_count  = 0;
    task automatic load_program_slow;
        for (int i = 0; i < 256; i++) begin
            imem_model_instance.mem[i] = 32'h00000013;
            dmem[i] = 32'd0;
        end
        $readmemh("../build/orion_top_tb/slow.hex", imem_model_instance.mem);
        dmem[32'h08 >> 2] = 32'h0000BAD1;   // wrong-path load data
        dmem[32'h44 >> 2] = 32'd77;
    endtask

    logic fib_test;
    task automatic load_prog_fib;
        for (int i = 0; i < 256; i++) begin 
            imem_model_instance.mem[i] = 32'h00000013;
            dmem[i] = 0; 
        end
        $readmemh("../build/orion_top_tb/fib.hex", imem_model_instance.mem);
    endtask

    // GCC-built sum(1..n) benchmark (sum.elf) It reads n from 0x3E0, sums 1..n, stores the result
    // to 0x3F0, then sets a done flag at 0x3F4
    logic perf_test;
    task automatic load_prog_perf;
        for (int i = 0; i < 256; i++) begin
            imem_model_instance.mem[i] = 32'h00000013; // ADDI x0,x0,0 (NOP)
            dmem[i] = 32'd0;
        end
        $readmemh("../build/bench/sum.hex", imem_model_instance.mem);
        dmem[32'h000003E0 >> 2] = 32'd10000;  
    endtask

    logic ilp_test;
    task automatic load_prog_ilp;
        for (int i = 0; i < 256; i++) begin
            imem_model_instance.mem[i] = 32'h00000013; // ADDI x0,x0,0 (NOP)
            dmem[i] = 32'd0;
        end
        $readmemh("../build/bench/ilp.hex", imem_model_instance.mem);
        dmem[32'h000003E0 >> 2] = 1000;
        dmem[32'h000003E4 >> 2] = 32'h12345678;
    endtask
    logic mem_muldiv_test;
    task automatic load_prog_mem_muldiv;
        for (int i = 0; i < 256; i++) begin
            imem_model_instance.mem[i] = 32'h00000013; // ADDI x0,x0,0 (NOP)
            dmem[i] = 32'd0;
        end
        $readmemh("../build/bench/mem_muldiv.hex", imem_model_instance.mem);
        dmem[32'h000003E0 >> 2] = 32'd1000;
        dmem[32'h000003E4 >> 2] = 32'h12345678;
    endtask
    logic general_test;
    task automatic load_prog_general;
        for (int i = 0; i < 256; i++) begin
            imem_model_instance.mem[i] = 32'h00000013; // ADDI x0,x0,0 (NOP)
            dmem[i] = 32'd0;
        end
        $readmemh("../build/bench/general.hex", imem_model_instance.mem);
        dmem[32'h000003E0 >> 2] = 32'd1000;
        dmem[32'h000003E4 >> 2] = 32'h12345678;
    endtask
    logic balanced_test;
    task automatic load_prog_balanced;
        for (int i = 0; i < 256; i++) begin
            imem_model_instance.mem[i] = 32'h00000013; // ADDI x0,x0,0 (NOP)
            dmem[i] = 32'd0;
        end
        $readmemh("../build/bench/general_balanced.hex", imem_model_instance.mem);
        dmem[32'h000003E0 >> 2] = 32'd1000;
        dmem[32'h000003E4 >> 2] = 32'h12345678;
    endtask
    logic matmul_test;
    task automatic load_prog_matmul;
        for (int i = 0; i < 256; i++) begin
            imem_model_instance.mem[i] = 32'h00000013; // ADDI x0,x0,0 (NOP)
        end
        for (int i = 0; i < 8192; i++) begin
            dmem[i] = 32'd0;
        end
        $readmemh("../build/bench/matmul.hex", imem_model_instance.mem);
        dmem[32'h000003E0 >> 2] = 32'd20;
        dmem[32'h000003E4 >> 2] = 32'h12345678;
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
        dmem_resp_valid = 1'b0;
        dmem_resp_rdata = '0;
        // pending_load = 1'b0;
        // pending_rdata = '0;
        repeat (3) @(posedge clk);
        rst_n = 1'b1;
        @(posedge clk);
    endtask

    // Simple one-entry memory response model. A request is accepted whenever
    // LSU presents it; a load response becomes valid for the following edge.
    // always_comb begin
    //     dmem_req_ready = 1'b1;
    //     dmem_resp_valid = pending_load;
    //     dmem_resp_rdata = pending_rdata;
    // end

    int MEM_LAT_MIN = 1;
    int MEM_LAT_MAX = 1;
    bit MEM_RANDLAT;
    initial begin
        int fixed_lat;
        MEM_RANDLAT = $test$plusargs("MEM_RANDLAT");
        if ($value$plusargs("MEM_LAT=%d", fixed_lat)) begin
            MEM_LAT_MIN = fixed_lat;
            MEM_LAT_MAX = fixed_lat;
        end else if (MEM_RANDLAT) begin
            MEM_LAT_MIN = 1;
            MEM_LAT_MAX = 6;   // widen/narrow as needed
        end
    end
    logic        resp_pending;
    int          resp_countdown;
    logic [31:0] resp_rdata_q;
    always_comb begin
        dmem_req_ready  = 1'b1;                       // no backpressure on accept
        dmem_resp_valid = resp_pending && (resp_countdown == 0);
        dmem_resp_rdata = resp_rdata_q;
    end

    always @(posedge clk) begin
        if (!rst_n) begin
            resp_pending      <= 1'b0;
            resp_countdown    <= 0;
            resp_rdata_q      <= '0;
            perf_bench_done   <= 1'b0;
            perf_bench_result <= '0;
        end else begin
            // Response delivered this cycle -> the slot is free again.
            if (resp_pending && resp_countdown == 0)
                resp_pending <= 1'b0;
            else if (resp_pending)
                resp_countdown <= resp_countdown - 1;
 
            if (dmem_req_valid && dmem_req_ready) begin
                if (dmem_req_we) begin
                    for (int b = 0; b < 4; b++)
                        if (dmem_req_wstrb[b])
                            dmem[dmem_req_addr[31:2]][8*b +: 8] <= dmem_req_wdata[8*b +: 8];
 
                    if (dmem_req_addr == 32'h000003F0) begin
                        perf_bench_result <= dmem_req_wdata;
                        $display("BENCH RESULT STORE: value=%0d", dmem_req_wdata);
                    end
                    if (dmem_req_addr == 32'h000003F4) begin
                        perf_bench_done <= 1'b1;
                        $display("BENCH DONE STORE: cycle=%0d", perf_cycle_count + 1);
                    end
                end else begin
                    resp_rdata_q   <= dmem[dmem_req_addr[31:2]];
                    resp_pending   <= 1'b1;
                    resp_countdown <= MEM_RANDLAT
                                        ? $urandom_range(MEM_LAT_MIN, MEM_LAT_MAX) - 1
                                        : MEM_LAT_MAX - 1;
                end
            end
        end
    end

    // always @(posedge clk) begin
    //     if (!rst_n) begin
    //         pending_load      <= 1'b0;
    //         pending_rdata     <= '0;
    //         perf_bench_done   <= 1'b0;
    //         perf_bench_result <= '0;
    //     end else begin
    //         if (pending_load)
    //             pending_load <= 1'b0;
    //         if (dmem_req_valid && dmem_req_ready) begin
    //             if (dmem_req_we) begin
    //                 for (int b = 0; b < 4; b++)
    //                     if (dmem_req_wstrb[b])
    //                         dmem[dmem_req_addr[31:2]][8*b +: 8] <= dmem_req_wdata[8*b +: 8];

    //                 // perf_test (sum.elf) completion protocol, same as benchmark_tb.sv
    //                 if (dmem_req_addr == 32'h000003F0) begin
    //                     perf_bench_result <= dmem_req_wdata;
    //                     $display("BENCH RESULT STORE: value=%0d", dmem_req_wdata);
    //                 end
    //                 if (dmem_req_addr == 32'h000003F4) begin
    //                     perf_bench_done <= 1'b1;
    //                     $display("BENCH DONE STORE: cycle=%0d", perf_cycle_count + 1);
    //                 end
    //             end else begin
    //                 pending_load <= 1'b1;
    //                 pending_rdata <= dmem[dmem_req_addr[31:2]];
    //             end
    //         end
    //     end
    // end
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
                // $display("BRANCH CDB: rob=%0d target=%08h mispredict=%0b",
                //          dut.cdb_rob_tag_i[CDB_PORT_BRANCH],
                //          dut.cdb_target_pc_i[CDB_PORT_BRANCH],
                //          dut.cdb_mispredict_i[CDB_PORT_BRANCH]);
            end

            if (branch_mispredict)
                rob_redirect_target_seen = redirect_pc;

            // if (commit_valid)
            //     $display("COMMIT: rd=x%0d pd=%0d value=%08h old_pd=%0d",
            //              commit_rd, commit_pd, dut.u_regread.prf[commit_pd], commit_old_pd);
        end
    end

    int pred_taken_count = 0;
    always @(posedge clk)
        if (rst_n && dut.u_fetch.pred_taken && !dut.rename_stall && !branch_mispredict)
            pred_taken_count++;
    logic   loop_pred_test;
    task automatic load_program_loop;
        for (int i = 0; i < 256; i++) begin
            imem_model_instance.mem[i] = 32'h00000013;
            dmem[i] = 32'd0;
        end
        $readmemh("../build/orion_top_tb/loop.hex", imem_model_instance.mem);
    endtask

    // always @(posedge clk) begin
    // if (dut.execute_out.valid) begin
    //         $display(
    //             "EXEC: pc=%08h uop=%0d fu=%0d rob=%0d s1=%08h s2=%08h",
    //             dut.execute_out.pc,
    //             dut.execute_out.exec_unit_uop,
    //             dut.execute_out.func_unit_type,
    //             dut.execute_out.rob_tag,
    //             dut.execute_out.src1_data,
    //             dut.execute_out.src2_data
    //         );
    //     end
    // end
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
        ilp_test        = $test$plusargs("ILP");
        mem_muldiv_test = $test$plusargs("MEM_MULDIV");
        general_test    = $test$plusargs("GEN");
        balanced_test   = $test$plusargs("BAL");
        matmul_test     = $test$plusargs("MATMUL");
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
        end else if(ilp_test) begin
            load_prog_ilp();
            $display("++++++++++++++++++++++ILP PERFORMANCE TEST++++++++++++++++++++++");
        end else if (mem_muldiv_test) begin
            load_prog_mem_muldiv();
            $display("++++++++++++++++++++++MEMORY & MUL DIV TEST++++++++++++++++++++++");
        end else if (general_test) begin 
            load_prog_general();
            $display("++++++++++++++++++++++GENERAL TEST++++++++++++++++++++++");
        end else if (balanced_test) begin
            load_prog_balanced();
            $display("++++++++++++++++++++++GENERAL BALANCED TEST++++++++++++++++++++++");
        end else if (matmul_test) begin
            load_prog_matmul();
            $display("++++++++++++++++++++++MATRIX MULTIPLY TEST++++++++++++++++++++++");
        end else
            load_program();
        reset_dut();

        
        // perf_test (sum.elf) signals completion uisng memory-mapped stores
        if (perf_test || ilp_test || mem_muldiv_test || general_test || balanced_test || matmul_test) begin
            wait (perf_bench_done === 1'b1);
            repeat (3) @(posedge clk);
        end else begin
            if (loop_pred_test)
                wait (commit_valid === 1'b1 && commit_rd === 5'd3);
            else
                wait (commit_valid === 1'b1 && commit_rd === 5'd10);
            wait (dut.u_sb.empty);
            repeat (3) @(posedge clk);
        end
        if (perf_test) begin : perf_checks
            check(perf_bench_result === 32'd50_005_000, "sum(1..100) = 5050");
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
        end else if(ilp_test) begin 
            check(
                perf_bench_result === 32'd453521456,
                $sformatf(
                    "ILP benchmark result = %0d (got %0d)",
                    32'd453521456,
                    perf_bench_result
                )
            );
        end else if (mem_muldiv_test) begin
            check(perf_bench_result === 32'h4691FED5,
                $sformatf("MEM+MULDIV benchmark result = 0x%08h (got 0x%08h)",
                32'h4691FED5, perf_bench_result)
            );
        end else if (general_test) begin
            check(perf_bench_result === 32'hEA897FD6,
                $sformatf("GENERAL benchmark result = 0x%08h (got 0x%08h)",
                32'hEA897FD6, perf_bench_result));
        end else if (balanced_test) begin
            check(perf_bench_result === 32'hF2127ECE,
                $sformatf(
                "BALANCED benchmark result = 0x%08h (got 0x%08h)",
                32'hF2127ECE,
                perf_bench_result
                )
            );
        end else if (matmul_test) begin
            check(perf_bench_result === 32'h2C2AF01D,
                $sformatf(
                "MATMUL benchmark result = 0x%08h (got 0x%08h)",
                32'h2C2AF01D,
                perf_bench_result
            ));
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
        #2000000;
        $display("\n*** WATCHDOG TIMEOUT ***");
        $display("SUMMARY SO FAR: %0d passed, %0d failed", pass_count, fail_count);
        $finish;
    end
endmodule