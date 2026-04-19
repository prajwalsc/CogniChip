// ============================================================================
// FILE       : cogniv_adapter_pkg.sv
// PROJECT    : Cogni-V Engine UVM Verification Framework
// CATEGORY   : [REUSABLE-UNCHANGED] Cross-level transaction adapters.
//              Convert between CX intent, CLB packet, NoC flit, tile op.
// ============================================================================
`ifndef COGNIV_ADAPTER_PKG_SV
`define COGNIV_ADAPTER_PKG_SV
`include "uvm_macros.svh"
package cogniv_adapter_pkg;
import uvm_pkg::*;
import cogniv_common_pkg::*;
import cogniv_txn_pkg::*;

//=============================================================================
// cogniv_cx_to_clb_adapter [REUSABLE-UNCHANGED]
// Converts a CX_DISPATCH intent transaction into a CLB packet transaction.
// Inputs:  cogniv_cx_intent_txn (CX_DISPATCH)
// Output:  cogniv_clb_pkt_txn
//=============================================================================
class cogniv_cx_to_clb_adapter extends uvm_component;
  `uvm_component_utils(cogniv_cx_to_clb_adapter)

  // Subscriber port: receives CX intent transactions from CX monitor
  uvm_analysis_export  #(cogniv_cx_intent_txn) ae_cx;
  // Analysis port: produces CLB packet transactions
  uvm_analysis_port    #(cogniv_clb_pkt_txn)   ap_clb;

  uvm_tlm_analysis_fifo #(cogniv_cx_intent_txn) cx_fifo;

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    ae_cx   = new("ae_cx",  this);
    ap_clb  = new("ap_clb", this);
    cx_fifo = new("cx_fifo",this);
  endfunction

  function void connect_phase(uvm_phase phase);
    ae_cx.connect(cx_fifo.analysis_export);
  endfunction

  task run_phase(uvm_phase phase);
    cogniv_cx_intent_txn cx_txn;
    cogniv_clb_pkt_txn   clb_txn;
    forever begin
      cx_fifo.get(cx_txn);
      if (cx_txn.cx_opcode == CX_DISPATCH || cx_txn.cx_opcode == CX_TILE_CFG) begin
        clb_txn = cogniv_clb_pkt_txn::type_id::create("from_cx");
        // Assemble 128-bit packet from PKT_HI + PKT_LO
        clb_txn.raw_pkt = {cx_txn.pkt_hi, cx_txn.pkt_lo};
        clb_txn.tile_id = cx_txn.get_tile_id();
        // Flag parity injection if requested
        clb_txn.inject_parity_error = 0; // set by test if needed
        ap_clb.write(clb_txn);
      end
    end
  endtask
endclass : cogniv_cx_to_clb_adapter

