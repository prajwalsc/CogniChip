// =============================================================================
// Module:      noc_router_xy
// Description: 3x3 Mesh NoC Router — XY routing, 2 VCs, credit-based flow
//              Cogni-V Engine — COGNIV-SPEC-001 ss2.3
//
//  5 ports: West(0), East(1), North(2), South(3), Local(4)
//  2 Virtual Channels: VC0=data flits, VC1=ACK flits  (flit[0]=is_ack)
//  XY routing: resolve column offset first (E/W), then row offset (N/S)
//  Per-output-port register FIFO, depth = FIFO_D per VC
//  Round-robin arbitration across input ports per output port
//  Routing key: flit[7:4] = dst_tile[3:0]  (3x3 grid tile_id 0-8)
// =============================================================================
module noc_router_xy #(
    parameter int unsigned TILE_ID  = 0,
    parameter int unsigned FLIT_W   = 128,
    parameter int unsigned VC_COUNT = 2,
    parameter int unsigned FIFO_D   = 4
)(
    input  logic             CLK_NOC,
    input  logic             RSTN_SYNC,

    // West port
    input  logic [FLIT_W-1:0] flit_in_west,
    input  logic               vld_in_west,
    output logic               rdy_in_west,
    output logic [FLIT_W-1:0] flit_out_west,
    output logic               vld_out_west,
    input  logic               rdy_out_west,

    // East port
    input  logic [FLIT_W-1:0] flit_in_east,
    input  logic               vld_in_east,
    output logic               rdy_in_east,
    output logic [FLIT_W-1:0] flit_out_east,
    output logic               vld_out_east,
    input  logic               rdy_out_east,

    // North port
    input  logic [FLIT_W-1:0] flit_in_north,
    input  logic               vld_in_north,
    output logic               rdy_in_north,
    output logic [FLIT_W-1:0] flit_out_north,
    output logic               vld_out_north,
    input  logic               rdy_out_north,

    // South port
    input  logic [FLIT_W-1:0] flit_in_south,
    input  logic               vld_in_south,
    output logic               rdy_in_south,
    output logic [FLIT_W-1:0] flit_out_south,
    output logic               vld_out_south,
    input  logic               rdy_out_south,

    // Local tile inject/eject
    input  logic [FLIT_W-1:0] flit_in_local,
    input  logic               vld_in_local,
    output logic               rdy_in_local,
    output logic [FLIT_W-1:0] flit_out_local,
    output logic               vld_out_local,
    input  logic               rdy_out_local
);
    // -------------------------------------------------------------------------
    // Grid position of this router
    // -------------------------------------------------------------------------
    localparam int MY_ROW  = int'(TILE_ID) / 3;
    localparam int MY_COL  = int'(TILE_ID) % 3;

    localparam int P_WEST  = 0;
    localparam int P_EAST  = 1;
    localparam int P_NORTH = 2;
    localparam int P_SOUTH = 3;
    localparam int P_LOCAL = 4;
    localparam int N_PORTS = 5;

    // -------------------------------------------------------------------------
    // Input port array aliases
    // -------------------------------------------------------------------------
    logic [FLIT_W-1:0] fi [0:N_PORTS-1];
    logic               vi [0:N_PORTS-1];
    logic               ri [0:N_PORTS-1];

    assign fi[P_WEST]  = flit_in_west;   assign fi[P_EAST]  = flit_in_east;
    assign fi[P_NORTH] = flit_in_north;  assign fi[P_SOUTH] = flit_in_south;
    assign fi[P_LOCAL] = flit_in_local;

    assign vi[P_WEST]  = vld_in_west;    assign vi[P_EAST]  = vld_in_east;
    assign vi[P_NORTH] = vld_in_north;   assign vi[P_SOUTH] = vld_in_south;
    assign vi[P_LOCAL] = vld_in_local;

    assign rdy_in_west  = ri[P_WEST];    assign rdy_in_east  = ri[P_EAST];
    assign rdy_in_north = ri[P_NORTH];   assign rdy_in_south = ri[P_SOUTH];
    assign rdy_in_local = ri[P_LOCAL];

    // -------------------------------------------------------------------------
    // Output FIFOs: [port][vc][slot]
    // -------------------------------------------------------------------------
    logic [FLIT_W-1:0] ofifo [0:N_PORTS-1][0:VC_COUNT-1][0:FIFO_D-1];
    logic [1:0]        owp   [0:N_PORTS-1][0:VC_COUNT-1];
    logic [1:0]        orp   [0:N_PORTS-1][0:VC_COUNT-1];
    logic [2:0]        ocnt  [0:N_PORTS-1][0:VC_COUNT-1];

    // -------------------------------------------------------------------------
    // XY routing function: returns output port index for a destination tile
    // -------------------------------------------------------------------------
    function automatic int xy_route_f(input logic [3:0] dst);
        int dr, dc;
        dr = int'(dst) / 3;
        dc = int'(dst) % 3;
        if      (dc > MY_COL) return P_EAST;
        else if (dc < MY_COL) return P_WEST;
        else if (dr > MY_ROW) return P_SOUTH;
        else if (dr < MY_ROW) return P_NORTH;
        else                   return P_LOCAL;
    endfunction

    // -------------------------------------------------------------------------
    // Combinatorial routing lookup per input port
    // -------------------------------------------------------------------------
    int route_p [0:N_PORTS-1];  // output port for each input
    int route_v [0:N_PORTS-1];  // VC (0 or 1) for each input

    always_comb begin
        for (int p = 0; p < N_PORTS; p++) begin
            route_p[p] = xy_route_f(fi[p][7:4]);
            route_v[p] = int'(fi[p][0]);  // is_ack bit selects VC
        end
    end

    // -------------------------------------------------------------------------
    // Round-robin arbitration pointer per output port
    // -------------------------------------------------------------------------
    int rr_r [0:N_PORTS-1];

    // -------------------------------------------------------------------------
    // Sequential: FIFO enqueue, dequeue, rdy_in update
    // -------------------------------------------------------------------------
    always_ff @(posedge CLK_NOC) begin : ff_main
        // Variables hoisted to block scope for Verilator compatibility
        // (declarations inside for-loop bodies are not reliably handled
        //  in always_ff contexts by all tools)
        int  sel_v, vc_v, op2_v, vc2_v;
        logic ordy_v;
        if (!RSTN_SYNC) begin
            for (int p = 0; p < N_PORTS; p++) begin
                rr_r[p] <= 0;
                ri[p]   <= 1'b1;
                ov_r[p] <= 1'b0;
                for (int v = 0; v < VC_COUNT; v++) begin
                    owp[p][v]  <= 2'd0;
                    orp[p][v]  <= 2'd0;
                    ocnt[p][v] <= 3'd0;
                end
            end
        end else begin
            // --- Enqueue: per output port, admit one winning input ---
            for (int op = 0; op < N_PORTS; op++) begin
                for (int ii = 0; ii < N_PORTS; ii++) begin
                    sel_v = (rr_r[op] + ii) % N_PORTS;
                    vc_v  = route_v[sel_v];
                    if (vi[sel_v] && (route_p[sel_v] == op) &&
                        (ocnt[op][vc_v] < 3'(FIFO_D))) begin
                        ofifo[op][vc_v][owp[op][vc_v]] <= fi[sel_v];
                        owp[op][vc_v]  <= owp[op][vc_v] + 2'd1;
                        ocnt[op][vc_v] <= ocnt[op][vc_v] + 3'd1;
                        rr_r[op]       <= (rr_r[op] + ii + 1) % N_PORTS;
                        break;
                    end
                end
            end

            // --- Dequeue: drain when downstream ready; VC0 has priority ---
            for (int op = 0; op < N_PORTS; op++) begin
                logic ordy;
                case (op)
                    P_WEST:  ordy_v = rdy_out_west;
                    P_EAST:  ordy_v = rdy_out_east;
                    P_NORTH: ordy_v = rdy_out_north;
                    P_SOUTH: ordy_v = rdy_out_south;
                    default: ordy_v = rdy_out_local;
                endcase
                // Only dequeue when ov_r is set (flit has been presented
                // for one full cycle) AND downstream is ready.
                // This ensures the receiver has at least one clock cycle
                // to sample vld_out before the flit is consumed.
                if (ov_r[op] && ordy_v) begin
                    if (ocnt[op][0] > 3'd0) begin
                        orp[op][0]  <= orp[op][0] + 2'd1;
                        ocnt[op][0] <= ocnt[op][0] - 3'd1;
                    end else if (ocnt[op][1] > 3'd0) begin
                        orp[op][1]  <= orp[op][1] + 2'd1;
                        ocnt[op][1] <= ocnt[op][1] - 3'd1;
                    end
                end
            end

            // --- rdy_in: assert when chosen output VC has space ---
            for (int ip = 0; ip < N_PORTS; ip++) begin
                op2_v = route_p[ip];
                vc2_v = route_v[ip];
                ri[ip] <= (ocnt[op2_v][vc2_v] < 3'(FIFO_D));
            end

            // --- Register ov_arr so dequeue fires one cycle after enqueue ---
            for (int op = 0; op < N_PORTS; op++)
                ov_r[op] <= ov_arr[op];
        end
    end

    // -------------------------------------------------------------------------
    // Output mux: present head-of-queue flit; VC0 priority over VC1
    // -------------------------------------------------------------------------
    logic [FLIT_W-1:0] of_arr [0:N_PORTS-1];
    logic               ov_arr [0:N_PORTS-1];

    // Registered output-valid: dequeue only fires AFTER the flit has been
    // visible for one full cycle (prevents same-cycle enqueue+dequeue draining
    // the flit before the downstream receiver can observe it).
    logic ov_r [0:N_PORTS-1];  // registered ov_arr — dequeue only fires after flit held 1 cycle

    always_comb begin
        for (int op = 0; op < N_PORTS; op++) begin
            if (ocnt[op][0] > 3'd0) begin
                of_arr[op] = ofifo[op][0][orp[op][0]];
                ov_arr[op] = 1'b1;
            end else if (ocnt[op][1] > 3'd0) begin
                of_arr[op] = ofifo[op][1][orp[op][1]];
                ov_arr[op] = 1'b1;
            end else begin
                of_arr[op] = '0;
                ov_arr[op] = 1'b0;
            end
        end
    end

    assign flit_out_west  = of_arr[P_WEST];   assign vld_out_west  = ov_arr[P_WEST];
    assign flit_out_east  = of_arr[P_EAST];   assign vld_out_east  = ov_arr[P_EAST];
    assign flit_out_north = of_arr[P_NORTH];  assign vld_out_north = ov_arr[P_NORTH];
    assign flit_out_south = of_arr[P_SOUTH];  assign vld_out_south = ov_arr[P_SOUTH];
    assign flit_out_local = of_arr[P_LOCAL];  assign vld_out_local = ov_arr[P_LOCAL];

endmodule : noc_router_xy
