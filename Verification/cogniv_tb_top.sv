// ============================================================================
// FILE       : cogniv_tb_top.sv
// PROJECT    : Cogni-V Engine UVM System-Level Testbench
// CATEGORY   : [MODULE-SPECIFIC] System testbench top
//
// PRE-RTL MODE (DEFAULT - all stubs active):
//   - tlc_dut_stub is instantiated 9x (one per tile)
//   - All agents run in pre_rtl_mode=1
//   - All 9 tiles drive their interfaces via stubs
//   - Scoreboard compares predictor vs observed outputs
//   - FST waveform: cogniv_tb_top.fst
//
// POST-RTL MODE (enable after RTL is ready):
//   Step 1: Uncomment cogniv_system_dut instantiation block
//   Step 2: Comment out all 9 tlc_dut_stub instantiations
//   Step 3: Set pre_rtl_mode=0 in the cfg creation below
//   Step 4: Add cogniv_system RTL files to DEPS_system.yml
// ============================================================================
`ifndef COGNIV_TB_TOP_SV
`define COGNIV_TB_TOP_SV
`include "uvm_macros.svh"
`timescale 1ns/1ps

import uvm_pkg::*;
import cogniv_common_pkg::*;
import cogniv_txn_pkg::*;
import cogniv_adapter_pkg::*;
import cogniv_env_pkg::*;
import cogniv_sequences_pkg::*;
import cogniv_tests_pkg::*;
import tlc_uvm_pkg::*;

