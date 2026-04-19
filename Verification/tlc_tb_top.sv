// ============================================================================
// FILE       : tlc_tb_top.sv
// PROJECT    : Cogni-V Engine TLC UVM Verification
// SPEC REF   : COGNIV-SPEC-004-MODULE ss1 (tile_local_ctrl)
// CATEGORY   : [MODULE-SPECIFIC] Top-level testbench module
//
// PRE-RTL MODE (DEFAULT, stub is active):
//   - tlc_dut_stub drives all DUT output signals on the interface
//   - UVM environment runs standalone; scoreboard compares predictor vs monitor
//   - Waveforms dumped to tlc_tb_top.fst for analysis in VaporView
//
// POST-RTL MODE (enable after RTL is ready):
//   Step 1: Uncomment the DUT instantiation block labelled "POST-RTL"
//   Step 2: Comment out (or `ifdef-guard) the tlc_dut_stub instantiation
//   Step 3: Add tile_local_ctrl.sv to DEPS.yml deps list
//   No changes to tlc_uvm_pkg.sv, tlc_env_pkg.sv, or any sequence/test needed.
// ============================================================================

`ifndef TLC_TB_TOP_SV
`define TLC_TB_TOP_SV

`include "uvm_macros.svh"
`timescale 1ns/1ps

import uvm_pkg::*;
import cogniv_common_pkg::*;
import tlc_uvm_pkg::*;
import tlc_env_pkg::*;
import tlc_sequences_pkg::*;
import tlc_tests_pkg::*;

