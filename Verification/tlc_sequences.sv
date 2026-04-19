// ============================================================================
// FILE       : tlc_sequences.sv
// PROJECT    : Cogni-V Engine TLC UVM Verification
// SPEC REF   : COGNIV-SPEC-004-MODULE ss1 + ss10 (TV-001, TV-007, TV-009..012)
// CATEGORY   : [REUSABLE] base and randomized sequences
//              [MODULE-SPECIFIC] directed sequences with spec-accurate values
// ============================================================================
`ifndef TLC_SEQUENCES_SV
`define TLC_SEQUENCES_SV
`include "uvm_macros.svh"
package tlc_sequences_pkg;
import uvm_pkg::*;
import cogniv_common_pkg::*;
import tlc_uvm_pkg::*;

//----------------------------------------------------------------------
// tlc_reset_seq - apply reset and wait for IDLE
//----------------------------------------------------------------------
class tlc_reset_seq extends uvm_sequence #(tlc_transaction);
  `uvm_object_utils(tlc_reset_seq)
  int unsigned post_reset_cycles = 5;
  function new(string name = "tlc_reset_seq"); super.new(name); endfunction
  task body();
    `uvm_info("SEQ_RST","Applying reset sequence",UVM_MEDIUM)
    // Reset is controlled by tb_top; wait here for interface to stabilise
    #(post_reset_cycles * 1ns);
    `uvm_info("SEQ_RST","Reset sequence done",UVM_MEDIUM)
  endtask
endclass

//----------------------------------------------------------------------
// tlc_cfg_seq - TV: tile configuration write (OPCODE=0xF)
// Spec ss1.3: CFG state transitions in 1 cycle back to IDLE.
//----------------------------------------------------------------------
class tlc_cfg_seq extends uvm_sequence #(tlc_transaction);
  `uvm_object_utils(tlc_cfg_seq)
  logic [3:0] target_tile = 0;
  logic [15:0] cfg_op_cfg = 16'h0001; // BF16, overwrite

  function new(string name = "tlc_cfg_seq"); super.new(name); endfunction

  task body();
    tlc_transaction txn;
    `uvm_create(txn)
    txn.opcode     = 4'hF;          // OP_TILE_CFG
    txn.tile_id    = target_tile;
    txn.op_cfg     = cfg_op_cfg;
    txn.weight_tag = 32'h0;
    txn.act_data   = 32'h0;
    txn.token_id   = 32'h0CF0_0001; // was 32'hCFG_0001 - 'G' is not a valid hex digit
    // CFG does not trigger tile_done
    txn.exp_tile_done  = 1'b0;
    txn.exp_tile_error = 1'b0;
    `uvm_send(txn)
    `uvm_info("SEQ_CFG", "CFG packet sent", UVM_MEDIUM)
  endtask
endclass

//----------------------------------------------------------------------
// tlc_mac_bf16_seq - TV-007: MAC_START + single-lane BF16 accumulation
// Spec ss2.2: BF16 mode; weight_A and weight_B both used per lane.
// Sends MAC_START, then MAC_DRAIN, checks tile_done and TOKEN_ID echo.
//----------------------------------------------------------------------
class tlc_mac_bf16_seq extends uvm_sequence #(tlc_transaction);
  `uvm_object_utils(tlc_mac_bf16_seq)
  logic [3:0]   target_tile   = 0;
  logic [31:0]  weight_tag    = 32'h0000_0010; // SRAM word 16
  logic [31:0]  act_data_val  = 32'h3F80_3F80; // two BF16 1.0 values
  logic [31:0]  token_id_val  = 32'hBEEF_0007;
  logic [511:0] mac_result    = 512'hDEAD;     // Stub will provide real result

  function new(string name = "tlc_mac_bf16_seq"); super.new(name); endfunction

  task body();
    tlc_transaction mac_start_txn, mac_drain_txn;

    // --- First: configure tile as BF16 overwrite mode ---
    begin
      tlc_cfg_seq cfg_seq;
      cfg_seq = tlc_cfg_seq::type_id::create("cfg_seq");
      cfg_seq.target_tile = target_tile;
      cfg_seq.cfg_op_cfg  = 16'h0001; // BF16, overwrite
      cfg_seq.start(m_sequencer);
    end

    // --- MAC_START (Spec ss1.3: IDLE->MAC_LOAD->MAC_EXEC) ---
    `uvm_create(mac_start_txn)
    mac_start_txn.opcode        = 4'h0;  // OP_MAC_START
    mac_start_txn.tile_id       = target_tile;
    mac_start_txn.weight_tag    = weight_tag;
    mac_start_txn.act_data      = act_data_val;
    mac_start_txn.token_id      = token_id_val;
    mac_start_txn.sram_rdata_val = 32'h3F80_3F80; // BF16 1.0 x2
    mac_start_txn.mac_result_val = mac_result;
    mac_start_txn.noc_ready_delay = 0;
    mac_start_txn.exp_tile_done  = 1'b0;  // no done yet on START
    mac_start_txn.exp_tile_error = 1'b0;
    `uvm_send(mac_start_txn)

    // --- MAC_DRAIN (Spec ss1.3: MAC_EXEC->MAC_DRAIN->RESULT_TX) ---
    `uvm_create(mac_drain_txn)
    mac_drain_txn.opcode        = 4'h2;  // OP_MAC_DRAIN
    mac_drain_txn.tile_id       = target_tile;
    mac_drain_txn.token_id      = token_id_val;
    mac_drain_txn.mac_result_val = mac_result;
    mac_drain_txn.noc_ready_delay = 0;
    mac_drain_txn.exp_tile_done  = 1'b1;  // tile_done expected after RESULT_TX
    mac_drain_txn.exp_tile_error = 1'b0;
    // TOKEN_ID echoed in result flit[119:88] (Spec ss1.4)
    mac_drain_txn.exp_result_flit = {8'h0, token_id_val, 88'h0};
    `uvm_send(mac_drain_txn)
    `uvm_info("SEQ_BF16","MAC BF16 sequence complete",UVM_MEDIUM)
  endtask
