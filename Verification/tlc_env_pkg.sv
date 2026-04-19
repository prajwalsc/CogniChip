// ============================================================================
// FILE       : tlc_env_pkg.sv
// PROJECT    : Cogni-V Engine TLC UVM Verification
// SPEC REF   : COGNIV-SPEC-004-MODULE ss1
// CATEGORY   : predictor[SEMI-REUSABLE], scoreboard[SEMI-REUSABLE],
//              coverage[REUSABLE], env[MODULE-SPECIFIC]
// ============================================================================
`ifndef TLC_ENV_PKG_SV
`define TLC_ENV_PKG_SV
`include "uvm_macros.svh"
`uvm_analysis_imp_decl(_observed)
`uvm_analysis_imp_decl(_predicted)
package tlc_env_pkg;
import uvm_pkg::*;
import cogniv_common_pkg::*;
import tlc_uvm_pkg::*;

//----------------------------------------------------------------------
// tlc_predictor [SEMI-REUSABLE]
// Implements Spec ss1.2/ss1.3 FSM transition table as golden model.
// Receives observed input flits, predicts expected DUT outputs.
//----------------------------------------------------------------------
class tlc_predictor extends uvm_subscriber #(tlc_transaction);
  `uvm_component_utils(tlc_predictor)
  uvm_analysis_port #(tlc_transaction) ap_predicted;
  tlc_cfg cfg;
  tlc_state_e shadow_state;
  logic [3:0] shadow_tile_id;

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    ap_predicted = new("ap_predicted", this);
    if (!uvm_config_db #(tlc_cfg)::get(this,"","cfg",cfg)) begin
      cfg = tlc_cfg::type_id::create("cfg");
    end
    shadow_state   = TLC_IDLE;
    shadow_tile_id = cfg.tile_id[3:0];
  endfunction

  // Called on every observed input transaction
  function void write(tlc_transaction txn);
    tlc_transaction pred;
    logic [127:0] pkt;
    logic [3:0]   exp_par;
    pred = tlc_transaction::type_id::create("pred_txn");
    pred.copy(txn);
    pkt = txn.to_raw_pkt();

    // Parity check (Spec ss4.4) - even parity over 4 groups of 31 bits
    exp_par[0] = ^pkt[30:0];
    exp_par[1] = ^pkt[61:31];
    exp_par[2] = ^pkt[92:62];
    exp_par[3] = ^pkt[123:93];
    if (txn.inject_parity_error || exp_par !== pkt[127:124]) begin
      pred.exp_tile_done  = 1'b0;
      pred.exp_tile_error = 1'b0;
      ap_predicted.write(pred);
      `uvm_info("PRED","Parity err: predict packet drop",UVM_MEDIUM)
      return;
    end

    // TILE_ID check (Spec ss1.4)
    if (txn.tile_id !== shadow_tile_id) begin
      pred.exp_tile_done  = 1'b0;
      pred.exp_tile_error = 1'b0;
      ap_predicted.write(pred);
      `uvm_info("PRED","TILE_ID mismatch: predict drop",UVM_MEDIUM)
      return;
    end

    // ECC 2-bit fault -> ERROR (Spec ss3.4)
    if (txn.inject_ecc_2b) begin
      shadow_state = TLC_ERROR;
      pred.exp_tile_done  = 1'b0;
      pred.exp_tile_error = 1'b1;
      ap_predicted.write(pred);
      `uvm_info("PRED","ECC 2b: predict ERROR",UVM_MEDIUM)
      return;
    end

    // FSM transitions (Spec ss1.3)
    case (shadow_state)
      TLC_IDLE: begin
        case (txn.opcode)
          4'hF: begin
            // CFG: 1-cycle, returns to IDLE (Spec ss1.3 row CFG)
            pred.exp_tile_done  = 1'b0;
            pred.exp_tile_error = 1'b0;
          end
          4'h0, 4'h1, 4'h2: begin
            // MAC_START/ACC/DRAIN: full pipe -> tile_done (Spec ss1.3)
            pred.exp_tile_done  = 1'b1;
            pred.exp_tile_error = 1'b0;
            // TOKEN_ID echoed in result flit [119:88] (Spec ss1.4)
            pred.exp_result_flit = 128'h0;
            pred.exp_result_flit[119:88] = txn.token_id;
          end
          default: begin
            pred.exp_tile_done  = 1'b0;
            pred.exp_tile_error = 1'b0;
          end
        endcase
      end
      TLC_ERROR: begin
        // Stays ERROR until RSTN_TILE
        pred.exp_tile_done  = 1'b0;
        pred.exp_tile_error = 1'b1;
      end
      default: begin
        pred.exp_tile_done  = 1'b0;
        pred.exp_tile_error = 1'b0;
      end
    endcase
    ap_predicted.write(pred);
  endfunction
endclass : tlc_predictor

//----------------------------------------------------------------------
// tlc_scoreboard [SEMI-REUSABLE]
// In-order comparison of predicted vs observed DUT outputs.
// Uses dual analysis imp (macros declared outside package).
//----------------------------------------------------------------------
class tlc_scoreboard extends uvm_scoreboard;
  `uvm_component_utils(tlc_scoreboard)
  uvm_analysis_imp_observed  #(tlc_transaction, tlc_scoreboard) ap_observed;
  uvm_analysis_imp_predicted #(tlc_transaction, tlc_scoreboard) ap_predicted;
  tlc_transaction pred_q[$];
  tlc_transaction obs_q[$];
  int unsigned pass_cnt, fail_cnt, total_cnt;

  function new(string name, uvm_component parent);
    super.new(name, parent);
    pass_cnt = 0; fail_cnt = 0; total_cnt = 0;
  endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    ap_observed  = new("ap_observed",  this);
    ap_predicted = new("ap_predicted", this);
  endfunction

  function void write_predicted(tlc_transaction t); pred_q.push_back(t); try_compare(); endfunction
  function void write_observed(tlc_transaction t);  obs_q.push_back(t);  try_compare(); endfunction

  function void try_compare();
    while (pred_q.size() > 0 && obs_q.size() > 0) begin
      compare_txn(pred_q.pop_front(), obs_q.pop_front());
    end
  endfunction

  function void compare_txn(tlc_transaction pred, tlc_transaction obs);
    bit pass = 1;
    total_cnt++;
    if (pred.exp_tile_done !== obs.exp_tile_done) begin
      `uvm_error("SB", $sformatf(
        "LOG: %0t : ERROR : tlc_scoreboard : dut.tile_done : expected_value: %0b actual_value: %0b",
        $time, pred.exp_tile_done, obs.exp_tile_done))
      pass = 0;
    end
    if (pred.exp_tile_error !== obs.exp_tile_error) begin
      `uvm_error("SB", $sformatf(
        "LOG: %0t : ERROR : tlc_scoreboard : dut.tile_error : expected_value: %0b actual_value: %0b",
        $time, pred.exp_tile_error, obs.exp_tile_error))
      pass = 0;
    end
    if (pred.exp_tile_done && obs.exp_tile_done) begin
      if (pred.exp_result_flit[119:88] !== obs.exp_result_flit[119:88]) begin
        `uvm_error("SB", $sformatf(
          "LOG: %0t : ERROR : tlc_scoreboard : dut.noc_flit_out[119:88] : expected_value: %08h actual_value: %08h",
          $time, pred.exp_result_flit[119:88], obs.exp_result_flit[119:88]))
        pass = 0;
      end
    end
    if (pass) begin
      pass_cnt++;
      `uvm_info("SB", $sformatf(
        "LOG: %0t : INFO : tlc_scoreboard : dut.tile_done : expected_value: %0b actual_value: %0b",
        $time, pred.exp_tile_done, obs.exp_tile_done), UVM_HIGH)
    end else begin
      fail_cnt++;
    end
  endfunction

  function void report_phase(uvm_phase phase);
    `uvm_info("SB", $sformatf("Scoreboard: PASS=%0d FAIL=%0d TOTAL=%0d",
              pass_cnt, fail_cnt, total_cnt), UVM_NONE)
    if (fail_cnt > 0) `uvm_error("SB","SCOREBOARD FAILURES DETECTED")
  endfunction
endclass : tlc_scoreboard

//----------------------------------------------------------------------
// tlc_coverage [REUSABLE]
// Functional covergroups for TV-001..TV-015 (Spec ss10)
//----------------------------------------------------------------------
class tlc_coverage extends uvm_subscriber #(tlc_transaction);
  `uvm_component_utils(tlc_coverage)
  tlc_transaction txn_h;

  covergroup cg_tlc_opcodes;
    cp_opcode: coverpoint txn_h.opcode {
      bins mac_start={4'h0}; bins mac_acc={4'h1};
      bins mac_drain={4'h2}; bins tile_cfg={4'hF};
    }
    cp_tile: coverpoint txn_h.tile_id { bins tiles[9]={[0:8]}; }
    cx_op_tile: cross cp_opcode, cp_tile;
  endgroup

  covergroup cg_ecc_paths;
    cp_1b: coverpoint txn_h.inject_ecc_1b { bins yes={1}; bins no={0}; }
    cp_2b: coverpoint txn_h.inject_ecc_2b { bins yes={1}; bins no={0}; }
  endgroup

  covergroup cg_fault_paths;
    cp_parity: coverpoint txn_h.inject_parity_error {
      bins injected={1}; bins clean={0};
    }
  endgroup

  covergroup cg_noc_bp;
    cp_delay: coverpoint txn_h.noc_ready_delay {
      bins zero={0}; bins one={1}; bins two={2}; bins three_p={[3:10]};
    }
  endgroup

  function new(string name, uvm_component parent);
    super.new(name, parent);
    cg_tlc_opcodes = new();
    cg_ecc_paths   = new();
    cg_fault_paths = new();
    cg_noc_bp      = new();
  endfunction

  function void write(tlc_transaction txn);
    txn_h = txn;
    cg_tlc_opcodes.sample();
    cg_ecc_paths.sample();
    cg_fault_paths.sample();
    cg_noc_bp.sample();
  endfunction
endclass : tlc_coverage

//----------------------------------------------------------------------
// cogniv_tlc_env [MODULE-SPECIFIC wiring]
// Wires agent + predictor + scoreboard + coverage.
//----------------------------------------------------------------------
class cogniv_tlc_env extends uvm_env;
  `uvm_component_utils(cogniv_tlc_env)
  tlc_agent      agent;
  tlc_predictor  predictor;
  tlc_scoreboard scoreboard;
  tlc_coverage   coverage;
  tlc_cfg        cfg;

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    if (!uvm_config_db #(tlc_cfg)::get(this,"","cfg",cfg)) begin
      cfg = tlc_cfg::type_id::create("cfg");
      uvm_config_db #(tlc_cfg)::set(this,"*","cfg",cfg);
    end
    agent      = tlc_agent::type_id::create("agent",      this);
    predictor  = tlc_predictor::type_id::create("predictor",  this);
    scoreboard = tlc_scoreboard::type_id::create("scoreboard", this);
    if (cfg.cov_enable) begin
      coverage = tlc_coverage::type_id::create("coverage", this);
    end
  endfunction

  function void connect_phase(uvm_phase phase);
    agent.ap_input.connect(predictor.analysis_export);
    if (cfg.cov_enable) agent.ap_input.connect(coverage.analysis_export);
    predictor.ap_predicted.connect(scoreboard.ap_predicted);
    agent.ap_output.connect(scoreboard.ap_observed);
  endfunction
endclass : cogniv_tlc_env

endpackage : tlc_env_pkg
`endif // TLC_ENV_PKG_SV
