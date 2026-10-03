
//
// MACRO_ID selects which OpenRAM macro is used when USE_OPENRAM is defined:
//   0 = icache_data_sram   1 = icache_tag_sram
//   2 = dcache_data_sram   3 = dcache_tag_sram
// Without USE_OPENRAM a flop-based behavioral model is used.

module sram_1rw #(
  parameter int MACRO_ID = 0,
  parameter int WIDTH    = 32,
  parameter int DEPTH    = 1024,
  parameter int WMASK_W  = 1          // 1 = no byte mask (full-word write)
) (
  input  logic                     clk,
  input  logic                     en,
  input  logic                     we,
  input  logic [WMASK_W-1:0]       wmask,   // ignored when WMASK_W == 1
  input  logic [$clog2(DEPTH)-1:0] addr,
  input  logic [WIDTH-1:0]         din,
  output logic [WIDTH-1:0]         dout
);

`ifdef USE_OPENRAM
  localparam int SIM_DELAY  = 1;
  localparam int SIM_T_HOLD = 1;   // model default
  generate
    if (MACRO_ID == 0) begin : g_icache_data
      `ifdef SYNTH_MACRO
        icache_data_sram_1rw0r0w_32_1024_freepdk45 icache_data_sram (
        .clk0  (clk),
        .csb0  (~en),
        .web0  (~we),
        .addr0 (addr),
        .din0  (din),
        .dout0 (dout)
      );
      `else
        icache_data_sram_1rw0r0w_32_1024_freepdk45 #(
        .DATA_WIDTH (WIDTH),
        .ADDR_WIDTH ($clog2(DEPTH)),
        .RAM_DEPTH  (DEPTH),
        .DELAY      (SIM_DELAY),
        .VERBOSE    (0),
        .T_HOLD     (SIM_T_HOLD)
      ) icache_data_sram (
        .clk0  (clk),
        .csb0  (~en),
        .web0  (~we),
        .addr0 (addr),
        .din0  (din),
        .dout0 (dout)
      );
      `endif
    end else if (MACRO_ID == 1) begin : g_icache_tag
      `ifdef SYNTH_MACRO
        icache_tag_sram_1rw0r0w_20_128_freepdk45 icache_tag_sram (
          .clk0  (clk),
          .csb0  (~en),
          .web0  (~we),
          .addr0 (addr),
          .din0  (din),
          .dout0 (dout)
        );
      `else
        icache_tag_sram_1rw0r0w_20_128_freepdk45 #(
        .DATA_WIDTH (WIDTH),
        .ADDR_WIDTH ($clog2(DEPTH)),
        .RAM_DEPTH  (DEPTH),
        .DELAY      (SIM_DELAY),
        .VERBOSE    (0),
        .T_HOLD     (SIM_T_HOLD)
        ) icache_tag_sram (
          .clk0  (clk),
          .csb0  (~en),
          .web0  (~we),
          .addr0 (addr),
          .din0  (din),
          .dout0 (dout)
      );
      `endif
    end else if (MACRO_ID == 2) begin : g_dcache_data
      dcache_data_sram_1rw0r0w_32_512_freepdk45 #(
        .DATA_WIDTH (WIDTH),
        .ADDR_WIDTH ($clog2(DEPTH)),
        .RAM_DEPTH  (DEPTH),
        .DELAY      (SIM_DELAY),
        .VERBOSE    (0),
        .T_HOLD     (SIM_T_HOLD)
      ) dcache_data_sram (
        .clk0  (clk),
        .csb0  (~en),
        .web0  (~we),
    .wmask0(wmask),
        .addr0 (addr),
        .din0  (din),
        .dout0 (dout)
      );
    end else begin : g_dcache_tag
      `ifdef SYNTH_MACRO
        dcache_tag_sram_1rw0r0w_21_64_freepdk45 dcache_tag_sram (
        .clk0  (clk),
        .csb0  (~en),
        .web0  (~we),
        .addr0 (addr),
        .din0  (din),
        .dout0 (dout)
      );
      `else
        dcache_tag_sram_1rw0r0w_21_64_freepdk45 #(
        .DATA_WIDTH (WIDTH),
        .ADDR_WIDTH ($clog2(DEPTH)),
        .RAM_DEPTH  (DEPTH),
        .DELAY      (SIM_DELAY),
        .VERBOSE    (0),
        .T_HOLD     (SIM_T_HOLD)
        ) dcache_tag_sram (
          .clk0  (clk),
          .csb0  (~en),
          .web0  (~we),
          .addr0 (addr),
          .din0  (din),
          .dout0 (dout)
        );
      `endif
    end
  endgenerate
`else
  localparam int G = WIDTH / WMASK_W;   // bits per mask lane
  logic [WIDTH-1:0] mem [DEPTH];
  logic [WIDTH-1:0] dout_q;

  always_ff @(posedge clk) begin
    dout_q <= 'x;                        // poison: no hold behavior
    if (en) begin
      if (we) begin
        if (WMASK_W == 1) mem[addr] <= din;
        else for (int i = 0; i < WMASK_W; i++)
          if (wmask[i]) mem[addr][i*G +: G] <= din[i*G +: G];
      end else begin
        dout_q <= mem[addr];
      end
    end
  end
  assign dout = dout_q;
`endif
endmodule