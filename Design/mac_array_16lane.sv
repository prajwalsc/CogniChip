// =============================================================================
// Module:      mac_array_16lane
// Description: 16-Lane Multiply-Accumulate Datapath
//              Cogni-V Engine — COGNIV-SPEC-004-MODULE v1.0, Section 2
//
// Notes:
//   - BF16 mode: each 32-bit weight lane carries 2 BF16 values (A=high, B=low)
//     acc[l] += BF16_to_FP32(W_A) * BF16_to_FP32(act[31:16])
//            += BF16_to_FP32(W_B) * BF16_to_FP32(act[15:0])
//   - INT8 mode: each 32-bit weight lane carries 4 INT8 values (W0..W3)
//     acc[l] += W0*act[31:24] + W1*act[23:16] + W2*act[15:8] + W3*act[7:0]
//   - Accumulators are FP32 (IEEE 754). BF16/FP32 conversion implemented as
//     zero-extend / shift since BF16 is the top 16 bits of FP32.
//   - acc_mode=0: overwrite on first mac_en; acc_mode=1: accumulate always.
//   - result_data is registered 1 cycle after mac_drain.
// =============================================================================

module mac_array_16lane (
    input  logic        CLK_TILE,
    input  logic        RSTN_TILE,

    input  logic        precision,      // 0=BF16, 1=INT8
    input  logic        acc_mode,       // 0=overwrite, 1=accumulate

    input  logic [511:0] weight_data,   // 16 x 32-bit weights
    input  logic [31:0]  act_data,      // 32-bit activation broadcast
    input  logic         mac_en,        // execute MAC this cycle
    input  logic         mac_drain,     // snapshot accumulators

    output logic [511:0] result_data,   // 16 x 32-bit accumulator snapshot
    output logic         result_vld     // registered, 1 cycle after drain
);

    // -------------------------------------------------------------------------
    // Parameters
    // -------------------------------------------------------------------------
    localparam int LANES = 16;

    // -------------------------------------------------------------------------
    // Accumulator array: 16 lanes × FP32 (32 bits)
    // -------------------------------------------------------------------------
    logic [31:0] acc [0:LANES-1];

    // Track first mac_en for overwrite mode
    logic        acc_init_done_r;

    always_ff @(posedge CLK_TILE) begin
        if (!RSTN_TILE)
            acc_init_done_r <= 1'b0;
        else if (mac_en)
            acc_init_done_r <= 1'b1;
        else if (mac_drain)
            acc_init_done_r <= 1'b0;
    end

    // -------------------------------------------------------------------------
    // BF16 → FP32 conversion: BF16 occupies the upper 16 bits of FP32
    //   FP32 = {bf16[15:0], 16'h0000}
    // -------------------------------------------------------------------------
    function automatic logic [31:0] bf16_to_fp32 (input logic [15:0] bf16_in);
        return {bf16_in, 16'h0000};
    endfunction

    // -------------------------------------------------------------------------
    // FP32 approximate multiply (combinatorial)
    // Full IEEE 754 multiply is not practical in RTL without vendor FP IPs.
    // This implementation represents the structural intent; replace with
    // vendor FP32 multiply IP (e.g., Synopsys DesignWare DW_fp_mult) in
    // production synthesis.
    //
    // For simulation correctness this uses $bitstoreal / $realtobits.
    // -------------------------------------------------------------------------
    function automatic logic [31:0] fp32_mul (
        input logic [31:0] a,
        input logic [31:0] b
    );
        // Synthesizable approximation: structural IEEE 754 single-precision
        // mantissa multiply + exponent add. Intended as placeholder for IP.
        logic        sign_a, sign_b, sign_r;
        logic [7:0]  exp_a, exp_b;
        logic [23:0] man_a, man_b;
        logic [47:0] man_product;
        logic [8:0]  exp_sum;
        logic [7:0]  exp_r;
        logic [22:0] man_r;

        sign_a = a[31];
        sign_b = b[31];
        exp_a  = a[30:23];
        exp_b  = b[30:23];
        man_a  = {1'b1, a[22:0]};  // implicit leading 1
        man_b  = {1'b1, b[22:0]};
        sign_r = sign_a ^ sign_b;
        exp_sum = {1'b0, exp_a} + {1'b0, exp_b} - 9'd127;  // remove bias once

        man_product = man_a * man_b;  // 48-bit product

        // Normalize: pick top 24 bits, adjust exponent
        if (man_product[47]) begin
            man_r = man_product[46:24];
            exp_r = exp_sum[7:0] + 8'd1;
        end else begin
            man_r = man_product[45:23];
            exp_r = exp_sum[7:0];
        end

        // Handle zero operands
        if ((exp_a == 8'd0) || (exp_b == 8'd0))
            fp32_mul = 32'd0;
        else
            fp32_mul = {sign_r, exp_r, man_r};
    endfunction

    // -------------------------------------------------------------------------
    // FP32 approximate add (combinatorial)
    // Production implementation should use vendor FP32 adder IP.
    // -------------------------------------------------------------------------
    function automatic logic [31:0] fp32_add (
        input logic [31:0] a,
        input logic [31:0] b
    );
        // Simplified FP32 add: handles same-sign and opposite-sign cases.
        // Production implementation should use vendor FP32 adder IP.
        logic        sign_a, sign_b;
        logic [7:0]  exp_a, exp_b, exp_diff, exp_r;
        logic [24:0] man_a_ext, man_b_ext, man_sum;
        logic [22:0] man_r;

        // Handle zero operands: full-word zero check covers +0.0 and -0.0
        if (a == 32'h0000_0000) return b;
        if (b == 32'h0000_0000) return a;

        sign_a = a[31];
        sign_b = b[31];
        exp_a  = a[30:23];
        exp_b  = b[30:23];

        if (exp_a >= exp_b) begin
            exp_diff  = exp_a - exp_b;
            man_a_ext = {2'b01, a[22:0]};
            man_b_ext = {2'b01, b[22:0]} >> exp_diff;
            exp_r     = exp_a;
        end else begin
            exp_diff  = exp_b - exp_a;
            man_b_ext = {2'b01, b[22:0]};
            man_a_ext = {2'b01, a[22:0]} >> exp_diff;
            exp_r     = exp_b;
        end

        if (sign_a == sign_b) begin
            // Same sign: add magnitudes, keep sign
            man_sum = man_a_ext + man_b_ext;
            if (man_sum[24]) begin
                man_r = man_sum[23:1];
                exp_r = exp_r + 8'd1;
            end else begin
                man_r = man_sum[22:0];
            end
            fp32_add = {sign_a, exp_r, man_r};
        end else begin
            // Opposite sign: subtract smaller from larger
            if (man_a_ext >= man_b_ext) begin
                man_sum = man_a_ext - man_b_ext;
                fp32_add = {sign_a, exp_r, man_sum[22:0]};
            end else begin
                man_sum = man_b_ext - man_a_ext;
                fp32_add = {sign_b, exp_r, man_sum[22:0]};
            end
        end
    endfunction

    // -------------------------------------------------------------------------
    // INT8 × INT8 → INT32 accumulation helper
    // -------------------------------------------------------------------------
    function automatic logic [31:0] int8_mac4 (
        input logic [7:0]  w0, w1, w2, w3,
        input logic [7:0]  a0, a1, a2, a3,
        input logic [31:0] acc_in
    );
        logic signed [15:0] p0, p1, p2, p3;
        logic signed [31:0] result;
        p0 = $signed(w0) * $signed(a0);
        p1 = $signed(w1) * $signed(a1);
        p2 = $signed(w2) * $signed(a2);
        p3 = $signed(w3) * $signed(a3);
        result = $signed(acc_in) + $signed(p0) + $signed(p1) + $signed(p2) + $signed(p3);
        return result[31:0];
    endfunction

    // -------------------------------------------------------------------------
    // MAC execution — per lane
    // -------------------------------------------------------------------------
    always_ff @(posedge CLK_TILE) begin
        // Local temporaries declared inside the block to avoid
        // cross-process sharing issues with Verilator
        logic [31:0] mac_w_v, mac_new_v, mac_base_v;
        logic [31:0] fp32_wA_v, fp32_wB_v, fp32_aA_v, fp32_aB_v;
        logic [31:0] prodA_v, prodB_v;
        if (!RSTN_TILE) begin
            for (int ll = 0; ll < LANES; ll++) acc[ll] <= 32'h0;
        end else if (mac_drain) begin
            // Clear accumulators after drain so next compute batch starts from zero
            for (int ll = 0; ll < LANES; ll++) acc[ll] <= 32'h0;
        end else if (mac_en) begin
            for (int ll = 0; ll < LANES; ll++) begin
                mac_w_v    = weight_data[32*ll +: 32];
                mac_base_v = (acc_mode == 1'b0 && !acc_init_done_r) ? 32'h0 : acc[ll];

                if (!precision) begin
                    // BF16 mode
                    fp32_wA_v = bf16_to_fp32(mac_w_v[31:16]);
                    fp32_wB_v = bf16_to_fp32(mac_w_v[15:0]);
                    fp32_aA_v = bf16_to_fp32(act_data[31:16]);
                    fp32_aB_v = bf16_to_fp32(act_data[15:0]);
                    prodA_v   = fp32_mul(fp32_wA_v, fp32_aA_v);
                    prodB_v   = fp32_mul(fp32_wB_v, fp32_aB_v);
                    mac_new_v = fp32_add(fp32_add(mac_base_v, prodA_v), prodB_v);
                end else begin
                    // INT8 mode
                    mac_new_v = int8_mac4(
                        mac_w_v[31:24], mac_w_v[23:16], mac_w_v[15:8], mac_w_v[7:0],
                        act_data[31:24], act_data[23:16], act_data[15:8], act_data[7:0],
                        mac_base_v
                    );
                end
                acc[ll] <= mac_new_v;
            end
        end
    end

    // -------------------------------------------------------------------------
    // Drain: snapshot accumulators to output register file
    // -------------------------------------------------------------------------
    logic [511:0] result_reg;
    logic         result_vld_r;

    always_ff @(posedge CLK_TILE) begin
        if (!RSTN_TILE) begin
            result_reg   <= 512'h0;
            result_vld_r <= 1'b0;
        end else begin
            if (mac_drain) begin
                // Snapshot accumulators and assert valid (sticky until next mac_en)
                result_vld_r <= 1'b1;
                for (int ll = 0; ll < LANES; ll++)
                    result_reg[32*ll +: 32] <= acc[ll];
            end else if (mac_en) begin
                // New MAC operation started — clear stale valid
                result_vld_r <= 1'b0;
            end
        end
    end

    assign result_data = result_reg;
    assign result_vld  = result_vld_r;

endmodule
