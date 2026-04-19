// =============================================================================
// Module:      icg_cell
// Description: Integrated Clock Gate — behavioural model
//              Cogni-V Engine — EPC gate_out drives EN; latch-based ICG.
//              Replace with foundry ICG macro for production synthesis.
// =============================================================================
module icg_cell (
    input  logic CLK,    // Free-running input clock
    input  logic EN,     // Clock enable (from EPC gate_out bit)
    input  logic TE,     // Test enable (scan bypass)
    output logic GCLK    // Gated clock output
);
    logic en_latch;

    // Level-sensitive latch: sample EN|TE on CLK-low phase to prevent glitch
    always_latch begin
        if (!CLK) begin
            en_latch = EN | TE;
        end
    end

    assign GCLK = CLK & en_latch;

endmodule : icg_cell
