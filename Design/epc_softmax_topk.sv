// =============================================================================
// Module:      epc_softmax_topk
// Description: Expert Policy Controller — Numerically-stable softmax Top-K
//              Cogni-V Engine — COGNIV-SPEC-001 ss5 / SPEC-004-MODULE ss3
//
//  Pipeline latency: exactly EPC_EVAL_CYCLES = 18 clock cycles after eval_start.
//
//  Arithmetic:  Logits are Q8.8 fixed-point (16-bit, signed two's complement).
//               Numerically stable softmax: subtract max logit before exp.
//               exp(x) is approximated by a 256-entry LUT indexed by the
//               8-bit integer part of (logit - max), offset by 128.
//               exp(0)=256 (Q8.8 value 1.0). Top-K ranking is performed on
//               un-normalised exp values (invariant to dividing by sum).
//
//  Pipeline stages (18 cycles):
//   Cycle  1     : Latch logit_in[8:0], k_cfg; validate k_cfg
//   Cycle  2     : Partial max tree — 4 pairs
//   Cycle  3     : Final max reduction; propagate logits
//   Cycles 4-12  : 9-cycle propagation delay; exp values computed combinatorially
//   Cycle 13     : Register all 9 exp values and their sum
//   Cycles 14-15 : Parallel Top-K selection sort (2 pipeline stages)
//   Cycles 16-17 : Gate bitmap build + tie detection
//   Cycle 18     : Output register — gate_out_valid asserted
//
// =============================================================================
module epc_softmax_topk #(
    parameter int unsigned EXPERTS     = 9,
    parameter int unsigned K_MAX       = 2,
    parameter int unsigned EVAL_CYCLES = 18
)(
    input  logic               CLK_TILE,
    input  logic               RSTN_TILE,

    input  logic               eval_start,           // Single-cycle pulse
    input  logic [1:0]         k_cfg,                // 2'b01=K1, 2'b10=K2

    input  logic signed [15:0] logit_in [0:8],       // 9 × Q8.8 signed logits

    output logic [8:0]         gate_out,             // One-hot tile bitmap
    output logic               gate_out_valid,       // Asserted exactly 1 cycle at cycle 18
    output logic               topk_tie,             // Tie at K-boundary
    output logic               invalid_k,            // k_cfg not in {01,10}
    output logic [8:0]         icg_enable            // = gate_out
);

    // -------------------------------------------------------------------------
    // 18-stage validity shift register (one bit per pipeline stage)
    // -------------------------------------------------------------------------
    logic [17:0] vld_pipe_r;
    always_ff @(posedge CLK_TILE) begin
        if (!RSTN_TILE) vld_pipe_r <= 18'h0;
        else            vld_pipe_r <= {vld_pipe_r[16:0], eval_start};
    end

    // -------------------------------------------------------------------------
    // Exp LUT: index = (logit - max) integer part + 128, range [0,128]
    // Values = round(256 * exp((idx-128)/256)) ≈ exp as Q8.8 (exp(0)=256)
    // Only indices 0..128 are meaningful (delta ≤ 0); 129..255 filled as 256.
    // -------------------------------------------------------------------------
    logic [15:0] exp_lut [0:255];
    initial begin
        // Precomputed: exp_lut[i] = round(256 * exp((i-128)/256))
        // i=0: exp(-0.5)≈155, i=64: exp(-0.25)≈200, i=128: exp(0)=256
        exp_lut[  0]=16'd155; exp_lut[  1]=16'd155; exp_lut[  2]=16'd156;
        exp_lut[  3]=16'd156; exp_lut[  4]=16'd157; exp_lut[  5]=16'd157;
        exp_lut[  6]=16'd158; exp_lut[  7]=16'd158; exp_lut[  8]=16'd159;
        exp_lut[  9]=16'd159; exp_lut[ 10]=16'd160; exp_lut[ 11]=16'd161;
        exp_lut[ 12]=16'd161; exp_lut[ 13]=16'd162; exp_lut[ 14]=16'd162;
        exp_lut[ 15]=16'd163; exp_lut[ 16]=16'd164; exp_lut[ 17]=16'd164;
        exp_lut[ 18]=16'd165; exp_lut[ 19]=16'd165; exp_lut[ 20]=16'd166;
        exp_lut[ 21]=16'd167; exp_lut[ 22]=16'd167; exp_lut[ 23]=16'd168;
        exp_lut[ 24]=16'd169; exp_lut[ 25]=16'd169; exp_lut[ 26]=16'd170;
        exp_lut[ 27]=16'd171; exp_lut[ 28]=16'd171; exp_lut[ 29]=16'd172;
        exp_lut[ 30]=16'd173; exp_lut[ 31]=16'd173; exp_lut[ 32]=16'd174;
        exp_lut[ 33]=16'd175; exp_lut[ 34]=16'd176; exp_lut[ 35]=16'd176;
        exp_lut[ 36]=16'd177; exp_lut[ 37]=16'd178; exp_lut[ 38]=16'd179;
        exp_lut[ 39]=16'd179; exp_lut[ 40]=16'd180; exp_lut[ 41]=16'd181;
        exp_lut[ 42]=16'd182; exp_lut[ 43]=16'd182; exp_lut[ 44]=16'd183;
        exp_lut[ 45]=16'd184; exp_lut[ 46]=16'd185; exp_lut[ 47]=16'd186;
        exp_lut[ 48]=16'd186; exp_lut[ 49]=16'd187; exp_lut[ 50]=16'd188;
        exp_lut[ 51]=16'd189; exp_lut[ 52]=16'd190; exp_lut[ 53]=16'd191;
        exp_lut[ 54]=16'd192; exp_lut[ 55]=16'd192; exp_lut[ 56]=16'd193;
        exp_lut[ 57]=16'd194; exp_lut[ 58]=16'd195; exp_lut[ 59]=16'd196;
        exp_lut[ 60]=16'd197; exp_lut[ 61]=16'd198; exp_lut[ 62]=16'd199;
        exp_lut[ 63]=16'd200; exp_lut[ 64]=16'd201; exp_lut[ 65]=16'd202;
        exp_lut[ 66]=16'd203; exp_lut[ 67]=16'd204; exp_lut[ 68]=16'd205;
        exp_lut[ 69]=16'd206; exp_lut[ 70]=16'd207; exp_lut[ 71]=16'd208;
        exp_lut[ 72]=16'd209; exp_lut[ 73]=16'd210; exp_lut[ 74]=16'd211;
        exp_lut[ 75]=16'd212; exp_lut[ 76]=16'd213; exp_lut[ 77]=16'd214;
        exp_lut[ 78]=16'd215; exp_lut[ 79]=16'd216; exp_lut[ 80]=16'd217;
        exp_lut[ 81]=16'd218; exp_lut[ 82]=16'd214; exp_lut[ 83]=16'd215;
        exp_lut[ 84]=16'd216; exp_lut[ 85]=16'd216; exp_lut[ 86]=16'd217;
        exp_lut[ 87]=16'd218; exp_lut[ 88]=16'd219; exp_lut[ 89]=16'd220;
        exp_lut[ 90]=16'd221; exp_lut[ 91]=16'd222; exp_lut[ 92]=16'd222;
        exp_lut[ 93]=16'd223; exp_lut[ 94]=16'd224; exp_lut[ 95]=16'd225;
        exp_lut[ 96]=16'd226; exp_lut[ 97]=16'd227; exp_lut[ 98]=16'd228;
        exp_lut[ 99]=16'd229; exp_lut[100]=16'd229; exp_lut[101]=16'd230;
        exp_lut[102]=16'd231; exp_lut[103]=16'd232; exp_lut[104]=16'd233;
        exp_lut[105]=16'd234; exp_lut[106]=16'd235; exp_lut[107]=16'd236;
        exp_lut[108]=16'd237; exp_lut[109]=16'd238; exp_lut[110]=16'd239;
        exp_lut[111]=16'd240; exp_lut[112]=16'd240; exp_lut[113]=16'd241;
        exp_lut[114]=16'd242; exp_lut[115]=16'd243; exp_lut[116]=16'd244;
        exp_lut[117]=16'd245; exp_lut[118]=16'd246; exp_lut[119]=16'd247;
        exp_lut[120]=16'd248; exp_lut[121]=16'd249; exp_lut[122]=16'd250;
        exp_lut[123]=16'd251; exp_lut[124]=16'd252; exp_lut[125]=16'd253;
        exp_lut[126]=16'd254; exp_lut[127]=16'd255; exp_lut[128]=16'd256;
        // Indices 129-255: delta > 0 cannot occur (max subtraction guarantees
        // delta <= 0). Clamp to exp(=256 as safety net.
        exp_lut[129]=16'd256; exp_lut[130]=16'd256; exp_lut[131]=16'd256;
        exp_lut[132]=16'd256; exp_lut[133]=16'd256; exp_lut[134]=16'd256;
        exp_lut[135]=16'd256; exp_lut[136]=16'd256; exp_lut[137]=16'd256;
        exp_lut[138]=16'd256; exp_lut[139]=16'd256; exp_lut[140]=16'd256;
        exp_lut[141]=16'd256; exp_lut[142]=16'd256; exp_lut[143]=16'd256;
        exp_lut[144]=16'd256; exp_lut[145]=16'd256; exp_lut[146]=16'd256;
        exp_lut[147]=16'd256; exp_lut[148]=16'd256; exp_lut[149]=16'd256;
        exp_lut[150]=16'd256; exp_lut[151]=16'd256; exp_lut[152]=16'd256;
        exp_lut[153]=16'd256; exp_lut[154]=16'd256; exp_lut[155]=16'd256;
        exp_lut[156]=16'd256; exp_lut[157]=16'd256; exp_lut[158]=16'd256;
        exp_lut[159]=16'd256; exp_lut[160]=16'd256; exp_lut[161]=16'd256;
        exp_lut[162]=16'd256; exp_lut[163]=16'd256; exp_lut[164]=16'd256;
        exp_lut[165]=16'd256; exp_lut[166]=16'd256; exp_lut[167]=16'd256;
        exp_lut[168]=16'd256; exp_lut[169]=16'd256; exp_lut[170]=16'd256;
        exp_lut[171]=16'd256; exp_lut[172]=16'd256; exp_lut[173]=16'd256;
        exp_lut[174]=16'd256; exp_lut[175]=16'd256; exp_lut[176]=16'd256;
        exp_lut[177]=16'd256; exp_lut[178]=16'd256; exp_lut[179]=16'd256;
        exp_lut[180]=16'd256; exp_lut[181]=16'd256; exp_lut[182]=16'd256;
        exp_lut[183]=16'd256; exp_lut[184]=16'd256; exp_lut[185]=16'd256;
        exp_lut[186]=16'd256; exp_lut[187]=16'd256; exp_lut[188]=16'd256;
        exp_lut[189]=16'd256; exp_lut[190]=16'd256; exp_lut[191]=16'd256;
        exp_lut[192]=16'd256; exp_lut[193]=16'd256; exp_lut[194]=16'd256;
        exp_lut[195]=16'd256; exp_lut[196]=16'd256; exp_lut[197]=16'd256;
        exp_lut[198]=16'd256; exp_lut[199]=16'd256; exp_lut[200]=16'd256;
        exp_lut[201]=16'd256; exp_lut[202]=16'd256; exp_lut[203]=16'd256;
        exp_lut[204]=16'd256; exp_lut[205]=16'd256; exp_lut[206]=16'd256;
        exp_lut[207]=16'd256; exp_lut[208]=16'd256; exp_lut[209]=16'd256;
        exp_lut[210]=16'd256; exp_lut[211]=16'd256; exp_lut[212]=16'd256;
        exp_lut[213]=16'd256; exp_lut[214]=16'd256; exp_lut[215]=16'd256;
        exp_lut[216]=16'd256; exp_lut[217]=16'd256; exp_lut[218]=16'd256;
        exp_lut[219]=16'd256; exp_lut[220]=16'd256; exp_lut[221]=16'd256;
        exp_lut[222]=16'd256; exp_lut[223]=16'd256; exp_lut[224]=16'd256;
        exp_lut[225]=16'd256; exp_lut[226]=16'd256; exp_lut[227]=16'd256;
        exp_lut[228]=16'd256; exp_lut[229]=16'd256; exp_lut[230]=16'd256;
        exp_lut[231]=16'd256; exp_lut[232]=16'd256; exp_lut[233]=16'd256;
        exp_lut[234]=16'd256; exp_lut[235]=16'd256; exp_lut[236]=16'd256;
        exp_lut[237]=16'd256; exp_lut[238]=16'd256; exp_lut[239]=16'd256;
        exp_lut[240]=16'd256; exp_lut[241]=16'd256; exp_lut[242]=16'd256;
        exp_lut[243]=16'd256; exp_lut[244]=16'd256; exp_lut[245]=16'd256;
        exp_lut[246]=16'd256; exp_lut[247]=16'd256; exp_lut[248]=16'd256;
        exp_lut[249]=16'd256; exp_lut[250]=16'd256; exp_lut[251]=16'd256;
        exp_lut[252]=16'd256; exp_lut[253]=16'd256; exp_lut[254]=16'd256;
        exp_lut[255]=16'd256;
    end

    // -------------------------------------------------------------------------
    // Stage 1 — Latch inputs
    // -------------------------------------------------------------------------
    logic signed [15:0] logit_r [0:8];
    logic [1:0]         k_r;
    logic               k_valid_r;

    always_ff @(posedge CLK_TILE) begin
        if (!RSTN_TILE) begin
            for (int i=0;i<9;i++) logit_r[i] <= '0;
            k_r <= 2'b0; k_valid_r <= 1'b0;
        end else if (eval_start) begin
            for (int i=0;i<9;i++) logit_r[i] <= logit_in[i];
            k_r       <= k_cfg;
            k_valid_r <= (k_cfg==2'b01)||(k_cfg==2'b10);
        end
    end

    // -------------------------------------------------------------------------
    // Stage 2 — Partial max tree (4 pairs)
    // -------------------------------------------------------------------------
    logic signed [15:0] max_s1 [0:3];
    logic signed [15:0] logit_s2 [0:8];

    always_ff @(posedge CLK_TILE) begin
        if (!RSTN_TILE) begin
            for (int i=0;i<4;i++) max_s1[i]  <= '0;
            for (int i=0;i<9;i++) logit_s2[i] <= '0;
        end else if (vld_pipe_r[0]) begin
            max_s1[0] <= (logit_r[0]>logit_r[1]) ? logit_r[0] : logit_r[1];
            max_s1[1] <= (logit_r[2]>logit_r[3]) ? logit_r[2] : logit_r[3];
            max_s1[2] <= (logit_r[4]>logit_r[5]) ? logit_r[4] : logit_r[5];
            max_s1[3] <= (logit_r[6]>logit_r[7]) ? logit_r[6] : logit_r[7];
            for (int i=0;i<9;i++) logit_s2[i] <= logit_r[i];
        end
    end

    // -------------------------------------------------------------------------
    // Stage 3 — Final max reduction
    // -------------------------------------------------------------------------
    logic signed [15:0] max_logit_r;
    logic signed [15:0] logit_s3 [0:8];
    logic [1:0]         k_s3_r;
    logic               kv_s3_r;

    always_ff @(posedge CLK_TILE) begin
        if (!RSTN_TILE) begin
            max_logit_r <= '0;
            for (int i=0;i<9;i++) logit_s3[i] <= '0;
            k_s3_r <= 2'b0; kv_s3_r <= 1'b0;
        end else if (vld_pipe_r[1]) begin
            begin
                logic signed [15:0] mab, mcd, mx;
                mab = (max_s1[0]>max_s1[1]) ? max_s1[0] : max_s1[1];
                mcd = (max_s1[2]>max_s1[3]) ? max_s1[2] : max_s1[3];
                mx  = (mab>mcd) ? mab : mcd;
                max_logit_r <= (logit_s2[8]>mx) ? logit_s2[8] : mx;
            end
            for (int i=0;i<9;i++) logit_s3[i] <= logit_s2[i];
            k_s3_r  <= k_r;
            kv_s3_r <= k_valid_r;
        end
    end

    // -------------------------------------------------------------------------
    // Stages 4-12 — Combinatorial exp LUT (all 9 in parallel)
    // Results held in a 9-stage propagation delay pipeline
    // -------------------------------------------------------------------------
    logic signed [15:0] delta   [0:8];
    logic [7:0]         lut_idx [0:8];
    logic [15:0]        exp_comb[0:8];

    genvar gi;
    generate
        for (gi=0; gi<9; gi++) begin : g_exp
            assign delta[gi]    = logit_s3[gi] - max_logit_r;
            // Map signed integer part to LUT index: idx = delta[15:8] + 128
            // Saturate: if delta < -128 (very negative), clamp to index 0
            // Clamp index to [0,128]: delta<=0 always, so index<=128
            // Saturate negative overflow (delta < -128/256 step)
            assign lut_idx[gi]  = ($signed(delta[gi][15:8]) < -8'sd128) ?
                                   8'd0 :
                                   (($signed(delta[gi][15:8]) >= 8'sd0) ?
                                    8'd128 :
                                    8'(8'($signed(delta[gi][15:8])) + 8'd128));
            assign exp_comb[gi] = exp_lut[lut_idx[gi]];
        end
    endgenerate

    // 9-stage delay pipeline to reach stage 13
    logic [15:0] exp_delay [0:8][0:8]; // [expert][stage 0..8]
    logic [1:0]  k_delay   [0:8];
    logic        kv_delay  [0:8];

    always_ff @(posedge CLK_TILE) begin
        if (!RSTN_TILE) begin
            for (int i=0;i<9;i++) begin
                for (int s=0;s<9;s++) exp_delay[i][s] <= 16'h0;
            end
            for (int s=0;s<9;s++) begin k_delay[s] <= 2'b0; kv_delay[s] <= 1'b0; end
        end else begin
            for (int i=0;i<9;i++) begin
                exp_delay[i][0] <= exp_comb[i];
                for (int s=1;s<9;s++) exp_delay[i][s] <= exp_delay[i][s-1];
            end
            k_delay[0]  <= k_s3_r;
            kv_delay[0] <= kv_s3_r;
            for (int s=1;s<9;s++) begin
                k_delay[s]  <= k_delay[s-1];
                kv_delay[s] <= kv_delay[s-1];
            end
        end
    end

    // -------------------------------------------------------------------------
    // Stage 13 — Register exp values
    // -------------------------------------------------------------------------
    logic [15:0] exp_r    [0:8];
    logic [1:0]  k_s13_r;
    logic        kv_s13_r;

    always_ff @(posedge CLK_TILE) begin
        if (!RSTN_TILE) begin
            for (int i=0;i<9;i++) exp_r[i] <= 16'h0;
            k_s13_r <= 2'b0; kv_s13_r <= 1'b0;
        end else if (vld_pipe_r[11]) begin
            for (int i=0;i<9;i++) exp_r[i] <= exp_delay[i][8];
            k_s13_r  <= k_delay[8];
            kv_s13_r <= kv_delay[8];
        end
    end

    // -------------------------------------------------------------------------
    // Stages 14-15 — Parallel Top-K selection (combinatorial + 2 FF stages)
    // -------------------------------------------------------------------------
    logic [3:0]  c_top1_idx, c_top2_idx;
    logic [15:0] c_top1_val, c_top2_val;
    logic        c_tie;

    // -------------------------------------------------------------------------
    // Synthesizable parallel Top-K: 9-input priority comparator tree
    // No loops with break; no local variables. Pure combinatorial priority.
    // Strategy: find top-1 by 8-wide parallel max-reduction, then top-2
    // by repeating over the remaining 8 experts.
    // Tie-breaking: lower index wins (compare indices when values equal).
    // -------------------------------------------------------------------------
    always_comb begin : comb_topk
        // --- Top-1: parallel comparator across all 9 experts ---
        // Compare pairs and propagate: this is a priority encoder with
        // max-value semantics. Lower index wins on equal values.
        c_top1_val = exp_r[0]; c_top1_idx = 4'd0;
        // Expert 1
        if ((exp_r[1] > c_top1_val) ||
            ((exp_r[1] == c_top1_val) && (4'd1 < c_top1_idx)))
        begin c_top1_val = exp_r[1]; c_top1_idx = 4'd1; end
        // Expert 2
        if ((exp_r[2] > c_top1_val) ||
            ((exp_r[2] == c_top1_val) && (4'd2 < c_top1_idx)))
        begin c_top1_val = exp_r[2]; c_top1_idx = 4'd2; end
        // Expert 3
        if ((exp_r[3] > c_top1_val) ||
            ((exp_r[3] == c_top1_val) && (4'd3 < c_top1_idx)))
        begin c_top1_val = exp_r[3]; c_top1_idx = 4'd3; end
        // Expert 4
        if ((exp_r[4] > c_top1_val) ||
            ((exp_r[4] == c_top1_val) && (4'd4 < c_top1_idx)))
        begin c_top1_val = exp_r[4]; c_top1_idx = 4'd4; end
        // Expert 5
        if ((exp_r[5] > c_top1_val) ||
            ((exp_r[5] == c_top1_val) && (4'd5 < c_top1_idx)))
        begin c_top1_val = exp_r[5]; c_top1_idx = 4'd5; end
        // Expert 6
        if ((exp_r[6] > c_top1_val) ||
            ((exp_r[6] == c_top1_val) && (4'd6 < c_top1_idx)))
        begin c_top1_val = exp_r[6]; c_top1_idx = 4'd6; end
        // Expert 7
        if ((exp_r[7] > c_top1_val) ||
            ((exp_r[7] == c_top1_val) && (4'd7 < c_top1_idx)))
        begin c_top1_val = exp_r[7]; c_top1_idx = 4'd7; end
        // Expert 8
        if ((exp_r[8] > c_top1_val) ||
            ((exp_r[8] == c_top1_val) && (4'd8 < c_top1_idx)))
        begin c_top1_val = exp_r[8]; c_top1_idx = 4'd8; end

        // --- Top-2: best among experts excluding top-1 index ---
        // Seed with first expert that is not top-1
        c_top2_val = 16'h0; c_top2_idx = 4'd0;
        // Iterate all 9 experts; skip the one that won top-1
        // Expert 0
        if ((c_top1_idx != 4'd0) &&
            ((exp_r[0] > c_top2_val) ||
             ((exp_r[0] == c_top2_val) && (4'd0 < c_top2_idx))))
        begin c_top2_val = exp_r[0]; c_top2_idx = 4'd0; end
        // Expert 1
        if ((c_top1_idx != 4'd1) &&
            ((exp_r[1] > c_top2_val) ||
             ((exp_r[1] == c_top2_val) && (4'd1 < c_top2_idx))))
        begin c_top2_val = exp_r[1]; c_top2_idx = 4'd1; end
        // Expert 2
        if ((c_top1_idx != 4'd2) &&
            ((exp_r[2] > c_top2_val) ||
             ((exp_r[2] == c_top2_val) && (4'd2 < c_top2_idx))))
        begin c_top2_val = exp_r[2]; c_top2_idx = 4'd2; end
        // Expert 3
        if ((c_top1_idx != 4'd3) &&
            ((exp_r[3] > c_top2_val) ||
             ((exp_r[3] == c_top2_val) && (4'd3 < c_top2_idx))))
        begin c_top2_val = exp_r[3]; c_top2_idx = 4'd3; end
        // Expert 4
        if ((c_top1_idx != 4'd4) &&
            ((exp_r[4] > c_top2_val) ||
             ((exp_r[4] == c_top2_val) && (4'd4 < c_top2_idx))))
        begin c_top2_val = exp_r[4]; c_top2_idx = 4'd4; end
        // Expert 5
        if ((c_top1_idx != 4'd5) &&
            ((exp_r[5] > c_top2_val) ||
             ((exp_r[5] == c_top2_val) && (4'd5 < c_top2_idx))))
        begin c_top2_val = exp_r[5]; c_top2_idx = 4'd5; end
        // Expert 6
        if ((c_top1_idx != 4'd6) &&
            ((exp_r[6] > c_top2_val) ||
             ((exp_r[6] == c_top2_val) && (4'd6 < c_top2_idx))))
        begin c_top2_val = exp_r[6]; c_top2_idx = 4'd6; end
        // Expert 7
        if ((c_top1_idx != 4'd7) &&
            ((exp_r[7] > c_top2_val) ||
             ((exp_r[7] == c_top2_val) && (4'd7 < c_top2_idx))))
        begin c_top2_val = exp_r[7]; c_top2_idx = 4'd7; end
        // Expert 8
        if ((c_top1_idx != 4'd8) &&
            ((exp_r[8] > c_top2_val) ||
             ((exp_r[8] == c_top2_val) && (4'd8 < c_top2_idx))))
        begin c_top2_val = exp_r[8]; c_top2_idx = 4'd8; end

        // Tie flag: top-1 and top-2 have equal exp value
        c_tie = (c_top1_val == c_top2_val);
    end

    // Stage 14 register
    logic [3:0]  top1_idx_r, top2_idx_r;
    logic [15:0] top1_val_r;
    logic        tie_r;
    logic [1:0]  k_s14_r;
    logic        kv_s14_r;

    always_ff @(posedge CLK_TILE) begin
        if (!RSTN_TILE) begin
            top1_idx_r <= 4'd0; top2_idx_r <= 4'd0;
            top1_val_r <= 16'h0; tie_r <= 1'b0;
            k_s14_r <= 2'b0; kv_s14_r <= 1'b0;
        end else if (vld_pipe_r[12]) begin
            top1_idx_r <= c_top1_idx;
            top2_idx_r <= c_top2_idx;
            top1_val_r <= c_top1_val;
            tie_r      <= c_tie;
            k_s14_r    <= k_s13_r;
            kv_s14_r   <= kv_s13_r;
        end
    end

    // Stage 15 register (one more pipeline cycle)
    logic [3:0]  top1_idx_s15_r, top2_idx_s15_r;
    logic        tie_s15_r;
    logic [1:0]  k_s15_r;
    logic        kv_s15_r;

    always_ff @(posedge CLK_TILE) begin
        if (!RSTN_TILE) begin
            top1_idx_s15_r <= 4'd0; top2_idx_s15_r <= 4'd0;
            tie_s15_r <= 1'b0; k_s15_r <= 2'b0; kv_s15_r <= 1'b0;
        end else if (vld_pipe_r[13]) begin
            top1_idx_s15_r <= top1_idx_r;
            top2_idx_s15_r <= top2_idx_r;
            tie_s15_r      <= tie_r;
            k_s15_r        <= k_s14_r;
            kv_s15_r       <= kv_s14_r;
        end
    end

    // -------------------------------------------------------------------------
    // Stage 16 — Build gate bitmap
    // -------------------------------------------------------------------------
    logic [8:0] gate_s16_r;
    logic       tie_s16_r, kv_s16_r;

    always_ff @(posedge CLK_TILE) begin
        if (!RSTN_TILE) begin
            gate_s16_r <= 9'h0; tie_s16_r <= 1'b0; kv_s16_r <= 1'b0;
        end else if (vld_pipe_r[14]) begin
            gate_s16_r                     <= 9'h0;
            gate_s16_r[top1_idx_s15_r]     <= 1'b1;
            if (k_s15_r == 2'b10)
                gate_s16_r[top2_idx_s15_r] <= 1'b1;
            tie_s16_r  <= (k_s15_r == 2'b10) ? tie_s15_r : 1'b0;
            kv_s16_r   <= kv_s15_r;
        end
    end

    // -------------------------------------------------------------------------
    // Stage 17 — Propagation register
    // -------------------------------------------------------------------------
    logic [8:0] gate_s17_r;
    logic       tie_s17_r, kv_s17_r;

    always_ff @(posedge CLK_TILE) begin
        if (!RSTN_TILE) begin
            gate_s17_r <= 9'h0; tie_s17_r <= 1'b0; kv_s17_r <= 1'b0;
        end else if (vld_pipe_r[15]) begin
            gate_s17_r <= gate_s16_r;
            tie_s17_r  <= tie_s16_r;
            kv_s17_r   <= kv_s16_r;
        end
    end

    // -------------------------------------------------------------------------
    // Stage 18 — Output register
    // -------------------------------------------------------------------------
    always_ff @(posedge CLK_TILE) begin
        if (!RSTN_TILE) begin
            gate_out       <= 9'h0;
            gate_out_valid <= 1'b0;
            topk_tie       <= 1'b0;
            invalid_k      <= 1'b0;
            icg_enable     <= 9'h0;
        end else begin
            gate_out_valid <= vld_pipe_r[17];  // cycle 18: one extra stage for spec-correct 18-cycle latency
            if (vld_pipe_r[17]) begin
                gate_out   <= gate_s17_r;
                topk_tie   <= tie_s17_r;
                invalid_k  <= !kv_s17_r;
                icg_enable <= gate_s17_r;
            end
        end
    end

endmodule : epc_softmax_topk
