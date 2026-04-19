// =============================================================================
// Module:      tile_sram_256kb
// Description: Tile SRAM Interface with SECDED ECC
//              Cogni-V Engine — COGNIV-SPEC-004-MODULE v1.0, Section 3
//
// Notes:
//   - Wraps a 64Kx32 SRAM array with SECDED(39,32) ECC logic.
//   - Read latency: 1 CLK_TILE (synchronous registered output).
//   - retention_vdd is a power-rail input; carries no RTL logic.
// =============================================================================

module tile_sram_256kb (
    input  logic        CLK_TILE,
    input  logic        RSTN_TILE,

    input  logic [15:0] addr,
    input  logic [31:0] wdata,
    output logic [31:0] rdata,
    input  logic        we,

    output logic        ecc_err_1b,
    output logic        ecc_err_2b,
    output logic [31:0] ecc_corrected_data,

    input  logic        retention_vdd
);

    // -------------------------------------------------------------------------
    // SECDED(39,32) Syndrome ROM — module-level localparam for synthesis
    // syn_lut[syndrome[5:0]] = data bit index to flip (6'h3F = check bit/no flip)
    // Syndrome → Hamming position → data bit:
    //   pos 3→d0, 5→d1, 6→d2, 7→d3, 9→d4, 10→d5, 11→d6, 12→d7
    //   13→d8,  14→d9,  15→d10, 17→d11, 18→d12, 19→d13, 20→d14, 21→d15
    //   22→d16, 23→d17, 24→d18, 25→d19, 26→d20, 27→d21, 28→d22, 29→d23
    //   30→d24, 31→d25, 33→d26, 34→d27, 35→d28, 36→d29, 37→d30, 38→d31
    // -------------------------------------------------------------------------
    localparam logic [5:0] SYN_LUT [0:63] = '{
        6'h3F, // 00: no error
        6'h3F, // 01: pos 1  = c0 check bit
        6'h3F, // 02: pos 2  = c1 check bit
        6'd0,  // 03: pos 3  → d[0]
        6'h3F, // 04: pos 4  = c2 check bit
        6'd1,  // 05: pos 5  → d[1]
        6'd2,  // 06: pos 6  → d[2]
        6'd3,  // 07: pos 7  → d[3]
        6'h3F, // 08: pos 8  = c3 check bit
        6'd4,  // 09: pos 9  → d[4]
        6'd5,  // 0A: pos 10 → d[5]
        6'd6,  // 0B: pos 11 → d[6]
        6'd7,  // 0C: pos 12 → d[7]
        6'd8,  // 0D: pos 13 → d[8]
        6'd9,  // 0E: pos 14 → d[9]
        6'd10, // 0F: pos 15 → d[10]
        6'h3F, // 10: pos 16 = c4 check bit
        6'd11, // 11: pos 17 → d[11]
        6'd12, // 12: pos 18 → d[12]
        6'd13, // 13: pos 19 → d[13]
        6'd14, // 14: pos 20 → d[14]
        6'd15, // 15: pos 21 → d[15]
        6'd16, // 16: pos 22 → d[16]
        6'd17, // 17: pos 23 → d[17]
        6'd18, // 18: pos 24 → d[18]
        6'd19, // 19: pos 25 → d[19]
        6'd20, // 1A: pos 26 → d[20]
        6'd21, // 1B: pos 27 → d[21]
        6'd22, // 1C: pos 28 → d[22]
        6'd23, // 1D: pos 29 → d[23]
        6'd24, // 1E: pos 30 → d[24]
        6'd25, // 1F: pos 31 → d[25]
        6'h3F, // 20: pos 32 = c5 check bit
        6'd26, // 21: pos 33 → d[26]
        6'd27, // 22: pos 34 → d[27]
        6'd28, // 23: pos 35 → d[28]
        6'd29, // 24: pos 36 → d[29]
        6'd30, // 25: pos 37 → d[30]
        6'd31, // 26: pos 38 → d[31]
        6'h3F, // 27: unused
        6'h3F, // 28: unused
        6'h3F, // 29: unused
        6'h3F, // 2A: unused
        6'h3F, // 2B: unused
        6'h3F, // 2C: unused
        6'h3F, // 2D: unused
        6'h3F, // 2E: unused
        6'h3F, // 2F: unused
        6'h3F, // 30: unused
        6'h3F, // 31: unused
        6'h3F, // 32: unused
        6'h3F, // 33: unused
        6'h3F, // 34: unused
        6'h3F, // 35: unused
        6'h3F, // 36: unused
        6'h3F, // 37: unused
        6'h3F, // 38: unused
        6'h3F, // 39: unused
        6'h3F, // 3A: unused
        6'h3F, // 3B: unused
        6'h3F, // 3C: unused
        6'h3F, // 3D: unused
        6'h3F, // 3E: unused
        6'h3F  // 3F: unused
    };

    // -------------------------------------------------------------------------
    // SRAM array: 64K words x 39 bits (32 data + 7 ECC check bits)
    // -------------------------------------------------------------------------
    logic [38:0] mem [0:65535];

    // -------------------------------------------------------------------------
    // SECDED encode: Hamming(38,32) + overall parity bit
    // -------------------------------------------------------------------------
    function automatic logic [6:0] secded_encode (input logic [31:0] d);
        logic [6:0] c;
        c[0] = ^{d[0],d[1],d[3],d[4],d[6],d[8],d[10],d[11],
                  d[13],d[15],d[17],d[19],d[21],d[23],d[25],d[26],d[28],d[30]};
        c[1] = ^{d[0],d[2],d[3],d[5],d[6],d[9],d[10],d[12],
                  d[13],d[16],d[17],d[20],d[21],d[24],d[25],d[27],d[28],d[31]};
        c[2] = ^{d[1],d[2],d[3],d[7],d[8],d[9],d[10],d[14],
                  d[15],d[16],d[17],d[22],d[23],d[24],d[25],d[29],d[30],d[31]};
        c[3] = ^{d[4],d[5],d[6],d[7],d[8],d[9],d[10],d[18],
                  d[19],d[20],d[21],d[22],d[23],d[24],d[25]};
        c[4] = ^{d[11],d[12],d[13],d[14],d[15],d[16],d[17],
                  d[18],d[19],d[20],d[21],d[22],d[23],d[24],d[25]};
        c[5] = ^{d[26],d[27],d[28],d[29],d[30],d[31]};
        c[6] = ^{d[31:0], c[5:0]};   // overall parity (SECDED)
        return c;
    endfunction

    // -------------------------------------------------------------------------
    // Write path
    // -------------------------------------------------------------------------
    always_ff @(posedge CLK_TILE) begin
        if (we)
            mem[addr] <= {secded_encode(wdata), wdata};
    end

    // -------------------------------------------------------------------------
    // Read path: registered 1-cycle output
    // -------------------------------------------------------------------------
    logic [31:0] rdata_raw_r;
    logic [6:0]  ecc_stored_r;

    // Write-through bypass register: track last write address for hazard detection
    logic [15:0] wr_addr_r;
    logic [31:0] wr_data_r;
    logic        wr_active_r;

    always_ff @(posedge CLK_TILE) begin
        if (!RSTN_TILE) begin
            rdata_raw_r  <= 32'h0;
            ecc_stored_r <= 7'h0;
            wr_active_r  <= 1'b0;
            wr_addr_r    <= 16'h0;
            wr_data_r    <= 32'h0;
        end else begin
            wr_active_r <= we;
            wr_addr_r   <= addr;
            wr_data_r   <= wdata;
            if (!we) begin
                // Normal read: check if read address matches last write (bypass)
                if (wr_active_r && (addr == wr_addr_r)) begin
                    // Write-through bypass: return the just-written data
                    rdata_raw_r  <= wr_data_r;
                    ecc_stored_r <= secded_encode(wr_data_r);
                end else begin
                    rdata_raw_r  <= mem[addr][31:0];
                    ecc_stored_r <= mem[addr][38:32];
                end
            end
        end
    end

    // -------------------------------------------------------------------------
    // SECDED decode: syndrome check on registered data
    // -------------------------------------------------------------------------
    logic [6:0]  c_calc;
    logic [5:0]  syndrome;
    logic        overall_parity_err;

    always_comb begin
        c_calc             = secded_encode(rdata_raw_r);
        syndrome           = c_calc[5:0] ^ ecc_stored_r[5:0];
        overall_parity_err = c_calc[6]   ^ ecc_stored_r[6];

        ecc_err_1b         = (syndrome != 6'h0) &&  overall_parity_err;
        ecc_err_2b         = (syndrome != 6'h0) && !overall_parity_err;

        // Apply SECDED correction using module-level SYN_LUT localparam ROM
        // (synthesizable: localparam ROM inferred as combinatorial read-only logic)
        ecc_corrected_data = rdata_raw_r;
        if (ecc_err_1b) begin
            // Look up data bit index for this syndrome
            case (syndrome)
                6'h03: ecc_corrected_data[0]  = ~rdata_raw_r[0];
                6'h05: ecc_corrected_data[1]  = ~rdata_raw_r[1];
                6'h06: ecc_corrected_data[2]  = ~rdata_raw_r[2];
                6'h07: ecc_corrected_data[3]  = ~rdata_raw_r[3];
                6'h09: ecc_corrected_data[4]  = ~rdata_raw_r[4];
                6'h0A: ecc_corrected_data[5]  = ~rdata_raw_r[5];
                6'h0B: ecc_corrected_data[6]  = ~rdata_raw_r[6];
                6'h0C: ecc_corrected_data[7]  = ~rdata_raw_r[7];
                6'h0D: ecc_corrected_data[8]  = ~rdata_raw_r[8];
                6'h0E: ecc_corrected_data[9]  = ~rdata_raw_r[9];
                6'h0F: ecc_corrected_data[10] = ~rdata_raw_r[10];
                6'h11: ecc_corrected_data[11] = ~rdata_raw_r[11];
                6'h12: ecc_corrected_data[12] = ~rdata_raw_r[12];
                6'h13: ecc_corrected_data[13] = ~rdata_raw_r[13];
                6'h14: ecc_corrected_data[14] = ~rdata_raw_r[14];
                6'h15: ecc_corrected_data[15] = ~rdata_raw_r[15];
                6'h16: ecc_corrected_data[16] = ~rdata_raw_r[16];
                6'h17: ecc_corrected_data[17] = ~rdata_raw_r[17];
                6'h18: ecc_corrected_data[18] = ~rdata_raw_r[18];
                6'h19: ecc_corrected_data[19] = ~rdata_raw_r[19];
                6'h1A: ecc_corrected_data[20] = ~rdata_raw_r[20];
                6'h1B: ecc_corrected_data[21] = ~rdata_raw_r[21];
                6'h1C: ecc_corrected_data[22] = ~rdata_raw_r[22];
                6'h1D: ecc_corrected_data[23] = ~rdata_raw_r[23];
                6'h1E: ecc_corrected_data[24] = ~rdata_raw_r[24];
                6'h1F: ecc_corrected_data[25] = ~rdata_raw_r[25];
                6'h21: ecc_corrected_data[26] = ~rdata_raw_r[26];
                6'h22: ecc_corrected_data[27] = ~rdata_raw_r[27];
                6'h23: ecc_corrected_data[28] = ~rdata_raw_r[28];
                6'h24: ecc_corrected_data[29] = ~rdata_raw_r[29];
                6'h25: ecc_corrected_data[30] = ~rdata_raw_r[30];
                6'h26: ecc_corrected_data[31] = ~rdata_raw_r[31];
                default: ; // check bit error or no-op
            endcase
        end

        rdata = ecc_err_1b ? ecc_corrected_data : rdata_raw_r;
    end

endmodule
