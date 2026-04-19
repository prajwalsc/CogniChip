// ============================================================================
// FILE       : tlc_uvm_pkg.sv
// PROJECT    : Cogni-V Engine TLC UVM Verification
// SPEC REF   : COGNIV-SPEC-004-MODULE ss1 (tile_local_ctrl)
// CATEGORY   : Combined UVM package - transaction, sequencer, driver, monitor,
//              predictor, scoreboard, coverage, agent, env
//
// PRE-RTL MODE (default):  DUT is NOT instantiated. The tlc_dut_stub module
//              drives DUT-output signals on the interface so simulation
//              can run and the scoreboard can compare against the predictor.
//
// POST-RTL MODE:  In tlc_tb_top.sv, uncomment the DUT instantiation block
//              and comment out the stub instantiation. No changes to this
//              package are required.
// ============================================================================

`ifndef TLC_UVM_PKG_SV
`define TLC_UVM_PKG_SV

`include "uvm_macros.svh"

package tlc_uvm_pkg;

import uvm_pkg::*;
import cogniv_common_pkg::*;

// ============================================================================
// REUSE CATEGORY LEGEND
//   [REUSABLE]      : Generic; reuse at subsystem/system level unchanged
//   [SEMI-REUSABLE] : Reuse with parameter/config changes
//   [MODULE-SPECIFIC]: TLC-specific logic; rewrite for other modules
// ============================================================================

// ============================================================================
// tlc_cfg - [SEMI-REUSABLE] UVM config object
// ============================================================================
class tlc_cfg extends uvm_object;
  `uvm_object_utils(tlc_cfg)

  // Tile ID under test (0..8)
  int unsigned tile_id = 0;

  // Pre-RTL mode flag:
  //   1 = stub drives DUT outputs (default, pre-RTL)
  //   0 = RTL DUT drives outputs  (post-RTL)
  bit pre_rtl_mode = 1;

  // Number of directed test transactions
  int unsigned num_transactions = 20;

  // Enable/disable coverage collection
  bit cov_enable = 1;

  function new(string name = "tlc_cfg");
    super.new(name);
  endfunction
endclass : tlc_cfg


