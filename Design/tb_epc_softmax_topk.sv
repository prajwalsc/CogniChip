// =============================================================================
// File:        tb_epc_softmax_topk.sv
// Description: Unit testbench for epc_softmax_topk
//              TV-004: K=1 -> exactly 1 bit set, correct expert selected
//              TV-005: K=2 -> exactly 2 bits set
//              TV-006: K=2 tie -> lower index wins, topk_tie=1
//              REQ-018: latency == 18 cycles exactly
// =============================================================================
`timescale 1ns/1ps
module tb_epc_softmax_topk;
    logic CLK_TILE=0, RSTN_TILE=0, eval_start=0;
    logic [1:0] k_cfg=2'b01;
    logic signed [15:0] logit_in[0:8];
    logic [8:0] gate_out; logic gate_out_valid, topk_tie, invalid_k;
    logic [8:0] icg_enable;
    always #0.25 CLK_TILE=~CLK_TILE;
    epc_softmax_topk dut(.*);
    int pass_cnt=0, fail_cnt=0;
    task automatic chk(string msg,logic got,logic exp);
        if(got===exp) begin $display("PASS [%0t] %s",$time,msg); pass_cnt++; end
        else begin $display("FAIL [%0t] %s: got=%0b exp=%0b",$time,msg,got,exp); fail_cnt++; end
    endtask
    task automatic run_eval(input logic signed[15:0] logits[0:8], input logic[1:0] k, output int lat);
        int c=0;
        for(int i=0;i<9;i++) logit_in[i]=logits[i]; k_cfg=k;
        @(posedge CLK_TILE); #0.05; eval_start=1;
        @(posedge CLK_TILE); #0.05; eval_start=0; c=1;
        @(posedge CLK_TILE); #0.05;
        while(!gate_out_valid) begin @(posedge CLK_TILE); #0.05; c++;
            if(c>50) begin $display("FAIL timeout"); fail_cnt++; lat=c; return; end end
        lat=c;
    endtask
    logic signed[15:0] lg[0:8]; int lat;
    initial begin
        $dumpfile("tb_epc_softmax_topk.fst"); $dumpvars(0,tb_epc_softmax_topk);
        for(int i=0;i<9;i++) logit_in[i]=16'h0;
        RSTN_TILE=0; repeat(5) @(posedge CLK_TILE); RSTN_TILE=1; repeat(3) @(posedge CLK_TILE);
        // TV-004: K=1, expert 5 highest (10.0)
        $display("--- TV-004 K=1 expert5 highest ---");
        lg[0]=16'h0100;lg[1]=16'h0200;lg[2]=16'h0300;lg[3]=16'h0100;lg[4]=16'h0400;
        lg[5]=16'h0A00;lg[6]=16'h0200;lg[7]=16'h0300;lg[8]=16'h0100;
        run_eval(lg,2'b01,lat);
        $display("TV-004 latency=%0d",lat);
        chk("TV-004 lat==18",logic'(lat==18),1'b1);
        chk("TV-004 countones=1",logic'($countones(gate_out)==1),1'b1);
        chk("TV-004 gate[5]",gate_out[5],1'b1);
        chk("TV-004 icg==gate",logic'(icg_enable==gate_out),1'b1);
        chk("TV-004 no tie",topk_tie,1'b0);
        chk("TV-004 valid_k",invalid_k,1'b0);
        repeat(3) @(posedge CLK_TILE);
        // TV-005: K=2, expert 4 (9.0) and expert 2 (8.0)
        $display("--- TV-005 K=2 experts 4&2 ---");
        lg[0]=16'h0100;lg[1]=16'h0100;lg[2]=16'h0800;lg[3]=16'h0100;lg[4]=16'h0900;
        lg[5]=16'h0200;lg[6]=16'h0100;lg[7]=16'h0300;lg[8]=16'h0200;
        run_eval(lg,2'b10,lat);
        chk("TV-005 lat==18",logic'(lat==18),1'b1);
        chk("TV-005 countones=2",logic'($countones(gate_out)==2),1'b1);
        chk("TV-005 gate[4]",gate_out[4],1'b1);
        chk("TV-005 gate[2]",gate_out[2],1'b1);
        chk("TV-005 no tie",topk_tie,1'b0);
        repeat(3) @(posedge CLK_TILE);
        // TV-006: K=2 tie, experts 0&1 equal highest
        $display("--- TV-006 K=2 tie expert0+1 ---");
        lg[0]=16'h0A00;lg[1]=16'h0A00;lg[2]=16'h0100;lg[3]=16'h0100;lg[4]=16'h0200;
        lg[5]=16'h0100;lg[6]=16'h0100;lg[7]=16'h0100;lg[8]=16'h0100;
        run_eval(lg,2'b10,lat);
        chk("TV-006 countones=2",logic'($countones(gate_out)==2),1'b1);
        chk("TV-006 gate[0]",gate_out[0],1'b1);
        chk("TV-006 gate[1]",gate_out[1],1'b1);
        chk("TV-006 topk_tie=1",topk_tie,1'b1);
        repeat(3) @(posedge CLK_TILE);
        // Invalid k
        for(int i=0;i<9;i++) lg[i]=16'h0200;
        run_eval(lg,2'b11,lat);
        chk("invalid_k=1 for k=3",invalid_k,1'b1);
        repeat(3) @(posedge CLK_TILE);
        $display("=== tb_epc_softmax_topk: PASS=%0d FAIL=%0d ===",pass_cnt,fail_cnt);
        $finish;
    end
    initial begin #10000; $display("TIMEOUT"); $finish; end
endmodule : tb_epc_softmax_topk
