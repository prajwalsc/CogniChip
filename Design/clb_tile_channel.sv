// =============================================================================

// Module:      clb_tile_channel
// Description: CLB FIFO and Credit Module (one instance per tile)
//              Cogni-V Engine — COGNIV-SPEC-004-MODULE v1.0, Section 4
// =============================================================================

module clb_tile_channel (
    input  logic         CLK_NOC,
    input  logic         RSTN_SYNC,
    input  logic [63:0]  pkt_hi_in,
    input  logic [63:0]  pkt_lo_in,
    input  logic         pkt_hi_wr,
    input  logic         pkt_lo_wr,
    output logic [127:0] noc_flit_out,
    output logic         noc_flit_vld,
    input  logic         noc_flit_rdy,
    input  logic         tile_ack_in,
    output logic [2:0]   credit_cnt,
    output logic         stall_out,
    output logic         overflow_err,
    output logic         parity_err,
    output logic         pkt_hi_valid
);

    logic [63:0]  pkt_hi_r;
    logic [127:0] assembled_pkt;
    logic [3:0]   parity_check, parity_stored;
    logic         parity_ok;
    logic [127:0] fifo_mem [0:3];
    logic [1:0]   wr_ptr_r, rd_ptr_r;
    logic [2:0]   fifo_cnt_r;
    logic         fifo_full, fifo_empty;
    logic         enqueue, dequeue;

    always_ff @(posedge CLK_NOC) begin
        if (!RSTN_SYNC) begin
            pkt_hi_r     <= 64'h0;
            pkt_hi_valid <= 1'b0;
        end else if (pkt_hi_wr) begin
            pkt_hi_r     <= pkt_hi_in;
            pkt_hi_valid <= 1'b1;
        end else if (pkt_lo_wr && pkt_hi_valid) begin
            pkt_hi_valid <= 1'b0;
        end
    end

    assign assembled_pkt   = {pkt_hi_r, pkt_lo_in};
    assign parity_stored   = assembled_pkt[127:124];
    assign parity_check[0] = ^assembled_pkt[30:0];
    assign parity_check[1] = ^assembled_pkt[61:31];
    assign parity_check[2] = ^assembled_pkt[92:62];
    assign parity_check[3] = ^assembled_pkt[123:93];
    assign parity_ok       = (parity_check == parity_stored);

    assign fifo_full  = (fifo_cnt_r == 3'd4);
    assign fifo_empty = (fifo_cnt_r == 3'd0);
    assign enqueue    = pkt_lo_wr && pkt_hi_valid && parity_ok && (credit_cnt > 3'd0);
    assign dequeue    = !fifo_empty && noc_flit_rdy;

    always_ff @(posedge CLK_NOC) begin
        if (!RSTN_SYNC) begin
            wr_ptr_r   <= 2'd0;
            rd_ptr_r   <= 2'd0;
            fifo_cnt_r <= 3'd0;
        end else begin
            if (enqueue && !fifo_full) begin
                fifo_mem[wr_ptr_r] <= assembled_pkt;
                wr_ptr_r           <= wr_ptr_r + 2'd1;
            end
            if (dequeue)
                rd_ptr_r <= rd_ptr_r + 2'd1;
            case ({(enqueue && !fifo_full), dequeue})
                2'b10:   fifo_cnt_r <= fifo_cnt_r + 3'd1;
                2'b01:   fifo_cnt_r <= fifo_cnt_r - 3'd1;
                default: fifo_cnt_r <= fifo_cnt_r;
            endcase
        end
    end

    assign noc_flit_out = fifo_mem[rd_ptr_r];
    assign noc_flit_vld = !fifo_empty;

    always_ff @(posedge CLK_NOC) begin
        if (!RSTN_SYNC)
            credit_cnt <= 3'd4;
        else begin
            case ({enqueue, tile_ack_in})
                2'b10:   credit_cnt <= (credit_cnt > 3'd0) ? credit_cnt - 3'd1 : credit_cnt;
                2'b01:   credit_cnt <= (credit_cnt < 3'd4) ? credit_cnt + 3'd1 : credit_cnt;
                default: credit_cnt <= credit_cnt;
            endcase
        end
    end

    assign stall_out = (credit_cnt == 3'd0);

    always_ff @(posedge CLK_NOC) begin
        if (!RSTN_SYNC) begin
            overflow_err <= 1'b0;
            parity_err   <= 1'b0;
        end else begin
            overflow_err <= enqueue && fifo_full;
            parity_err   <= pkt_lo_wr && pkt_hi_valid && !parity_ok;
        end
    end

endmodule
