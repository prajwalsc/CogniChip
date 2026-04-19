// ============================================================================
// FILE       : cogniv_txn_pkg.sv
// PROJECT    : Cogni-V Engine UVM Verification Framework
// CATEGORY   : [REUSABLE-UNCHANGED] Full multi-level transaction hierarchy.
//              Used across module, subsystem, and system verification.
//
// TRANSACTION STACK (ordered by abstraction, high to low):
//
//   cogniv_cx_intent_txn      CX instruction intent (SW-level)
//        |
//        v (via cx_to_clb_adapter)
//   cogniv_clb_pkt_txn        128-bit CLB packet (CLB-level)
//        |
//        v (via clb_to_flit_adapter)
//   cogniv_noc_flit_txn       128-bit NoC flit (link-level)
//        |
//        v (via flit_to_tile_adapter)
//   cogniv_tile_op_txn        Tile operation (TLC semantic)
//        |
//        v (split)
//   cogniv_sram_op_txn        SRAM read/write
//   cogniv_mac_op_txn         MAC multiply-accumulate
//
// Additional:
//   cogniv_epc_eval_txn       EPC evaluation (gate_eval intent)
//   cogniv_clk_gate_txn       ICG clock gating event
//   cogniv_result_txn         Tile result collection
// ============================================================================
`ifndef COGNIV_TXN_PKG_SV
`define COGNIV_TXN_PKG_SV
`include "uvm_macros.svh"
package cogniv_txn_pkg;
import uvm_pkg::*;
import cogniv_common_pkg::*;

//=============================================================================
// LEVEL 1: CX INSTRUCTION INTENT TRANSACTION [REUSABLE-UNCHANGED]
// Models a RISC-V CX instruction before it hits the CLB.
//=============================================================================
class cogniv_cx_intent_txn extends uvm_sequence_item;
  `uvm_object_utils_begin(cogniv_cx_intent_txn)
    `uvm_field_enum(cx_opcode_e, cx_opcode,    UVM_ALL_ON)
    `uvm_field_int(tile_mask,                   UVM_ALL_ON)
    `uvm_field_int(pkt_hi,                      UVM_ALL_ON)
    `uvm_field_int(pkt_lo,                      UVM_ALL_ON)
    `uvm_field_int(gate_base,                   UVM_ALL_ON)
    `uvm_field_int(k_val,                       UVM_ALL_ON)
    `uvm_field_int(timeout_cycles,              UVM_ALL_ON)
    `uvm_field_int(cfg_word,                    UVM_ALL_ON)
    `uvm_field_int(inject_credit_stall,         UVM_ALL_ON)
  `uvm_object_utils_end

  rand cx_opcode_e cx_opcode;          // Which CX instruction
  rand logic [8:0]  tile_mask;         // Tile selection (for CX_DISPATCH: 1-hot; CX_SYNC: multi-hot)
  rand logic [63:0] pkt_hi;            // Upper 64 bits of micro-op (CX_DISPATCH)
  rand logic [63:0] pkt_lo;            // Lower 64 bits of micro-op (CX_DISPATCH)
  rand logic [63:0] gate_base;         // Gating logit base address (CX_GATE_EVAL)
  rand logic [1:0]  k_val;             // K value (CX_GATE_EVAL): 2'b01=K1, 2'b10=K2
  rand logic [15:0] timeout_cycles;   // CX_COLLECT timeout (0=infinite)
  rand logic [31:0] cfg_word;          // Config payload (CX_TILE_CFG)
  rand bit          inject_credit_stall; // Force credit-stall scenario

  // Derived: extract tile_id from one-hot mask
  function automatic logic [3:0] get_tile_id();
    for (int i = 0; i < 9; i++) begin
      if (tile_mask[i]) return logic'(i);
    end
    return 4'hF;
  endfunction

  constraint c_valid_k { k_val inside {2'b01, 2'b10}; }
  constraint c_no_stall_default { inject_credit_stall == 0; }
  constraint c_valid_tile_mask {
    (cx_opcode == CX_DISPATCH || cx_opcode == CX_TILE_CFG) ->
      ($countones(tile_mask) == 1 && tile_mask[8:0] inside {9'b000000001, 9'b000000010,
       9'b000000100, 9'b000001000, 9'b000010000, 9'b000100000, 9'b001000000,
       9'b010000000, 9'b100000000});
  }

  function new(string name = "cogniv_cx_intent_txn");
    super.new(name);
  endfunction
