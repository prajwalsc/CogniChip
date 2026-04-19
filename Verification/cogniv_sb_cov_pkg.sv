// ============================================================================
// FILE       : cogniv_sb_cov_pkg.sv
// PROJECT    : Cogni-V Engine UVM Verification Framework
// CATEGORY   : [REUSABLE-UNCHANGED] Base scoreboard + base coverage classes.
//              Every module/subsystem/system scoreboard extends cogniv_sb_base.
// ============================================================================
`ifndef COGNIV_SB_COV_PKG_SV
`define COGNIV_SB_COV_PKG_SV
`include "uvm_macros.svh"
// Declare dual analysis imp outside any package (SV LRM requirement)
`uvm_analysis_imp_decl(_obs)
`uvm_analysis_imp_decl(_pred)
// Per-tile analysis imp for 9-tile scoreboard
`uvm_analysis_imp_decl(_tile0) `uvm_analysis_imp_decl(_tile1)
`uvm_analysis_imp_decl(_tile2) `uvm_analysis_imp_decl(_tile3)
`uvm_analysis_imp_decl(_tile4) `uvm_analysis_imp_decl(_tile5)
`uvm_analysis_imp_decl(_tile6) `uvm_analysis_imp_decl(_tile7)
`uvm_analysis_imp_decl(_tile8)

package cogniv_sb_cov_pkg;
import uvm_pkg::*;
import cogniv_common_pkg::*;
import cogniv_txn_pkg::*;

//=============================================================================
// cogniv_sb_base [REUSABLE-UNCHANGED]
// Parameterized base scoreboard. Extend for each DUT boundary.
// Provides: ordered pred/obs queues, pass/fail counters, log-format reporting.
//=============================================================================
class cogniv_sb_base #(type OBS_T = uvm_sequence_item,
                       type PRED_T = uvm_sequence_item)
  extends uvm_scoreboard;

  uvm_analysis_imp_obs  #(OBS_T,  cogniv_sb_base #(OBS_T, PRED_T)) ap_obs;
  uvm_analysis_imp_pred #(PRED_T, cogniv_sb_base #(OBS_T, PRED_T)) ap_pred;

  OBS_T   obs_q[$];
  PRED_T  pred_q[$];

  int unsigned pass_cnt;
  int unsigned fail_cnt;
  int unsigned total_cnt;

  // Override these in derived classes for specific field comparison
  // Returns 1 = match, 0 = mismatch
  virtual function bit compare(PRED_T pred, OBS_T obs);
    `uvm_warning("SB_BASE","cogniv_sb_base::compare() not overridden")
    return 1;
  endfunction

  function new(string name, uvm_component parent);
    super.new(name, parent);
    pass_cnt = 0; fail_cnt = 0; total_cnt = 0;
  endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    ap_obs  = new("ap_obs",  this);
    ap_pred = new("ap_pred", this);
  endfunction

  function void write_obs(OBS_T txn);
    obs_q.push_back(txn);
    drain();
  endfunction

  function void write_pred(PRED_T txn);
    pred_q.push_back(txn);
    drain();
  endfunction

  function void drain();
    while (obs_q.size() > 0 && pred_q.size() > 0) begin
      OBS_T  o = obs_q.pop_front();
      PRED_T p = pred_q.pop_front();
      total_cnt++;
      if (compare(p, o)) begin
        pass_cnt++;
      end else begin
        fail_cnt++;
        `uvm_error(get_type_name(), $sformatf(
          "LOG: %0t : ERROR : %s : comparison_failed : expected_value: <pred> actual_value: <obs>",
          $time, get_full_name()))
      end
    end
  endfunction

  function void report_phase(uvm_phase phase);
    `uvm_info(get_type_name(), $sformatf(
      "Scoreboard %s: PASS=%0d FAIL=%0d TOTAL=%0d",
      get_full_name(), pass_cnt, fail_cnt, total_cnt), UVM_NONE)
    if (fail_cnt > 0) begin
      `uvm_error(get_type_name(), "SCOREBOARD: FAILURES DETECTED")
    end
  endfunction
endclass : cogniv_sb_base