endclass

//----------------------------------------------------------------------
// tlc_mac_int8_seq - TV-008: INT8 precision mode MAC
// Spec ss2.3: 4 INT8 weights per lane word.
//----------------------------------------------------------------------
class tlc_mac_int8_seq extends uvm_sequence #(tlc_transaction);
  `uvm_object_utils(tlc_mac_int8_seq)
  logic [3:0]  target_tile  = 0;
  logic [31:0] token_id_val = 32'hBEEF_0008;

  function new(string name = "tlc_mac_int8_seq"); super.new(name); endfunction

  task body();
    tlc_transaction mac_txn, drain_txn;

    // Configure tile as INT8 mode first
    begin
      tlc_cfg_seq cfg_seq;
      cfg_seq = tlc_cfg_seq::type_id::create("cfg_int8");
      cfg_seq.target_tile = target_tile;
      cfg_seq.cfg_op_cfg  = 16'h0101; // INT8 [0]=1, overwrite [12]=0
      cfg_seq.start(m_sequencer);
    end

    `uvm_create(mac_txn)
    mac_txn.opcode        = 4'h0;
    mac_txn.tile_id       = target_tile;
    mac_txn.weight_tag    = 32'h0000_0020; // SRAM word 32
    mac_txn.act_data      = 32'h01_02_03_04; // 4x INT8 activations
    mac_txn.token_id      = token_id_val;
    mac_txn.sram_rdata_val = 32'h01_01_01_01; // 4x INT8 weight=1
    mac_txn.mac_result_val = 512'h10; // Expected: 4 products of 1*1..1*4 summed
    mac_txn.exp_tile_done  = 1'b0;
    mac_txn.exp_tile_error = 1'b0;
    `uvm_send(mac_txn)

    `uvm_create(drain_txn)
    drain_txn.opcode        = 4'h2;
    drain_txn.tile_id       = target_tile;
    drain_txn.token_id      = token_id_val;
    drain_txn.mac_result_val = mac_txn.mac_result_val;
    drain_txn.noc_ready_delay = 0;
    drain_txn.exp_tile_done  = 1'b1;
    drain_txn.exp_tile_error = 1'b0;
    drain_txn.exp_result_flit = {8'h0, token_id_val, 88'h0};
    `uvm_send(drain_txn)
    `uvm_info("SEQ_INT8","MAC INT8 sequence complete",UVM_MEDIUM)
  endtask
endclass