endclass : cogniv_cx_intent_txn

//=============================================================================
// LEVEL 2: CLB PACKET TRANSACTION [REUSABLE-UNCHANGED]
// 128-bit assembled packet at the CLB boundary.
//=============================================================================
class cogniv_clb_pkt_txn extends uvm_sequence_item;
  `uvm_object_utils_begin(cogniv_clb_pkt_txn)
    `uvm_field_int(raw_pkt,             UVM_ALL_ON)
    `uvm_field_int(tile_id,             UVM_ALL_ON)
    `uvm_field_int(inject_parity_error, UVM_ALL_ON)
    `uvm_field_int(credit_snap,         UVM_ALL_ON)
    `uvm_field_int(exp_credit_after,    UVM_ALL_ON)
    `uvm_field_int(exp_stall,           UVM_ALL_ON)
    `uvm_field_int(exp_overflow,        UVM_ALL_ON)
    `uvm_field_int(exp_parity_err,      UVM_ALL_ON)
  `uvm_object_utils_end

  rand logic [127:0] raw_pkt;            // Full assembled 128-bit packet
  rand logic [3:0]   tile_id;            // Target tile (redundant with pkt; for quick access)
  rand bit           inject_parity_error;// TV-012

  // Credit state tracking
  logic [2:0] credit_snap;       // Credit count at time of dispatch
  logic [2:0] exp_credit_after;  // Expected credit after dispatch
  logic       exp_stall;         // Expected stall signal
  logic       exp_overflow;      // Expected overflow
  logic       exp_parity_err;    // Expected parity error

  // Decode helpers
  function automatic micro_op_pkt_t decoded();
    return cogniv_common_pkg::decode_micro_op_pkt(raw_pkt);
  endfunction

  function automatic bit parity_ok();
    return cogniv_common_pkg::check_pkt_parity(raw_pkt);
  endfunction

  constraint c_valid_tile { tile_id inside {[4'd0:4'd8]}; }
  constraint c_no_parity_default { inject_parity_error == 0; }

  function new(string name = "cogniv_clb_pkt_txn");
    super.new(name);
  endfunction
endclass : cogniv_clb_pkt_txn

//=============================================================================
// LEVEL 3: NOC FLIT TRANSACTION [REUSABLE-UNCHANGED]
// 128-bit link-level flit as seen on a NoC router port.
//=============================================================================
class cogniv_noc_flit_txn extends uvm_sequence_item;
  `uvm_object_utils_begin(cogniv_noc_flit_txn)
    `uvm_field_int(flit_data,   UVM_ALL_ON)
    `uvm_field_int(src_tile_id, UVM_ALL_ON)
    `uvm_field_int(dst_tile_id, UVM_ALL_ON)
    `uvm_field_int(vc_id,       UVM_ALL_ON)
    `uvm_field_int(hop_count,   UVM_ALL_ON)
    `uvm_field_int(is_ack,      UVM_ALL_ON)
  `uvm_object_utils_end

  rand logic [127:0] flit_data;    // Raw 128-bit flit payload
  rand logic [3:0]   src_tile_id;  // Source tile (0..8; CLB = 4'hF)
  rand logic [3:0]   dst_tile_id;  // Destination tile (0..8)
  rand logic [1:0]   vc_id;        // VC0=data, VC1=ACK
  int unsigned       hop_count;    // Actual hop count taken (observed)
  bit                is_ack;       // True if this is an ACK flit (VC1)

  // XY routing: compute expected hop count from src to dst
  function automatic int unsigned expected_hops();
    return cogniv_common_pkg::tile_hop_count(src_tile_id, dst_tile_id);
  endfunction

  constraint c_valid_dst { dst_tile_id inside {[4'd0:4'd8]}; }
  constraint c_valid_vc  { vc_id inside {2'b00, 2'b01}; }

  function new(string name = "cogniv_noc_flit_txn");
    super.new(name);
  endfunction