//=============================================================================
// cogniv_clb_to_flit_adapter [REUSABLE-UNCHANGED]
// Converts CLB packet transaction to NoC flit transaction.
// Adds routing header and VC assignment.
//=============================================================================
class cogniv_clb_to_flit_adapter extends uvm_component;
  `uvm_component_utils(cogniv_clb_to_flit_adapter)

  uvm_analysis_export #(cogniv_clb_pkt_txn)  ae_clb;
  uvm_analysis_port   #(cogniv_noc_flit_txn) ap_flit;
  uvm_tlm_analysis_fifo #(cogniv_clb_pkt_txn) clb_fifo;

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    ae_clb   = new("ae_clb",   this);
    ap_flit  = new("ap_flit",  this);
    clb_fifo = new("clb_fifo", this);
  endfunction

  function void connect_phase(uvm_phase phase);
    ae_clb.connect(clb_fifo.analysis_export);
  endfunction

  task run_phase(uvm_phase phase);
    cogniv_clb_pkt_txn   clb_txn;
    cogniv_noc_flit_txn  flit_txn;
    forever begin
      clb_fifo.get(clb_txn);
      flit_txn = cogniv_noc_flit_txn::type_id::create("from_clb");
      flit_txn.flit_data   = clb_txn.raw_pkt;
      flit_txn.src_tile_id = 4'hF;  // CLB = source 0xF
      flit_txn.dst_tile_id = clb_txn.tile_id;
      flit_txn.vc_id       = 2'b00; // VC0 = data
      flit_txn.is_ack      = 0;
      ap_flit.write(flit_txn);
    end
  endtask
endclass : cogniv_clb_to_flit_adapter

//=============================================================================
// cogniv_flit_to_tile_adapter [REUSABLE-UNCHANGED]
// Converts a NoC flit arriving at a tile port into a tile_op_txn.
//=============================================================================
class cogniv_flit_to_tile_adapter extends uvm_component;
  `uvm_component_utils(cogniv_flit_to_tile_adapter)

  uvm_analysis_export #(cogniv_noc_flit_txn) ae_flit;
  uvm_analysis_port   #(cogniv_tile_op_txn)  ap_tile;
  uvm_tlm_analysis_fifo #(cogniv_noc_flit_txn) flit_fifo;

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    ae_flit   = new("ae_flit",   this);
    ap_tile   = new("ap_tile",   this);
    flit_fifo = new("flit_fifo", this);
  endfunction

  function void connect_phase(uvm_phase phase);
    ae_flit.connect(flit_fifo.analysis_export);
  endfunction

  task run_phase(uvm_phase phase);
    cogniv_noc_flit_txn flit_txn;
    cogniv_tile_op_txn  tile_txn;
    micro_op_pkt_t      pkt;
    forever begin
      flit_fifo.get(flit_txn);
      if (!flit_txn.is_ack) begin
        tile_txn = cogniv_tile_op_txn::type_id::create("from_flit");
        tile_txn.from_clb_pkt(
          cogniv_clb_pkt_txn::type_id::create("tmp"));
        // Decode flit directly
        pkt = cogniv_common_pkg::decode_micro_op_pkt(flit_txn.flit_data);
        tile_txn.tile_id    = pkt.tile_id;
        tile_txn.token_id   = pkt.token_id;
        tile_txn.weight_tag = pkt.weight_tag;
        tile_txn.act_data   = pkt.act_data;
        tile_txn.opcode     = tlc_opcode_e'(pkt.opcode);
        tile_txn.precision  = PREC_BF16;
        tile_txn.acc_mode   = ACC_OVERWRITE;
        ap_tile.write(tile_txn);
      end
    end
  endtask
endclass : cogniv_flit_to_tile_adapter

//=============================================================================
// cogniv_result_collector [REUSABLE-UNCHANGED]
// Subscribes to tile result flits (VC1 ACK flits) and builds result_txns.
// Used at subsystem and system levels.
//=============================================================================
class cogniv_result_collector extends uvm_subscriber #(cogniv_noc_flit_txn);
  `uvm_component_utils(cogniv_result_collector)

  uvm_analysis_port #(cogniv_result_txn) ap_result;

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    ap_result = new("ap_result", this);
  endfunction

  function void write(cogniv_noc_flit_txn flit);
    cogniv_result_txn res;
    if (flit.is_ack || flit.vc_id == 2'b01) begin
      res = cogniv_result_txn::type_id::create("result");
      res.tile_id   = flit.src_tile_id;
      res.token_id  = flit.flit_data[119:88];
      res.result_lo = flit.flit_data[63:0];
      res.result_hi = flit.flit_data[127:64];
      res.tile_done = 1'b1;
      res.tile_error= 1'b0;
      ap_result.write(res);
      `uvm_info("COLL", $sformatf(
        "LOG: %0t : INFO : cogniv_result_collector : tile%0d.token_id : expected_value: N/A actual_value: %08h",
        $time, res.tile_id, res.token_id), UVM_HIGH)
    end
  endfunction
endclass : cogniv_result_collector