//----------------------------------------------------------------------
// tlc_ecc_1bit_seq - TV-009: ECC 1-bit error injection
// Spec ss3.4: 1-bit auto-corrected; TLC continues to MAC_EXEC; tile_done=1
//----------------------------------------------------------------------
class tlc_ecc_1bit_seq extends uvm_sequence #(tlc_transaction);
  `uvm_object_utils(tlc_ecc_1bit_seq)
  logic [3:0] target_tile  = 0;
  logic [31:0] token_id_val = 32'hECC1_0001;
  function new(string name = "tlc_ecc_1bit_seq"); super.new(name); endfunction

  task body();
    tlc_transaction txn, drain_txn;
    `uvm_create(txn)
    txn.opcode         = 4'h0;
    txn.tile_id        = target_tile;
    txn.token_id       = token_id_val;
    txn.inject_ecc_1b  = 1'b1;  // Inject 1-bit ECC error
    txn.sram_rdata_val = 32'hABCD_EF01;
    txn.mac_result_val = 512'h42;
    txn.exp_tile_done  = 1'b0;
    txn.exp_tile_error = 1'b0;
    // 1-bit ECC: corrected silently; tile still proceeds (Spec ss3.4)
    `uvm_send(txn)

    `uvm_create(drain_txn)
    drain_txn.opcode        = 4'h2;
    drain_txn.tile_id       = target_tile;
    drain_txn.token_id      = token_id_val;
    drain_txn.mac_result_val = txn.mac_result_val;
    drain_txn.exp_tile_done  = 1'b1;
    drain_txn.exp_tile_error = 1'b0;
    drain_txn.exp_result_flit = {8'h0, token_id_val, 88'h0};
    `uvm_send(drain_txn)
    `uvm_info("SEQ_ECC1B","ECC 1-bit sequence complete",UVM_MEDIUM)
  endtask
endclass

//----------------------------------------------------------------------
// tlc_ecc_2bit_seq - TV-010: ECC 2-bit error injection
// Spec ss3.4: 2-bit = uncorrectable; TLC must enter ERROR state; tile_error=1
//----------------------------------------------------------------------
class tlc_ecc_2bit_seq extends uvm_sequence #(tlc_transaction);
  `uvm_object_utils(tlc_ecc_2bit_seq)
  logic [3:0] target_tile  = 0;
  function new(string name = "tlc_ecc_2bit_seq"); super.new(name); endfunction

  task body();
    tlc_transaction txn;
    `uvm_create(txn)
    txn.opcode         = 4'h0;
    txn.tile_id        = target_tile;
    txn.token_id       = 32'hECC2_0002;
    txn.inject_ecc_2b  = 1'b1;  // Inject 2-bit ECC error
    txn.sram_rdata_val = 32'hDEAD_BEEF;
    txn.exp_tile_done  = 1'b0;
    txn.exp_tile_error = 1'b1;  // ERROR state expected
    `uvm_send(txn)
    `uvm_info("SEQ_ECC2B","ECC 2-bit sequence complete (ERROR expected)",UVM_MEDIUM)
  endtask
endclass

//----------------------------------------------------------------------
// tlc_parity_err_seq - TV-012: parity error injection
// Spec ss4.4: CLB drops packet; tile_error not asserted (handled by CLB)
// From TLC perspective: flit never arrives; TLC stays IDLE
//----------------------------------------------------------------------
class tlc_parity_err_seq extends uvm_sequence #(tlc_transaction);
  `uvm_object_utils(tlc_parity_err_seq)
  logic [3:0] target_tile = 0;
  function new(string name = "tlc_parity_err_seq"); super.new(name); endfunction

  task body();
    tlc_transaction txn;
    `uvm_create(txn)
    txn.opcode               = 4'h0;
    txn.tile_id              = target_tile;
    txn.token_id             = 32'hBAD_PA12;
    txn.inject_parity_error  = 1'b1;  // Corrupt parity
    txn.exp_tile_done        = 1'b0;
    txn.exp_tile_error       = 1'b0;  // Packet dropped; no TLC error
    `uvm_send(txn)
    `uvm_info("SEQ_PARERR","Parity error sequence done",UVM_MEDIUM)
  endtask
endclass

//----------------------------------------------------------------------
// tlc_random_seq - Constrained-random all-opcode sequence
//----------------------------------------------------------------------
class tlc_random_seq extends uvm_sequence #(tlc_transaction);
  `uvm_object_utils(tlc_random_seq)
  int unsigned num_txns = 20;
  function new(string name = "tlc_random_seq"); super.new(name); endfunction

  task body();
    tlc_transaction txn;
    for (int i = 0; i < num_txns; i++) begin
      `uvm_create(txn)
      if (!txn.randomize()) begin
        `uvm_error("SEQ_RAND","Randomize failed")
      end
      `uvm_send(txn)
    end
    `uvm_info("SEQ_RAND",$sformatf("Random seq done: %0d txns",num_txns),UVM_MEDIUM)
  endtask
endclass

endpackage : tlc_sequences_pkg
`endif // TLC_SEQUENCES_SV