endclass : cogniv_noc_flit_txn

//=============================================================================
// LEVEL 4: TILE OPERATION TRANSACTION [SEMI-REUSABLE - config driven]
// Represents a complete semantic MAC operation on a tile.
//=============================================================================
class cogniv_tile_op_txn extends uvm_sequence_item;
  `uvm_object_utils_begin(cogniv_tile_op_txn)
    `uvm_field_int(tile_id,         UVM_ALL_ON)
    `uvm_field_int(token_id,        UVM_ALL_ON)
    `uvm_field_int(weight_tag,      UVM_ALL_ON)
    `uvm_field_int(act_data,        UVM_ALL_ON)
    `uvm_field_enum(tlc_opcode_e, opcode, UVM_ALL_ON)
    `uvm_field_enum(precision_e,  precision, UVM_ALL_ON)
    `uvm_field_enum(acc_mode_e,   acc_mode,  UVM_ALL_ON)
    `uvm_field_int(inject_ecc_1b,   UVM_ALL_ON)
    `uvm_field_int(inject_ecc_2b,   UVM_ALL_ON)
    `uvm_field_int(noc_rdy_delay,   UVM_ALL_ON)
    // Response stimulus
    `uvm_field_int(sram_rdata_val,  UVM_ALL_ON)
    `uvm_field_int(mac_result_val,  UVM_ALL_ON)
    // Expected outputs
    `uvm_field_int(exp_tile_done,   UVM_ALL_ON)
    `uvm_field_int(exp_tile_error,  UVM_ALL_ON)
    `uvm_field_int(exp_result_flit, UVM_ALL_ON)
  `uvm_object_utils_end

  rand logic [3:0]   tile_id;
  rand logic [31:0]  token_id;
  rand logic [31:0]  weight_tag;
  rand logic [31:0]  act_data;
  rand tlc_opcode_e  opcode;
  rand precision_e   precision;
  rand acc_mode_e    acc_mode;
  rand bit           inject_ecc_1b;
  rand bit           inject_ecc_2b;
  rand int unsigned  noc_rdy_delay;
  // Response stimulus for pre-RTL
  rand logic [31:0]  sram_rdata_val;
  rand logic [511:0] mac_result_val;
  // Expected
  logic       exp_tile_done;
  logic       exp_tile_error;
  logic [127:0] exp_result_flit;

  constraint c_valid_tile { tile_id inside {[4'd0:4'd8]}; }
  constraint c_valid_opcode { opcode inside {OP_MAC_START, OP_MAC_ACC, OP_MAC_DRAIN, OP_TILE_CFG}; }
  constraint c_one_ecc_max { !(inject_ecc_1b && inject_ecc_2b); }
  constraint c_no_ecc_default { inject_ecc_1b == 0; inject_ecc_2b == 0; }
  constraint c_noc_delay { noc_rdy_delay inside {[0:3]}; }

  // Upgrade from CLB packet transaction
  function automatic void from_clb_pkt(cogniv_clb_pkt_txn pkt_txn);
    micro_op_pkt_t p;
    p = cogniv_common_pkg::decode_micro_op_pkt(pkt_txn.raw_pkt);
    tile_id    = p.tile_id;
    token_id   = p.token_id;
    weight_tag = p.weight_tag;
    act_data   = p.act_data;
    opcode     = tlc_opcode_e'(p.opcode);
    precision  = PREC_BF16;
    acc_mode   = ACC_OVERWRITE;
  endfunction

  // Downgrade to CLB packet transaction
  function automatic cogniv_clb_pkt_txn to_clb_pkt();
    cogniv_clb_pkt_txn pkt_txn;
    pkt_txn = cogniv_clb_pkt_txn::type_id::create("from_tile_op");
    pkt_txn.tile_id  = tile_id;
    pkt_txn.raw_pkt  = cogniv_common_pkg::build_micro_op_pkt(
      opcode, tile_id, {precision, 4'h0, acc_mode[0], 8'h0},
      weight_tag, act_data, token_id);
    return pkt_txn;
  endfunction

  function new(string name = "cogniv_tile_op_txn");
    super.new(name);
  endfunction
endclass : cogniv_tile_op_txn

//=============================================================================
// LEVEL 5a: SRAM OPERATION TRANSACTION [REUSABLE-UNCHANGED]
//=============================================================================
class cogniv_sram_op_txn extends uvm_sequence_item;
  `uvm_object_utils_begin(cogniv_sram_op_txn)
    `uvm_field_int(addr,      UVM_ALL_ON)
    `uvm_field_int(wdata,     UVM_ALL_ON)
    `uvm_field_int(rdata,     UVM_ALL_ON)
    `uvm_field_int(we,        UVM_ALL_ON)
    `uvm_field_enum(ecc_err_e, ecc_type, UVM_ALL_ON)
  `uvm_object_utils_end

  rand logic [15:0] addr;
  rand logic [31:0] wdata;
  logic [31:0]      rdata;      // Response; set by driver/monitor
  rand logic        we;
  rand ecc_err_e    ecc_type;   // Fault injection type

  constraint c_no_ecc_default { ecc_type == ECC_NONE; }
  constraint c_one_ecc { !(ecc_type == ECC_1BIT && ecc_type == ECC_2BIT); }

  function new(string name = "cogniv_sram_op_txn");
    super.new(name);
  endfunction
