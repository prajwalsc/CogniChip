// ============================================================================
// FILE       : tlc_dut_stub.sv
// PROJECT    : Cogni-V Engine TLC UVM Verification
// SPEC REF   : COGNIV-SPEC-004-MODULE ss1 (tile_local_ctrl)
// CATEGORY   : [MODULE-SPECIFIC] Behavioral stub — PRE-RTL MODE ONLY
//
// PURPOSE    : This stub implements the spec-defined TLC FSM behavior
//              (Spec ss1.2/ss1.3) in behavioural SystemVerilog.
//              It connects to the same tlc_if interface as the real DUT.
//              Remove this stub and enable the real RTL DUT when RTL is ready.
//
// PRE-RTL MODE  : tlc_dut_stub is instantiated in tlc_tb_top.sv
// POST-RTL MODE : Comment out stub; uncomment tile_local_ctrl instantiation
// ============================================================================
`ifndef TLC_DUT_STUB_SV
`define TLC_DUT_STUB_SV

import cogniv_common_pkg::*;

module tlc_dut_stub #(
  parameter logic [3:0] TILE_ID = 4'h0  // Local tile ID for TILE_ID check
) (
  input  logic CLK_TILE,
  input  logic RSTN_TILE,
  // NoC flit interface
  input  logic [127:0] noc_flit_in,
  input  logic         noc_flit_in_vld,
  output logic         noc_flit_in_rdy,
  output logic [127:0] noc_flit_out,
  output logic         noc_flit_out_vld,
  input  logic         noc_flit_out_rdy,
  // SRAM interface (stub ignores sram_addr/wdata; sram_rdata driven by driver)
  output logic [15:0]  sram_addr,
  output logic [31:0]  sram_wdata,
  input  logic [31:0]  sram_rdata,
  output logic         sram_we,
  input  logic         sram_ecc_err_1b,
  input  logic         sram_ecc_err_2b,
  // MAC interface (stub ignores mac_weight_data; mac_result driven by driver)
  output logic [511:0] mac_weight_data,
  output logic [31:0]  mac_act_data,
  output logic         mac_en,
  output logic         mac_drain,
  input  logic [511:0] mac_result,
  input  logic         mac_result_vld,
  // Status
  output logic [31:0]  cfg_reg,
  output logic         tile_done,
  output logic         tile_error,
  output logic [2:0]   tlc_state
);

  // ---- Internal FSM state (Spec ss1.2) ----
  tlc_state_e state_r, state_nxt;

  // Latched packet fields
  logic [3:0]  lat_opcode;
  logic [31:0] lat_weight_tag;
  logic [31:0] lat_act_data_r;
  logic [31:0] lat_token_id;
  logic [31:0] cfg_reg_r;

  // SRAM read pipeline register (1-cycle latency Spec ss3.2)
  logic [15:0] sram_addr_r;
  logic        sram_read_pending;

  // Result flit register
  logic [127:0] result_flit_r;

  // ---- State register ----
  always_ff @(posedge CLK_TILE) begin
    if (!RSTN_TILE) begin
      state_r         <= TLC_IDLE;
      lat_opcode      <= 4'h0;
      lat_weight_tag  <= 32'h0;
      lat_act_data_r  <= 32'h0;
      lat_token_id    <= 32'h0;
      cfg_reg_r       <= 32'h0;
      sram_addr_r     <= 16'h0;
      sram_read_pending <= 1'b0;
      result_flit_r   <= 128'h0;
    end else begin
      state_r <= state_nxt;
      case (state_r)
        TLC_IDLE: begin
          if (noc_flit_in_vld) begin
            lat_opcode     <= noc_flit_in[3:0];
            lat_weight_tag <= noc_flit_in[55:24];
            lat_act_data_r <= noc_flit_in[87:56];
            lat_token_id   <= noc_flit_in[119:88];
          end
        end
        TLC_CFG: begin
          // Write configuration register (Spec ss1.3 CFG row)
          cfg_reg_r <= {15'h0, noc_flit_in[23:8]};
        end
        TLC_MAC_LOAD: begin
          sram_addr_r <= lat_weight_tag[15:0];
          sram_read_pending <= 1'b1;
        end
        TLC_MAC_EXEC: begin
          sram_read_pending <= 1'b0;
          // Auto-increment weight_tag for next SRAM read (Spec ss1.3)
          lat_weight_tag <= lat_weight_tag + 32'd16;
        end
        TLC_MAC_DRAIN: begin
          // Latch result flit; echo TOKEN_ID in [119:88] (Spec ss1.4)
          result_flit_r[127:120] <= 8'h0;
          result_flit_r[119:88]  <= lat_token_id;
          result_flit_r[87:0]    <= mac_result[511:424];
        end
        default: begin end
      endcase
    end
  end

  // ---- Next-state logic (Spec ss1.3 state transition table) ----
  always_comb begin
    state_nxt = state_r;
    case (state_r)
      TLC_IDLE: begin
        if (noc_flit_in_vld) begin
          if (noc_flit_in[7:4] !== TILE_ID) begin
            // TILE_ID mismatch: drop (Spec ss1.4)
            state_nxt = TLC_IDLE;
          end else begin
            case (noc_flit_in[3:0])
              4'hF: state_nxt = TLC_CFG;
              4'h0, 4'h1: state_nxt = TLC_MAC_LOAD;
              4'h2: state_nxt = TLC_MAC_DRAIN;
              default: state_nxt = TLC_IDLE;
            endcase
          end
        end
      end
      TLC_CFG:      state_nxt = TLC_IDLE;  // 1-cycle (Spec ss1.3)
      TLC_MAC_LOAD: begin
        if (sram_ecc_err_2b) begin
          state_nxt = TLC_ERROR;           // Spec ss3.4 / ss1.3
        end else begin
          state_nxt = TLC_MAC_EXEC;        // SRAM read valid next cycle
        end
      end
      TLC_MAC_EXEC: begin
        // In stub: single MAC cycle then drain
        state_nxt = TLC_MAC_DRAIN;
      end
      TLC_MAC_DRAIN: begin
        if (mac_result_vld) begin
          state_nxt = TLC_RESULT_TX;
        end
      end
      TLC_RESULT_TX: begin
        if (noc_flit_out_rdy) begin
          state_nxt = TLC_IDLE;
        end
      end
      TLC_ERROR: begin
        state_nxt = TLC_ERROR;  // Stays until RSTN_TILE
      end
      default: state_nxt = TLC_ERROR; // State 3'b110 invalid (Spec ss1.2)
    endcase
  end

  // ---- Output assignments (Spec ss1.2 output table) ----
  // noc_flit_in_rdy: only asserted in IDLE
  assign noc_flit_in_rdy = (state_r == TLC_IDLE);

  // sram_addr: driven in MAC_LOAD
  assign sram_addr  = (state_r == TLC_MAC_LOAD) ? lat_weight_tag[15:0] : 16'h0;
  assign sram_wdata = 32'h0;  // Stub does not perform DMA writes
  assign sram_we    = 1'b0;

  // MAC datapath outputs
  assign mac_weight_data = (state_r == TLC_MAC_EXEC) ? {16{sram_rdata}} : 512'h0;
  assign mac_act_data    = (state_r == TLC_MAC_EXEC) ? lat_act_data_r : 32'h0;
  assign mac_en          = (state_r == TLC_MAC_EXEC);
  assign mac_drain       = (state_r == TLC_MAC_DRAIN);

  // Result flit
  assign noc_flit_out     = result_flit_r;
  assign noc_flit_out_vld = (state_r == TLC_RESULT_TX);

  // Configuration register
  assign cfg_reg = cfg_reg_r;

  // Status outputs
  assign tile_done  = (state_r == TLC_RESULT_TX) && noc_flit_out_rdy;
  assign tile_error = (state_r == TLC_ERROR);
  assign tlc_state  = state_r;

endmodule : tlc_dut_stub

`endif // TLC_DUT_STUB_SV
