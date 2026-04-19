# =============================================================================
# Constraints: cogniv_system.xdc
# Cogni-V Engine — Clock Domain Definitions
# COGNIV-SPEC-001 / Three-domain clocking: CORE, TILE, NOC
#
# Adjust periods to match your target frequency / FPGA/ASIC node.
# These values assume a mid-range FPGA target (e.g. UltraScale+).
# For ASIC 16nm: CORE=2.0ns(500MHz), TILE=2.0ns(500MHz), NOC=1.6ns(625MHz)
# =============================================================================

# -----------------------------------------------------------------------------
# Primary Clocks
# -----------------------------------------------------------------------------

# CLK_CORE: RV64 host core clock (drives cx_decode_unit)
create_clock -period 4.0 -name CLK_CORE [get_ports CLK_CORE]

# CLK_TILE: Tile processing clock (MACs, SRAMs, TLC FSM, EPC softmax pipeline)
create_clock -period 4.0 -name CLK_TILE [get_ports CLK_TILE]

# CLK_NOC: Network-on-Chip clock (noc_router_xy, clb_tile_channel)
create_clock -period 3.2 -name CLK_NOC  [get_ports CLK_NOC]

# -----------------------------------------------------------------------------
# Generated Clocks: ICG gated clocks (one per tile)
# ICG cells gate CLK_TILE per-tile; Vivado needs to know these are derived
# from CLK_TILE so it doesn't treat them as unrelated clock sources.
# -----------------------------------------------------------------------------

# Tile gated clocks — derived from CLK_TILE through icg_cell/GCLK
# Vivado typically auto-derives these; if not, uncomment and enumerate:
# create_generated_clock -name gclk_tile_0 -source [get_ports CLK_TILE] \
#     -divide_by 1 [get_pins g_icg[0].u_icg/GCLK]
# create_generated_clock -name gclk_tile_1 -source [get_ports CLK_TILE] \
#     -divide_by 1 [get_pins g_icg[1].u_icg/GCLK]
# create_generated_clock -name gclk_tile_2 -source [get_ports CLK_TILE] \
#     -divide_by 1 [get_pins g_icg[2].u_icg/GCLK]
# create_generated_clock -name gclk_tile_3 -source [get_ports CLK_TILE] \
#     -divide_by 1 [get_pins g_icg[3].u_icg/GCLK]
# create_generated_clock -name gclk_tile_4 -source [get_ports CLK_TILE] \
#     -divide_by 1 [get_pins g_icg[4].u_icg/GCLK]
# create_generated_clock -name gclk_tile_5 -source [get_ports CLK_TILE] \
#     -divide_by 1 [get_pins g_icg[5].u_icg/GCLK]
# create_generated_clock -name gclk_tile_6 -source [get_ports CLK_TILE] \
#     -divide_by 1 [get_pins g_icg[6].u_icg/GCLK]
# create_generated_clock -name gclk_tile_7 -source [get_ports CLK_TILE] \
#     -divide_by 1 [get_pins g_icg[7].u_icg/GCLK]
# create_generated_clock -name gclk_tile_8 -source [get_ports CLK_TILE] \
#     -divide_by 1 [get_pins g_icg[8].u_icg/GCLK]

# -----------------------------------------------------------------------------
# Clock Domain Crossing (CDC) — set_clock_groups
# CLK_CORE, CLK_TILE, CLK_NOC are asynchronous to each other.
# This prevents Vivado from reporting false timing paths across domains.
# -----------------------------------------------------------------------------
set_clock_groups -asynchronous \
    -group [get_clocks CLK_CORE] \
    -group [get_clocks CLK_TILE] \
    -group [get_clocks CLK_NOC]

# -----------------------------------------------------------------------------
# Input / Output Delays (adjust to your board/interface requirements)
# Using 20% of clock period as a placeholder
# -----------------------------------------------------------------------------

# CLK_CORE domain I/O
set_input_delay  -clock CLK_CORE -max 0.8 [get_ports {cx_instr_word[*] cx_instr_valid cx_operand_a[*] cx_operand_b[*]}]
set_output_delay -clock CLK_CORE -max 0.8 [get_ports {cx_opcode[*] cx_tile_mask[*] cx_decode_valid cx_illegal_instr}]

# CLK_TILE domain I/O
set_input_delay  -clock CLK_TILE -max 0.8 [get_ports {epc_eval_start epc_k_cfg[*] epc_logit_in[*]}]
set_output_delay -clock CLK_TILE -max 0.8 [get_ports {tile_done[*] tile_error[*] epc_gate_out[*] epc_gate_out_valid epc_topk_tie epc_invalid_k}]

# CLK_NOC domain I/O
set_input_delay  -clock CLK_NOC  -max 0.6 [get_ports {clb_pkt_hi_in[*] clb_pkt_lo_in[*] clb_pkt_hi_wr[*] clb_pkt_lo_wr[*] clb_tile_ack[*]}]
set_output_delay -clock CLK_NOC  -max 0.6 [get_ports {clb_stall[*] clb_overflow_err[*] clb_parity_err[*]}]

# Scan test enable (quasi-static, constrain loosely)
set_input_delay  -clock CLK_TILE -max 0.8 [get_ports scan_te]

# -----------------------------------------------------------------------------
# False Paths
# -----------------------------------------------------------------------------

# Reset pins are synchronous per domain but driven asynchronously at top level
set_false_path -from [get_ports RSTN_CORE]
set_false_path -from [get_ports RSTN_TILE]
set_false_path -from [get_ports RSTN_NOC]