module cogniv_tb_top;

  //=========================================================================
  // Clock and Reset Generation
  // CLK_CORE = CLK_NOC = CLK_TILE = 2 GHz (0.5 ns period) — Spec ss1.1
  //=========================================================================
  logic clk_core;
  logic clk_noc;
  logic rstn_sync;
  logic rstn_tile[9];
  logic clk_tile[9];

  // 2 GHz core/NoC clock
  initial begin
    clk_core = 1'b0;
    forever #0.25 clk_core = ~clk_core;
  end

  // NoC clock (phase-aligned with core clock per Spec ss2.3)
  initial begin
    clk_noc = 1'b0;
    forever #0.25 clk_noc = ~clk_noc;
  end

  // Global synchronous reset: assert for 10 cycles then deassert
  initial begin
    rstn_sync = 1'b0;
    for (int i = 0; i < 9; i++) rstn_tile[i] = 1'b0;
    repeat(10) @(posedge clk_core);
    @(negedge clk_core);
    rstn_sync = 1'b1;
    for (int i = 0; i < 9; i++) rstn_tile[i] = 1'b1;
    `uvm_info("TB","System reset deasserted - all tiles entering IDLE",UVM_NONE)
  end

  // Tile clocks: in PRE-RTL mode, all enabled; EPC ICG modeling is behavioral
  for (genvar i = 0; i < 9; i++) begin : tile_clk_gen
    assign clk_tile[i] = clk_noc; // ICG model: always-on in pre-RTL
  end

  //=========================================================================
  // Per-tile interfaces (9 tiles)
  // Individual instantiations required — packed interface port arrays are
  // not portable across simulators (non-standard SV).
  //=========================================================================
  tlc_if tile_if0(.CLK_TILE(clk_tile[0]), .RSTN_TILE(rstn_tile[0]));
  tlc_if tile_if1(.CLK_TILE(clk_tile[1]), .RSTN_TILE(rstn_tile[1]));
  tlc_if tile_if2(.CLK_TILE(clk_tile[2]), .RSTN_TILE(rstn_tile[2]));
  tlc_if tile_if3(.CLK_TILE(clk_tile[3]), .RSTN_TILE(rstn_tile[3]));
  tlc_if tile_if4(.CLK_TILE(clk_tile[4]), .RSTN_TILE(rstn_tile[4]));
  tlc_if tile_if5(.CLK_TILE(clk_tile[5]), .RSTN_TILE(rstn_tile[5]));
  tlc_if tile_if6(.CLK_TILE(clk_tile[6]), .RSTN_TILE(rstn_tile[6]));
  tlc_if tile_if7(.CLK_TILE(clk_tile[7]), .RSTN_TILE(rstn_tile[7]));
  tlc_if tile_if8(.CLK_TILE(clk_tile[8]), .RSTN_TILE(rstn_tile[8]));

  //=========================================================================
  // PRE-RTL MODE: 9 DUT stubs (one per tile)
  // Explicit instantiations — required now that interface array was unrolled.
  // Comment out this block when switching to POST-RTL mode.
  //=========================================================================
  // Helper macro to reduce repetition
  `define STUB_CONN(N) \
    tlc_dut_stub #(.TILE_ID(4'(N))) u_stub_``N ( \
      .CLK_TILE         (clk_tile[N]),          \
      .RSTN_TILE        (rstn_tile[N]),          \
      .noc_flit_in      (tile_if``N.noc_flit_in),      \
      .noc_flit_in_vld  (tile_if``N.noc_flit_in_vld),  \
      .noc_flit_in_rdy  (tile_if``N.noc_flit_in_rdy),  \
      .noc_flit_out     (tile_if``N.noc_flit_out),      \
      .noc_flit_out_vld (tile_if``N.noc_flit_out_vld),  \
      .noc_flit_out_rdy (tile_if``N.noc_flit_out_rdy),  \
      .sram_addr        (tile_if``N.sram_addr),         \
      .sram_wdata       (tile_if``N.sram_wdata),        \
      .sram_rdata       (tile_if``N.sram_rdata),        \
      .sram_we          (tile_if``N.sram_we),           \
      .sram_ecc_err_1b  (tile_if``N.sram_ecc_err_1b),  \
      .sram_ecc_err_2b  (tile_if``N.sram_ecc_err_2b),  \
      .mac_weight_data  (tile_if``N.mac_weight_data),   \
      .mac_act_data     (tile_if``N.mac_act_data),      \
      .mac_en           (tile_if``N.mac_en),            \
      .mac_drain        (tile_if``N.mac_drain),         \
      .mac_result       (tile_if``N.mac_result),        \
      .mac_result_vld   (tile_if``N.mac_result_vld),    \
      .cfg_reg          (tile_if``N.cfg_reg),           \
      .tile_done        (tile_if``N.tile_done),         \
      .tile_error       (tile_if``N.tile_error),        \
      .tlc_state        (tile_if``N.tlc_state)          \
    )

  `STUB_CONN(0);
  `STUB_CONN(1);
  `STUB_CONN(2);
  `STUB_CONN(3);
  `STUB_CONN(4);
  `STUB_CONN(5);
  `STUB_CONN(6);
  `STUB_CONN(7);
  `STUB_CONN(8);

  //=========================================================================
  // POST-RTL MODE: Full system DUT (COMMENTED OUT)
  // To enable:
  //   1. Remove or guard the stub_gen block above with `ifdef PRE_RTL
  //   2. Uncomment the cogniv_system_dut block below
  //   3. Set pre_rtl_mode=0 in the UVM config
  //   4. Add RTL files to DEPS_system.yml
  //=========================================================================
  /*
  cogniv_system u_dut (
    .CLK_CORE   (clk_core),
    .CLK_NOC    (clk_noc),
    .RSTN_SYNC  (rstn_sync),
    // Per-tile interfaces via generate loop
    // .tile_if[0..8] connected here
  );
  */

  //=========================================================================
  // UVM config_db: register all 9 tile interfaces
  //=========================================================================
  // Helper macro for config_db registration (matches unrolled interface names)
  `define REG_IF(N) \
    uvm_config_db #(virtual tlc_if.drv_mp)::set( \
      null, $sformatf("uvm_test_top.env.tile_agent_%0d.drv", N), \
      "vif", tile_if``N.drv_mp); \
    uvm_config_db #(virtual tlc_if.mon_mp)::set( \
      null, $sformatf("uvm_test_top.env.tile_agent_%0d.mon", N), \
      "vif", tile_if``N.mon_mp)

  initial begin
    cogniv_agent_cfg sys_cfg;
    sys_cfg = new("sys_cfg");
    sys_cfg.pre_rtl_mode = 1;
    sys_cfg.cov_enable   = 1;
    uvm_config_db #(cogniv_agent_cfg)::set(null,"uvm_test_top.*","cfg",sys_cfg);

    `REG_IF(0);
    `REG_IF(1);
    `REG_IF(2);
    `REG_IF(3);
    `REG_IF(4);
    `REG_IF(5);
    `REG_IF(6);
    `REG_IF(7);
    `REG_IF(8);
  end

  //=========================================================================
  // Waveform dump (FST format for VaporView — Spec requirement)
  //=========================================================================
  initial begin
    $dumpfile("cogniv_tb_top.fst");
    $dumpvars(0);
  end

  //=========================================================================
  // Test launch
  //   +UVM_TESTNAME=tv001_test
  //   +UVM_TESTNAME=tv013_test    (TV-013: MoE full layer end-to-end)
  //   +UVM_TESTNAME=tv015_test    (TV-015: clock gate idle power)
  //=========================================================================
  initial begin
    $display("TEST START");
    run_test();
  end

  //=========================================================================
  // Global simulation timeout (100 µs at 2 GHz = 200 000 cycles)
  //=========================================================================
  initial begin
    #100000ns;
    `uvm_fatal("TIMEOUT",
      "Global simulation timeout - check for stuck FSM or missing stimulus")
    $finish;
  end

endmodule : cogniv_tb_top
`endif // COGNIV_TB_TOP_SV
