// =============================================================================
// File:        tb_cx_decode_unit.sv
// Description: Unit testbench for cx_decode_unit
//              Tests: all 5 valid CX opcodes, illegal detection, non-CX reject
// =============================================================================
`timescale 1ns/1ps
module tb_cx_decode_unit;
    logic CLK_CORE=0, RSTN_SYNC=0;
    logic [31:0] instr_word='0; logic instr_valid=0;
    logic [63:0] operand_a='0, operand_b='0;
    logic [2:0]  cx_opcode; logic [8:0] tile_mask;
    logic [63:0] op_a_out, op_b_out;
    logic        decode_valid, illegal_instr;
    always #0.25 CLK_CORE=~CLK_CORE;
    cx_decode_unit dut(.*);
    int pass_cnt=0, fail_cnt=0;
    task automatic chk(string msg,logic got,logic exp);
        if(got===exp) begin $display("PASS [%0t] %s",$time,msg); pass_cnt++; end
        else begin $display("FAIL [%0t] %s: got=%0b exp=%0b",$time,msg,got,exp); fail_cnt++; end
    endtask
    function automatic logic[31:0] make_cx(input logic[2:0] f3);
        return {7'b0,5'b0,5'b0,f3,5'b0,7'b000_1011};
    endfunction
    task automatic drive(input logic[31:0] iw, input logic[63:0] ra, rb);
        @(posedge CLK_CORE); #0.05; instr_word=iw; instr_valid=1; operand_a=ra; operand_b=rb;
        @(posedge CLK_CORE); #0.05; instr_valid=0;
    endtask
    initial begin
        $dumpfile("tb_cx_decode_unit.fst"); $dumpvars(0,tb_cx_decode_unit);
        RSTN_SYNC=0; repeat(4) @(posedge CLK_CORE); RSTN_SYNC=1; repeat(2) @(posedge CLK_CORE);
        for(int op=0;op<=4;op++) begin
            drive(make_cx(3'(op)),64'h1FF,64'hDEAD_BEEF);
            chk($sformatf("op%0d decode_valid",op),decode_valid,1'b1);
            chk($sformatf("op%0d no illegal",op),illegal_instr,1'b0);
            chk($sformatf("op%0d tile_mask=1FF",op),logic'(tile_mask==9'h1FF),1'b1);
        end
        drive(make_cx(3'b101),64'h0,64'h0);
        chk("illegal op5 illegal=1",illegal_instr,1'b1);
        chk("illegal op5 valid=0",decode_valid,1'b0);
        drive(make_cx(3'b111),64'h0,64'h0);
        chk("illegal op7 illegal=1",illegal_instr,1'b1);
        @(posedge CLK_CORE); #0.05; instr_word=32'h0000_0033; instr_valid=1; operand_a=64'h1;
        @(posedge CLK_CORE); #0.05; instr_valid=0;
        chk("non-CX no decode",decode_valid,1'b0);
        @(posedge CLK_CORE); #0.05; instr_word=make_cx(3'b000); instr_valid=0;
        @(posedge CLK_CORE); #0.05;
        chk("instr_valid=0 no decode",decode_valid,1'b0);
        repeat(3) @(posedge CLK_CORE);
        $display("=== tb_cx_decode_unit: PASS=%0d FAIL=%0d ===",pass_cnt,fail_cnt);
        $finish;
    end
    initial begin #2000; $display("TIMEOUT"); $finish; end
endmodule : tb_cx_decode_unit
