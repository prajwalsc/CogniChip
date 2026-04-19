// =============================================================================
// File:        tb_tile_local_ctrl.sv
// Description: Unit testbench for tile_local_ctrl
//              REQ-007: initial state=IDLE, noc_flit_in_rdy=1
//              REQ-023: CX_TILE_CFG writes cfg_reg, stays IDLE, no tile_done
//              TV-007:  BF16 MAC -> tile_done=1, token_id echoed
//              TV-009:  ECC 1-bit -> corrected, tile_done, no tile_error
//              TV-010:  ECC 2-bit -> TLC_ERROR, tile_error=1
// =============================================================================
`timescale 1ns/1ps
module tb_tile_local_ctrl;
    logic CLK_TILE=0, RSTN_TILE=0;
    logic [127:0] noc_flit_in='0; logic noc_flit_in_vld=0, noc_flit_in_rdy;
    logic [127:0] noc_flit_out; logic noc_flit_out_vld, noc_flit_out_rdy=1;
    logic [15:0] sram_addr; logic [31:0] sram_wdata; logic [31:0] sram_rdata='0; logic sram_we;
    logic sram_ecc_err_1b=0, sram_ecc_err_2b=0;
    logic [511:0] mac_weight_data; logic [31:0] mac_act_data;
    logic mac_en, mac_drain; logic [511:0] mac_result='0; logic mac_result_vld=0;
    logic [31:0] cfg_reg; logic tile_done, tile_error; logic [2:0] tlc_state;
    always #0.25 CLK_TILE=~CLK_TILE;
    tile_local_ctrl dut(.*);
    int pass_cnt=0, fail_cnt=0;
    task automatic chk(string msg,logic got,logic exp);
        if(got===exp) begin $display("PASS [%0t] %s",$time,msg); pass_cnt++; end
        else begin $display("FAIL [%0t] %s: got=%0b exp=%0b",$time,msg,got,exp); fail_cnt++; end
    endtask
    task automatic chk3(string msg,logic[2:0] got,logic[2:0] exp);
        if(got===exp) begin $display("PASS [%0t] %s state=%03b",$time,msg,got); pass_cnt++; end
        else begin $display("FAIL [%0t] %s: got=%03b exp=%03b",$time,msg,got,exp); fail_cnt++; end
    endtask
    function automatic logic[127:0] build_pkt(
        input logic[3:0] opc,tid; input logic[15:0] ocfg;
        input logic[31:0] wtag,act,tok);
        logic[127:0] p; p[3:0]=opc; p[7:4]=tid; p[23:8]=ocfg;
        p[55:24]=wtag; p[87:56]=act; p[119:88]=tok; p[123:120]=4'h0; p[127:124]=4'h0;
        p[127:124]={^p[123:93],^p[92:62],^p[61:31],^p[30:0]}; return p;
    endfunction
    task automatic send_flit(input logic[127:0] flit);
        while(!noc_flit_in_rdy) @(posedge CLK_TILE);
        @(posedge CLK_TILE); #0.05; noc_flit_in=flit; noc_flit_in_vld=1;
        @(posedge CLK_TILE); #0.05; noc_flit_in_vld=0; noc_flit_in='0;
    endtask
    task automatic wait_idle(input int to=200);
        int t=0;
        while(tlc_state!=3'b000 && t<to) begin @(posedge CLK_TILE); t++; end
        if(t>=to) begin $display("FAIL wait_idle timeout"); fail_cnt++; end
    endtask
    logic [31:0] token;
    initial begin
        $dumpfile("tb_tile_local_ctrl.fst"); $dumpvars(0,tb_tile_local_ctrl);
        for(int i=0;i<16;i++) mac_result[32*i+:32]=32'h4000_0000;
        RSTN_TILE=0; repeat(8) @(posedge CLK_TILE); RSTN_TILE=1; repeat(3) @(posedge CLK_TILE);
        // REQ-007
        chk3("Init IDLE",tlc_state,3'b000);
        chk("Init rdy=1",noc_flit_in_rdy,1'b1);
        chk("Init tile_done=0",tile_done,1'b0);
        chk("Init tile_error=0",tile_error,1'b0);
        // REQ-023: TILE_CFG
        $display("--- REQ-023 TILE_CFG ---");
        send_flit(build_pkt(4'h0,4'h0,16'hABCD,32'h0,32'h0,32'h0));
        repeat(3) @(posedge CLK_TILE); #0.05;
        chk3("CFG->IDLE",tlc_state,3'b000);
        chk("CFG no tile_done",tile_done,1'b0);
        chk("CFG cfg_reg[15:0]=ABCD",logic'(cfg_reg[15:0]==16'hABCD),1'b1);
        // TV-007: BF16 MAC
        $display("--- TV-007 BF16 MAC ---");
        token=32'hDEAD_0007;
        send_flit(build_pkt(4'h1,4'h0,16'h0000,32'h0010,32'hBF80_3F80,token));
        @(posedge CLK_TILE); #0.05;
        begin int t=0; while(!mac_en && t<50) begin @(posedge CLK_TILE); #0.05; t++; end
            chk("TV-007 mac_en",mac_en,1'b1); end
        @(posedge CLK_TILE); #0.05; mac_result_vld=1;
        @(posedge CLK_TILE); #0.05; mac_result_vld=0;
        begin int t=0; while(!tile_done && t<50) begin @(posedge CLK_TILE); #0.05; t++; end
            chk("TV-007 tile_done",tile_done,1'b1); end
        @(posedge CLK_TILE); #0.05;
        if(noc_flit_out_vld) chk("TV-007 token echo",logic'(noc_flit_out[119:88]==token),1'b1);
        else begin $display("FAIL TV-007 noc_flit_out_vld=0"); fail_cnt++; end
        chk("TV-007 no error",tile_error,1'b0);
        wait_idle(); chk3("TV-007 back IDLE",tlc_state,3'b000);
        repeat(3) @(posedge CLK_TILE);
        // TV-010: ECC 2-bit -> ERROR
        $display("--- TV-010 ECC 2b ---");
        send_flit(build_pkt(4'h1,4'h0,16'h0,32'h0020,32'h0,32'hDEAD_0010));
        repeat(4) @(posedge CLK_TILE); #0.05;
        sram_ecc_err_2b=1; @(posedge CLK_TILE); #0.05; sram_ecc_err_2b=0;
        begin int t=0; while(tlc_state!=3'b111 && t<30) begin @(posedge CLK_TILE); #0.05; t++; end
            chk3("TV-010 ERROR state",tlc_state,3'b111); end
        chk("TV-010 tile_error=1",tile_error,1'b1);
        RSTN_TILE=0; repeat(3) @(posedge CLK_TILE); RSTN_TILE=1; repeat(2) @(posedge CLK_TILE); #0.05;
        chk3("TV-010 RSTN clears",tlc_state,3'b000);
        chk("TV-010 error cleared",tile_error,1'b0);
        // TV-009: ECC 1-bit -> corrected, tile_done
        $display("--- TV-009 ECC 1b ---");
        send_flit(build_pkt(4'h1,4'h0,16'h0,32'h0030,32'h0,32'hDEAD_0009));
        repeat(3) @(posedge CLK_TILE); #0.05;
        sram_ecc_err_1b=1; @(posedge CLK_TILE); #0.05; sram_ecc_err_1b=0;
        mac_result_vld=1; @(posedge CLK_TILE); #0.05; mac_result_vld=0;
        begin int t=0; while(!tile_done && t<50) begin @(posedge CLK_TILE); #0.05; t++; end
            chk("TV-009 tile_done",tile_done,1'b1); end
        chk("TV-009 no tile_error",tile_error,1'b0);
        wait_idle();
        repeat(4) @(posedge CLK_TILE);
        $display("=== tb_tile_local_ctrl: PASS=%0d FAIL=%0d ===",pass_cnt,fail_cnt);
        $finish;
    end
    initial begin #20000; $display("TIMEOUT"); $finish; end
endmodule : tb_tile_local_ctrl
