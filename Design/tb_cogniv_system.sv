// =============================================================================
// File:        tb_cogniv_system.sv
// Description: Simple system-level testbench for cogniv_system
//              Tests: reset, CX decode, CLB→Tile4 MAC dispatch
// =============================================================================
`timescale 1ns/1ps

module tb_cogniv_system;

    // -------------------------------------------------------------------------
    // Clock half-periods
    // -------------------------------------------------------------------------
    localparam real T_CORE = 5.0;   // 100 MHz
    localparam real T_TILE = 4.0;   // 125 MHz
    localparam real T_NOC  = 3.0;   // ~167 MHz

    // -------------------------------------------------------------------------
    // DUT signals
    // -------------------------------------------------------------------------
    logic        CLK_CORE = 0, RSTN_CORE = 0;
    logic        CLK_TILE = 0, RSTN_TILE = 0;
    logic        CLK_NOC  = 0, RSTN_NOC  = 0;

    logic [31:0] cx_instr_word  = 0;
    logic        cx_instr_valid = 0;
    logic [63:0] cx_operand_a   = 0;
    logic [63:0] cx_operand_b   = 0;

    logic [63:0] clb_pkt_hi_in  = 0;
    logic [63:0] clb_pkt_lo_in  = 0;
    logic [8:0]  clb_pkt_hi_wr  = 0;
    logic [8:0]  clb_pkt_lo_wr  = 0;
    logic [8:0]  clb_tile_ack   = 9'h1FF; // always return credits

    logic        epc_eval_start = 0;
    logic [1:0]  epc_k_cfg      = 2'd1;
    logic signed [15:0] epc_logit_in [0:8];

    // scan_te=1 bypasses ICG gates → tiles run on CLK_TILE during test
    logic        scan_te = 1;

    logic [8:0]  tile_done, tile_error;
    logic [8:0]  clb_stall, clb_overflow_err, clb_parity_err;
    logic [2:0]  cx_opcode;
    logic [8:0]  cx_tile_mask;
    logic        cx_decode_valid, cx_illegal_instr;
    logic [8:0]  epc_gate_out;
    logic        epc_gate_out_valid, epc_topk_tie, epc_invalid_k;

    // -------------------------------------------------------------------------
    // DUT instantiation
    // -------------------------------------------------------------------------
    cogniv_system dut (
        .CLK_CORE          (CLK_CORE),
        .RSTN_CORE         (RSTN_CORE),
        .CLK_TILE          (CLK_TILE),
        .RSTN_TILE         (RSTN_TILE),
        .CLK_NOC           (CLK_NOC),
        .RSTN_NOC          (RSTN_NOC),
        .cx_instr_word     (cx_instr_word),
        .cx_instr_valid    (cx_instr_valid),
        .cx_operand_a      (cx_operand_a),
        .cx_operand_b      (cx_operand_b),
        .clb_pkt_hi_in     (clb_pkt_hi_in),
        .clb_pkt_lo_in     (clb_pkt_lo_in),
        .clb_pkt_hi_wr     (clb_pkt_hi_wr),
        .clb_pkt_lo_wr     (clb_pkt_lo_wr),
        .clb_tile_ack      (clb_tile_ack),
        .epc_eval_start    (epc_eval_start),
        .epc_k_cfg         (epc_k_cfg),
        .epc_logit_in      (epc_logit_in),
        .tile_done         (tile_done),
        .tile_error        (tile_error),
        .clb_stall         (clb_stall),
        .clb_overflow_err  (clb_overflow_err),
        .clb_parity_err    (clb_parity_err),
        .cx_opcode         (cx_opcode),
        .cx_tile_mask      (cx_tile_mask),
        .cx_decode_valid   (cx_decode_valid),
        .cx_illegal_instr  (cx_illegal_instr),
        .epc_gate_out      (epc_gate_out),
        .epc_gate_out_valid(epc_gate_out_valid),
        .epc_topk_tie      (epc_topk_tie),
        .epc_invalid_k     (epc_invalid_k),
        .scan_te           (scan_te)
    );

    // -------------------------------------------------------------------------
    // Clocks
    // -------------------------------------------------------------------------
    always #(T_CORE) CLK_CORE = ~CLK_CORE;
    always #(T_TILE) CLK_TILE = ~CLK_TILE;
    always #(T_NOC)  CLK_NOC  = ~CLK_NOC;

    // -------------------------------------------------------------------------
    // Test counters
    // -------------------------------------------------------------------------
    int pass_cnt = 0, fail_cnt = 0;

    // -------------------------------------------------------------------------
    // EPC logit default (all zero)
    // -------------------------------------------------------------------------
    initial begin
        for (int i = 0; i < 9; i++) begin
            epc_logit_in[i] = 16'sh0000;
        end
    end

    // -------------------------------------------------------------------------
    // Tasks
    // -------------------------------------------------------------------------
    task automatic apply_reset();
        RSTN_CORE = 0; RSTN_TILE = 0; RSTN_NOC = 0;
        repeat(8) @(posedge CLK_NOC);
        @(posedge CLK_TILE);
        RSTN_CORE = 1; RSTN_TILE = 1; RSTN_NOC = 1;
        repeat(4) @(posedge CLK_TILE);
    endtask

    task automatic chk(input string name, input logic got, input logic exp);
        if (got === exp) begin
            $display("PASS [%0t] %s", $time, name);
            pass_cnt++;
        end else begin
            $display("LOG: %0t : ERROR : tb_cogniv_system : dut.%s : expected_value: %0b actual_value: %0b",
                     $time, name, exp, got);
            $display("ERROR");
            fail_cnt++;
        end
    endtask

    // Build a CX instruction: opcode in funct3 [14:12], opcode 7'b000_1011 (custom-0)
    function automatic logic [31:0] make_cx(input logic [2:0] f3);
        return {7'b0, 5'b0, 5'b0, f3, 5'b0, 7'b000_1011};
    endfunction

    // -------------------------------------------------------------------------
    // Main test
    // -------------------------------------------------------------------------
    initial begin
        $display("TEST START");

        // =====================================================================
        // TC-SYS-001: Reset check
        // =====================================================================
        $display("--- TC-SYS-001 Reset Check ---");
        apply_reset();

        chk("TC-SYS-001 tile_done=0   after reset", |tile_done,       1'b0);
        chk("TC-SYS-001 tile_error=0  after reset", |tile_error,      1'b0);
        chk("TC-SYS-001 cx_decode_valid=0",          cx_decode_valid,  1'b0);
        chk("TC-SYS-001 cx_illegal_instr=0",         cx_illegal_instr, 1'b0);

        // =====================================================================
        // TC-SYS-002: CX instruction decode
        // Opcode=1 (f3=3'b001), tile_mask=9'h1FF (all tiles), valid CX op
        // =====================================================================
        $display("--- TC-SYS-002 CX Decode ---");
        @(posedge CLK_CORE);
        cx_instr_word  = make_cx(3'b001); // CX opcode 1
        cx_operand_a   = 64'h0000_01FF;   // tile_mask = all 9 tiles
        cx_operand_b   = 64'h0;
        cx_instr_valid = 1'b1;
        @(posedge CLK_CORE);
        cx_instr_valid = 1'b0;
        cx_instr_word  = 0;
        @(posedge CLK_CORE); // one more cycle for output register
        chk("TC-SYS-002 cx_decode_valid=1",  cx_decode_valid,  1'b1);
        chk("TC-SYS-002 cx_illegal_instr=0", cx_illegal_instr, 1'b0);
        chk("TC-SYS-002 cx_tile_mask=1FF",   logic'(cx_tile_mask == 9'h1FF), 1'b1);

        // =====================================================================
        // TC-SYS-003: CLB dispatch MAC micro-op to Tile 4 (center tile)
        //
        // Packet format (128-bit):
        //   [3:0]    opcode    = 4'h1  (MAC op)
        //   [7:4]    tile_id   = 4'h4  (tile 4)
        //   [23:8]   op_cfg    = 16'h0
        //   [55:24]  weight_tag= 32'h0
        //   [87:56]  act_data  = 32'h0
        //   [119:88] token_id  = 32'h0
        //   [123:120] rsvd     = 4'h0
        //   [127:124] parity   = XOR nibbles[123:0] = 4'h1 ^ 4'h4 = 4'h5
        //
        //   pkt_hi = pkt[127:64] = 64'h5000_0000_0000_0000
        //   pkt_lo = pkt[63:0]   = 64'h0000_0000_0000_0041
        // =====================================================================
        $display("--- TC-SYS-003 CLB->Tile4 MAC Dispatch ---");

        repeat(2) @(posedge CLK_NOC);

        // Write hi half for tile 4
        clb_pkt_hi_in = 64'h5000_0000_0000_0000;
        clb_pkt_hi_wr = 9'b0_0001_0000; // bit 4
        @(posedge CLK_NOC);
        clb_pkt_hi_wr = 9'h0;

        // Write lo half for tile 4
        clb_pkt_lo_in = 64'h0000_0000_0000_0041;
        clb_pkt_lo_wr = 9'b0_0001_0000; // bit 4
        @(posedge CLK_NOC);
        clb_pkt_lo_wr = 9'h0;

        // Wait for tile_done[4] with 500-cycle timeout
        fork
            begin : wait_done
                wait (tile_done[4] === 1'b1);
            end
            begin : timeout_done
                repeat(500) @(posedge CLK_TILE);
                $display("LOG: %0t : WARNING : tb_cogniv_system : dut.tile_done[4] : expected_value: 1 actual_value: 0",
                         $time);
            end
        join_any
        disable fork;

        chk("TC-SYS-003 tile_done[4]=1",  tile_done[4],  1'b1);
        chk("TC-SYS-003 tile_error[4]=0", tile_error[4], 1'b0);

        // =====================================================================
        // Summary
        // =====================================================================
        repeat(4) @(posedge CLK_TILE);
        $display("=== tb_cogniv_system: PASS=%0d FAIL=%0d ===", pass_cnt, fail_cnt);
        if (fail_cnt == 0) begin
            $display("TEST PASSED");
        end else begin
            $display("TEST FAILED");
            $error("System-level test had %0d failure(s)", fail_cnt);
        end
        $finish;
    end

    // -------------------------------------------------------------------------
    // Simulation watchdog
    // -------------------------------------------------------------------------
    initial begin
        #200000;
        $display("LOG: %0t : ERROR : tb_cogniv_system : watchdog : expected_value: finish actual_value: timeout",
                 $time);
        $display("TEST FAILED");
        $fatal(1, "Simulation watchdog timeout at 200us");
    end

    // -------------------------------------------------------------------------
    // Waveform dump
    // -------------------------------------------------------------------------
    initial begin
        $dumpfile("dumpfile.fst");
        $dumpvars(0);
    end

endmodule : tb_cogniv_system
