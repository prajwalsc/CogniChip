// =============================================================================
// Module:      tile_local_ctrl
// Description: Tile Local Controller FSM
//              Cogni-V Engine — COGNIV-SPEC-004-MODULE v1.0, Section 1
// =============================================================================

module tile_local_ctrl (
    input  logic        CLK_TILE,
    input  logic        RSTN_TILE,

    // NoC flit interface
    input  logic [127:0] noc_flit_in,
    input  logic         noc_flit_in_vld,
    output logic         noc_flit_in_rdy,
    output logic [127:0] noc_flit_out,
    output logic         noc_flit_out_vld,
    input  logic         noc_flit_out_rdy,

    // SRAM interface
    output logic [15:0]  sram_addr,
    output logic [31:0]  sram_wdata,
    input  logic [31:0]  sram_rdata,
    output logic         sram_we,
    input  logic         sram_ecc_err_1b,
    input  logic         sram_ecc_err_2b,

    // MAC array interface
    output logic [511:0] mac_weight_data,
    output logic [31:0]  mac_act_data,
    output logic         mac_en,
    output logic         mac_drain,
    input  logic [511:0] mac_result,
    input  logic         mac_result_vld,

    // Configuration and status
    output logic [31:0]  cfg_reg,
    output logic         tile_done,
    output logic         tile_error,
    output logic [2:0]   tlc_state
);

    // -------------------------------------------------------------------------
    // FSM State Encoding (Section 1.2)
    // -------------------------------------------------------------------------
    localparam logic [2:0] ST_IDLE      = 3'b000;
    localparam logic [2:0] ST_CFG       = 3'b001;
    localparam logic [2:0] ST_MAC_LOAD  = 3'b010;
    localparam logic [2:0] ST_MAC_EXEC  = 3'b011;
    localparam logic [2:0] ST_MAC_DRAIN = 3'b100;
    localparam logic [2:0] ST_RESULT_TX = 3'b101;
    // 3'b110 unused — redirect to ERROR
    localparam logic [2:0] ST_ERROR     = 3'b111;

    // -------------------------------------------------------------------------
    // Internal registers
    // -------------------------------------------------------------------------
    logic [2:0]   state_r, state_next;

    // Latched packet fields (Section 1.4)
    logic [3:0]   opcode_r;
    logic [3:0]   tile_id_r;
    logic [31:0]  weight_tag_r;     // [55:24] of flit → sram_addr base
    logic [31:0]  act_data_r;       // [87:56] of flit
    logic [31:0]  token_id_r;       // [119:88] of flit

    // SRAM read-valid tracking (1-cycle registered latency)
    logic         sram_rd_pending_r;
    logic         sram_read_valid;

    // Output result register file
    logic [511:0] result_reg_r;

    // -------------------------------------------------------------------------
    // Packet field extraction (Section 1.4)
    // -------------------------------------------------------------------------
    wire [3:0]   pkt_opcode    = noc_flit_in[3:0];
    wire [3:0]   pkt_tile_id   = noc_flit_in[7:4];
    wire [31:0]  pkt_weight_tag = noc_flit_in[55:24];
    wire [31:0]  pkt_act_data  = noc_flit_in[87:56];
    wire [31:0]  pkt_token_id  = noc_flit_in[119:88];

    // -------------------------------------------------------------------------
    // SRAM read-valid: one clock after address is driven
    // -------------------------------------------------------------------------
    always_ff @(posedge CLK_TILE) begin
        if (!RSTN_TILE)
            sram_rd_pending_r <= 1'b0;
        else
            sram_rd_pending_r <= (state_r == ST_MAC_LOAD);
    end
    assign sram_read_valid = sram_rd_pending_r;

    // -------------------------------------------------------------------------
    // FSM next-state logic (Section 1.3)
    // -------------------------------------------------------------------------
    always_comb begin
        state_next = state_r;
        case (state_r)
            ST_IDLE: begin
                if (noc_flit_in_vld) begin
                    if (pkt_opcode == 4'hF)
                        state_next = ST_CFG;
                    else if (pkt_opcode == 4'h0)
                        state_next = ST_MAC_LOAD;
                    // opcode mismatch / tile_id mismatch → stay IDLE (drop)
                end
            end

            ST_CFG: begin
                // 1-cycle config write, unconditionally return to IDLE
                state_next = ST_IDLE;
            end

            ST_MAC_LOAD: begin
                if (sram_ecc_err_2b)
                    state_next = ST_ERROR;
                else if (sram_read_valid)
                    state_next = ST_MAC_EXEC;
            end

            ST_MAC_EXEC: begin
                if (opcode_r == 4'h2)
                    state_next = ST_MAC_DRAIN;
                else
                    state_next = ST_MAC_LOAD;
            end

            ST_MAC_DRAIN: begin
                if (mac_result_vld)
                    state_next = ST_RESULT_TX;
            end

            ST_RESULT_TX: begin
                if (noc_flit_out_rdy)
                    state_next = ST_IDLE;
            end

            ST_ERROR: begin
                // Sticky — only reset clears it (handled in sequential block)
                state_next = ST_ERROR;
            end

            default: begin
                // Unused encoding 3'b110 → ERROR
                state_next = ST_ERROR;
            end
        endcase
    end

    // -------------------------------------------------------------------------
    // FSM sequential state register
    // -------------------------------------------------------------------------
    always_ff @(posedge CLK_TILE) begin
        if (!RSTN_TILE)
            state_r <= ST_IDLE;
        else
            state_r <= state_next;
    end

    // -------------------------------------------------------------------------
    // Packet latch on IDLE → CFG/MAC_LOAD transition
    // -------------------------------------------------------------------------
    always_ff @(posedge CLK_TILE) begin
        if (!RSTN_TILE) begin
            opcode_r     <= 4'h0;
            tile_id_r    <= 4'h0;
            weight_tag_r <= 32'h0;
            act_data_r   <= 32'h0;
            token_id_r   <= 32'h0;
        end else if ((state_r == ST_IDLE) && noc_flit_in_vld) begin
            opcode_r     <= pkt_opcode;
            tile_id_r    <= pkt_tile_id;
            weight_tag_r <= pkt_weight_tag;
            act_data_r   <= pkt_act_data;
            token_id_r   <= pkt_token_id;
        end
    end

    // -------------------------------------------------------------------------
    // WEIGHT_TAG auto-increment in MAC_EXEC (increment by 16 per loop)
    // -------------------------------------------------------------------------
    always_ff @(posedge CLK_TILE) begin
        if (!RSTN_TILE)
            weight_tag_r <= 32'h0;
        else if ((state_r == ST_IDLE) && noc_flit_in_vld)
            weight_tag_r <= pkt_weight_tag;
        else if (state_r == ST_MAC_EXEC && opcode_r != 4'h2)
            weight_tag_r <= weight_tag_r + 32'd16;
    end

    // -------------------------------------------------------------------------
    // cfg_reg update in CFG state
    // -------------------------------------------------------------------------
    always_ff @(posedge CLK_TILE) begin
        if (!RSTN_TILE)
            cfg_reg <= 32'h0;
        else if (state_r == ST_CFG)
            cfg_reg <= noc_flit_in[31:0]; // lower 32 bits carry config payload
    end

    // -------------------------------------------------------------------------
    // Result register file — latch mac_result in MAC_DRAIN
    // -------------------------------------------------------------------------
    always_ff @(posedge CLK_TILE) begin
        if (!RSTN_TILE)
            result_reg_r <= 512'h0;
        else if ((state_r == ST_MAC_DRAIN) && mac_result_vld)
            result_reg_r <= mac_result;
    end

    // -------------------------------------------------------------------------
    // Output assignments — combinatorial decode of state
    // -------------------------------------------------------------------------

    // NoC ready: only in IDLE
    assign noc_flit_in_rdy = (state_r == ST_IDLE);

    // SRAM address driven from weight_tag_r[15:0]; no write from TLC (weights
    // come via DMA / CFG path, sram_we only asserted during DMA — simplified
    // here to never write during normal MAC operation)
    assign sram_addr  = weight_tag_r[15:0];
    assign sram_wdata = 32'h0;  // write data driven by DMA path (not shown)
    assign sram_we    = 1'b0;   // no write during MAC flow

    // MAC control
    assign mac_en        = (state_r == ST_MAC_EXEC);
    assign mac_drain     = (state_r == ST_MAC_DRAIN);
    assign mac_weight_data = {16{sram_rdata}};  // broadcast 32-bit word to all 16 lanes
    assign mac_act_data  = act_data_r;

    // Result flit output (assemble: token_id echoed, result data)
    assign noc_flit_out     = {token_id_r, result_reg_r[95:0]};  // simplified assembly
    assign noc_flit_out_vld = (state_r == ST_RESULT_TX);

    // Status outputs
    assign tile_done  = (state_r == ST_RESULT_TX) && noc_flit_out_rdy;
    assign tile_error = (state_r == ST_ERROR);
    assign tlc_state  = state_r;

endmodule
