// ============================================================================
// FILE       : cogniv_common_pkg.sv
// PROJECT    : Cogni-V Engine UVM Verification Framework
// SPEC REF   : COGNIV-SPEC-001-FULL v3.0 / SPEC-004-MODULE
// CATEGORY   : [REUSABLE - UNCHANGED] Foundation layer; no UVM dependency.
//              Import this package in every UVM package at every level.
// ============================================================================
`ifndef COGNIV_COMMON_PKG_SV
`define COGNIV_COMMON_PKG_SV
package cogniv_common_pkg;

  //===========================================================================
  // 1. FUNDAMENTAL CONSTANTS
  //===========================================================================
  localparam int unsigned TILE_COUNT      = 9;
  localparam int unsigned TILE_ROWS       = 3;
  localparam int unsigned TILE_COLS       = 3;
  localparam int unsigned MAC_LANES       = 16;
  localparam int unsigned SRAM_WORDS      = 65536;  // 256KB / 4B
  localparam int unsigned FLIT_WIDTH      = 128;
  localparam int unsigned CLB_CREDIT_MAX  = 4;
  localparam int unsigned CLB_FIFO_DEPTH  = 4;
  localparam int unsigned EPC_EVAL_CYCLES = 18;
  localparam int unsigned TLC_SYNC_TIMEOUT= 4096;
  localparam int unsigned NOC_MAX_HOPS    = 4;
  localparam int unsigned BATCH_MAX       = 64;

  // MMIO base addresses (Spec ss2.2 / ss4.5)
  localparam logic [63:0] MMIO_CLB_BASE   = 64'hFFFF_0000_0000;
  localparam logic [63:0] MMIO_CLB_STRIDE = 64'h0000_0000_0040; // 64B per tile
  localparam logic [63:0] MMIO_EPC_BASE   = 64'h0000_0000_2000;
  localparam logic [63:0] MMIO_CSR_BASE   = 64'h0000_0000_1000;

  //===========================================================================
  // 2. TILE COORDINATE HELPERS
  //===========================================================================
  // Tile index to (x,y) coordinates: i = y*3 + x
  function automatic logic [1:0] tile_x(input int unsigned id);
    return logic'(id % 3);
  endfunction

  function automatic logic [1:0] tile_y(input int unsigned id);
    return logic'(id / 3);
  endfunction

  function automatic int unsigned tile_idx(input int unsigned x, input int unsigned y);
    return y * 3 + x;
  endfunction

  // Manhattan distance between two tiles (= NoC hop count)
  function automatic int unsigned tile_hop_count(
    input int unsigned src_id, input int unsigned dst_id);
    return (tile_x(src_id) > tile_x(dst_id) ?
              tile_x(src_id) - tile_x(dst_id) :
              tile_x(dst_id) - tile_x(src_id)) +
           (tile_y(src_id) > tile_y(dst_id) ?
              tile_y(src_id) - tile_y(dst_id) :
              tile_y(dst_id) - tile_y(src_id));
  endfunction

  //===========================================================================
  // 3. ENUMERATIONS
  //===========================================================================

  // TLC FSM State Encoding (Spec ss1.2 / ss5.5)
  typedef enum logic [2:0] {
    TLC_IDLE      = 3'b000,
    TLC_CFG       = 3'b001,
    TLC_MAC_LOAD  = 3'b010,
    TLC_MAC_EXEC  = 3'b011,
    TLC_MAC_DRAIN = 3'b100,
    TLC_RESULT_TX = 3'b101,
    // 3'b110 intentionally omitted (ILLEGAL -> encode as ERROR)
    TLC_ERROR     = 3'b111
  } tlc_state_e;

  // Micro-op OPCODE (Spec ss4.2)
  typedef enum logic [3:0] {
    OP_MAC_START  = 4'h0,
    OP_MAC_ACC    = 4'h1,
    OP_MAC_DRAIN  = 4'h2,
    // 4'h3..4'hE = reserved
    OP_TILE_CFG   = 4'hF
  } tlc_opcode_e;

  // Precision mode (Spec ss2.1)
  typedef enum logic { PREC_BF16 = 1'b0, PREC_INT8 = 1'b1 } precision_e;

  // Accumulator mode (Spec ss2.4)
  typedef enum logic { ACC_OVERWRITE = 1'b0, ACC_ACCUMULATE = 1'b1 } acc_mode_e;

  // ECC error type (Spec ss3.4)
  typedef enum logic [1:0] {
    ECC_NONE = 2'b00,
    ECC_1BIT = 2'b01,
    ECC_2BIT = 2'b10
  } ecc_err_e;

  // CX Instruction encodings (Spec ss3.4, funct3 field)
  typedef enum logic [2:0] {
    CX_DISPATCH   = 3'b000,
    CX_COLLECT    = 3'b001,
    CX_GATE_EVAL  = 3'b010,
    CX_TILE_CFG   = 3'b011,
    CX_SYNC       = 3'b100
  } cx_opcode_e;

  // EPC internal pipeline phase (Spec ss5.2)
  typedef enum logic [3:0] {
    EPC_IDLE       = 4'd0,
    EPC_INIT       = 4'd1,
    EPC_LOGIT_RD   = 4'd2,
    EPC_MAX_FIND   = 4'd3,
    EPC_EXP_EVAL   = 4'd4,
    EPC_SUM        = 4'd5,
    EPC_SOFTMAX    = 4'd6,
    EPC_TOPK       = 4'd7,
    EPC_GATE       = 4'd8,
    EPC_WRITEBACK  = 4'd9
  } epc_phase_e;

  //===========================================================================
  // 4. PACKED STRUCTS
  //===========================================================================

  // 128-bit micro-op packet (Spec ss4.2)
  typedef struct packed {
    logic [3:0]  parity;      // [127:124]
    logic [3:0]  rsvd;        // [123:120]
    logic [31:0] token_id;    // [119: 88]
    logic [31:0] act_data;    // [ 87: 56]
    logic [31:0] weight_tag;  // [ 55: 24]
    logic [15:0] op_cfg;      // [ 23:  8]
    logic [3:0]  tile_id;     // [  7:  4]
    logic [3:0]  opcode;      // [  3:  0]
  } micro_op_pkt_t;

  // TLC configuration register (Spec ss5.5)
  typedef struct packed {
    logic [14:0] rsvd;       // [31:17]
    logic        ecc_en;     // [16]
    logic [3:0]  acc_mode;   // [15:12]
    logic [3:0]  layer_id;   // [11:8]
    logic [3:0]  expert_id;  // [7:4]
    logic [3:0]  precision;  // [3:0]
  } tlc_cfg_reg_t;

  // CLB per-tile status (Spec ss4.5 TILE_STATUS)
  typedef struct packed {
    logic [28:0] rsvd;
    logic        tile_error;
    logic        tile_busy;
    logic        result_valid;
  } clb_tile_status_t;

  // EPC evaluation result
  typedef struct packed {
    logic [22:0] rsvd;
    logic        topk_tie;
    logic        invalid_k;
    logic        gate_addr_fault;
    logic [8:0]  gate_out;         // one-hot tile selection
  } epc_result_t;

  // NoC route header (flit bits [127:120] reused as routing)
  typedef struct packed {
    logic [3:0]  parity;   // [127:124]
    logic [3:0]  rsvd;     // [123:120]
    // lower flit bits used for actual content:
    logic [3:0]  dest_x;   // [7:4] destination column
    logic [3:0]  dest_y;   // [3:0] destination row
  } noc_route_hdr_t;

  //===========================================================================
  // 5. PARITY AND PACKET HELPERS
  //===========================================================================

  // Compute 4-bit even parity (Spec ss4.2 / ss4.4)
  // PARITY[k] = ^(packet[31*(k+1)-2 : 31*k]) for k=0..3
  function automatic logic [3:0] compute_pkt_parity(input logic [127:0] pkt);
    logic [3:0] p;
    p[0] = ^pkt[30:0];
    p[1] = ^pkt[61:31];
    p[2] = ^pkt[92:62];
    p[3] = ^pkt[123:93];
    return p;
  endfunction

  // Verify parity on received packet (returns 1=OK, 0=mismatch)
  function automatic bit check_pkt_parity(input logic [127:0] pkt);
    return (compute_pkt_parity(pkt) === pkt[127:124]);
  endfunction

  // Build a complete 128-bit packet with auto-computed parity
  function automatic logic [127:0] build_micro_op_pkt(
    input logic [3:0]  opcode,
    input logic [3:0]  tile_id,
    input logic [15:0] op_cfg,
    input logic [31:0] weight_tag,
    input logic [31:0] act_data,
    input logic [31:0] token_id
  );
    logic [127:0] raw;
    raw[3:0]     = opcode;
    raw[7:4]     = tile_id;
    raw[23:8]    = op_cfg;
    raw[55:24]   = weight_tag;
    raw[87:56]   = act_data;
    raw[119:88]  = token_id;
    raw[123:120] = 4'h0;
    raw[127:124] = compute_pkt_parity(raw);
    return raw;
  endfunction

  // Decode a raw 128-bit packet into struct fields
  function automatic micro_op_pkt_t decode_micro_op_pkt(input logic [127:0] raw);
    micro_op_pkt_t p;
    p.opcode     = raw[3:0];
    p.tile_id    = raw[7:4];
    p.op_cfg     = raw[23:8];
    p.weight_tag = raw[55:24];
    p.act_data   = raw[87:56];
    p.token_id   = raw[119:88];
    p.rsvd       = raw[123:120];
    p.parity     = raw[127:124];
    return p;
  endfunction

  //===========================================================================
  // 6. BF16 / INT8 MODEL HELPERS
  //===========================================================================

  // BF16 to real32 conversion (for use in reference model)
  function automatic real bf16_to_real(input logic [15:0] bf16_val);
    logic        sign;
    logic [7:0]  exp8;
    logic [6:0]  man7;
    real         result;
    sign = bf16_val[15];
    exp8 = bf16_val[14:7];
    man7 = bf16_val[6:0];
    if (exp8 == 8'hFF) begin
      result = (man7 != 0) ? 0.0 : (sign ? -1e38 : 1e38); // NaN/Inf approx
    end else if (exp8 == 8'h00) begin
      result = (1.0 - 2.0 * sign) * (2.0 ** -126) * ({1'b0, man7} / 128.0);
    end else begin
      result = (1.0 - 2.0 * sign) * (2.0 ** (int'(exp8) - 127)) * (1.0 + man7/128.0);
    end
    return result;
  endfunction

  // Simple INT8 signed to real conversion
  function automatic real int8_to_real(input logic [7:0] val);
    return $signed(val);
  endfunction

  //===========================================================================
  // 7. Q8.8 FIXED-POINT HELPERS (for EPC model)
  //===========================================================================

  // Convert Q8.8 to real
  function automatic real q8_8_to_real(input logic [15:0] val);
    return $signed(val) / 256.0;
  endfunction

  // Approximate exp() for EPC reference model (Spec ss5.3)
  // Input: Q8.8 fixed-point (always <= 0 in stable softmax)
  function automatic real epc_exp_approx(input logic [15:0] x_q8_8);
    return $exp(q8_8_to_real(x_q8_8));
  endfunction

endpackage : cogniv_common_pkg
`endif // COGNIV_COMMON_PKG_SV
