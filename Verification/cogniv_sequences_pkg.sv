// ============================================================================
// FILE       : cogniv_sequences_pkg.sv
// PROJECT    : Cogni-V Engine UVM Verification Framework
// CATEGORY   : [SEMI-REUSABLE] Sequences mapping all 15 spec test vectors.
//   Base sequences are reusable; test-specific constraint overrides are module-specific.
//
// TV→Level mapping:
//   MODULE:    TV-001 (partial), TV-007, TV-008, TV-009, TV-010
//   SUBSYSTEM: TV-001 (full), TV-002, TV-003 (partial), TV-004, TV-005, TV-006, TV-011, TV-012
//   SYSTEM:    TV-003 (full), TV-013, TV-014, TV-015
// ============================================================================
`ifndef COGNIV_SEQUENCES_PKG_SV
`define COGNIV_SEQUENCES_PKG_SV
`include "uvm_macros.svh"
package cogniv_sequences_pkg;
import uvm_pkg::*;
import cogniv_common_pkg::*;
import cogniv_txn_pkg::*;
import cogniv_adapter_pkg::*;
import cogniv_env_pkg::*;

//=============================================================================
// cogniv_vseq_base [REUSABLE-UNCHANGED]
// All virtual sequences extend this. Provides access to all sub-sequencers.
//=============================================================================
class cogniv_vseq_base extends uvm_sequence;
  `uvm_object_utils(cogniv_vseq_base)
  `uvm_declare_p_sequencer(cogniv_vseqr)

  function new(string name = "cogniv_vseq_base");
    super.new(name);
  endfunction
endclass

//=============================================================================
// TV-001 seq: cx_dispatch_basic
// LEVEL: SUBSYSTEM (CLB + NoC inject side)
// Pass: credit_cnt[0] decrements; flit appears at NoC inject
//=============================================================================
class tv001_cx_dispatch_basic_seq extends cogniv_vseq_base;
  `uvm_object_utils(tv001_cx_dispatch_basic_seq)
  logic [3:0] target_tile = 0;

  function new(string name = "tv001_cx_dispatch_basic_seq"); super.new(name); endfunction

  task body();
    cogniv_cx_intent_txn cx_txn;
    `uvm_info("TV001","TV-001: CX_DISPATCH basic - single flit to tile 0",UVM_NONE)
    cx_txn = cogniv_cx_intent_txn::type_id::create("tv001_cx");
    cx_txn.cx_opcode = CX_DISPATCH;
    cx_txn.tile_mask = 9'b000000001;  // tile 0
    cx_txn.pkt_hi    = 64'h0000_BEEF_0001_0000; // token_id upper
    cx_txn.pkt_lo    = 64'h0000_0010_0000_0000; // weight_tag + opcode
    start_item(cx_txn, -1, p_sequencer.rv_seqr);
    if (!cx_txn.randomize() with {cx_opcode == CX_DISPATCH; tile_mask == 9'b1;})
      `uvm_warning("TV001","Randomize failed, using defaults")
    finish_item(cx_txn, -1);
    #50ns;
    `uvm_info("TV001","TV-001 complete",UVM_NONE)
  endtask
endclass

//=============================================================================
// TV-002 seq: cx_dispatch_backpressure
// LEVEL: SUBSYSTEM (CLB credit=0 → stall)
// Pass: stall asserted; no 5th flit injected after 4 dispatches
//=============================================================================
class tv002_cx_dispatch_backpressure_seq extends cogniv_vseq_base;
  `uvm_object_utils(tv002_cx_dispatch_backpressure_seq)

  function new(string name = "tv002_cx_dispatch_backpressure_seq"); super.new(name); endfunction

  task body();
    cogniv_cx_intent_txn cx_txn;
    `uvm_info("TV002","TV-002: CX_DISPATCH backpressure - drain 4 credits",UVM_NONE)
    // Send 4 dispatches to the same tile (drain all credits)
    for (int i = 0; i < 4; i++) begin
      cx_txn = cogniv_cx_intent_txn::type_id::create($sformatf("tv002_cx_%0d",i));
      cx_txn.cx_opcode = CX_DISPATCH;
      cx_txn.tile_mask = 9'b000000001; // tile 0
      cx_txn.pkt_lo    = 64'h000F_0000 | (i << 20); // unique token
      start_item(cx_txn, -1, p_sequencer.rv_seqr);
      if (!cx_txn.randomize() with {cx_opcode == CX_DISPATCH;})
        `uvm_warning("TV002","Randomize failed")
      finish_item(cx_txn, -1);
    end
    // 5th dispatch - stall_out should be asserted before this fires
    `uvm_info("TV002","Attempting 5th dispatch - stall expected",UVM_MEDIUM)
    cx_txn = cogniv_cx_intent_txn::type_id::create("tv002_cx_5th");
    cx_txn.cx_opcode  = CX_DISPATCH;
    cx_txn.tile_mask  = 9'b000000001;
    cx_txn.inject_credit_stall = 1; // Alert driver to check stall
    start_item(cx_txn, -1, p_sequencer.rv_seqr);
    if (!cx_txn.randomize() with {inject_credit_stall == 1;})
      `uvm_warning("TV002","Randomize failed")
    finish_item(cx_txn, -1);
    #50ns;
    `uvm_info("TV002","TV-002 complete",UVM_NONE)
  endtask
endclass

//=============================================================================
// TV-003 seq: noc_9tile_congestion
// LEVEL: SYSTEM (9 simultaneous dispatches)
// Pass: all 9 results received within 50 cycles of first dispatch
//=============================================================================
class tv003_noc_9tile_congestion_seq extends cogniv_vseq_base;
  `uvm_object_utils(tv003_noc_9tile_congestion_seq)

  function new(string name = "tv003_noc_9tile_congestion_seq"); super.new(name); endfunction

  task body();
    cogniv_cx_intent_txn cx_txn[9];
    `uvm_info("TV003","TV-003: NoC 9-tile congestion test",UVM_NONE)
    // Send simultaneously to all 9 tiles
    fork
      begin
        for (int t = 0; t < 9; t++) begin
          cx_txn[t] = cogniv_cx_intent_txn::type_id::create($sformatf("tv003_tile%0d",t));
          cx_txn[t].cx_opcode = CX_DISPATCH;
          cx_txn[t].tile_mask = 9'(1 << t);
          cx_txn[t].pkt_lo    = 64'h000F_0000 | (t << 24);
          cx_txn[t].pkt_hi    = 64'hBEEF_0003 | (t << 20);
          start_item(cx_txn[t]);
          if (!cx_txn[t].randomize() with {cx_opcode == CX_DISPATCH; tile_mask == 9'(1<<t);}) begin
            `uvm_warning("TV003","Randomize failed, using defaults")
          end
          finish_item(cx_txn[t]);
        end
      end
    join
    // Measure latency via CX_SYNC on all tiles
    begin
      cogniv_cx_intent_txn sync_txn;
      sync_txn = cogniv_cx_intent_txn::type_id::create("tv003_sync");
      sync_txn.cx_opcode  = CX_SYNC;
      sync_txn.tile_mask  = 9'h1FF; // All 9 tiles
      sync_txn.timeout_cycles = 50; // 50-cycle window per spec
      start_item(sync_txn, -1, p_sequencer.rv_seqr);
      if (!sync_txn.randomize() with {cx_opcode == CX_SYNC; tile_mask == 9'h1FF;})
        `uvm_warning("TV003","Randomize failed")
      finish_item(sync_txn, -1);
    end
    `uvm_info("TV003","TV-003 complete",UVM_NONE)
  endtask
endclass

//=============================================================================
// TV-004 seq: epc_gate_eval_k1
// LEVEL: SUBSYSTEM (EPC only)
// Pass: EPC_GATE_OUT is one-hot; exactly 1 bit set
//=============================================================================
class tv004_epc_gate_k1_seq extends cogniv_vseq_base;
  `uvm_object_utils(tv004_epc_gate_k1_seq)

  function new(string name = "tv004_epc_gate_k1_seq"); super.new(name); endfunction

  task body();
    cogniv_cx_intent_txn cx_txn;
    `uvm_info("TV004","TV-004: EPC gating K=1",UVM_NONE)
    cx_txn = cogniv_cx_intent_txn::type_id::create("tv004_gate");
    cx_txn.cx_opcode = CX_GATE_EVAL;
    cx_txn.gate_base = 64'h0000_0000_2008; // EPC_GATE_BASE
    cx_txn.k_val     = 2'b01;             // K=1
    start_item(cx_txn, -1, p_sequencer.rv_seqr);
    if (!cx_txn.randomize() with {cx_opcode == CX_GATE_EVAL; k_val == 2'b01;})
      `uvm_warning("TV004","Randomize failed")
    finish_item(cx_txn, -1);
    #20ns; // Wait 18 EPC cycles + margin
    `uvm_info("TV004","TV-004 complete",UVM_NONE)
  endtask
endclass

//=============================================================================
// TV-005 seq: epc_gate_eval_k2
// LEVEL: SUBSYSTEM (EPC only)
// Pass: EPC_GATE_OUT has exactly 2 bits set
//=============================================================================
class tv005_epc_gate_k2_seq extends cogniv_vseq_base;
  `uvm_object_utils(tv005_epc_gate_k2_seq)

  function new(string name = "tv005_epc_gate_k2_seq"); super.new(name); endfunction

  task body();
    cogniv_cx_intent_txn cx_txn;
    `uvm_info("TV005","TV-005: EPC gating K=2",UVM_NONE)
    cx_txn = cogniv_cx_intent_txn::type_id::create("tv005_gate");
    cx_txn.cx_opcode = CX_GATE_EVAL;
    cx_txn.gate_base = 64'h0000_0000_2008;
    cx_txn.k_val     = 2'b10; // K=2
    start_item(cx_txn, -1, p_sequencer.rv_seqr);
    if (!cx_txn.randomize() with {cx_opcode == CX_GATE_EVAL; k_val == 2'b10;})
      `uvm_warning("TV005","Randomize failed")
    finish_item(cx_txn, -1);
    #20ns;
    `uvm_info("TV005","TV-005 complete",UVM_NONE)
  endtask
endclass

//=============================================================================
// TV-006 seq: epc_tie_break
// LEVEL: SUBSYSTEM (EPC tie-break behavior)
// Pass: lower tile index wins; EPC_ERR_STAT[2] (topk_tie) set
//=============================================================================
class tv006_epc_tie_break_seq extends cogniv_vseq_base;
  `uvm_object_utils(tv006_epc_tie_break_seq)

  function new(string name = "tv006_epc_tie_break_seq"); super.new(name); endfunction

  task body();
    cogniv_epc_eval_txn epc_txn;
    `uvm_info("TV006","TV-006: EPC tie-break - equal logits at k-boundary",UVM_NONE)
    epc_txn = cogniv_epc_eval_txn::type_id::create("tv006_epc");
    // All logits equal -> forces tie on all K selections
    for (int i = 0; i < 9; i++) epc_txn.logit_vals[i] = 16'h0100; // Q8.8 = 1.0
    epc_txn.k_cfg       = 2'b10; // K=2
    epc_txn.inject_tie  = 1;
    epc_txn.gate_base   = 64'h0000_0000_2008;
    // Expected: tiles 0 and 1 selected (lower index wins); topk_tie set
    epc_txn.exp_gate_out = 9'b000000011;
    if (p_sequencer.epc_seqr != null) begin
      start_item(epc_txn); finish_item(epc_txn);
    end
    #20ns;
    `uvm_info("TV006","TV-006 complete",UVM_NONE)
  endtask
endclass

//=============================================================================
// TV-007 seq: tile_mac_bf16_single
// LEVEL: MODULE (TLC + MAC BF16)
// Pass: result flit TOKEN_ID matches; tile_done asserted
//=============================================================================
class tv007_tile_mac_bf16_seq extends cogniv_vseq_base;
  `uvm_object_utils(tv007_tile_mac_bf16_seq)
  logic [3:0] target_tile = 0;

  function new(string name = "tv007_tile_mac_bf16_seq"); super.new(name); endfunction

  task body();
    cogniv_tile_op_txn mac_txn;
    `uvm_info("TV007","TV-007: Tile MAC BF16 single computation",UVM_NONE)

    // Configure tile for BF16 overwrite mode
    begin
      cogniv_tile_op_txn cfg_txn;
      cfg_txn = cogniv_tile_op_txn::type_id::create("tv007_cfg");
      cfg_txn.tile_id  = target_tile;
      cfg_txn.opcode   = OP_TILE_CFG;
      cfg_txn.token_id = 32'hCFG_0007;
      cfg_txn.precision = PREC_BF16;
      cfg_txn.acc_mode  = ACC_OVERWRITE;
      cfg_txn.exp_tile_done  = 1'b0;
      cfg_txn.exp_tile_error = 1'b0;
      start_item(cfg_txn); finish_item(cfg_txn);
    end

    // MAC_START: BF16 weights; act = 1.0 (BF16 x2)
    mac_txn = cogniv_tile_op_txn::type_id::create("tv007_mac");
    mac_txn.tile_id      = target_tile;
    mac_txn.opcode       = OP_MAC_START;
    mac_txn.weight_tag   = 32'h0000_0010;
    mac_txn.act_data     = 32'h3F80_3F80; // BF16 1.0 × 2
    mac_txn.token_id     = 32'hBEEF_0007;
    mac_txn.precision    = PREC_BF16;
    mac_txn.sram_rdata_val = 32'h3F80_3F80; // BF16 1.0 × 2
    mac_txn.mac_result_val = 512'h2; // Simple non-zero result
    mac_txn.exp_tile_done  = 1'b1;
    mac_txn.exp_tile_error = 1'b0;
    mac_txn.exp_result_flit = {8'h0, 32'hBEEF_0007, 88'h0};
    start_item(mac_txn); finish_item(mac_txn);
    `uvm_info("TV007","TV-007 complete",UVM_NONE)
  endtask
endclass

//=============================================================================
// TV-008 seq: tile_mac_int8_single
// LEVEL: MODULE (TLC + MAC INT8)
//=============================================================================
class tv008_tile_mac_int8_seq extends cogniv_vseq_base;
  `uvm_object_utils(tv008_tile_mac_int8_seq)
  logic [3:0] target_tile = 0;

  function new(string name = "tv008_tile_mac_int8_seq"); super.new(name); endfunction

  task body();
    cogniv_tile_op_txn mac_txn;
    `uvm_info("TV008","TV-008: Tile MAC INT8 computation",UVM_NONE)
    mac_txn = cogniv_tile_op_txn::type_id::create("tv008_mac");
    mac_txn.tile_id      = target_tile;
    mac_txn.opcode       = OP_MAC_START;
    mac_txn.weight_tag   = 32'h0000_0020;
    mac_txn.act_data     = 32'h01_02_03_04; // INT8 × 4
    mac_txn.token_id     = 32'hBEEF_0008;
    mac_txn.precision    = PREC_INT8;
    mac_txn.sram_rdata_val = 32'h01_01_01_01;
    mac_txn.mac_result_val = 512'hA;
    mac_txn.exp_tile_done  = 1'b1;
    mac_txn.exp_tile_error = 1'b0;
    mac_txn.exp_result_flit = {8'h0, 32'hBEEF_0008, 88'h0};
    start_item(mac_txn); finish_item(mac_txn);
    `uvm_info("TV008","TV-008 complete",UVM_NONE)
  endtask
endclass

//=============================================================================
// TV-009 seq: tile_sram_ecc_1bit
// LEVEL: MODULE (TLC + SRAM ECC)
// Pass: ecc_err_1b asserted; tile_done=1; result correct
//=============================================================================
class tv009_sram_ecc_1bit_seq extends cogniv_vseq_base;
  `uvm_object_utils(tv009_sram_ecc_1bit_seq)

  function new(string name = "tv009_sram_ecc_1bit_seq"); super.new(name); endfunction

  task body();
    cogniv_tile_op_txn txn;
    `uvm_info("TV009","TV-009: SRAM ECC 1-bit error injection",UVM_NONE)
    txn = cogniv_tile_op_txn::type_id::create("tv009_ecc1");
    txn.tile_id       = 0;
    txn.opcode        = OP_MAC_START;
    txn.token_id      = 32'hECC1_0009;
    txn.inject_ecc_1b = 1;
    txn.sram_rdata_val = 32'hABCD_EF01;
    txn.mac_result_val = 512'h42;
    txn.exp_tile_done  = 1'b1; // 1-bit ECC: corrected; tile proceeds
    txn.exp_tile_error = 1'b0;
    txn.exp_result_flit = {8'h0, 32'hECC1_0009, 88'h0};
    start_item(txn); finish_item(txn);
    `uvm_info("TV009","TV-009 complete",UVM_NONE)
  endtask
endclass

//=============================================================================
// TV-010 seq: tile_sram_ecc_2bit
// LEVEL: MODULE (TLC ERROR state)
// Pass: tile_error=1; TLC FSM in ERROR (3'b111)
//=============================================================================
class tv010_sram_ecc_2bit_seq extends cogniv_vseq_base;
  `uvm_object_utils(tv010_sram_ecc_2bit_seq)

  function new(string name = "tv010_sram_ecc_2bit_seq"); super.new(name); endfunction

  task body();
    cogniv_tile_op_txn txn;
    `uvm_info("TV010","TV-010: SRAM ECC 2-bit error -> ERROR state",UVM_NONE)
    txn = cogniv_tile_op_txn::type_id::create("tv010_ecc2");
    txn.tile_id        = 0;
    txn.opcode         = OP_MAC_START;
    txn.token_id       = 32'hECC2_0010;
    txn.inject_ecc_2b  = 1;
    txn.sram_rdata_val = 32'hDEAD_BEEF;
    txn.exp_tile_done  = 1'b0;
    txn.exp_tile_error = 1'b1; // ERROR state
    start_item(txn); finish_item(txn);
    `uvm_info("TV010","TV-010 complete",UVM_NONE)
  endtask
endclass

//=============================================================================
// TV-011 seq: cx_collect_timeout
// LEVEL: SUBSYSTEM (CX_COLLECT timeout)
// Pass: rd = 0xDEAD_DEAD; CX_ERR_STAT[1] set
//=============================================================================
class tv011_cx_collect_timeout_seq extends cogniv_vseq_base;
  `uvm_object_utils(tv011_cx_collect_timeout_seq)

  function new(string name = "tv011_cx_collect_timeout_seq"); super.new(name); endfunction

  task body();
    cogniv_cx_intent_txn cx_txn;
    `uvm_info("TV011","TV-011: CX_COLLECT timeout test",UVM_NONE)
    cx_txn = cogniv_cx_intent_txn::type_id::create("tv011_collect");
    cx_txn.cx_opcode      = CX_COLLECT;
    cx_txn.tile_mask      = 9'b000000001; // tile 0 - never sends result
    cx_txn.timeout_cycles = 16'h0064;     // 100-cycle timeout
    start_item(cx_txn, -1, p_sequencer.rv_seqr);
    if (!cx_txn.randomize() with {cx_opcode == CX_COLLECT; timeout_cycles == 16'h64;})
      `uvm_warning("TV011","Randomize failed")
    finish_item(cx_txn, -1);
    #200ns; // Wait for timeout to fire
    `uvm_info("TV011","TV-011 complete (CX_ERR_STAT[1] should be set)",UVM_NONE)
  endtask
endclass

//=============================================================================
// TV-012 seq: cx_parity_error
// LEVEL: SUBSYSTEM (CLB parity error)
// Pass: packet dropped; clb_parity_err asserted
//=============================================================================
class tv012_cx_parity_error_seq extends cogniv_vseq_base;
  `uvm_object_utils(tv012_cx_parity_error_seq)

  function new(string name = "tv012_cx_parity_error_seq"); super.new(name); endfunction

  task body();
    cogniv_clb_pkt_txn pkt_txn;
    `uvm_info("TV012","TV-012: CLB parity error injection",UVM_NONE)
    pkt_txn = cogniv_clb_pkt_txn::type_id::create("tv012_parity");
    pkt_txn.tile_id = 0;
    pkt_txn.raw_pkt = cogniv_common_pkg::build_micro_op_pkt(
      4'h0, 4'h0, 16'h0001, 32'h0010, 32'h3F80, 32'hBAD_PA12);
    pkt_txn.inject_parity_error = 1; // corrupt parity
    pkt_txn.exp_stall    = 0;
    pkt_txn.exp_parity_err = 1;
    start_item(pkt_txn); finish_item(pkt_txn);
    #50ns;
    `uvm_info("TV012","TV-012 complete",UVM_NONE)
  endtask
endclass

//=============================================================================
// TV-013 seq: moe_full_layer
// LEVEL: SYSTEM (end-to-end MoE layer)
// Pass: all token results match golden model; total <= 400 cycles
//=============================================================================
class tv013_moe_full_layer_seq extends cogniv_vseq_base;
  `uvm_object_utils(tv013_moe_full_layer_seq)

  int unsigned batch_size  = 7;
  int unsigned k_val_int   = 2;
  logic [63:0] gate_base   = 64'h0000_0000_2008;

  function new(string name = "tv013_moe_full_layer_seq"); super.new(name); endfunction

  task body();
    `uvm_info("TV013",$sformatf("TV-013: MoE full layer - %0d tokens, K=%0d",
              batch_size, k_val_int),UVM_NONE)

    // Step 1: EPC gating evaluation
    begin
      cogniv_cx_intent_txn epc_txn;
      epc_txn = cogniv_cx_intent_txn::type_id::create("tv013_epc");
      epc_txn.cx_opcode = CX_GATE_EVAL;
      epc_txn.gate_base = gate_base;
      epc_txn.k_val     = k_val_int[1:0];
      start_item(epc_txn, -1, p_sequencer.rv_seqr);
      if (!epc_txn.randomize() with {cx_opcode == CX_GATE_EVAL; k_val == 2'b10;})
        `uvm_warning("TV013","Randomize failed")
      finish_item(epc_txn, -1);
      #20ns; // 18 EPC cycles
    end

    // Step 2: Dispatch all tokens to active tiles
    for (int tok = 0; tok < int'(batch_size); tok++) begin
      cogniv_cx_intent_txn dispatch_txn;
      dispatch_txn = cogniv_cx_intent_txn::type_id::create($sformatf("tv013_tok%0d",tok));
      dispatch_txn.cx_opcode = CX_DISPATCH;
      dispatch_txn.tile_mask = 9'b000000011; // Tiles 0 and 1 (K=2)
      dispatch_txn.pkt_hi    = 64'(tok << 24) | 64'hBEEF_0013_0000_0000;
      dispatch_txn.pkt_lo    = 64'h3F80_3F80_0010_0000; // BF16 act
      start_item(dispatch_txn, -1, p_sequencer.rv_seqr);
      if (!dispatch_txn.randomize() with {cx_opcode == CX_DISPATCH;})
        `uvm_warning("TV013","Randomize failed")
      finish_item(dispatch_txn, -1);
      #5ns; // 1 dispatch per ~10 cycles
    end

    // Step 3: Sync on both active tiles
    begin
      cogniv_cx_intent_txn sync_txn;
      sync_txn = cogniv_cx_intent_txn::type_id::create("tv013_sync");
      sync_txn.cx_opcode = CX_SYNC;
      sync_txn.tile_mask = 9'b000000011; // Tiles 0 and 1
      sync_txn.timeout_cycles = 16'h01F4; // 500 cycles
      start_item(sync_txn, -1, p_sequencer.rv_seqr);
      if (!sync_txn.randomize() with {cx_opcode == CX_SYNC; tile_mask == 9'b11;})
        `uvm_warning("TV013","Randomize failed")
      finish_item(sync_txn, -1);
    end

    #400ns; // Full layer budget: 350 cycles + margin (Spec ss7.2)
    `uvm_info("TV013","TV-013 complete",UVM_NONE)
  endtask
endclass

//=============================================================================
// TV-014 seq: cx_sync_all_tiles
// LEVEL: SYSTEM
// Pass: returns when all tiles assert tile_done; no timeout
//=============================================================================
class tv014_cx_sync_all_seq extends cogniv_vseq_base;
  `uvm_object_utils(tv014_cx_sync_all_seq)

  function new(string name = "tv014_cx_sync_all_seq"); super.new(name); endfunction

  task body();
    cogniv_cx_intent_txn sync_txn;
    `uvm_info("TV014","TV-014: CX_SYNC all tiles",UVM_NONE)
    sync_txn = cogniv_cx_intent_txn::type_id::create("tv014_sync");
    sync_txn.cx_opcode     = CX_SYNC;
    sync_txn.tile_mask     = 9'h1FF; // All 9 tiles
    sync_txn.timeout_cycles= 16'h0100; // 256-cycle timeout
    start_item(sync_txn, -1, p_sequencer.rv_seqr);
    if (!sync_txn.randomize() with {cx_opcode == CX_SYNC; tile_mask == 9'h1FF;})
      `uvm_warning("TV014","Randomize failed")
    finish_item(sync_txn, -1);
    `uvm_info("TV014","TV-014 complete",UVM_NONE)
  endtask
endclass

//=============================================================================
// TV-015 seq: clock_gate_idle_power
// LEVEL: SYSTEM (EPC + ICG)
// Pass: zero transitions on CLK_TILE[i] for gated-off tiles
//=============================================================================
class tv015_clock_gate_idle_seq extends cogniv_vseq_base;
  `uvm_object_utils(tv015_clock_gate_idle_seq)

  function new(string name = "tv015_clock_gate_idle_seq"); super.new(name); endfunction

  task body();
    cogniv_cx_intent_txn epc_txn;
    `uvm_info("TV015","TV-015: Clock gate idle power - K=1, 8 tiles gated",UVM_NONE)
    epc_txn = cogniv_cx_intent_txn::type_id::create("tv015_epc");
    epc_txn.cx_opcode = CX_GATE_EVAL;
    epc_txn.gate_base = 64'h0000_0000_2008;
    epc_txn.k_val     = 2'b01; // K=1 - only 1 tile active
    start_item(epc_txn, -1, p_sequencer.rv_seqr);
    if (!epc_txn.randomize() with {cx_opcode == CX_GATE_EVAL; k_val == 2'b01;})
      `uvm_warning("TV015","Randomize failed")
    finish_item(epc_txn, -1);
    #50ns; // EPC + ICG settling
    // Monitor should observe zero transitions on CLK_TILE[1..8]
    // Scoreboard will check ICG state via EPC_CLK_GATE register
    `uvm_info("TV015","TV-015 complete",UVM_NONE)
  endtask
endclass

endpackage : cogniv_sequences_pkg
`endif // COGNIV_SEQUENCES_PKG_SV
