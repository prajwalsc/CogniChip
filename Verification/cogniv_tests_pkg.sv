// ============================================================================
// FILE       : cogniv_tests_pkg.sv
// PROJECT    : Cogni-V Engine UVM Verification Framework
// CATEGORY   : [MODULE-SPECIFIC] Test classes mapping 15 spec TVs to levels
// ============================================================================
`ifndef COGNIV_TESTS_PKG_SV
`define COGNIV_TESTS_PKG_SV
`include "uvm_macros.svh"
package cogniv_tests_pkg;
import uvm_pkg::*;
import cogniv_common_pkg::*;
import cogniv_txn_pkg::*;
import cogniv_adapter_pkg::*;
import cogniv_env_pkg::*;
import cogniv_sequences_pkg::*;

//=============================================================================
// cogniv_base_test - all tests extend this
//=============================================================================
class cogniv_base_test extends uvm_test;
  `uvm_component_utils(cogniv_base_test)
  cogniv_env      env;
  cogniv_agent_cfg cfg;

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    cfg = cogniv_agent_cfg::type_id::create("cfg");
    cfg.pre_rtl_mode = 1;
    cfg.cov_enable   = 1;
    uvm_config_db #(cogniv_agent_cfg)::set(this,"*","cfg",cfg);
    env = cogniv_env::type_id::create("env", this);
  endfunction

  function void start_of_simulation_phase(uvm_phase phase);
    super.start_of_simulation_phase(phase);
    `uvm_info("TEST","PRE-RTL MODE: DUT stubs are active",UVM_NONE)
    uvm_top.print_topology();
  endfunction

  task run_phase(uvm_phase phase);
    phase.raise_objection(this);
    `uvm_info("BASE_TEST","Base test - override in derived classes",UVM_MEDIUM)
    #100ns;
    phase.drop_objection(this);
  endtask

  function void report_phase(uvm_phase phase);
    uvm_report_server srv;
    super.report_phase(phase);
    srv = uvm_report_server::get_server();
    if (srv.get_severity_count(UVM_ERROR) == 0 &&
        srv.get_severity_count(UVM_FATAL) == 0) begin
      `uvm_info("TEST","TEST PASSED",UVM_NONE)
    end else begin
      `uvm_error("TEST","TEST FAILED")
    end
  endfunction
endclass

// ---- TV-001: cx_dispatch_basic [SUBSYSTEM] ----
class tv001_test extends cogniv_base_test;
  `uvm_component_utils(tv001_test)
  function new(string name, uvm_component parent); super.new(name, parent); endfunction
  task run_phase(uvm_phase phase);
    tv001_cx_dispatch_basic_seq seq;
    phase.raise_objection(this);
    seq = tv001_cx_dispatch_basic_seq::type_id::create("seq");
    seq.target_tile = 0;
    seq.start(env.vseqr);
    phase.drop_objection(this);
  endtask
endclass

// ---- TV-002: cx_dispatch_backpressure [SUBSYSTEM] ----
class tv002_test extends cogniv_base_test;
  `uvm_component_utils(tv002_test)
  function new(string name, uvm_component parent); super.new(name, parent); endfunction
  task run_phase(uvm_phase phase);
    tv002_cx_dispatch_backpressure_seq seq;
    phase.raise_objection(this);
    seq = tv002_cx_dispatch_backpressure_seq::type_id::create("seq");
    seq.start(env.vseqr);
    phase.drop_objection(this);
  endtask
endclass

// ---- TV-003: noc_9tile_congestion [SYSTEM] ----
class tv003_test extends cogniv_base_test;
  `uvm_component_utils(tv003_test)
  function new(string name, uvm_component parent); super.new(name, parent); endfunction
  task run_phase(uvm_phase phase);
    tv003_noc_9tile_congestion_seq seq;
    phase.raise_objection(this);
    seq = tv003_noc_9tile_congestion_seq::type_id::create("seq");
    seq.start(env.vseqr);
    phase.drop_objection(this);
  endtask
endclass

// ---- TV-004: epc_gate_eval_k1 [SUBSYSTEM] ----
class tv004_test extends cogniv_base_test;
  `uvm_component_utils(tv004_test)
  function new(string name, uvm_component parent); super.new(name, parent); endfunction
  task run_phase(uvm_phase phase);
    tv004_epc_gate_k1_seq seq;
    phase.raise_objection(this);
    seq = tv004_epc_gate_k1_seq::type_id::create("seq");
    seq.start(env.vseqr);
    phase.drop_objection(this);
  endtask
endclass

// ---- TV-005: epc_gate_eval_k2 [SUBSYSTEM] ----
class tv005_test extends cogniv_base_test;
  `uvm_component_utils(tv005_test)
  function new(string name, uvm_component parent); super.new(name, parent); endfunction
  task run_phase(uvm_phase phase);
    tv005_epc_gate_k2_seq seq;
    phase.raise_objection(this);
    seq = tv005_epc_gate_k2_seq::type_id::create("seq");
    seq.start(env.vseqr);
    phase.drop_objection(this);
  endtask
endclass

// ---- TV-006: epc_tie_break [SUBSYSTEM] ----
class tv006_test extends cogniv_base_test;
  `uvm_component_utils(tv006_test)
  function new(string name, uvm_component parent); super.new(name, parent); endfunction
  task run_phase(uvm_phase phase);
    tv006_epc_tie_break_seq seq;
    phase.raise_objection(this);
    seq = tv006_epc_tie_break_seq::type_id::create("seq");
    seq.start(env.vseqr);
    phase.drop_objection(this);
  endtask