// ============================================================================
// tlc_transaction - [REUSABLE] UVM sequence_item
// Represents one micro-op dispatch + expected TLC response.
// ============================================================================
class tlc_transaction extends uvm_sequence_item;

  `uvm_object_utils_begin(tlc_transaction)
    `uvm_field_int(opcode,              UVM_ALL_ON)
    `uvm_field_int(tile_id,             UVM_ALL_ON)
    `uvm_field_int(op_cfg,              UVM_ALL_ON)
    `uvm_field_int(weight_tag,          UVM_ALL_ON)
    `uvm_field_int(act_data,            UVM_ALL_ON)
    `uvm_field_int(token_id,            UVM_ALL_ON)
    `uvm_field_int(inject_parity_error, UVM_ALL_ON)
    `uvm_field_int(inject_ecc_1b,       UVM_ALL_ON)
    `uvm_field_int(inject_ecc_2b,       UVM_ALL_ON)
    `uvm_field_int(noc_ready_delay,     UVM_ALL_ON)
    `uvm_field_int(sram_rdata_val,      UVM_ALL_ON)
    `uvm_field_int(mac_result_val,      UVM_ALL_ON)
    `uvm_field_int(exp_tile_done,       UVM_ALL_ON)
    `uvm_field_int(exp_tile_error,      UVM_ALL_ON)
    `uvm_field_int(exp_result_flit,     UVM_ALL_ON)
  `uvm_object_utils_end

  // Packet stimulus fields (Spec ss1.4)
  rand logic [3:0]   opcode;       // OP_MAC_START/ACC/DRAIN/TILE_CFG
  rand logic [3:0]   tile_id;      // Target tile (0..8)
  rand logic [15:0]  op_cfg;       // [7:0]=layer_id, [11:8]=expert_id
  rand logic [31:0]  weight_tag;   // [15:0]=SRAM word addr
  rand logic [31:0]  act_data;     // Activation broadcast
  rand logic [31:0]  token_id;     // Echoed in result flit

  // Fault injection
  rand bit inject_parity_error;
  rand bit inject_ecc_1b;
  rand bit inject_ecc_2b;

  // NoC ready delay (cycles)
  rand int unsigned noc_ready_delay;

  // Response stimulus (driven by driver to complete TLC handshake)
  rand logic [31:0]  sram_rdata_val;
  rand logic [511:0] mac_result_val;

  // Expected outputs (set by sequences, checked by scoreboard)
  logic       exp_tile_done;
  logic       exp_tile_error;
  logic [127:0] exp_result_flit;

  // ---- Constraints ---------------------------------------------------
  constraint c_valid_opcode {
    opcode inside {4'h0, 4'h1, 4'h2, 4'hF};
  }
  constraint c_valid_tile {
    tile_id inside {[4'd0 : 4'd8]};
  }
  constraint c_sram_range {
    weight_tag[15:0] inside {[16'h0000 : 16'hFFFF]};
  }
  constraint c_no_faults_default {
    inject_parity_error == 0;
    inject_ecc_1b       == 0;
    inject_ecc_2b       == 0;
  }
  constraint c_one_ecc_max {
    !(inject_ecc_1b && inject_ecc_2b);
  }
  constraint c_noc_ready_default {
    noc_ready_delay inside {[0:3]};
  }

  // Build the 128-bit raw packet (parity auto-computed)
  function automatic logic [127:0] to_raw_pkt();
    logic [127:0] pkt;
    pkt = cogniv_common_pkg::build_micro_op_pkt(
      opcode, tile_id, op_cfg, weight_tag, act_data, token_id);
    if (inject_parity_error) begin
      pkt[124] = ~pkt[124];
    end
    return pkt;
  endfunction

  function new(string name = "tlc_transaction");
    super.new(name);
  endfunction
endclass : tlc_transaction


// ============================================================================
// tlc_sequencer - [REUSABLE]
// ============================================================================
class tlc_sequencer extends uvm_sequencer #(tlc_transaction);
  `uvm_component_utils(tlc_sequencer)
  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction
endclass : tlc_sequencer


