// ============================================================================
// FILE       : cogniv_env_pkg.sv
// PROJECT    : Cogni-V Engine UVM Verification Framework
// CATEGORY   : [MODULE-SPECIFIC wiring; SEMI-REUSABLE logic]
//   Full-chip cogniv_env + all agents (rv_orch, clb, noc, 9x tile).
//   Subsystem envs reuse the same agent classes with different wiring.
// ============================================================================
`ifndef COGNIV_ENV_PKG_SV
`define COGNIV_ENV_PKG_SV
`include "uvm_macros.svh"
package cogniv_env_pkg;
import uvm_pkg::*;
import cogniv_common_pkg::*;
import cogniv_txn_pkg::*;
import cogniv_adapter_pkg::*;
import cogniv_sb_cov_pkg::*;
// Import module VIPs
import tlc_uvm_pkg::*;

//=============================================================================
// cogniv_agent_cfg [REUSABLE-UNCHANGED]
// Base configuration object for all Cogni-V agents.
//=============================================================================
class cogniv_agent_cfg extends uvm_object;
  `uvm_object_utils(cogniv_agent_cfg)

  // Agent mode: 0=active (drives interface), 1=passive (monitor only)
  bit passive_mode = 0;

  // Pre-RTL: stub drives outputs; Post-RTL: DUT drives outputs
  bit pre_rtl_mode = 1;

  // Instance-specific tile ID (0..8 for tile agents; -1 for non-tile agents)
  int tile_id = -1;

  // Coverage enabled
  bit cov_enable = 1;

  // Timeout for transactions (in cycles)
  int unsigned txn_timeout_cycles = 4096;

  function new(string name = "cogniv_agent_cfg");
    super.new(name);
  endfunction
endclass : cogniv_agent_cfg

//=============================================================================
// cogniv_flit_if wrapper info (Protocol VIP — interface defined externally)
// [REUSABLE-UNCHANGED]
// The generic flit agent works with any 128-bit valid/ready interface.
// Config: use cogniv_agent_cfg with tile_id set appropriately.
//=============================================================================