endclass : cogniv_sram_op_txn

//=============================================================================
// LEVEL 5b: MAC OPERATION TRANSACTION [REUSABLE-UNCHANGED]
//=============================================================================
class cogniv_mac_op_txn extends uvm_sequence_item;
  `uvm_object_utils_begin(cogniv_mac_op_txn)
    `uvm_field_int(weight_bus,     UVM_ALL_ON)
    `uvm_field_int(act_broadcast,  UVM_ALL_ON)
    `uvm_field_enum(precision_e, precision, UVM_ALL_ON)
    `uvm_field_enum(acc_mode_e,  acc_mode,  UVM_ALL_ON)
    `uvm_field_int(result_bus,     UVM_ALL_ON)
    `uvm_field_int(result_vld,     UVM_ALL_ON)
    `uvm_field_int(exp_acc,        UVM_ALL_ON)
  `uvm_object_utils_end

  rand logic [511:0] weight_bus;     // 16 × 32-bit weights
  rand logic [31:0]  act_broadcast;  // 32-bit activation
  rand precision_e   precision;      // BF16 or INT8
  rand acc_mode_e    acc_mode;       // Overwrite or accumulate
  logic [511:0]      result_bus;     // Observed result (set by monitor)
  logic              result_vld;     // Observed result valid
  real               exp_acc[16];    // Expected per-lane accumulator (reference model)

  function new(string name = "cogniv_mac_op_txn");
    super.new(name);
  endfunction
endclass : cogniv_mac_op_txn

//=============================================================================
// EPC EVALUATION TRANSACTION [SEMI-REUSABLE]
//=============================================================================
class cogniv_epc_eval_txn extends uvm_sequence_item;
  `uvm_object_utils_begin(cogniv_epc_eval_txn)
    `uvm_field_int(gate_base,        UVM_ALL_ON)
    `uvm_field_int(k_cfg,            UVM_ALL_ON)
    `uvm_field_int(logit_vals,       UVM_ALL_ON)
    `uvm_field_int(exp_gate_out,     UVM_ALL_ON)
    `uvm_field_int(exp_eval_cycles,  UVM_ALL_ON)
    `uvm_field_int(inject_tie,       UVM_ALL_ON)
    `uvm_field_int(inject_invalid_k, UVM_ALL_ON)
    `uvm_field_int(use_sw_override,  UVM_ALL_ON)
    `uvm_field_int(sw_tile_map,      UVM_ALL_ON)
  `uvm_object_utils_end

  rand logic [63:0] gate_base;         // SRAM base address for 9 logits
  rand logic [1:0]  k_cfg;             // K: 2'b01=K1, 2'b10=K2
  rand logic [15:0] logit_vals[9];     // Q8.8 logit values (0..8)
  logic [8:0]       exp_gate_out;      // Expected one-hot output
  int unsigned      exp_eval_cycles;   // Expected: always 18
  rand bit          inject_tie;        // Force tie-break scenario (TV-006)
  rand bit          inject_invalid_k;  // Force invalid K (0 or 3) for error test
  rand bit          use_sw_override;
  rand logic [8:0]  sw_tile_map;

  constraint c_valid_k_default { !inject_invalid_k -> k_cfg inside {2'b01, 2'b10}; }
  constraint c_no_tie_default  { inject_tie == 0; }
  constraint c_no_override_default { use_sw_override == 0; }

  function new(string name = "cogniv_epc_eval_txn");
    super.new(name);
    exp_eval_cycles = cogniv_common_pkg::EPC_EVAL_CYCLES;
  endfunction