//=============================================================================
// cogniv_tile_result_sb [SEMI-REUSABLE]
// Compares tile_op_txn (predicted) against cogniv_result_txn (observed).
//=============================================================================
class cogniv_tile_result_sb
  extends cogniv_sb_base #(cogniv_result_txn, cogniv_tile_op_txn);
  `uvm_component_utils(cogniv_tile_result_sb)

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  virtual function bit compare(
    cogniv_tile_op_txn pred, cogniv_result_txn obs);
    bit pass = 1;

    // Check tile_done
    if (pred.exp_tile_done !== obs.tile_done) begin
      `uvm_error("TILE_SB", $sformatf(
        "LOG: %0t : ERROR : cogniv_tile_result_sb : tile%0d.tile_done : expected_value: %0b actual_value: %0b",
        $time, pred.tile_id, pred.exp_tile_done, obs.tile_done))
      pass = 0;
    end

    // Check tile_error
    if (pred.exp_tile_error !== obs.tile_error) begin
      `uvm_error("TILE_SB", $sformatf(
        "LOG: %0t : ERROR : cogniv_tile_result_sb : tile%0d.tile_error : expected_value: %0b actual_value: %0b",
        $time, pred.tile_id, pred.exp_tile_error, obs.tile_error))
      pass = 0;
    end

    // Check TOKEN_ID echo in result flit (Spec ss1.4)
    if (pred.exp_tile_done && obs.tile_done) begin
      if (pred.token_id !== obs.token_id) begin
        `uvm_error("TILE_SB", $sformatf(
          "LOG: %0t : ERROR : cogniv_tile_result_sb : tile%0d.token_id : expected_value: %08h actual_value: %08h",
          $time, pred.tile_id, pred.token_id, obs.token_id))
        pass = 0;
      end
    end

    if (pass) begin
      `uvm_info("TILE_SB", $sformatf(
        "LOG: %0t : INFO : cogniv_tile_result_sb : tile%0d.tile_done : expected_value: %0b actual_value: %0b",
        $time, pred.tile_id, pred.exp_tile_done, obs.tile_done), UVM_HIGH)
    end
    return pass;
  endfunction
endclass : cogniv_tile_result_sb

//=============================================================================
// cogniv_system_sb [MODULE-SPECIFIC wiring, SEMI-REUSABLE logic]
// System scoreboard: 9 per-tile analysis imps + one dispatch analysis imp.
// Checks end-to-end: CX dispatch → result collected matches expectation.
//=============================================================================
class cogniv_system_sb extends uvm_scoreboard;
  `uvm_component_utils(cogniv_system_sb)

  // Dispatch input (CX intent transactions)
  uvm_analysis_imp_obs  #(cogniv_cx_intent_txn, cogniv_system_sb) ap_dispatch;
  // Per-tile result inputs
  uvm_analysis_imp_pred #(cogniv_result_txn,    cogniv_system_sb) ap_result;

  // Pending dispatch queue (keyed by token_id)
  cogniv_cx_intent_txn dispatch_q[logic [31:0]]; // token_id → txn map
  // Received results
  cogniv_result_txn result_q[$];

  int unsigned pass_cnt;
  int unsigned fail_cnt;

  function new(string name, uvm_component parent);
    super.new(name, parent);
    pass_cnt = 0; fail_cnt = 0;
  endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    ap_dispatch = new("ap_dispatch", this);
    ap_result   = new("ap_result",   this);
  endfunction

  function void write_obs(cogniv_cx_intent_txn txn);
    logic [31:0] tok;
    tok = txn.pkt_hi[55:24]; // token_id = assembled_pkt[119:88] = pkt_hi[55:24]
                              // (was pkt_lo[119:88] — out-of-range on 64-bit field)
    dispatch_q[tok] = txn;
    `uvm_info("SYS_SB", $sformatf(
      "LOG: %0t : INFO : cogniv_system_sb : dispatch_token : expected_value: N/A actual_value: %08h",
      $time, tok), UVM_HIGH)
  endfunction

  function void write_pred(cogniv_result_txn res);
    if (dispatch_q.exists(res.token_id)) begin
      cogniv_cx_intent_txn dispatch;
      dispatch = dispatch_q[res.token_id];
      dispatch_q.delete(res.token_id);
      if (res.tile_error) begin
        `uvm_error("SYS_SB", $sformatf(
          "LOG: %0t : ERROR : cogniv_system_sb : tile%0d.tile_error : expected_value: 0 actual_value: 1",
          $time, res.tile_id))
        fail_cnt++;
      end else begin
        pass_cnt++;
        `uvm_info("SYS_SB", $sformatf(
          "LOG: %0t : INFO : cogniv_system_sb : tile%0d.result_valid : expected_value: 1 actual_value: 1",
          $time, res.tile_id), UVM_HIGH)
      end
    end else begin
      `uvm_warning("SYS_SB", $sformatf(
        "Result received for unknown token %08h", res.token_id))
    end
  endfunction

  function void check_phase(uvm_phase phase);
    if (dispatch_q.size() > 0) begin
      `uvm_error("SYS_SB", $sformatf(
        "%0d dispatches never received a result", dispatch_q.size()))
      fail_cnt += dispatch_q.size();
    end
    `uvm_info("SYS_SB", $sformatf("System SB: PASS=%0d FAIL=%0d",
              pass_cnt, fail_cnt), UVM_NONE)
  endfunction
endclass : cogniv_system_sb

