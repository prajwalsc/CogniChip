// ============================================================================
// FILE       : tlc_tests.sv
// PROJECT    : Cogni-V Engine TLC UVM Verification
// SPEC REF   : COGNIV-SPEC-004-MODULE ss10 (TV-001, TV-007, TV-009, TV-010, TV-012)
// CATEGORY   : [MODULE-SPECIFIC] - test classes implementing specific TVs
// ============================================================================
`ifndef TLC_TESTS_SV
`define TLC_TESTS_SV
`include "uvm_macros.svh"
package tlc_tests_pkg;
import uvm_pkg::*;
import cogniv_common_pkg::*;
import tlc_uvm_pkg::*;
import tlc_env_pkg::*;
import tlc_sequences_pkg::*;

//----------------------------------------------------------------------
// tlc_base_test - Base test; all other tests extend this.
//----------------------------------------------------------------------
class tlc_base_test extends uvm_test;
  `uvm_component_utils(tlc_base_test)

  cogniv_tlc_env env;
  tlc_cfg        cfg;

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    cfg = tlc_cfg::type_id::create("cfg");
    cfg.tile_id        = 0;
    cfg.pre_rtl_mode   = 1;
    cfg.num_transactions = 10;
    cfg.cov_enable     = 1;
    uvm_config_db #(tlc_cfg)::set(this,"*","cfg",cfg);
    env = cogniv_tlc_env::type_id::create("env", this);
  endfunction

  function void start_of_simulation_phase(uvm_phase phase);
    super.start_of_simulation_phase(phase);
    `uvm_info("TEST","PRE-RTL MODE: DUT stub is active. UVM env runs standalone.",UVM_NONE)
    uvm_top.print_topology();
  endfunction

  task run_phase(uvm_phase phase);
    phase.raise_objection(this);
    `uvm_info("BASE_TEST","Run phase starting - override in child tests",UVM_MEDIUM)
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
endclass : tlc_base_test

//----------------------------------------------------------------------
// tlc_tv001_test - TV-001: CX_DISPATCH basic flit and credit check
// Spec ss4.3: credit decrements on dispatch; flit appears on NoC inject port.
//----------------------------------------------------------------------
class tlc_tv001_test extends tlc_base_test;
  `uvm_component_utils(tlc_tv001_test)
  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  task run_phase(uvm_phase phase);
    tlc_cfg_seq  cfg_seq;
    phase.raise_objection(this);
    `uvm_info("TV001","TV-001: CX_DISPATCH basic - CFG packet to tile 0",UVM_NONE)

    cfg_seq = tlc_cfg_seq::type_id::create("cfg_seq");
    cfg_seq.target_tile = 0;
    cfg_seq.cfg_op_cfg  = 16'h0001; // BF16, overwrite
    cfg_seq.start(env.agent.seqr);

    #50ns;
    `uvm_info("TV001","TV-001 complete",UVM_NONE)
    phase.drop_objection(this);
  endtask
endclass : tlc_tv001_test

//----------------------------------------------------------------------
// tlc_tv007_test - TV-007: Tile MAC BF16 single computation
// Spec ss2.2: BF16 mode; MAC_START->DRAIN; tile_done=1; TOKEN_ID echoed.
// Pass: tile_done asserted; result flit TOKEN_ID matches input TOKEN_ID.
//----------------------------------------------------------------------
class tlc_tv007_test extends tlc_base_test;
  `uvm_component_utils(tlc_tv007_test)
  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  task run_phase(uvm_phase phase);
    tlc_mac_bf16_seq bf16_seq;
    phase.raise_objection(this);
    `uvm_info("TV007","TV-007: Tile MAC BF16 single computation",UVM_NONE)

    bf16_seq = tlc_mac_bf16_seq::type_id::create("bf16_seq");
    bf16_seq.target_tile  = 0;
    bf16_seq.weight_tag   = 32'h0000_0010; // SRAM word 16
    bf16_seq.act_data_val = 32'h3F80_3F80; // two BF16 1.0 values
    bf16_seq.token_id_val = 32'hBEEF_0007;
    bf16_seq.mac_result   = 512'hDEAD_BEEF_1234_5678;
    bf16_seq.start(env.agent.seqr);

    #100ns;
    `uvm_info("TV007","TV-007 complete",UVM_NONE)
    phase.drop_objection(this);
  endtask
endclass : tlc_tv007_test

