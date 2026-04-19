# Cogni-V Engine — Verification Specification
**Document ID:** COGNIV-VSPEC-001  
**Spec Ref:** COGNIV-SPEC-001-FULL v3.0 / SPEC-004-MODULE  
**Status:** Preliminary — Derived from RTL & UVM Source Analysis  
**Date:** 2026-04-19

---

## Table of Contents
1. [Introduction](#1-introduction)
2. [Feature Summary](#2-feature-summary)
3. [Functional Description](#3-functional-description)
4. [Interface Description](#4-interface-description)
5. [Parameterization Options](#5-parameterization-options)
6. [Register Description](#6-register-description)
7. [Design Guidelines](#7-design-guidelines)
8. [Timing Diagrams](#8-timing-diagrams)

---

## 1. Introduction

### 1.1 Overview

The **Cogni-V Engine** is a tile-array neural network accelerator implementing a
Mixture-of-Experts (MoE) datapath on a 3×3 grid of nine compute tiles. Each tile
contains a 16-lane MAC array, a 256 KB SRAM weight store, and a Tile Local
Controller (TLC) FSM. The engine is controlled by a RISC-V host processor via a
five-instruction Custom Extension (CX) ISA. An Expert Policy Controller (EPC)
evaluates a 9-expert softmax Top-K gate to enable or disable individual tile
clocks, providing per-tile dynamic power gating.

The entire design runs at **2 GHz** (0.5 ns clock period) on two phase-aligned
clocks: `CLK_CORE` (host/CLB domain) and `CLK_NOC`/`CLK_TILE` (tile domain).

### 1.2 Scope

This document specifies the verification requirements, functional behaviour,
interfaces, registers, and timing of the Cogni-V Engine at **three verification
levels**:

| Level | DUT Scope | Key Files |
|-------|-----------|-----------|
| **Module** | Single `tile_local_ctrl` + sub-modules | `tlc_env_pkg`, `tlc_if`, `tlc_dut_stub` |
| **Subsystem** | CLB + NoC + EPC + single tile | `cogniv_env_pkg`, adapters |
| **System** | Full 9-tile array end-to-end | `cogniv_tb_top` |

### 1.3 Document Conventions

- **REQ_ID** — Requirement identifier (REQ_xxx)
- **TV-xxx** — Test vector identifier as referenced in `cogniv_sequences_pkg.sv`
- `code` — Signal names, register fields, or file references
- *(spec ref ss_N.M)* — Cross-reference to COGNIV-SPEC-001-FULL section N.M

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

Full verification specification: [`cogniv_engine_verification_spec.md`](cogniv_engine_verification_spec.md)

Covers: 25 functional requirements, 15 directed test vectors, complete interface tables (TLC, CLB, NoC, EPC, system top), register map, timing diagrams (WaveDrom), UVM testbench architecture, regression plan (3-tier), and sign-off criteria.
