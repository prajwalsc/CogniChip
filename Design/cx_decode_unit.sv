// =============================================================================
// Module:      cx_decode_unit
// Description: RISC-V Custom Extension (CX) Instruction Decoder
//              Cogni-V Engine — COGNIV-SPEC-001 ss3 / ss4
//
//  custom-0 opcode (7b0001011), funct3[14:12] = CX opcode:
//   3b000=CX_DISPATCH  3b001=CX_COLLECT  3b010=CX_GATE_EVAL
//   3b011=CX_TILE_CFG  3b100=CX_SYNC     others=ILLEGAL
//  tile_mask = operand_a[8:0]. Output registered (1-cycle latency).
// =============================================================================
module cx_decode_unit (
    input  logic        CLK_CORE,
    input  logic        RSTN_SYNC,
    input  logic [31:0] instr_word,
    input  logic        instr_valid,
    input  logic [63:0] operand_a,
    input  logic [63:0] operand_b,
    output logic [2:0]  cx_opcode,
    output logic [8:0]  tile_mask,
    output logic [63:0] op_a_out,
    output logic [63:0] op_b_out,
    output logic        decode_valid,
    output logic        illegal_instr
);
    localparam logic [6:0] CX_MAJOR = 7'b000_1011;
    logic [2:0] funct3;
    logic       is_cx, is_ill;
    assign funct3  = instr_word[14:12];
    assign is_cx   = (instr_word[6:0] == CX_MAJOR) && instr_valid;
    assign is_ill  = is_cx && (funct3 > 3'b100);
    always_ff @(posedge CLK_CORE) begin
        if (!RSTN_SYNC) begin
            cx_opcode <= 3'b0; tile_mask <= 9'h0;
            op_a_out  <= '0;   op_b_out  <= '0;
            decode_valid <= 1'b0; illegal_instr <= 1'b0;
        end else begin
            decode_valid  <= is_cx && !is_ill;
            illegal_instr <= is_ill;
            if (is_cx) begin
                cx_opcode <= funct3;
                tile_mask <= operand_a[8:0];
                op_a_out  <= operand_a;
                op_b_out  <= operand_b;
            end
        end
    end
endmodule : cx_decode_unit