//----------------------------------------------------------------------
// tlc_tv008_test - TV-008: Tile MAC INT8 computation
// Spec ss2.3: INT8 mode; 4 weights per lane; integer arithmetic.
//----------------------------------------------------------------------
class tlc_tv008_test extends tlc_base_test;
  `uvm_component_utils(tlc_tv008_test)
  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  task run_phase(uvm_phase phase);
    tlc_mac_int8_seq int8_seq;
    phase.raise_objection(this);
    `uvm_info("TV008","TV-008: Tile MAC INT8 computation",UVM_NONE)

    int8_seq = tlc_mac_int8_seq::type_id::create("int8_seq");
    int8_seq.target_tile  = 0;
    int8_seq.token_id_val = 32'hBEEF_0008;
    int8_seq.start(env.agent.seqr);

    #100ns;
    `uvm_info("TV008","TV-008 complete",UVM_NONE)
    phase.drop_objection(this);
  endtask
endclass : tlc_tv008_test

//----------------------------------------------------------------------
// tlc_tv009_test - TV-009: SRAM ECC 1-bit error injection
// Spec ss3.4: SECDED corrects 1-bit; ecc_err_1b asserted; tile_done=1
//----------------------------------------------------------------------
class tlc_tv009_test extends tlc_base_test;
  `uvm_component_utils(tlc_tv009_test)
  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  task run_phase(uvm_phase phase);
    tlc_ecc_1bit_seq ecc1_seq;
    phase.raise_objection(this);
    `uvm_info("TV009","TV-009: SRAM ECC 1-bit error injection",UVM_NONE)

    ecc1_seq = tlc_ecc_1bit_seq::type_id::create("ecc1_seq");
    ecc1_seq.target_tile = 0;
    ecc1_seq.start(env.agent.seqr);

    #100ns;
    `uvm_info("TV009","TV-009 complete",UVM_NONE)
    phase.drop_objection(this);
  endtask
endclass : tlc_tv009_test

//----------------------------------------------------------------------
// tlc_tv010_test - TV-010: SRAM ECC 2-bit error injection
// Spec ss3.4: 2-bit uncorrectable; TLC enters ERROR; tile_error=1.
// Pass: tile_error asserted; TLC FSM in ERROR state (3'b111).
//----------------------------------------------------------------------
class tlc_tv010_test extends tlc_base_test;
  `uvm_component_utils(tlc_tv010_test)
  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  task run_phase(uvm_phase phase);
    tlc_ecc_2bit_seq ecc2_seq;
    phase.raise_objection(this);
    `uvm_info("TV010","TV-010: SRAM ECC 2-bit error (TLC ERROR state expected)",UVM_NONE)

    ecc2_seq = tlc_ecc_2bit_seq::type_id::create("ecc2_seq");
    ecc2_seq.target_tile = 0;
    ecc2_seq.start(env.agent.seqr);

    #100ns;
    `uvm_info("TV010","TV-010 complete",UVM_NONE)
    phase.drop_objection(this);
  endtask
endclass : tlc_tv010_test

//----------------------------------------------------------------------
// tlc_tv012_test - TV-012: Parity error injection
// Spec ss4.4: CLB drops packet on parity mismatch; TLC never sees flit.
// Pass: no tile_done; no tile_error; parity_err on CLB side.
//----------------------------------------------------------------------
class tlc_tv012_test extends tlc_base_test;
  `uvm_component_utils(tlc_tv012_test)
  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  task run_phase(uvm_phase phase);
    tlc_parity_err_seq par_seq;
    phase.raise_objection(this);
    `uvm_info("TV012","TV-012: Parity error injection",UVM_NONE)

    par_seq = tlc_parity_err_seq::type_id::create("par_seq");
    par_seq.target_tile = 0;
    par_seq.start(env.agent.seqr);

    #100ns;
    `uvm_info("TV012","TV-012 complete",UVM_NONE)
    phase.drop_objection(this);
  endtask
endclass : tlc_tv012_test

//----------------------------------------------------------------------
// tlc_random_test - Constrained-random all-opcode regression test
//----------------------------------------------------------------------
class tlc_random_test extends tlc_base_test;
  `uvm_component_utils(tlc_random_test)
  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  task run_phase(uvm_phase phase);
    tlc_random_seq rand_seq;
    phase.raise_objection(this);
    `uvm_info("RAND_TEST","Random regression: 50 transactions",UVM_NONE)

    rand_seq = tlc_random_seq::type_id::create("rand_seq");
    rand_seq.num_txns = 50;
    rand_seq.start(env.agent.seqr);

    #500ns;
    phase.drop_objection(this);
  endtask
endclass : tlc_random_test

endpackage : tlc_tests_pkg
`endif // TLC_TESTS_SV