module tlc_tb_top;

  // --------------------------------------------------------------------------
  // Clock and Reset Generation
  //   CLK_TILE = 2 GHz (0.5 ns period) per Spec ss1 (TSMC N7)
  // --------------------------------------------------------------------------
  logic clk;
  logic rstn;

  // Generate 2 GHz clock: period=0.5ns, half=0.25ns
  initial begin
    clk = 1'b0;
    forever #0.25 clk = ~clk;
  end

  // Apply reset: assert for 10 cycles then deassert
  initial begin
    rstn = 1'b0;
    repeat(10) @(posedge clk);
    @(negedge clk);
    rstn = 1'b1;
    `uvm_info("TB","RSTN_TILE deasserted - TLC entering IDLE state",UVM_NONE)
  end

  // --------------------------------------------------------------------------
  // Interface instantiation
  // --------------------------------------------------------------------------
  tlc_if dut_if (.CLK_TILE(clk), .RSTN_TILE(rstn));

  // --------------------------------------------------------------------------
  // PRE-RTL MODE: DUT Stub instantiation
  //   Comment out this block when switching to POST-RTL mode.
  // --------------------------------------------------------------------------
  tlc_dut_stub #(.TILE_ID(4'h0)) u_stub (
    .CLK_TILE          (clk),
    .RSTN_TILE         (rstn),
    .noc_flit_in       (dut_if.noc_flit_in),
    .noc_flit_in_vld   (dut_if.noc_flit_in_vld),
    .noc_flit_in_rdy   (dut_if.noc_flit_in_rdy),
    .noc_flit_out      (dut_if.noc_flit_out),
    .noc_flit_out_vld  (dut_if.noc_flit_out_vld),
    .noc_flit_out_rdy  (dut_if.noc_flit_out_rdy),
    .sram_addr         (dut_if.sram_addr),
    .sram_wdata        (dut_if.sram_wdata),
    .sram_rdata        (dut_if.sram_rdata),
    .sram_we           (dut_if.sram_we),
    .sram_ecc_err_1b   (dut_if.sram_ecc_err_1b),
    .sram_ecc_err_2b   (dut_if.sram_ecc_err_2b),
    .mac_weight_data   (dut_if.mac_weight_data),
    .mac_act_data      (dut_if.mac_act_data),
    .mac_en            (dut_if.mac_en),
    .mac_drain         (dut_if.mac_drain),
    .mac_result        (dut_if.mac_result),
    .mac_result_vld    (dut_if.mac_result_vld),
    .cfg_reg           (dut_if.cfg_reg),
    .tile_done         (dut_if.tile_done),
    .tile_error        (dut_if.tile_error),
    .tlc_state         (dut_if.tlc_state)
  );

  // ==========================================================================
  // POST-RTL MODE: DUT instantiation (COMMENTED OUT — enable after RTL ready)
  // ==========================================================================
  // To switch to POST-RTL mode:
  //   1. Comment out tlc_dut_stub instantiation above
  //   2. Uncomment the tile_local_ctrl block below
  //   3. Add tile_local_ctrl.sv to deps list in DEPS.yml
  // ==========================================================================
  /*
  tile_local_ctrl #(.TILE_ID(4'h0)) u_dut (
    .CLK_TILE          (clk),
    .RSTN_TILE         (rstn),
    .noc_flit_in       (dut_if.noc_flit_in),
    .noc_flit_in_vld   (dut_if.noc_flit_in_vld),
    .noc_flit_in_rdy   (dut_if.noc_flit_in_rdy),
    .noc_flit_out      (dut_if.noc_flit_out),
    .noc_flit_out_vld  (dut_if.noc_flit_out_vld),
    .noc_flit_out_rdy  (dut_if.noc_flit_out_rdy),
    .sram_addr         (dut_if.sram_addr),
    .sram_wdata        (dut_if.sram_wdata),
    .sram_rdata        (dut_if.sram_rdata),
    .sram_we           (dut_if.sram_we),
    .sram_ecc_err_1b   (dut_if.sram_ecc_err_1b),
    .sram_ecc_err_2b   (dut_if.sram_ecc_err_2b),
    .mac_weight_data   (dut_if.mac_weight_data),
    .mac_act_data      (dut_if.mac_act_data),
    .mac_en            (dut_if.mac_en),
    .mac_drain         (dut_if.mac_drain),
    .mac_result        (dut_if.mac_result),
    .mac_result_vld    (dut_if.mac_result_vld),
    .cfg_reg           (dut_if.cfg_reg),
    .tile_done         (dut_if.tile_done),
    .tile_error        (dut_if.tile_error),
    .tlc_state         (dut_if.tlc_state)
  );
  */

  // --------------------------------------------------------------------------
  // UVM config_db registrations
  // --------------------------------------------------------------------------
  initial begin
    // Register both driver and monitor virtual interface handles
    uvm_config_db #(virtual tlc_if.drv_mp)::set(
      null, "uvm_test_top.env.agent.drv", "vif", dut_if.drv_mp);
    uvm_config_db #(virtual tlc_if.mon_mp)::set(
      null, "uvm_test_top.env.agent.mon", "vif", dut_if.mon_mp);
  end

  // --------------------------------------------------------------------------
  // Waveform dump (FST format for VaporView — Spec requirement)
  // --------------------------------------------------------------------------
  initial begin
    $dumpfile("tlc_tb_top.fst");
    $dumpvars(0);
  end

  // --------------------------------------------------------------------------
  // UVM test launch
  //   Pass +UVM_TESTNAME=<test_class_name> on the command line, e.g.:
  //     +UVM_TESTNAME=tlc_tv007_test
  //     +UVM_TESTNAME=tlc_tv010_test
  //     +UVM_TESTNAME=tlc_random_test
  // --------------------------------------------------------------------------
  initial begin
    $display("TEST START");
    run_test();
  end

  // --------------------------------------------------------------------------
  // Global timeout: prevent infinite simulations (Spec ss10 timeout note)
  // --------------------------------------------------------------------------
  initial begin
    #100000ns;
    `uvm_fatal("TIMEOUT","Simulation timeout - check for stuck FSM or missing stimulus")
    $finish;
  end

endmodule : tlc_tb_top

`endif // TLC_TB_TOP_SV