//=============================================================================
// cogniv_cov_base [REUSABLE-UNCHANGED]
// Shared coverage base with all spec-mandated covergroups.
// Each level extends this and adds level-specific coverpoints.
//=============================================================================
class cogniv_cov_base extends uvm_component;
  `uvm_component_utils(cogniv_cov_base)

  // Sampled transaction handles
  cogniv_cx_intent_txn  cx_txn_h;
  cogniv_noc_flit_txn   flit_txn_h;
  cogniv_tile_op_txn    tile_txn_h;
  cogniv_epc_eval_txn   epc_txn_h;
  cogniv_clb_pkt_txn    clb_txn_h;

  // Analysis imports
  uvm_analysis_imp_obs  #(cogniv_cx_intent_txn, cogniv_cov_base) ap_cx;
  uvm_analysis_imp_pred #(cogniv_noc_flit_txn,  cogniv_cov_base) ap_flit;

  // ---- cg_cx_opcodes: all 5 CX instructions exercised ----
  covergroup cg_cx_opcodes;
    cp_opcode: coverpoint cx_txn_h.cx_opcode {
      bins cx_dispatch   = {CX_DISPATCH};
      bins cx_collect    = {CX_COLLECT};
      bins cx_gate_eval  = {CX_GATE_EVAL};
      bins cx_tile_cfg   = {CX_TILE_CFG};
      bins cx_sync       = {CX_SYNC};
    }
  endgroup

  // ---- cg_tile_targets: all 9 tiles dispatched to ----
  covergroup cg_tile_targets;
    cp_tile: coverpoint cx_txn_h.tile_mask {
      bins tile0 = {9'b000000001};
      bins tile1 = {9'b000000010};
      bins tile2 = {9'b000000100};
      bins tile3 = {9'b000001000};
      bins tile4 = {9'b000010000};
      bins tile5 = {9'b000100000};
      bins tile6 = {9'b001000000};
      bins tile7 = {9'b010000000};
      bins tile8 = {9'b100000000};
    }
  endgroup

  // ---- cg_noc_hops: 1-4 hop counts covered ----
  covergroup cg_noc_hops;
    cp_hops: coverpoint flit_txn_h.hop_count {
      bins hop1 = {1}; bins hop2 = {2};
      bins hop3 = {3}; bins hop4 = {4};
    }
  endgroup

  // ---- cg_epc_k_values: K=1 and K=2 both exercised ----
  covergroup cg_epc_k;
    cp_k: coverpoint epc_txn_h.k_cfg {
      bins k1 = {2'b01}; bins k2 = {2'b10};
    }
    cp_tie: coverpoint epc_txn_h.inject_tie { bins yes={1}; bins no={0}; }
    cp_inv_k: coverpoint epc_txn_h.inject_invalid_k { bins yes={1}; bins no={0}; }
  endgroup

  // ---- cg_tlc_states: all 7 TLC states entered ----
  covergroup cg_tlc_states;
    cp_state: coverpoint tile_txn_h.opcode {
      bins mac_start = {OP_MAC_START};
      bins mac_acc   = {OP_MAC_ACC};
      bins mac_drain = {OP_MAC_DRAIN};
      bins cfg       = {OP_TILE_CFG};
    }
    cp_precision: coverpoint tile_txn_h.precision {
      bins bf16 = {PREC_BF16}; bins int8 = {PREC_INT8};
    }
    cp_acc_mode: coverpoint tile_txn_h.acc_mode {
      bins overwrite  = {ACC_OVERWRITE};
      bins accumulate = {ACC_ACCUMULATE};
    }
    cp_ecc: coverpoint tile_txn_h.inject_ecc_2b { bins ecc2b={1}; bins clean={0}; }
    cx_prec_acc: cross cp_precision, cp_acc_mode;
  endgroup

  // ---- cg_error_paths: all error scenarios covered ----
  covergroup cg_error_paths;
    cp_parity: coverpoint clb_txn_h.inject_parity_error { bins injected={1}; bins clean={0}; }
  endgroup

  // ---- cg_batch_sizes: batch sizes 1, 8, 32, 64 ----
  covergroup cg_credit_levels;
    cp_credit: coverpoint clb_txn_h.credit_snap {
      bins full={3'd4}; bins three={3'd3}; bins two={3'd2};
      bins one={3'd1};  bins empty={3'd0};
    }
  endgroup

  function new(string name, uvm_component parent);
    super.new(name, parent);
    cg_cx_opcodes    = new();
    cg_tile_targets  = new();
    cg_noc_hops      = new();
    cg_epc_k         = new();
    cg_tlc_states    = new();
    cg_error_paths   = new();
    cg_credit_levels = new();
  endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    ap_cx   = new("ap_cx",   this);
    ap_flit = new("ap_flit", this);
  endfunction

  function void write_obs(cogniv_cx_intent_txn txn);
    cx_txn_h = txn; cg_cx_opcodes.sample(); cg_tile_targets.sample();
  endfunction

  function void write_pred(cogniv_noc_flit_txn txn);
    flit_txn_h = txn; cg_noc_hops.sample();
  endfunction
endclass : cogniv_cov_base

endpackage : cogniv_sb_cov_pkg
`endif // COGNIV_SB_COV_PKG_SV