//=============================================================================
// cogniv_tile_agent [SEMI-REUSABLE - parameterized by tile_id]
// Per-tile UVM agent. Reuses tlc_driver + tlc_monitor from tlc_uvm_pkg.
// Multiplied 9x in cogniv_env.
//=============================================================================
class cogniv_tile_agent extends uvm_agent;
  `uvm_component_utils(cogniv_tile_agent)

  tlc_driver    drv;
  tlc_monitor   mon;
  tlc_sequencer seqr;
  cogniv_agent_cfg cfg;

  // Per-tile analysis ports
  uvm_analysis_port #(cogniv_tile_op_txn)  ap_tile_in;
  uvm_analysis_port #(cogniv_result_txn)   ap_tile_out;

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    if (!uvm_config_db #(cogniv_agent_cfg)::get(this,"","cfg",cfg)) begin
      cfg = cogniv_agent_cfg::type_id::create("cfg");
    end
    if (!cfg.passive_mode) begin
      seqr = tlc_sequencer::type_id::create("seqr", this);
      drv  = tlc_driver::type_id::create("drv",  this);
    end
    mon = tlc_monitor::type_id::create("mon", this);
    ap_tile_in  = new("ap_tile_in",  this);
    ap_tile_out = new("ap_tile_out", this);
  endfunction

  function void connect_phase(uvm_phase phase);
    if (!cfg.passive_mode) begin
      drv.seq_item_port.connect(seqr.seq_item_export);
    end
    // Monitor analysis ports exposed at agent level via wrappers
    // The tlc_monitor uses tlc_transaction; we adapt at env level
  endfunction
endclass : cogniv_tile_agent

//=============================================================================
// cogniv_rv_orch_agent [SEMI-REUSABLE - CX ISA driver/monitor]
// Drives and monitors CX instructions on the RISC-V + CLB interface.
// In pre-RTL mode, drives CX intent transactions directly as CLB packets.
//=============================================================================
class cogniv_rv_orch_agent extends uvm_agent;
  `uvm_component_utils(cogniv_rv_orch_agent)

  cogniv_agent_cfg cfg;

  // Analysis ports
  uvm_analysis_port #(cogniv_cx_intent_txn) ap_cx_dispatch;
  uvm_analysis_port #(cogniv_cx_intent_txn) ap_cx_collect;

  // Virtual sequencer for sending CX intents
  uvm_sequencer #(cogniv_cx_intent_txn) seqr;

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    if (!uvm_config_db #(cogniv_agent_cfg)::get(this,"","cfg",cfg)) begin
      cfg = cogniv_agent_cfg::type_id::create("cfg");
    end
    seqr = uvm_sequencer #(cogniv_cx_intent_txn)::type_id::create("seqr",this);
    ap_cx_dispatch = new("ap_cx_dispatch", this);
    ap_cx_collect  = new("ap_cx_collect",  this);
    `uvm_info("RV_AGENT",
      "rv_orch_agent: In pre-RTL mode, sequences drive CX intents directly",
      UVM_MEDIUM)
  endfunction
endclass : cogniv_rv_orch_agent

//=============================================================================
// cogniv_clb_agent [SEMI-REUSABLE]
// Monitors CLB packet assembly, credit tracking, and error injection.
//=============================================================================
class cogniv_clb_agent extends uvm_agent;
  `uvm_component_utils(cogniv_clb_agent)

  cogniv_agent_cfg cfg;

  // Per-tile credit tracking (observed from interface)
  logic [2:0] credit_cnt[9];

  uvm_analysis_port #(cogniv_clb_pkt_txn) ap_clb_dispatch[9];
  uvm_sequencer #(cogniv_clb_pkt_txn)     seqr;

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    if (!uvm_config_db #(cogniv_agent_cfg)::get(this,"","cfg",cfg)) begin
      cfg = cogniv_agent_cfg::type_id::create("cfg");
    end
    seqr = uvm_sequencer #(cogniv_clb_pkt_txn)::type_id::create("seqr",this);
    for (int i = 0; i < 9; i++) begin
      ap_clb_dispatch[i] = new($sformatf("ap_clb_tile%0d",i), this);
      credit_cnt[i] = 3'd4; // Reset value (Spec ss4.3)
    end
  endfunction
endclass : cogniv_clb_agent

//=============================================================================
// cogniv_noc_agent [SEMI-REUSABLE - passive only in most contexts]
// Monitors all NoC links. In pre-RTL mode, counts hops on adapter output.
//=============================================================================
class cogniv_noc_agent extends uvm_agent;
  `uvm_component_utils(cogniv_noc_agent)

  cogniv_agent_cfg cfg;
  uvm_analysis_port #(cogniv_noc_flit_txn) ap_flit_inject;
  uvm_analysis_port #(cogniv_noc_flit_txn) ap_flit_eject;

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    if (!uvm_config_db #(cogniv_agent_cfg)::get(this,"","cfg",cfg)) begin
      cfg = cogniv_agent_cfg::type_id::create("cfg");
    end
    ap_flit_inject = new("ap_flit_inject", this);
    ap_flit_eject  = new("ap_flit_eject",  this);
  endfunction
endclass : cogniv_noc_agent

//=============================================================================
// cogniv_epc_agent [SEMI-REUSABLE]
// Drives and monitors EPC evaluation transactions.
//=============================================================================
class cogniv_epc_agent extends uvm_agent;
  `uvm_component_utils(cogniv_epc_agent)

  cogniv_agent_cfg cfg;
  uvm_analysis_port #(cogniv_epc_eval_txn) ap_epc_eval;
  uvm_sequencer #(cogniv_epc_eval_txn)     seqr;

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    if (!uvm_config_db #(cogniv_agent_cfg)::get(this,"","cfg",cfg)) begin
      cfg = cogniv_agent_cfg::type_id::create("cfg");
    end
    seqr = uvm_sequencer #(cogniv_epc_eval_txn)::type_id::create("seqr",this);
    ap_epc_eval = new("ap_epc_eval", this);
  endfunction
endclass : cogniv_epc_agent

//=============================================================================
// cogniv_vseqr [REUSABLE - virtual sequencer for full-chip coordination]
// Provides sub-sequencer handles so virtual sequences can coordinate
// across all agents without direct hierarchy access.
//=============================================================================
class cogniv_vseqr extends uvm_sequencer;
  `uvm_component_utils(cogniv_vseqr)

  // Sub-sequencer handles (set in cogniv_env connect phase)
  uvm_sequencer #(cogniv_cx_intent_txn) rv_seqr;
  uvm_sequencer #(cogniv_clb_pkt_txn)   clb_seqr;
  uvm_sequencer #(cogniv_epc_eval_txn)  epc_seqr;
  tlc_sequencer                          tile_seqr[9];  // One per tile

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction
endclass : cogniv_vseqr

//=============================================================================
// cogniv_env [MODULE-SPECIFIC wiring; SEMI-REUSABLE agent/SB/COV logic]
// Full-chip UVM environment as required by Spec ss9.1.
//=============================================================================
class cogniv_env extends uvm_env;
  `uvm_component_utils(cogniv_env)

  // Agents
  cogniv_rv_orch_agent  rv_agent;
  cogniv_clb_agent      clb_agent;
  cogniv_noc_agent      noc_agent;
  cogniv_epc_agent      epc_agent;
  cogniv_tile_agent     tile_agent[9];

  // Infrastructure
  cogniv_vseqr          vseqr;
  cogniv_system_sb      sys_sb;
  cogniv_cov_base       coverage;

  // Adapters (CX → CLB → flit → tile)
  cogniv_cx_to_clb_adapter    cx_to_clb;
  cogniv_clb_to_flit_adapter  clb_to_flit;
  cogniv_flit_to_tile_adapter flit_to_tile;
  cogniv_result_collector     result_coll;

  // Global config
  cogniv_agent_cfg cfg;

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    if (!uvm_config_db #(cogniv_agent_cfg)::get(this,"","cfg",cfg)) begin
      cfg = cogniv_agent_cfg::type_id::create("cfg");
    end

    rv_agent  = cogniv_rv_orch_agent::type_id::create("rv_agent",  this);
    clb_agent = cogniv_clb_agent::type_id::create("clb_agent", this);
    noc_agent = cogniv_noc_agent::type_id::create("noc_agent", this);
    epc_agent = cogniv_epc_agent::type_id::create("epc_agent", this);

    for (int i = 0; i < 9; i++) begin
      cogniv_agent_cfg tile_cfg;
      tile_cfg = cogniv_agent_cfg::type_id::create($sformatf("tile%0d_cfg",i));
      tile_cfg.tile_id     = i;
      tile_cfg.pre_rtl_mode = cfg.pre_rtl_mode;
      tile_cfg.cov_enable  = cfg.cov_enable;
      uvm_config_db #(cogniv_agent_cfg)::set(this,
        $sformatf("tile_agent[%0d]",i), "cfg", tile_cfg);
      tile_agent[i] = cogniv_tile_agent::type_id::create(
        $sformatf("tile_agent_%0d",i), this);
    end

    vseqr = cogniv_vseqr::type_id::create("vseqr", this);

    sys_sb = cogniv_system_sb::type_id::create("sys_sb", this);
    if (cfg.cov_enable) begin
      coverage = cogniv_cov_base::type_id::create("coverage", this);
    end

    cx_to_clb   = cogniv_cx_to_clb_adapter::type_id::create("cx_to_clb",   this);
    clb_to_flit = cogniv_clb_to_flit_adapter::type_id::create("clb_to_flit",this);
    flit_to_tile= cogniv_flit_to_tile_adapter::type_id::create("flit_to_tile",this);
    result_coll = cogniv_result_collector::type_id::create("result_coll", this);
  endfunction

  function void connect_phase(uvm_phase phase);
    // Wire virtual sequencer to agent sequencers
    vseqr.rv_seqr  = rv_agent.seqr;
    vseqr.clb_seqr = clb_agent.seqr;
    vseqr.epc_seqr = epc_agent.seqr;
    for (int i = 0; i < 9; i++) begin
      if (tile_agent[i].seqr != null) begin
        vseqr.tile_seqr[i] = tile_agent[i].seqr;
      end
    end

    // Adapter chain: CX dispatch → CLB pkt → NoC flit → tile op
    rv_agent.ap_cx_dispatch.connect(cx_to_clb.ae_cx);
    cx_to_clb.ap_clb.connect(clb_to_flit.ae_clb);
    clb_to_flit.ap_flit.connect(flit_to_tile.ae_flit);

    // System scoreboard: dispatch side
    rv_agent.ap_cx_dispatch.connect(sys_sb.ap_dispatch);

    // NoC result flit → result collector → system scoreboard
    noc_agent.ap_flit_eject.connect(result_coll.analysis_export);
    result_coll.ap_result.connect(sys_sb.ap_result);

    // Coverage connections
    if (cfg.cov_enable) begin
      rv_agent.ap_cx_dispatch.connect(coverage.ap_cx);
      noc_agent.ap_flit_inject.connect(coverage.ap_flit);
    end
  endfunction

endclass : cogniv_env

endpackage : cogniv_env_pkg
`endif // COGNIV_ENV_PKG_SV
