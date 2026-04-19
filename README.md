# Cogni-V Engine

A 3×3 tile-based neural network accelerator implementing a **Mixture-of-Experts (MoE)** datapath in SystemVerilog. The design targets **Xilinx Artix-7 FPGA** for prototyping and is architected for migration to **TSMC 16nm FFC ASIC**.

---

## What It Does

The Cogni-V Engine accelerates sparse MoE inference by routing compute tokens to selected expert tiles via a mesh Network-on-Chip (NoC). A RISC-V host CPU controls the engine through a 5-instruction Custom Extension (CX) ISA. An Expert Policy Controller (EPC) runs a softmax Top-K gate each inference step to decide which tiles are active, then power-gates the rest using Integrated Clock Gate (ICG) cells.

```
RISC-V Host
    │
    ├─ CX_DISPATCH ──► CLB (Command Launch Block) ──► NoC (XY Mesh)
    ├─ CX_GATE_EVAL ─► EPC (Softmax Top-K) ──────────► ICG cells
    └─ CX_COLLECT   ◄─ result flits ◄───────────────── Tiles [0..8]
                                                            │
                                                     TLC + MAC + SRAM
```

---

## Repository Structure

```
CogniChip/
├── Design/                        # RTL source files
│   ├── cogniv_system.sv           # Top-level integration (3×3 tile array)
│   ├── tile_local_ctrl.sv         # TLC FSM (7-state, per tile)
│   ├── mac_array_16lane.sv        # 16-lane BF16/INT8 MAC array
│   ├── tile_sram_256kb.sv         # 256 KB SECDED SRAM (65536×32b)
│   ├── noc_router_xy.sv           # 5-port XY router, credit-based flow ctrl
│   ├── clb_tile_channel.sv        # Host→Tile dispatch channel, 4-credit FIFO
│   ├── epc_softmax_topk.sv        # Softmax Top-K gate (18-cycle pipeline)
│   ├── cx_decode_unit.sv          # CX instruction decoder
│   ├── icg_cell.sv                # Per-tile clock gate cell
│   ├── tb_cogniv_system.sv        # System-level testbench
│   └── tb_*.sv                    # Unit testbenches (one per module)
│
├── Verification/                  # UVM verification infrastructure
│   ├── cogniv_common_pkg.sv       # Shared types, packet builder, parity utils
│   ├── cogniv_adapter_pkg.sv      # Transaction adapters & EPC reference model
│   └── tlc_uvm_pkg.sv             # Full UVM env for TLC (txn/seq/drv/mon/sb/cov)
│
├── DEPS.yml                       # Simulation dependency and target definitions
├── cogniv_engine_verification_spec.md  # Full verification specification (COGNIV-VSPEC-001)
└── README.md                      # This file
```

---

## Key Modules

| Module | Description |
|--------|-------------|
| `cogniv_system` | Top-level: 9 tiles, 9 NoC routers, 9 CLB channels, 1 EPC, 1 CX decoder |
| `tile_local_ctrl` | 7-state FSM — IDLE → MAC_LOAD → MAC_EXEC → MAC_DRAIN → RESULT_TX → ERROR |
| `mac_array_16lane` | 16-lane parallel MAC; BF16 (2 ops/lane/cycle) or INT8 (4 ops/lane/cycle) |
| `tile_sram_256kb` | 64K×32b SRAM with SECDED ECC (1-bit correct, 2-bit detect) |
| `noc_router_xy` | 5-port (W/E/N/S/Local) XY router; round-robin arbitration; max 4 hops |
| `clb_tile_channel` | 4-credit flow-controlled dispatch channel; 4-nibble parity check |
| `epc_softmax_topk` | 10-phase numerically-stable softmax; Top-K in 18 cycles; ICG driver |
| `cx_decode_unit` | Decodes RISC-V custom-0 instructions; 5 valid opcodes; illegal detection |
| `icg_cell` | Latch-based ICG; scan-TE bypass for simulation |

---

## Clock Domains

| Domain | Signal | Frequency (RTL) | Description |
|--------|--------|----------------|-------------|
| CORE | `CLK_CORE` | 100 MHz | CX decode, host interface |
| TILE | `CLK_TILE` | 125 MHz | TLC FSM, MAC array, EPC |
| NOC | `CLK_NOC` | ~167 MHz | NoC routers, CLB channels |

All resets are active-low synchronous (`RSTN_*`).

---

## Simulation Targets (`DEPS.yml`)

| Target | Top Module | What It Tests |
|--------|-----------|---------------|
| `bench_tile_sram_256kb` | `tb_tile_sram_256kb` | SECDED R/W, ECC 1b/2b, retention |
| `bench_mac_array_16lane` | `tb_mac_array_16lane` | BF16/INT8, accumulate, drain |
| `bench_tile_local_ctrl` | `tb_tile_local_ctrl` | FSM states, CFG, ECC error |
| `bench_clb_tile_channel` | `tb_clb_tile_channel` | Credits, parity, overflow |
| `bench_epc_softmax_topk` | `tb_epc_softmax_topk` | Softmax, Top-K, tie, invalid-K |
| `bench_noc_router_xy` | `tb_noc_router_xy` | XY routing, backpressure |
| `bench_icg_cell` | `tb_icg_cell` | EN/TE gating, glitch-free |
| `bench_cx_decode_unit` | `tb_cx_decode_unit` | All 5 opcodes, illegal detect |
| `bench_cogniv_system` | `tb_cogniv_system` | Reset, CX decode, CLB→NoC→MAC→tile_done |

---

## Simulation Results

All 8 unit-level benchmarks pass with **189 checks, 0 failures**.

| Target | Checks Passed | Checks Failed |
|--------|:------------:|:-------------:|
| bench_tile_sram_256kb | 39 | 0 |
| bench_mac_array_16lane | 66 | 0 |
| bench_tile_local_ctrl | 18 | 0 |
| bench_clb_tile_channel | 12 | 0 |
| bench_epc_softmax_topk | 16 | 0 |
| bench_noc_router_xy | 12 | 0 |
| bench_icg_cell | 6 | 0 |
| bench_cx_decode_unit | 20 | 0 |
| **Total** | **189** | **0** |

---

## Target Platforms

| Platform | Details |
|----------|---------|
| **FPGA (prototype)** | Xilinx Artix-7 (XC7A200T) — ~85K LUTs, 125/167 MHz achievable |
| **ASIC (target)** | TSMC 16nm FFC — ~1.0–1.5 mm², 800 MHz+ capable, ~70–90 mW total |

---

## Documentation

Full specification: COGNIV-SPEC.md