//=============================================================================
// cogniv_mac_ref_model [SEMI-REUSABLE]
// BF16 and INT8 golden MAC reference model.
// Used by tile-level and subsystem predictors.
//=============================================================================
class cogniv_mac_ref_model extends uvm_object;
  `uvm_object_utils(cogniv_mac_ref_model)

  // Per-lane 32-bit accumulators
  real acc[16];
  precision_e prec;
  acc_mode_e  acc_mode;

  function new(string name = "cogniv_mac_ref_model");
    super.new(name);
    reset();
  endfunction

  function void reset();
    foreach (acc[i]) acc[i] = 0.0;
    prec     = PREC_BF16;
    acc_mode = ACC_OVERWRITE;
  endfunction

  // Execute one cycle of 16-lane MAC
  function void execute(
    input logic [511:0] weight_bus,
    input logic [31:0]  act_data,
    input bit           is_first_cycle
  );
    for (int l = 0; l < 16; l++) begin
      logic [31:0] w_word;
      real w0, w1, a0, a1;
      w_word = weight_bus[l*32 +: 32];
      if (prec == PREC_BF16) begin
        w0 = cogniv_common_pkg::bf16_to_real(w_word[31:16]);
        w1 = cogniv_common_pkg::bf16_to_real(w_word[15:0]);
        a0 = cogniv_common_pkg::bf16_to_real(act_data[31:16]);
        a1 = cogniv_common_pkg::bf16_to_real(act_data[15:0]);
        if (is_first_cycle && acc_mode == ACC_OVERWRITE) begin
          acc[l] = 0.0;
        end
        acc[l] += w0 * a0 + w1 * a1;
      end else begin
        // INT8: 4 weights per word
        int signed w[4];
        int signed a[4];
        w[0] = signed'(w_word[31:24]);
        w[1] = signed'(w_word[23:16]);
        w[2] = signed'(w_word[15:8]);
        w[3] = signed'(w_word[7:0]);
        a[0] = signed'(act_data[31:24]);
        a[1] = signed'(act_data[23:16]);
        a[2] = signed'(act_data[15:8]);
        a[3] = signed'(act_data[7:0]);
        if (is_first_cycle && acc_mode == ACC_OVERWRITE) begin
          acc[l] = 0.0;
        end
        for (int k = 0; k < 4; k++) begin
          acc[l] += w[k] * a[k];
        end
      end
    end
  endfunction

  // Drain: return current accumulator values
  function void drain(output real out_acc[16]);
    foreach (acc[i]) out_acc[i] = acc[i];
  endfunction
endclass : cogniv_mac_ref_model

//=============================================================================
// cogniv_epc_ref_model [SEMI-REUSABLE]
// Q8.8 softmax + Top-K reference model for EPC verification.
//=============================================================================
class cogniv_epc_ref_model extends uvm_object;
  `uvm_object_utils(cogniv_epc_ref_model)

  function new(string name = "cogniv_epc_ref_model");
    super.new(name);
  endfunction

  // Evaluate softmax top-K on 9 Q8.8 logits.
  // Returns one-hot selection bitmap.
  function automatic logic [8:0] evaluate_topk(
    input logic [15:0] logits[9],
    input logic [1:0]  k_cfg,
    output bit         topk_tie_flag
  );
    real    logit_real[9];
    real    max_logit;
    real    exp_vals[9];
    real    sum_exp;
    real    softmax_vals[9];
    int     sorted_idx[9];
    real    sorted_val[9];
    logic [8:0] result;
    int     k_count;
    int unsigned k_sel;

    topk_tie_flag = 0;
    k_sel = (k_cfg == 2'b01) ? 1 : 2;

    // Convert logits to real
    foreach (logits[i]) logit_real[i] = cogniv_common_pkg::q8_8_to_real(logits[i]);

    // Find max (stable softmax, Spec ss3.3)
    max_logit = logit_real[0];
    foreach (logit_real[i]) begin
      if (logit_real[i] > max_logit) max_logit = logit_real[i];
    end

    // Compute exp and sum
    sum_exp = 0.0;
    foreach (exp_vals[i]) begin
      exp_vals[i] = $exp(logit_real[i] - max_logit);
      sum_exp += exp_vals[i];
    end

    // Compute softmax
    foreach (softmax_vals[i]) begin
      softmax_vals[i] = exp_vals[i] / sum_exp;
    end

    // Simple selection sort (descending) with tie-break = lower index wins
    foreach (sorted_idx[i]) sorted_idx[i] = i;
    for (int i = 0; i < 9-1; i++) begin
      for (int j = i+1; j < 9; j++) begin
        bit swap;
        swap = (softmax_vals[sorted_idx[j]] > softmax_vals[sorted_idx[i]]) ||
               ((softmax_vals[sorted_idx[j]] == softmax_vals[sorted_idx[i]]) &&
                (sorted_idx[j] < sorted_idx[i]));
        if (swap) begin
          int tmp;
          tmp = sorted_idx[i]; sorted_idx[i] = sorted_idx[j]; sorted_idx[j] = tmp;
        end
      end
    end

    // Check for tie at boundary (Spec ss3.3)
    if (k_sel > 1 &&
        softmax_vals[sorted_idx[k_sel-1]] == softmax_vals[sorted_idx[k_sel]]) begin
      topk_tie_flag = 1;
    end

    // Build one-hot result
    result = 9'h0;
    for (int i = 0; i < int'(k_sel); i++) begin
      result[sorted_idx[i]] = 1'b1;
    end
    return result;
  endfunction
endclass : cogniv_epc_ref_model

endpackage : cogniv_adapter_pkg
`endif // COGNIV_ADAPTER_PKG_SV