endclass

// ---- TV-007: tile_mac_bf16_single [MODULE] ----
class tv007_test extends cogniv_base_test;
  `uvm_component_utils(tv007_test)
  function new(string name, uvm_component parent); super.new(name, parent); endfunction
  task run_phase(uvm_phase phase);
    tv007_tile_mac_bf16_seq seq;
    phase.raise_objection(this);
    seq = tv007_tile_mac_bf16_seq::type_id::create("seq");
    seq.target_tile = 0;
    seq.start(env.vseqr);
    phase.drop_objection(this);
  endtask
endclass

// ---- TV-008: tile_mac_int8_single [MODULE] ----
class tv008_test extends cogniv_base_test;
  `uvm_component_utils(tv008_test)
  function new(string name, uvm_component parent); super.new(name, parent); endfunction
  task run_phase(uvm_phase phase);
    tv008_tile_mac_int8_seq seq;
    phase.raise_objection(this);
    seq = tv008_tile_mac_int8_seq::type_id::create("seq");
    seq.start(env.vseqr);
    phase.drop_objection(this);
  endtask
endclass

// ---- TV-009: tile_sram_ecc_1bit [MODULE] ----
class tv009_test extends cogniv_base_test;
  `uvm_component_utils(tv009_test)
  function new(string name, uvm_component parent); super.new(name, parent); endfunction
  task run_phase(uvm_phase phase);
    tv009_sram_ecc_1bit_seq seq;
    phase.raise_objection(this);
    seq = tv009_sram_ecc_1bit_seq::type_id::create("seq");
    seq.start(env.vseqr);
    phase.drop_objection(this);
  endtask
endclass

// ---- TV-010: tile_sram_ecc_2bit [MODULE] ----
class tv010_test extends cogniv_base_test;
  `uvm_component_utils(tv010_test)
  function new(string name, uvm_component parent); super.new(name, parent); endfunction
  task run_phase(uvm_phase phase);
    tv010_sram_ecc_2bit_seq seq;
    phase.raise_objection(this);
    seq = tv010_sram_ecc_2bit_seq::type_id::create("seq");
    seq.start(env.vseqr);
    phase.drop_objection(this);
  endtask
endclass

// ---- TV-011: cx_collect_timeout [SUBSYSTEM] ----
class tv011_test extends cogniv_base_test;
  `uvm_component_utils(tv011_test)
  function new(string name, uvm_component parent); super.new(name, parent); endfunction
  task run_phase(uvm_phase phase);
    tv011_cx_collect_timeout_seq seq;
    phase.raise_objection(this);
    seq = tv011_cx_collect_timeout_seq::type_id::create("seq");
    seq.start(env.vseqr);
    phase.drop_objection(this);
  endtask
endclass

// ---- TV-012: cx_parity_error [SUBSYSTEM] ----
class tv012_test extends cogniv_base_test;
  `uvm_component_utils(tv012_test)
  function new(string name, uvm_component parent); super.new(name, parent); endfunction
  task run_phase(uvm_phase phase);
    tv012_cx_parity_error_seq seq;
    phase.raise_objection(this);
    seq = tv012_cx_parity_error_seq::type_id::create("seq");
    seq.start(env.vseqr);
    phase.drop_objection(this);
  endtask
endclass

// ---- TV-013: moe_full_layer [SYSTEM] ----
class tv013_test extends cogniv_base_test;
  `uvm_component_utils(tv013_test)
  function new(string name, uvm_component parent); super.new(name, parent); endfunction
  task run_phase(uvm_phase phase);
    tv013_moe_full_layer_seq seq;
    phase.raise_objection(this);
    seq = tv013_moe_full_layer_seq::type_id::create("seq");
    seq.batch_size = 7;
    seq.k_val_int  = 2;
    seq.start(env.vseqr);
    phase.drop_objection(this);
  endtask
endclass

// ---- TV-014: cx_sync_all_tiles [SYSTEM] ----
class tv014_test extends cogniv_base_test;
  `uvm_component_utils(tv014_test)
  function new(string name, uvm_component parent); super.new(name, parent); endfunction
  task run_phase(uvm_phase phase);
    tv014_cx_sync_all_seq seq;
    phase.raise_objection(this);
    seq = tv014_cx_sync_all_seq::type_id::create("seq");
    seq.start(env.vseqr);
    phase.drop_objection(this);
  endtask
endclass

// ---- TV-015: clock_gate_idle_power [SYSTEM] ----
class tv015_test extends cogniv_base_test;
  `uvm_component_utils(tv015_test)
  function new(string name, uvm_component parent); super.new(name, parent); endfunction
  task run_phase(uvm_phase phase);
    tv015_clock_gate_idle_seq seq;
    phase.raise_objection(this);
    seq = tv015_clock_gate_idle_seq::type_id::create("seq");
    seq.start(env.vseqr);
    phase.drop_objection(this);
  endtask
endclass

endpackage : cogniv_tests_pkg
`endif // COGNIV_TESTS_PKG_SV
