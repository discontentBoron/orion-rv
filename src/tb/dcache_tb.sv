// -----------------------------------------------------------------------------
// tb_dcache : self-checking testbench for dcache (+ sram_1rw behavioral model).
//
// Structure (everything outside the DUT is independent of its internals):
//   dcache_tb_pkg            : init_word() / merge() helpers shared by model + TB
//   dcache_backing_model     : sparse word memory behind the cache. Serves
//                              8-beat line refills and strobed word writes,
//                              with random latency / gaps / write stalls.
//   tb_dcache
//     arbitration            : copied verbatim from orion_core (sel_sb, sb_lock_q)
//     agents                 : do_load()  = what the LSU does (request held until
//                                           ready, then wait for the response)
//                              do_store() = what the store buffer does (request
//                                           held until pop)
//     monitors / scoreboard  : PORT-LEVEL ONLY. A reference memory (`golden`)
//                              predicts every load; protocol checkers watch
//                              both interfaces.
//     directed tests + random stress, final backing-store vs golden compare.
//
// Run with USE_OPENRAM undefined. Optional plusarg: +SEED=<n>
// -----------------------------------------------------------------------------
`timescale 1ns/1ps

package dcache_tb_pkg;
  // Deterministic initial memory contents (function of the word address).
  function automatic logic [31:0] init_word(input logic [31:0] a);
    logic [31:0] x;
    x = ({a[31:2], 2'b00} ^ 32'hA5C3_1E97) * 32'h9E37_79B1;
    return x ^ (x >> 13) ^ 32'h0BAD_F00D;
  endfunction

  // Apply byte strobes: take bytes of new_w where strb is set, else old_w.
  function automatic logic [31:0] merge(input logic [31:0] old_w,
                                        input logic [31:0] new_w,
                                        input logic [3:0]  strb);
    logic [31:0] r;
    r = old_w;
    for (int i = 0; i < 4; i++)
      if (strb[i]) r[i*8 +: 8] = new_w[i*8 +: 8];
    return r;
  endfunction
endpackage

// -----------------------------------------------------------------------------
// Backing store. One channel, one op at a time, strictly in order.
//   read  (we=0): ready immediately when idle; after lat_min..lat_max cycles
//                 returns 8 beats (word 0 first), resp_last on the 8th.
//                 Beats appear >= 2 cycles after the handshake.
//   write (we=1): ready after 0..wr_stall_max extra cycles; the write is
//                 performed at the handshake. No response beat.
// -----------------------------------------------------------------------------
module dcache_backing_model
  import dcache_tb_pkg::*;
#(
  parameter int AW = 32
) (
  input  logic          clk,
  input  logic          rst_n,
  input  logic          req_valid,
  output logic          req_ready,
  input  logic          req_we,
  input  logic [AW-1:0] req_addr,
  input  logic [31:0]   req_wdata,
  input  logic [3:0]    req_wstrb,
  output logic          resp_valid,
  output logic [31:0]   resp_data,
  output logic          resp_last
);
  logic [31:0] mem [logic [29:0]];                 // sparse; absent = init_word
  int lat_min = 1, lat_max = 3, gap_pct = 0, wr_stall_max = 0;

  function automatic logic [31:0] rd(input logic [31:0] a);
    logic [29:0] k;
    k = a[31:2];
    return mem.exists(k) ? mem[k] : init_word(a);
  endfunction

  typedef enum logic [1:0] { B_IDLE, B_WAIT, B_BEATS } bs_e;
  bs_e           st;
  logic [AW-1:0] base;
  int            wait_cnt, beat;
  logic          wr_armed;
  int            wr_wait;

  assign req_ready = (st == B_IDLE) &&
                     (!(req_valid && req_we) || (wr_armed && wr_wait == 0));

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      st         <= B_IDLE;
      resp_valid <= 1'b0;
      resp_last  <= 1'b0;
      resp_data  <= '0;
      base       <= '0;
      wait_cnt   <= 0;
      beat       <= 0;
      wr_armed   <= 1'b0;
      wr_wait    <= 0;
    end else begin
      resp_valid <= 1'b0;
      resp_last  <= 1'b0;
      case (st)
        B_IDLE: begin
          if (req_valid && req_we) begin
            if (!wr_armed) begin                       // first sight: pick a stall
              wr_armed <= 1'b1;
              wr_wait  <= $urandom_range(wr_stall_max, 0);
            end else if (wr_wait == 0) begin           // handshake this cycle
              mem[req_addr[31:2]] = merge(rd(req_addr), req_wdata, req_wstrb);
              wr_armed <= 1'b0;
            end else begin
              wr_wait <= wr_wait - 1;
            end
          end else if (req_valid) begin                // read handshake this cycle
            base     <= {req_addr[AW-1:5], 5'b0};
            wait_cnt <= $urandom_range(lat_max, lat_min);
            beat     <= 0;
            st       <= B_WAIT;
          end
        end
        B_WAIT: begin
          if (wait_cnt <= 1) st <= B_BEATS;
          else               wait_cnt <= wait_cnt - 1;
        end
        B_BEATS: begin
          if (!($urandom_range(99, 0) < gap_pct)) begin
            resp_valid <= 1'b1;
            resp_data  <= rd(base + (beat << 2));
            resp_last  <= (beat == 7);
            beat       <= beat + 1;
            if (beat == 7) st <= B_IDLE;
          end
        end
        default: st <= B_IDLE;
      endcase
    end
  end
endmodule

// =============================================================================
module dcache_tb;
  import dcache_tb_pkg::*;

  // ------------------------------------------------------------ clock / bookkeeping
  logic clk   = 1'b0;
  logic rst_n = 1'b0;
  always #2.5 clk = ~clk;                          // 200 MHz

  int unsigned cyc    = 0;
  int unsigned errors = 0;
  always @(posedge clk) cyc <= cyc + 1;

  task automatic fail(input string msg);
    errors++;
    $display("[%0t] ERROR: %s", $time, msg);
    if (errors > 20) begin
      $display("FAIL: too many errors, stopping");
      $finish;
    end
  endtask

  task automatic check(input bit cond, input string msg);
    if (!cond) fail(msg);
  endtask

  // ------------------------------------------------------------ agents' wires
  logic        lsu_req_valid = 1'b0;               // "LSU" load request
  logic [31:0] lsu_req_addr  = '0;
  logic        sb_valid      = 1'b0;               // "store buffer" drain request
  logic [31:0] sb_addr       = '0;
  logic [31:0] sb_wdata      = '0;
  logic [3:0]  sb_wstrb      = '0;

  // ------------------------------------------------------------ arbitration
  // Copied from orion_core: drain wins only if it already started (lock) or
  // the LSU is not requesting. lock holds the drain stable until accepted.
  logic        sb_lock_q, sel_sb;
  logic        req_valid, req_we, req_ready;
  logic [31:0] req_addr, req_wdata;
  logic [3:0]  req_wstrb;
  logic        lsu_req_ready, sb_pop;

  assign sel_sb        = sb_valid & (sb_lock_q | ~lsu_req_valid);
  assign req_valid     = sel_sb | lsu_req_valid;
  assign req_we        = sel_sb;
  assign req_addr      = sel_sb ? sb_addr : lsu_req_addr;
  assign req_wdata     = sb_wdata;
  assign req_wstrb     = sel_sb ? sb_wstrb : 4'b0000;
  assign lsu_req_ready = req_ready & ~sel_sb;
  assign sb_pop        = req_ready &  sel_sb;

  always_ff @(posedge clk or negedge rst_n)
    if (!rst_n) sb_lock_q <= 1'b0;
    else        sb_lock_q <= sel_sb & ~req_ready;

  // ------------------------------------------------------------ DUT + backing store
  logic        resp_valid;
  logic [31:0] resp_rdata;
  logic        mem_req_valid, mem_req_ready, mem_req_we;
  logic [31:0] mem_req_addr, mem_req_wdata;
  logic [3:0]  mem_req_wstrb;
  logic        mem_resp_valid, mem_resp_last;
  logic [31:0] mem_resp_data;

  dcache dut (
    .clk(clk), .rst_n(rst_n),
    .req_valid(req_valid), .req_we(req_we), .req_addr(req_addr),
    .req_wdata(req_wdata), .req_wstrb(req_wstrb), .req_ready(req_ready),
    .resp_valid(resp_valid), .resp_rdata(resp_rdata),
    .mem_req_valid(mem_req_valid), .mem_req_ready(mem_req_ready),
    .mem_req_we(mem_req_we), .mem_req_addr(mem_req_addr),
    .mem_req_wdata(mem_req_wdata), .mem_req_wstrb(mem_req_wstrb),
    .mem_resp_valid(mem_resp_valid), .mem_resp_data(mem_resp_data),
    .mem_resp_last(mem_resp_last)
  );

  dcache_backing_model u_backing (
    .clk(clk), .rst_n(rst_n),
    .req_valid(mem_req_valid), .req_ready(mem_req_ready), .req_we(mem_req_we),
    .req_addr(mem_req_addr), .req_wdata(mem_req_wdata), .req_wstrb(mem_req_wstrb),
    .resp_valid(mem_resp_valid), .resp_data(mem_resp_data), .resp_last(mem_resp_last)
  );

  // ------------------------------------------------------------ reference model
  logic [31:0] golden [logic [29:0]];              // words written by stores
  function automatic logic [31:0] gword(input logic [31:0] a);
    logic [29:0] k;
    k = a[31:2];
    return golden.exists(k) ? golden[k] : init_word(a);
  endfunction

  // ------------------------------------------------------------ monitors (port-level)
  bit          ld_out = 1'b0;                      // a load is outstanding
  logic [31:0] ld_exp;                             // value predicted at accept time
  bit          wr_seen = 1'b0;                     // backing write seen for current store
  int unsigned loads_done = 0, stores_done = 0, refill_cnt = 0, wr_cnt = 0;

  // previous-cycle memory request, for the "held until ready" check
  bit          mpend = 1'b0;
  logic        mp_we;
  logic [31:0] mp_addr, mp_wdata;
  logic [3:0]  mp_wstrb;

  always @(posedge clk) if (rst_n) begin
    // X sanity
    if (^{req_ready, mem_req_valid} === 1'bx) fail("X on req_ready / mem_req_valid");
    if (resp_valid && (^resp_rdata === 1'bx)) fail("X on resp_rdata while resp_valid");

    // ---- load response: must match the value predicted when it was accepted
    if (resp_valid) begin
      if (!ld_out) fail("resp_valid with no load outstanding");
      else begin
        if (resp_rdata !== ld_exp)
          fail($sformatf("load data mismatch: got %h expected %h", resp_rdata, ld_exp));
        ld_out = 1'b0;
        loads_done++;
      end
    end

    // ---- load accepted: snapshot what memory should return right now
    if (req_valid && req_ready && !req_we) begin
      if (ld_out) fail("load accepted while another load is outstanding");
      ld_out = 1'b1;
      ld_exp = gword(req_addr);
    end

    // ---- backing-store write handshake: must be exactly the store presented
    if (mem_req_valid && mem_req_ready && mem_req_we) begin
      if (!(req_valid && req_we)) fail("backing write with no store presented");
      else begin
        if (mem_req_addr  !== {req_addr[31:2], 2'b00}) fail("backing write: wrong address");
        if (mem_req_wdata !== req_wdata)               fail("backing write: wrong data");
        if (mem_req_wstrb !== req_wstrb)               fail("backing write: wrong strobes");
      end
      if (wr_seen) fail("two backing writes for one store");
      wr_seen = 1'b1;
      wr_cnt++;
    end

    // ---- store completion: only after its write reached the backing store
    if (req_valid && req_ready && req_we) begin
      if (!wr_seen) fail("store req_ready before backing write was accepted");
      wr_seen = 1'b0;
      golden[req_addr[31:2]] = merge(gword(req_addr), req_wdata, req_wstrb);
      stores_done++;
    end

    // ---- refill request
    if (mem_req_valid && mem_req_ready && !mem_req_we) begin
      refill_cnt++;
      if (mem_req_addr[4:0] !== 5'd0) fail("refill address not line aligned");
    end

    // ---- backing request must be held, unchanged, until ready
    if (mpend) begin
      if (!mem_req_valid)          fail("mem_req_valid dropped before ready");
      else begin
        if (mem_req_we !== mp_we || mem_req_addr !== mp_addr)
          fail("mem request changed while waiting for ready");
        if (mp_we && (mem_req_wdata !== mp_wdata || mem_req_wstrb !== mp_wstrb))
          fail("mem write data changed while waiting for ready");
      end
    end
    mpend    = mem_req_valid && !mem_req_ready;
    mp_we    = mem_req_we;
    mp_addr  = mem_req_addr;
    mp_wdata = mem_req_wdata;
    mp_wstrb = mem_req_wstrb;
  end

  // ------------------------------------------------------------ agents
  // Mimic the LSU: hold the request until ready, then wait for the response.
  // `lat` = cycles from accept to response (2 on a hit).
  task automatic do_load(input  logic [31:0] addr,
                         output logic [31:0] data,
                         output int          lat);
    int          t;
    int unsigned c_acc;
    lsu_req_valid <= 1'b1;
    lsu_req_addr  <= addr;
    t = 0;
    forever begin
      @(posedge clk);
      if (lsu_req_ready) begin c_acc = cyc; break; end
      if (++t > 2000) begin fail("do_load: accept timeout"); c_acc = cyc; break; end
    end
    lsu_req_valid <= 1'b0;
    t = 0;
    forever begin
      @(posedge clk);
      if (resp_valid) begin data = resp_rdata; lat = int'(cyc - c_acc); break; end
      if (++t > 2000) begin fail("do_load: response timeout"); data = 'x; lat = -1; break; end
    end
  endtask

  // Mimic the store buffer: hold the drain request until it is popped.
  task automatic do_store(input logic [31:0] addr,
                          input logic [31:0] wdata,
                          input logic [3:0]  wstrb);
    int t;
    sb_valid <= 1'b1;
    sb_addr  <= {addr[31:2], 2'b00};
    sb_wdata <= wdata;
    sb_wstrb <= wstrb;
    t = 0;
    forever begin
      @(posedge clk);
      if (sb_pop) break;
      if (++t > 2000) begin fail("do_store: pop timeout"); break; end
    end
    sb_valid <= 1'b0;
  endtask

  task automatic idle(input int n);
    repeat (n) @(posedge clk);
  endtask

  // ------------------------------------------------------------ random stress helpers
  // 60%: 4 tags x 2 sets x 8 words, all tags share an index -> conflicts in a
  // 2-way cache. 40%: anywhere in 32 KB, sometimes with bit 31 set.
  function automatic logic [31:0] rand_addr();
    logic [31:0] a;
    if ($urandom_range(99, 0) < 60) begin
      a = 32'h0001_0000
        + ($urandom_range(3, 0) << 11)             // tag
        + ($urandom_range(1, 0) << 5)              // set
        + ($urandom_range(7, 0) << 2);             // word
    end else begin
      a = $urandom_range(32'h7fff, 0) & 32'hFFFF_FFFC;
      if ($urandom_range(3, 0) == 0) a[31] = 1'b1;
    end
    return a;
  endfunction

  task automatic idle_rand();
    if ($urandom_range(99, 0) < 40) idle($urandom_range(6, 1));
  endtask

  task automatic load_thread(input int n);
    logic [31:0] a, dd;
    int          lt;
    for (int i = 0; i < n; i++) begin
      a = rand_addr() | $urandom_range(3, 0);      // byte offset: cache must ignore addr[1:0]
      do_load(a, dd, lt);
      idle_rand();
    end
  endtask

  task automatic store_thread(input int n);
    logic [3:0] strb;
    for (int i = 0; i < n; i++) begin
      strb = $urandom_range(15, 1);
      do_store(rand_addr(), $urandom, strb);
      idle_rand();
    end
  endtask

  // ------------------------------------------------------------ end-of-test checks
  task automatic check_backing_vs_golden();
    int n = 0;
    foreach (golden[k]) begin
      logic [31:0] bw;
      bw = u_backing.mem.exists(k) ? u_backing.mem[k] : init_word({k, 2'b00});
      if (bw !== golden[k])
        fail($sformatf("backing store %h = %h, expected %h", {k, 2'b00}, bw, golden[k]));
      n++;
    end
    foreach (u_backing.mem[k])
      if (!golden.exists(k))
        fail($sformatf("backing store word %h written but no store targeted it", {k, 2'b00}));
    $display("    backing store matches reference model (%0d written words)", n);
  endtask

  task automatic final_sweep();                    // re-read every written word through the cache
    logic [31:0] dd;
    int          lt;
    foreach (golden[k]) do_load({k, 2'b00}, dd, lt);
  endtask

  // ------------------------------------------------------------ main sequence
  logic [31:0] d;
  int          lat;
  int unsigned r0, w0;
  int          seed;

  initial begin
    if ($value$plusargs("SEED=%d", seed)) void'($urandom(seed));    

    repeat (4) @(posedge clk);
    rst_n <= 1'b1;
    repeat (2) @(posedge clk);

    // ---- T1: cold miss, then hits; exact hit latency ---------------------------
    $display("T1: load miss / hit / hit latency");
    do_load(32'h0000_1000, d, lat);
    check(refill_cnt == 1, $sformatf("T1 expected 1 refill, got %0d", refill_cnt));
    $display("    miss latency %0d cycles (backing latency %0d..%0d)",
             lat, u_backing.lat_min, u_backing.lat_max);
    do_load(32'h0000_1004, d, lat);
    check(refill_cnt == 1, "T1 same-line load caused a refill");
    check(lat == 2, $sformatf("T1 hit latency expected 2, got %0d", lat));
    do_load(32'h0000_101C, d, lat);                // last word of the line
    check(refill_cnt == 1, "T1 last word of line caused a refill");
    do_load(32'h0000_1020, d, lat);                // next line
    check(refill_cnt == 2, "T1 next line should refill");

    // ---- T2: store hit updates the cache and writes through ---------------------
    $display("T2: store hit");
    do_load(32'h0000_2000, d, lat);                // bring the line in
    r0 = refill_cnt;  w0 = wr_cnt;
    do_store(32'h0000_2008, 32'hDEAD_BEEF, 4'hF);
    check(wr_cnt == w0 + 1,  "T2 store did not write through");
    check(refill_cnt == r0,  "T2 store hit caused a refill");
    do_load(32'h0000_2008, d, lat);
    check(d == 32'hDEAD_BEEF, $sformatf("T2 load after store got %h", d));
    check(refill_cnt == r0,  "T2 load after store hit should not refill");

    // ---- T3: store miss does not allocate ---------------------------------------
    $display("T3: store miss (no-write-allocate)");
    r0 = refill_cnt;
    do_store(32'h0000_3000, 32'h1234_5678, 4'hF);  // cold line
    check(refill_cnt == r0, "T3 store miss caused a refill (should not allocate)");
    do_load(32'h0000_3000, d, lat);
    check(refill_cnt == r0 + 1, "T3 line must NOT have been allocated by the store");
    check(d == 32'h1234_5678, $sformatf("T3 load got %h", d));

    // ---- T4: byte strobes, on a resident word and on a cold word ----------------
    $display("T4: byte strobes");
    do_load(32'h0000_2010, d, lat);                // resident
    do_store(32'h0000_2010, 32'hAABB_CCDD, 4'b0001);
    do_load (32'h0000_2010, d, lat);
    check(d == merge(init_word(32'h2010), 32'hAABB_CCDD, 4'b0001), "T4 strobe 0001");
    do_store(32'h0000_2010, 32'h1122_3344, 4'b1010);
    do_load (32'h0000_2010, d, lat);
    check(d == merge(merge(init_word(32'h2010), 32'hAABB_CCDD, 4'b0001),
                     32'h1122_3344, 4'b1010), "T4 strobe 1010");
    do_store(32'h0000_3040, 32'hFEED_FACE, 4'b0110); // cold word -> backing merges
    do_load (32'h0000_3040, d, lat);
    check(d == merge(init_word(32'h3040), 32'hFEED_FACE, 4'b0110), "T4 cold-word strobes");

    // ---- T5: 2-way associativity and LRU -----------------------------------------
    // A, B, C share set 0 (same index, different tags).
    $display("T5: associativity / LRU");
    begin
      logic [31:0] seq   [8] = '{32'h4000, 32'h4800, 32'h4000, 32'h5000,
                                 32'h4000, 32'h5000, 32'h4800, 32'h4000};
      int          delta [8] = '{1, 1, 0, 1, 0, 0, 1, 1};
      for (int i = 0; i < 8; i++) begin
        r0 = refill_cnt;
        do_load(seq[i], d, lat);
        check(refill_cnt - r0 == delta[i],
              $sformatf("T5 step %0d (addr %h): expected %0d refill(s), got %0d",
                        i, seq[i], delta[i], refill_cnt - r0));
      end
    end

    // ---- T6: store arrives while a long load refill is in flight ----------------
    $display("T6: store vs load-miss arbitration");
    u_backing.lat_min = 10;  u_backing.lat_max = 10;
    begin
      logic [31:0] d6;  int l6;
      fork
        do_load(32'h0000_6000, d6, l6);            // cold: long refill
        begin idle(3); do_store(32'h0000_6000, 32'hCAFE_F00D, 4'hF); end
      join
      check(d6 == init_word(32'h6000), "T6 load must see the pre-store value");
    end
    do_load(32'h0000_6000, d, lat);
    check(d == 32'hCAFE_F00D, $sformatf("T6 later load got %h", d));
    begin
      logic [31:0] d6;  int l6;
      fork                                          // both request in the same cycle
        do_load(32'h0000_6100, d6, l6);
        do_store(32'h0000_6104, 32'h0BAD_CAFE, 4'hF);
      join
    end
    u_backing.lat_min = 1;  u_backing.lat_max = 3;

    // ---- T7: constrained-random stress -------------------------------------------
    $display("T7: random stress (concurrent loads+stores, random latency/gaps/write stalls)");
    u_backing.lat_min = 1;  u_backing.lat_max = 8;
    u_backing.gap_pct = 25; u_backing.wr_stall_max = 4;
    fork
      load_thread (4000);
      store_thread(4000);
    join
    $display("    %0d loads, %0d stores, %0d refills, %0d backing writes",
             loads_done, stores_done, refill_cnt, wr_cnt);

    // ---- final: everything must be consistent -------------------------------------
    idle(10);
    u_backing.gap_pct = 0;  u_backing.wr_stall_max = 0;
    final_sweep();
    check_backing_vs_golden();

    if (errors == 0) $display("PASS: tb_dcache");
    else             $display("FAIL: tb_dcache, %0d error(s)", errors);
    $finish;
  end
endmodule