endclass : cogniv_epc_eval_txn

//=============================================================================
// RESULT COLLECTION TRANSACTION [REUSABLE-UNCHANGED]
//=============================================================================
class cogniv_result_txn extends uvm_sequence_item;
  `uvm_object_utils_begin(cogniv_result_txn)
    `uvm_field_int(tile_id,      UVM_ALL_ON)
    `uvm_field_int(token_id,     UVM_ALL_ON)
    `uvm_field_int(result_lo,    UVM_ALL_ON)
    `uvm_field_int(result_hi,    UVM_ALL_ON)
    `uvm_field_int(tile_done,    UVM_ALL_ON)
    `uvm_field_int(tile_error,   UVM_ALL_ON)
    `uvm_field_int(latency_cyc,  UVM_ALL_ON)
  `uvm_object_utils_end

  logic [3:0]   tile_id;
  logic [31:0]  token_id;
  logic [63:0]  result_lo;
  logic [63:0]  result_hi;
  logic         tile_done;
  logic         tile_error;
  int unsigned  latency_cyc;  // Cycles from dispatch to result_valid

  function new(string name = "cogniv_result_txn");
    super.new(name);
  endfunction
endclass : cogniv_result_txn

//=============================================================================
// CLOCK GATE EVENT TRANSACTION [REUSABLE-UNCHANGED]
//=============================================================================
class cogniv_clk_gate_txn extends uvm_sequence_item;
  `uvm_object_utils_begin(cogniv_clk_gate_txn)
    `uvm_field_int(tile_bitmap_before, UVM_ALL_ON)
    `uvm_field_int(tile_bitmap_after,  UVM_ALL_ON)
    `uvm_field_int(k_used,             UVM_ALL_ON)
  `uvm_object_utils_end

  logic [8:0] tile_bitmap_before; // ICG state before EPC evaluation
  logic [8:0] tile_bitmap_after;  // ICG state after EPC evaluation
  logic [1:0] k_used;             // K value used in this evaluation

  function new(string name = "cogniv_clk_gate_txn");
    super.new(name);
  endfunction
endclass : cogniv_clk_gate_txn

endpackage : cogniv_txn_pkg
`endif // COGNIV_TXN_PKG_SV
