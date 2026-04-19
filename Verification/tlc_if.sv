// ============================================================================
// FILE       : tlc_if.sv
// PROJECT    : Cogni-V Engine TLC UVM Verification
// SPEC REF   : COGNIV-SPEC-004-MODULE §1.1  (tile_local_ctrl port table)
// CATEGORY   : REUSABLE — sole connection point to DUT; no UVM dependency
// DESCRIPTION: SystemVerilog interface for tile_local_ctrl.
//              Contains clocking blocks for driver (drv_cb) and monitor
//              (mon_cb), plus modports for driver, monitor and DUT.
//              The interface is the ONLY connection point to the DUT.
// ============================================================================

`ifndef TLC_IF_SV
`define TLC_IF_SV

interface tlc_if (input logic CLK_TILE, input logic RSTN_TILE);

  // --------------------------------------------------------------------------
  // NoC flit ports  (Spec §1.1)
  // --------------------------------------------------------------------------
  logic [127:0] noc_flit_in;        // Incoming flit from NoC router
  logic         noc_flit_in_vld;    // Incoming flit valid
  logic         noc_flit_in_rdy;    // TLC ready (asserted only in IDLE)

  logic [127:0] noc_flit_out;       // Outgoing result flit
  logic         noc_flit_out_vld;   // Result flit valid (RESULT_TX state)
  logic         noc_flit_out_rdy;   // NoC ready to accept result

  // --------------------------------------------------------------------------
  // SRAM ports  (Spec §3.1)
  // --------------------------------------------------------------------------
  logic [15:0]  sram_addr;          // SRAM word address [15:0]
  logic [31:0]  sram_wdata;         // SRAM write data
  logic [31:0]  sram_rdata;         // SRAM read data (1-cycle registered latency)
  logic         sram_we;            // SRAM write enable
  logic         sram_ecc_err_1b;    // SECDED 1-bit correctable error
  logic         sram_ecc_err_2b;    // SECDED 2-bit uncorrectable error

  // --------------------------------------------------------------------------
  // MAC array ports  (Spec §2.1)
  // --------------------------------------------------------------------------
  logic [511:0] mac_weight_data;    // 16 × 32-bit weight bus to MAC array
  logic [31:0]  mac_act_data;       // 32-bit activation broadcast to all 16 lanes
  logic         mac_en;             // MAC execute enable
  logic         mac_drain;          // Accumulator drain command
  logic [511:0] mac_result;         // 16 × 32-bit MAC results
  logic         mac_result_vld;     // MAC result valid

  // --------------------------------------------------------------------------
  // Control / status  (Spec §1.1)
  // --------------------------------------------------------------------------
  logic [31:0]  cfg_reg;            // Tile configuration register output
  logic         tile_done;          // Computation complete
  logic         tile_error;         // Error flag (ECC 2-bit or parity)
  logic [2:0]   tlc_state;          // FSM state (debug scan chain)

  // --------------------------------------------------------------------------
  // DRIVER clocking block
  //   default output skew: #1 before posedge (avoids hold violations)
  //   default input skew:  #1step (sample just before posedge)
  // --------------------------------------------------------------------------
  clocking drv_cb @(posedge CLK_TILE);
    default input #1step output #1;

    // Signals driven by testbench (DUT inputs)
    output noc_flit_in;
    output noc_flit_in_vld;
    output noc_flit_out_rdy;
    output sram_rdata;
    output sram_ecc_err_1b;
    output sram_ecc_err_2b;
    output mac_result;
    output mac_result_vld;

    // Signals read by driver (DUT outputs — for handshaking)
    input  noc_flit_in_rdy;
    input  noc_flit_out;
    input  noc_flit_out_vld;
    input  sram_addr;
    input  sram_wdata;
    input  sram_we;
    input  mac_weight_data;
    input  mac_act_data;
    input  mac_en;
    input  mac_drain;
    input  cfg_reg;
    input  tile_done;
    input  tile_error;
    input  tlc_state;
  endclocking : drv_cb

  // --------------------------------------------------------------------------
  // MONITOR clocking block — all signals sampled #1step before posedge
  // --------------------------------------------------------------------------
  clocking mon_cb @(posedge CLK_TILE);
    default input #1step;

    input  noc_flit_in;
    input  noc_flit_in_vld;
    input  noc_flit_in_rdy;
    input  noc_flit_out;
    input  noc_flit_out_vld;
    input  noc_flit_out_rdy;
    input  sram_addr;
    input  sram_wdata;
    input  sram_rdata;
    input  sram_we;
    input  sram_ecc_err_1b;
    input  sram_ecc_err_2b;
    input  mac_weight_data;
    input  mac_act_data;
    input  mac_en;
    input  mac_drain;
    input  mac_result;
    input  mac_result_vld;
    input  cfg_reg;
    input  tile_done;
    input  tile_error;
    input  tlc_state;
  endclocking : mon_cb

  // --------------------------------------------------------------------------
  // MODPORTS
  // --------------------------------------------------------------------------

  // Driver modport — used by UVM driver
  modport drv_mp (
    clocking drv_cb,
    input    CLK_TILE, RSTN_TILE
  );

  // Monitor modport — used by UVM monitor
  modport mon_mp (
    clocking mon_cb,
    input    CLK_TILE, RSTN_TILE
  );

  // DUT modport — connects to tile_local_ctrl (enable with RTL)
  modport dut_mp (
    input  CLK_TILE, RSTN_TILE,
    // DUT inputs (driven by TB in pre-RTL mode)
    input  noc_flit_in, noc_flit_in_vld, noc_flit_out_rdy,
    input  sram_rdata, sram_ecc_err_1b, sram_ecc_err_2b,
    input  mac_result, mac_result_vld,
    // DUT outputs (driven by DUT; observed by monitor)
    output noc_flit_in_rdy, noc_flit_out, noc_flit_out_vld,
    output sram_addr, sram_wdata, sram_we,
    output mac_weight_data, mac_act_data, mac_en, mac_drain,
    output cfg_reg, tile_done, tile_error, tlc_state
  );

endinterface : tlc_if

`endif // TLC_IF_SV