// ============================================================================
// tlc_driver - [SEMI-REUSABLE]
// Drives micro-op packets onto the interface and responds to DUT-issued
// SRAM and MAC handshake signals.
// In PRE-RTL mode the stub already drives DUT outputs, so the driver only
// drives the DUT input side.
// ============================================================================
class tlc_driver extends uvm_driver #(tlc_transaction);
  `uvm_component_utils(tlc_driver)

  virtual tlc_if.drv_mp vif;
  tlc_cfg cfg;

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    if (!uvm_config_db #(virtual tlc_if.drv_mp)::get(
        this, "", "vif", vif)) begin
      `uvm_fatal("DRV", "Cannot get vif from config_db")
    end
    if (!uvm_config_db #(tlc_cfg)::get(this, "", "cfg", cfg)) begin
      cfg = tlc_cfg::type_id::create("cfg");
    end
  endfunction

  task run_phase(uvm_phase phase);
    tlc_transaction txn;
    // Idle the interface
    vif.drv_cb.noc_flit_in      <= 128'h0;
    vif.drv_cb.noc_flit_in_vld  <= 1'b0;
    vif.drv_cb.noc_flit_out_rdy <= 1'b1;
    vif.drv_cb.sram_rdata       <= 32'h0;
    vif.drv_cb.sram_ecc_err_1b  <= 1'b0;
    vif.drv_cb.sram_ecc_err_2b  <= 1'b0;
    vif.drv_cb.mac_result       <= 512'h0;
    vif.drv_cb.mac_result_vld   <= 1'b0;

    forever begin
      seq_item_port.get_next_item(txn);
      drive_transaction(txn);
      seq_item_port.item_done();
    end
  endtask

  // Drive one complete TLC transaction:
  //  1. Wait for TLC IDLE (noc_flit_in_rdy asserted)
  //  2. Present flit for 1 cycle
  //  3. Wait for SRAM read request; supply sram_rdata
  //  4. Wait for mac_drain; supply mac_result
  //  5. Wait for noc_flit_out_vld; assert noc_flit_out_rdy after delay
  task drive_transaction(tlc_transaction txn);
    logic [127:0] pkt;
    int timeout_cnt;

    pkt = txn.to_raw_pkt();

    // ---- Step 1: Wait for TLC ready (IDLE state) ----
    timeout_cnt = 0;
    @(vif.drv_cb);
    while (!vif.drv_cb.noc_flit_in_rdy) begin
      @(vif.drv_cb);
      if (++timeout_cnt > 1000) begin
        `uvm_error("DRV", "Timeout waiting for noc_flit_in_rdy")
        return;
      end
    end

    // ---- Step 2: Present flit ----
    vif.drv_cb.noc_flit_in     <= pkt;
    vif.drv_cb.noc_flit_in_vld <= 1'b1;
    @(vif.drv_cb);
    vif.drv_cb.noc_flit_in_vld <= 1'b0;
    vif.drv_cb.noc_flit_in     <= 128'h0;

    // CFG packets are 1-cycle; skip SRAM/MAC steps
    if (txn.opcode == 4'hF) begin
      @(vif.drv_cb);
      return;
    end

    // ---- Step 3: Supply SRAM read data (after sram_we deasserted) ----
    timeout_cnt = 0;
    @(vif.drv_cb);
    while (vif.drv_cb.sram_we === 1'b1) begin
      @(vif.drv_cb);
      if (++timeout_cnt > 500) begin
        `uvm_error("DRV", "Timeout waiting for SRAM read (sram_we=0)")
        return;
      end
    end
    // SRAM has 1-cycle latency; present rdata next cycle
    vif.drv_cb.sram_rdata      <= txn.sram_rdata_val;
    vif.drv_cb.sram_ecc_err_1b <= txn.inject_ecc_1b;
    vif.drv_cb.sram_ecc_err_2b <= txn.inject_ecc_2b;
    @(vif.drv_cb);
    vif.drv_cb.sram_ecc_err_1b <= 1'b0;
    vif.drv_cb.sram_ecc_err_2b <= 1'b0;

    // ECC 2-bit: TLC goes to ERROR — no further handshake expected
    if (txn.inject_ecc_2b) begin
      return;
    end

    // ---- Step 4: Wait for mac_drain, supply mac_result ----
    timeout_cnt = 0;
    @(vif.drv_cb);
    while (!vif.drv_cb.mac_drain) begin
      @(vif.drv_cb);
      if (++timeout_cnt > 500) begin
        `uvm_error("DRV", "Timeout waiting for mac_drain")
        return;
      end
    end
    // Result available 1 cycle after drain
    @(vif.drv_cb);
    vif.drv_cb.mac_result     <= txn.mac_result_val;
    vif.drv_cb.mac_result_vld <= 1'b1;
    @(vif.drv_cb);
    vif.drv_cb.mac_result_vld <= 1'b0;

    // ---- Step 5: Wait for result flit; apply noc_flit_out_rdy ----
    timeout_cnt = 0;
    @(vif.drv_cb);
    while (!vif.drv_cb.noc_flit_out_vld) begin
      @(vif.drv_cb);
      if (++timeout_cnt > 500) begin
        `uvm_error("DRV", "Timeout waiting for noc_flit_out_vld")
        return;
      end
    end
    // Apply backpressure delay if requested
    vif.drv_cb.noc_flit_out_rdy <= 1'b0;
    repeat(txn.noc_ready_delay) @(vif.drv_cb);
    vif.drv_cb.noc_flit_out_rdy <= 1'b1;
    @(vif.drv_cb);
    vif.drv_cb.noc_flit_out_rdy <= 1'b0;
  endtask

endclass : tlc_driver


// ============================================================================
// tlc_monitor - [REUSABLE]
// Observes all interface signals and captures both input and output
// transactions for the scoreboard and coverage collector.
// ============================================================================
class tlc_monitor extends uvm_monitor;
  `uvm_component_utils(tlc_monitor)

  virtual tlc_if.mon_mp vif;

  // Analysis ports — connect to scoreboard and coverage
  uvm_analysis_port #(tlc_transaction) ap_input;   // Observed input flits
  uvm_analysis_port #(tlc_transaction) ap_output;  // Observed result flits

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    ap_input  = new("ap_input",  this);
    ap_output = new("ap_output", this);
    if (!uvm_config_db #(virtual tlc_if.mon_mp)::get(
        this, "", "vif", vif)) begin
      `uvm_fatal("MON", "Cannot get vif from config_db")
    end
  endfunction

  task run_phase(uvm_phase phase);
    fork
      monitor_input();
      monitor_output();
    join
  endtask

  // Observe incoming flit and build a transaction
  task monitor_input();
    tlc_transaction txn;
    forever begin
      @(vif.mon_cb);
      if (vif.mon_cb.noc_flit_in_vld && vif.mon_cb.noc_flit_in_rdy) begin
        txn = tlc_transaction::type_id::create("mon_in_txn");
        // Decode packet fields from the raw flit (Spec ss1.4)
        txn.opcode     = vif.mon_cb.noc_flit_in[3:0];
        txn.tile_id    = vif.mon_cb.noc_flit_in[7:4];
        txn.op_cfg     = vif.mon_cb.noc_flit_in[23:8];
        txn.weight_tag = vif.mon_cb.noc_flit_in[55:24];
        txn.act_data   = vif.mon_cb.noc_flit_in[87:56];
        txn.token_id   = vif.mon_cb.noc_flit_in[119:88];
        // Capture ECC injection signals in same cycle
        txn.inject_ecc_1b = vif.mon_cb.sram_ecc_err_1b;
        txn.inject_ecc_2b = vif.mon_cb.sram_ecc_err_2b;
        ap_input.write(txn);
        `uvm_info("MON", $sformatf("Input flit: op=%0h tile=%0d", 
                  txn.opcode, txn.tile_id), UVM_HIGH)
      end
    end
  endtask

  // Observe outgoing result flit and tile_done/tile_error
  task monitor_output();
    tlc_transaction txn;
    forever begin
      @(vif.mon_cb);
      if (vif.mon_cb.noc_flit_out_vld && vif.mon_cb.noc_flit_out_rdy) begin
        txn = tlc_transaction::type_id::create("mon_out_txn");
        txn.exp_result_flit = vif.mon_cb.noc_flit_out;
        txn.exp_tile_done   = vif.mon_cb.tile_done;
        txn.exp_tile_error  = vif.mon_cb.tile_error;
        ap_output.write(txn);
        `uvm_info("MON", $sformatf("Result flit observed, tile_done=%0b tile_error=%0b",
                  txn.exp_tile_done, txn.exp_tile_error), UVM_HIGH)
      end
    end
  endtask

endclass : tlc_monitor


// ============================================================================
// tlc_agent - [MODULE-SPECIFIC wiring; internals REUSABLE]
// ============================================================================
class tlc_agent extends uvm_agent;
  `uvm_component_utils(tlc_agent)

  tlc_driver    drv;
  tlc_monitor   mon;
  tlc_sequencer seqr;
  tlc_cfg       cfg;

  // Expose monitor's analysis ports at agent level
  uvm_analysis_port #(tlc_transaction) ap_input;
  uvm_analysis_port #(tlc_transaction) ap_output;

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    if (!uvm_config_db #(tlc_cfg)::get(this, "", "cfg", cfg)) begin
      cfg = tlc_cfg::type_id::create("cfg");
    end
    seqr = tlc_sequencer::type_id::create("seqr", this);
    drv  = tlc_driver::type_id::create("drv",  this);
    mon  = tlc_monitor::type_id::create("mon",  this);
    ap_input  = new("ap_input",  this);
    ap_output = new("ap_output", this);
  endfunction

  function void connect_phase(uvm_phase phase);
    drv.seq_item_port.connect(seqr.seq_item_export);
    mon.ap_input.connect(ap_input);
    mon.ap_output.connect(ap_output);
  endfunction

endclass : tlc_agent

endpackage : tlc_uvm_pkg

`endif // TLC_UVM_PKG_SV
