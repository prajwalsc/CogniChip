# Cogni-V Engine — Full Detailed Design Specification
### Memory-Efficient AI Accelerator for LLM / MoE Inference

| Field              | Value                                                   |
|--------------------|---------------------------------------------------------|
| **Document ID**    | COGNIV-SPEC-001-FULL                                    |
| **Version**        | 3.0                     |
| **Based On**       | COGNIV-SPEC-002 v2.0 (April 17, 2026)                  |
| **Target Node**    | TSMC 7 nm FinFET (N7)                                   |
| **EDA Platform**   | CogniChip ACI                                           |
| **Authors**        | Rohit Perumal C.B. · Prajwal Chavadi · Madan Girish    |
| **Program**        | SJSU CogniChip Hackathon 2026 — Team Bit-Bashers        |
| **Classification** | Confidential — Internal Use Only                        |


---

## Log (v2.0 → v3.0)

| ID  | Location           | v2.0                           | v3.0 (Corrected)                              |
|-----|--------------------|----------------------------------------------|------------------------------------------------|
| H-1 | §1.2 Perf Targets  | 256 GMAC/s/tile                              | **32 GMAC/s/tile** (16 MACs × 2 GHz)          |
| H-2 | §6.2 EPC_TILE_WEIGHT | "9×BF8 packed in 32-bit"                  | **72-bit minimum required; register TBD**      |
| H-3 | §1 Exec Summary    | "No off-chip DRAM on critical path"          | **Removed; weight streaming model is TBD**     |
| H-4 | §3.4 CX ISA        | "R4-type encoding"                           | **R-type encoding** (rd, rs1, rs2 only)        |
| H-5 | §7.3 Attention     | K=9 via SW_TILE_OVERRIDE                     | **Mechanism undefined; K register is 2-bit**   |
| H-6 | §9.4 SVA           | `$past(PKT_HI_wr, 1)` — 1 cycle assumption  | **Relaxed to `$past(..., 1:N)` or sequence**   |
| H-7 | §6.2 / Glossary    | BF8 format used                              | **Replaced with FP8-E4M3 or INT8; TBD**        |
| H-8 | §1.2 Perf Targets  | "≥ 500 tok/s (7B params)"                   | **TBD — depends on weight streaming arch**     |

---

## Table of Contents

1. [Executive Summary](#1-executive-summary)
2. [System Architecture Overview](#2-system-architecture-overview)
3. [RISC-V Orchestrator Core](#3-risc-v-orchestrator-core)
4. [Cogni-Link Interconnect Bridge](#4-cogni-link-interconnect-bridge)
5. [Mini-Wafer Tile Mesh](#5-mini-wafer-tile-mesh)
6. [Expert Parallelism Controller (EPC)](#6-expert-parallelism-controller-epc)
7. [End-to-End MoE Inference Execution](#7-end-to-end-moe-inference-execution)
8. [Top-Level Interface Signal Tables](#8-top-level-interface-signal-tables)
9. [UVM Verification Environment](#9-uvm-verification-environment)
10. [Clocking and Power Domains](#10-clocking-and-power-domains)
11. [Risk Register](#11-risk-register)
12. [Glossary](#12-glossary)

---

## 1. Executive Summary

The **Cogni-V Engine** is a ground-up AI accelerator SoC targeting Large Language Model (LLM)
inference with Mixture-of-Experts (MoE) sparsity. It reduces memory-bandwidth pressure through
three architectural mechanisms:

1. **On-tile SRAM weight caching** — active expert weights for the current batch window reside
   in per-tile SRAMs. Weight streaming from host via PCIe is required between batch windows.
   *[⚠ CORRECTED from "no off-chip DRAM ever" — H-3]*
2. **Cogni-Link zero-overhead dispatch** — a memory-mapped, credit-based bridge issues
   128-bit micro-op packets to tiles in one store instruction (≤ 5 ns end-to-end latency
   covering CLB + 2 NoC hops).
3. **Dynamic Expert Parallelism (EP)** — the Expert Parallelism Controller (EPC) maps
   Top-K gating output directly to tile cluster assignments every MoE layer, clock-gating
   idle experts at 0.6 V retention voltage.

### 1.1 Top-Level Parameters

| Parameter                      | Value               | Notes                                          |
|-------------------------------|---------------------|------------------------------------------------|
| Process node                   | TSMC N7 FinFET      | SVT / HVT cell libraries                       |
| Core clock (`CLK_CORE`)       | 2 GHz               | PLL-derived, 0.5 ns period                    |
| NoC / bridge clock (`CLK_NOC`)| 2 GHz               | Same PLL source, phase-aligned                |
| Tile clock (`CLK_TILE`)       | 2 GHz               | Per-tile clock gate; gatable per tile         |
| Supply voltage (active)        | 0.8 V               | SVT, nominal                                   |
| Supply voltage (retention)     | 0.6 V               | Idle tile clock-gated                         |
| Tile mesh                      | 3 × 3 (9 tiles)     | Indexed `tile[0]`…`tile[8]`, row-major        |
| SRAM per tile                  | 256 KB              | Single-port, 32-bit wide, 65 536 entries      |
| Total on-chip SRAM             | 2 304 KB (≈ 2.25 MB)| Tile mesh only                                 |
| Max active experts (Top-K)     | 2                   | MoE gating, K ∈ {1, 2}                        |
| Max experts supported          | 9                   | One expert per tile maximum                   |
| CX instruction set             | 5 instructions      | `CX_DISPATCH`, `CX_COLLECT`, `CX_GATE_EVAL`, `CX_TILE_CFG`, `CX_SYNC` |
| Token batch size               | 1–64 tokens         | Configurable via `EPC_BATCH_CFG`               |
| Transformer layers             | 32                  | One MoE loop per layer                        |

### 1.2 Performance Targets

| Metric                               | Target                | 
|--------------------------------------|-----------------------|
| Token throughput (MoE)               | TBD *(H-8)*           | 
| Cogni-Link dispatch latency          | ≤ 5 ns                | 
| MAC throughput per tile              | **32 GMAC/s** *(H-1)* | 
| Idle expert power                    | ≤ 1 mW/tile           | 
| Active tile power                    | ≤ 200 mW/tile         | 

> **Note on MAC throughput (H-1):** 16 MAC units × 2 GHz = **32 GMAC/s** per tile.
> The v2.0 figure of 256 GMAC/s would require 128 MAC units, inconsistent with §5.3.

---

## 2. System Architecture Overview

### 2.1 Block Diagram

```
HOST CPU / PCIe (Off-chip)
    │  PCIe x8 @ 16 GT/s
    │  DMA: weight load per batch window
    ▼
RISC-V Orchestrator  ◄──── CX ISA micro-ops / CSR R/W ────► EPC Co-processor
    │
    │  Store to MMIO: 0xFFFF_0000_0000 base
    ▼
Cogni-Link Bridge (CLB)
    │  128-bit flits, credit flow-control
    ▼
3×3 Mesh NoC  ──────────────────────────────────────────────
    ├── Tile 0 (256 KB SRAM, 16× MAC) ── Tile 1 ── Tile 2
    ├── Tile 3                         ── Tile 4 ── Tile 5
    └── Tile 6                         ── Tile 7 ── Tile 8
```

### 2.2 Address Map (Physical, 64-bit)

| Region                         | Base Address         | Size     | Description                            |
|-------------------------------|----------------------|----------|----------------------------------------|
| RISC-V M-mode CSRs             | `0x0000_0000_0000`   | 4 KB     | Standard RV64 CSRs (mstatus, misa…)   |
| CX custom CSRs                 | `0x0000_0000_1000`   | 4 KB     | CX_STATUS, CX_DISPATCH_CNT, …          |
| EPC registers                  | `0x0000_0000_2000`   | 4 KB     | GATE_OUT, TILE_MAP, EPC_CTRL, …        |
| Cogni-Link MMIO base           | `0xFFFF_0000_0000`   | 576 B    | 9 tiles × 64 B per tile                |
| Tile SRAM (weight DMA window)  | `0xFFFF_1000_0000`   | 2 304 KB | 9 × 256 KB, aliased through CLB        |
| Boot ROM                       | `0x0000_0010_0000`   | 64 KB    | Immutable inference firmware           |

### 2.3 Clock Domain Summary

| Domain        | Frequency | Source        | Gating                          |
|--------------|-----------|---------------|---------------------------------|
| `CLK_CORE`   | 2 GHz     | PLL0 ÷ 1      | Always-on                       |
| `CLK_NOC`    | 2 GHz     | PLL0 ÷ 1      | Always-on                       |
| `CLK_TILE[i]`| 2 GHz     | CLK_NOC gated | EPC-controlled per-tile ICG     |

All three domains share PLL0 and are phase-aligned; no CDC synchronizers
are required between `CLK_CORE`, `CLK_NOC`, and active `CLK_TILE[i]`.

### 2.4 Reset Architecture

| Signal          | Type         | Polarity | Assertion Source                                |
|----------------|--------------|----------|-------------------------------------------------|
| `RSTN_POR`     | Asynchronous | Active-L | Power-on reset cell                             |
| `RSTN_SYNC`    | Synchronous  | Active-L | Derived from `RSTN_POR`, 2-FF synchronizer on `CLK_CORE` |
| `RSTN_TILE[i]` | Synchronous  | Active-L | EPC write to `TILE_RST` CSR                    |

All RTL flops use `RSTN_SYNC` or `RSTN_TILE[i]`. No asynchronous resets inside RTL boundary.

---

## 3. RISC-V Orchestrator Core

### 3.1 Overview

The orchestrator is a **64-bit in-order, scalar, 5-stage pipeline** implementing `RV64I`
plus the five-instruction **Cogni Extension (CX)** set. It is the sole master of the
Cogni-Link bridge and the EPC co-processor.

### 3.2 Pipeline Stages

| Stage | Name              | Depth | Operation                                                  |
|-------|------------------|-------|------------------------------------------------------------|
| IF    | Instruction Fetch | 1     | PC register → I-cache (or Boot ROM), 64-bit aligned fetch |
| ID    | Instruction Decode| 1     | RV64I + CX opcode decode, register file read (2 read ports)|
| EX    | Execute          | 1     | ALU / branch resolution / CX execution unit               |
| MEM   | Memory           | 1     | D-cache load/store, MMIO store to Cogni-Link, CSR access  |
| WB    | Write-Back       | 1     | Register file write (1 write port), interrupt handling     |

**Hazard handling:**
- **Data hazard:** Full forwarding from EX/MEM/WB to EX inputs. Load-use hazard inserts 1 stall cycle.
- **Control hazard:** All branches resolved in EX stage. Branch-not-taken prediction; misprediction flushes IF+ID (2-cycle penalty).
- **CX structural hazard:** `CX_DISPATCH` stalls ID stage until the bridge FIFO has at least 1 credit (checked combinatorially in ID).

### 3.3 Register File

| Property      | Value                                    |
|--------------|------------------------------------------|
| Width        | 64-bit                                   |
| Depth        | 32 registers (x0–x31, x0 hardwired 0)  |
| Read ports   | 2 (synchronous, 1-cycle latency)        |
| Write port   | 1 (synchronous, registered)             |
| Reset value  | All registers = `0x0000_0000_0000_0000` |

### 3.4 CX Custom ISA

All five CX instructions use the **R-type** encoding *(H-4: corrected from "R4-type")* in the
RISC-V `custom-0` opcode space (`opcode[6:0] = 0x0B`). Bits `[14:12]` select the CX function.

> **[⚠ CORRECTED H-4]:** v2.0 incorrectly labeled this "R4-type." R4-type in RISC-V encodes
> a fourth register operand (rs3) for FMA-style instructions. CX instructions use only
> rd, rs1, rs2 — this is standard **R-type** encoding.

#### 3.4.1 Instruction Encodings

```
  31      25 24   20 19  15 14 12 11    7 6      0
 +---------+-------+------+-----+--------+--------+
 | funct7  |  rs2  |  rs1 |funct3|   rd  | 0x0B   |
 +---------+-------+------+-----+--------+--------+
```

| Mnemonic       | funct7    | funct3 | rs1       | rs2       | rd           |
|----------------|-----------|--------|-----------|-----------|--------------|
| `CX_DISPATCH`  | `0000000` | `000`  | tile_id   | pkt_lo    | status       |
| `CX_COLLECT`   | `0000001` | `001`  | tile_id   | timeout   | result_ptr   |
| `CX_GATE_EVAL` | `0000010` | `010`  | gate_base | K_val     | gate_out_ptr |
| `CX_TILE_CFG`  | `0000011` | `011`  | tile_id   | cfg_word  | 0 (unused)   |
| `CX_SYNC`      | `0000100` | `100`  | tile_mask | 0 (unused)| sync_status  |

#### 3.4.2 Instruction Semantics

**`CX_DISPATCH rd, rs1, rs2`**
- **Purpose:** Enqueue a 128-bit micro-op packet into the Cogni-Link bridge FIFO for tile `rs1[3:0]`.
- **Operation:**
  1. Reads `rs2` as the lower 64 bits of the packet; upper 64 bits from `CSR_CX_PKT_HI` (address `0x1001`).
  2. Writes 128-bit packet to MMIO address `0xFFFF_0000_0000 + (rs1[3:0] × 64)`.
  3. Decrements credit counter for the target tile by 1.
  4. `rd` ← `{62'b0, credit_ok, dispatch_done}`.
- **Latency:** 1 cycle (MEM stage; combinatorial MMIO write).
- **Stall condition:** Stalls in ID stage while `CLB_CREDIT[tile_id] == 0`.

**`CX_COLLECT rd, rs1, rs2`**
- **Purpose:** Poll for result availability from tile `rs1[3:0]` with a timeout of `rs2[15:0]` cycles.
- **Operation:**
  1. Reads `CLB_STATUS[tile_id]` every cycle until `RESULT_VALID == 1` or timeout expires.
  2. `rd` ← result tag (32-bit) if valid; `rd` ← `64'hDEAD_DEAD` on timeout.
- **Timeout encoding:** `rs2 = 0` means infinite wait (blocking).

**`CX_GATE_EVAL rd, rs1, rs2`**
- **Purpose:** Trigger the EPC to evaluate the gating network softmax and produce the Top-K tile assignment.
- **Operation:**
  1. Writes `rs1` (gating weight base address) to `EPC_GATE_BASE_ADDR`.
  2. Writes `rs2[1:0]` (K value, 1 or 2) to `EPC_K_CFG[1:0]`.
  3. Asserts `EPC_CTRL.EVAL_START` for 1 cycle.
  4. `rd` ← `{32'b0, EPC_GATE_OUT[31:0]}` (one-hot tile selection bitmap).
- **Latency:** 1 cycle to start; EPC completes asynchronously (18 cycles total).

**`CX_TILE_CFG rd, rs1, rs2`**
- **Purpose:** Write a 32-bit configuration word to a tile's local control register.
- **Operation:**
  1. Packs packet with `OPCODE = 4'hF`, `PAYLOAD = rs2[31:0]`, `TILE_ID = rs1[3:0]`.
  2. Issues through Cogni-Link bridge identically to `CX_DISPATCH`.
  3. `rd` = `{63'b0, ack_received}`.

**`CX_SYNC rd, rs1, rs2`**
- **Purpose:** Wait for all tiles indicated by one-hot `rs1[8:0]` mask to assert `DONE`.
- **Operation:**
  1. Polls `CLB_TILE_DONE_STATUS[8:0]` masked with `rs1[8:0]`.
  2. Stalls pipeline until `(CLB_TILE_DONE_STATUS & rs1[8:0]) == rs1[8:0]` or 4096-cycle timeout.
  3. `rd` ← `{55'b0, timed_out, CLB_TILE_DONE_STATUS[8:0]}`.

### 3.5 Custom CSR Map

| CSR Address | Name              | RW  | Reset Value              | Description                                         |
|-------------|-------------------|-----|--------------------------|-----------------------------------------------------|
| `0x1000`    | `CX_STATUS`       | RO  | `0x0000_0000`            | `[0]` dispatch_busy; `[1]` collect_pending; `[8:2]` tile_done[6:0] |
| `0x1001`    | `CX_PKT_HI`       | RW  | `0x0000_0000_0000_0000`  | Upper 64 bits of next `CX_DISPATCH` packet         |
| `0x1002`    | `CX_DISPATCH_CNT` | RO  | `0x0000_0000`            | Cumulative dispatch count (wraps at 2³²)             |
| `0x1003`    | `CX_ERR_STAT`     | W1C | `0x0000_0000`            | `[0]` credit_underflow; `[1]` timeout; `[2]` parity |
| `0x1004`    | `CX_TIMEOUT_CFG`  | RW  | `0x0000_1000` (4096)     | Default timeout for `CX_COLLECT` in cycles          |
| `0x1005`    | `CX_TILE_EN`      | RW  | `0x0000_01FF`            | `[8:0]` one-hot tile enable; `0` disables CLK_TILE  |

### 3.6 Pipeline State Machine

States: `RESET → FETCH → DECODE → EXECUTE → MEMORY → WRITEBACK → FETCH`

- FETCH stalls on I-cache miss.
- DECODE stalls on load-use hazard or CX credit stall.
- MEMORY stalls on D-cache miss.
- EXECUTE flushes IF+ID on branch-taken (2-cycle penalty).

---

## 4. Cogni-Link Interconnect Bridge

### 4.1 Overview

The Cogni-Link Bridge (CLB) is a **memory-mapped, credit-based, synchronous interconnect**
between the RISC-V orchestrator and the 3×3 tile mesh NoC. A single 64-bit store instruction
targeting the CLB MMIO window enqueues a 128-bit micro-op packet in ≤ 1 `CLK_CORE` cycle,
meeting the ≤ 5 ns end-to-end dispatch latency target including up to 4 NoC hops.

### 4.2 Micro-Op Packet Format (128 bits)

```
 127     124 123  120 119        88 87          56 55         24 23       8  7       4 3        0
 +---------+-------+-------------+--------------+-------------+----------+----------+---------+
 |  PARITY | RSVD  |  TOKEN_ID   |   ACT_DATA   |  WEIGHT_TAG |  OP_CFG  |  TILE_ID |  OPCODE |
 |  [4b]   | [4b]  |  [32b]      |  [32b]       |  [32b]      |  [16b]   |  [4b]    |  [4b]   |
 +---------+-------+-------------+--------------+-------------+----------+----------+---------+
```

| Field        | Bits        | Width | Description                                                               |
|-------------|-------------|-------|---------------------------------------------------------------------------|
| `OPCODE`    | `[3:0]`     | 4     | `0x0`=MAC_START, `0x1`=MAC_ACC, `0x2`=MAC_DRAIN, `0xF`=TILE_CFG         |
| `TILE_ID`   | `[7:4]`     | 4     | Target tile index 0–8. Values 9–15 reserved (packet dropped)             |
| `OP_CFG`    | `[23:8]`    | 16    | `[7:0]` layer_id; `[11:8]` expert_id; `[15:12]` sub-op flags            |
| `WEIGHT_TAG`| `[55:24]`   | 32    | SRAM byte offset into the tile's 256 KB weight buffer                    |
| `ACT_DATA`  | `[87:56]`   | 32    | Activation data (BF16×2 packed, or INT8×4 packed, per `OP_CFG[12]`)     |
| `TOKEN_ID`  | `[119:88]`  | 32    | Token index within current batch (0–63)                                  |
| `RSVD`      | `[123:120]` | 4     | Reserved; must be `4'b0000` by software                                  |
| `PARITY`    | `[127:124]` | 4     | Even parity over bits [123:0], split into four 31-bit groups             |

**Parity computation:** `PARITY[k] = ^(packet[31k+30 : 31k])` for k=0..3.
The CLB rejects and flags packets with parity mismatch (`CX_ERR_STAT[2]` set).

### 4.3 Credit Protocol

Each tile has an independent **4-entry credit pool**. Credits are managed entirely in CLB hardware.

| Event                               | Credit Change           |
|------------------------------------|-------------------------|
| Reset de-assertion                  | +4 per tile             |
| RISC-V dispatches packet to tile N  | −1 for tile N           |
| Tile N returns ACK flit through NoC | +1 for tile N           |
| Credit underflow (bug)              | Error flag, no dispatch |

- **Credit width:** 3-bit saturating counter (0–4).
- **Backpressure:** When `CREDIT[tile_id] == 0`, CLB asserts `CLB_STALL[tile_id]`, stalling `CX_DISPATCH` in ID.

### 4.4 FIFO Architecture

```
RISC-V MEM stage
      │ 128-bit MMIO write
      ▼
┌─────────────────┐
│  Input FIFO     │  4 entries × 128-bit, synchronous, 1-cycle push
│  (per tile)     │  Pop on first available NoC flit slot
└────────┬────────┘
         │ 128-bit flit
         ▼
  NoC Ingress Router (tile[x,y] injection port)
```

| Property         | Value                                   |
|-----------------|-----------------------------------------|
| FIFO depth       | 4 entries per tile                      |
| FIFO width       | 128 bits                                |
| Number of FIFOs  | 9 (one per tile)                        |
| Write latency    | 1 `CLK_NOC` cycle                       |
| Overflow behavior| Asserts `CLB_OVERFLOW`, drops packet, sets `CX_ERR_STAT[3]` |

### 4.5 CLB Register Map

All registers memory-mapped at `0xFFFF_0000_0000`. Each tile's 64-byte window starts at
`0xFFFF_0000_0000 + tile_id × 64`.

| Offset | Name         | Width | RW | Reset  | Description                                           |
|--------|-------------|-------|----|--------|-------------------------------------------------------|
| `0x00` | `PKT_LO`    | 64    | WO | —      | Lower 64 bits — triggers enqueue on write             |
| `0x08` | `PKT_HI`    | 64    | WO | —      | Upper 64 bits — **must be written before `PKT_LO`**  |
| `0x10` | `CREDIT_STAT`| 32   | RO | `0x4`  | `[2:0]` current credit count                         |
| `0x14` | `TILE_STATUS`| 32   | RO | `0x0`  | `[0]` result_valid; `[1]` tile_busy; `[2]` tile_error|
| `0x18` | `RESULT_LO` | 64    | RO | `0x0`  | Lower 64 bits of tile result                         |
| `0x20` | `RESULT_HI` | 64    | RO | `0x0`  | Upper 64 bits of tile result                         |
| `0x28` | `CLR_RESULT`| 32    | WO | —      | Write any value to clear `result_valid` and `RESULT_*`|

**Enqueue protocol:** Write `PKT_HI` first, then `PKT_LO`. Writing `PKT_LO` first is undefined behavior.

---

## 5. Mini-Wafer Tile Mesh

### 5.1 Tile Indexing

```
 tile[0](0,0)  tile[1](1,0)  tile[2](2,0)
 tile[3](0,1)  tile[4](1,1)  tile[5](2,1)
 tile[6](0,2)  tile[7](1,2)  tile[8](2,2)
```

Tile address `(x,y)` maps to index `i = y×3 + x`. CLB and NoC address tiles by linear index in `TILE_ID[3:0]`.

### 5.2 Per-Tile Architecture

```
NoC Router + Inject/Eject
      │ 128-bit flit
      ▼
Tile Local Controller (TLC)
      │                    │
      ▼                    ▼
256 KB SRAM          Config Register
(64K × 32-bit)
      │ 32-bit weight × 16
      ▼
16× MAC Units (BF16 or INT8)
      │ 32-bit partial sum × 16
      ▼
Accumulator (32-bit, 16 lanes)
      │
Output Register File (16×32-bit)
      │ result flit
      ▼
NoC Router
```

### 5.3 MAC Datapath

Each tile contains **16 parallel MAC units** operating in lock-step.

| Property             | Value                                                      |
|---------------------|------------------------------------------------------------|
| Number of MAC units  | 16 per tile                                                |
| Input precision      | BF16 (16-bit) or INT8 (8-bit), selected by `OP_CFG[12]`  |
| Accumulator width    | 32-bit IEEE 754 single precision                          |
| Throughput           | **32 GMAC/s @ 2 GHz** *(H-1: corrected from 256)*        |
| SRAM read bandwidth  | 16 × 32-bit = 512 bits/cycle                              |
| Activation input     | Sourced from `ACT_DATA[31:0]` in the micro-op packet      |
| Output               | 16-lane 32-bit accumulator → packed into 128-bit result   |

**MAC computation per cycle:**
```
For lane l in [0..15]:
  weight[l] = SRAM[WEIGHT_TAG + l]          // 32-bit read (2× BF16 or 4× INT8)
  acc[l]    += unpack(weight[l]) × ACT_DATA // BF16 or INT8 multiply-accumulate
```

### 5.4 Tile SRAM Specification

| Property         | Value                                                      |
|-----------------|------------------------------------------------------------|
| Capacity         | 256 KB (262 144 bytes)                                     |
| Organization     | 65 536 entries × 32 bits                                  |
| Access type      | Single-port (one read or write per cycle, not both)        |
| Read latency     | 1 `CLK_TILE` cycle (synchronous output register)          |
| Write latency    | 1 `CLK_TILE` cycle                                        |
| Port width       | 32-bit data, 16-bit address                               |
| ECC              | SECDED (1-bit correct / 2-bit detect) per 32-bit word     |
| Retention voltage| 0.6 V (when `CLK_TILE[i]` is gated off)                  |
| DMA write path   | Through CLB → NoC → TLC; `OPCODE=0xF` + write sub-op     |

**SRAM address decode:**
- `WEIGHT_TAG[15:0]` = word address within tile SRAM (0–65 535).
- `WEIGHT_TAG[31:16]` = expert ID (validation only; not used as SRAM address).

### 5.5 Tile Local Controller (TLC)

#### TLC States

| State      | Encoding | Description                                                |
|-----------|----------|------------------------------------------------------------|
| `IDLE`    | `3'b000` | Waiting for valid flit from NoC router                    |
| `CFG`     | `3'b001` | Processing `TILE_CFG` packet; writing config register      |
| `MAC_LOAD`| `3'b010` | Reading weight from SRAM (1 cycle per 16-lane iteration)  |
| `MAC_EXEC`| `3'b011` | Executing 16 MACs; updating accumulators                   |
| `MAC_DRAIN`| `3'b100`| Reading accumulated result; preparing result flit          |
| `RESULT_TX`| `3'b101`| Transmitting result flit to NoC toward CLB                |
| `ERROR`   | `3'b111` | SRAM ECC error or parity error; tile asserts error flag   |

**TLC State Transitions:**
- `IDLE → CFG` on `flit.OPCODE == 0xF`
- `IDLE → MAC_LOAD` on `flit.OPCODE == 0x0 (MAC_START)`
- `CFG → IDLE` on `config_wr_done`
- `MAC_LOAD → MAC_EXEC` on `sram_read_valid`
- `MAC_EXEC → MAC_LOAD` on `more_activations`
- `MAC_EXEC → MAC_DRAIN` on `OPCODE == 0x2 (MAC_DRAIN)`
- `MAC_DRAIN → RESULT_TX` on `result_ready`
- `RESULT_TX → IDLE` on `ack_received`
- `MAC_LOAD → ERROR` on `ecc_error`
- `ERROR → IDLE` on `RSTN_TILE`

#### TLC Configuration Register (per tile, 32-bit)

| Bits     | Name       | Reset | Description                                         |
|---------|-----------|-------|-----------------------------------------------------|
| `[3:0]` | `PRECISION`| `0x0` | `0x0`=BF16, `0x1`=INT8                              |
| `[7:4]` | `EXPERT_ID`| `0xF` | Expert identifier (0–8); `0xF` = unassigned         |
| `[11:8]`| `LAYER_ID` | `0x0` | Current transformer layer index (0–31)              |
| `[15:12]`|`ACC_MODE` | `0x0` | `0x0`=overwrite, `0x1`=accumulate                   |
| `[16]`  | `ECC_EN`   | `0x1` | `1`=enable SECDED; `0`=disable (debug only)         |
| `[31:17]`|`RSVD`    | `0x0` | Reserved; ignored on write; reads 0                 |

### 5.6 Network-on-Chip (NoC)

| Property             | Value                                                   |
|--------------------|---------------------------------------------------------|
| Topology            | 3×3 mesh (9 nodes)                                      |
| Routing algorithm   | Deterministic XY (dimension-ordered)                    |
| Flit width          | 128 bits                                                |
| Virtual channels    | 2 per link (VC0=data, VC1=ACK/control)                  |
| Credits per VC/link | 8                                                       |
| Arbitration         | Round-robin across input ports per output port          |
| Adjacent-hop latency| 1 `CLK_NOC` cycle                                       |
| Max diameter        | 4 hops (corner-to-corner)                              |
| Header location     | Flit `[127:120]`: `[7:4]` dest_x; `[3:0]` dest_y      |

**End-to-end latency budget (CLB → tile[8] worst case):**
- FIFO pop + NoC inject: 1 cycle
- 4 NoC hops × 1 cycle/hop: 4 cycles
- TLC receive: 1 cycle
- **Total: 6 cycles = 3.0 ns @ 2 GHz** (within 5 ns budget)

---

## 6. Expert Parallelism Controller (EPC)

### 6.1 Overview

The EPC is a **hardwired co-processor** tightly coupled to the RISC-V orchestrator via the
CX ISA. It evaluates the MoE gating network output (softmax + Top-K), produces a one-hot
tile assignment bitmap, and manages per-tile clock gating. All operations complete in a
**fixed 18 `CLK_CORE` cycles** after `EVAL_START`.

### 6.2 EPC Register Map (base: `0x0000_0000_2000`)

| Offset | Name              | Width | RW  | Reset        | Description                                                         |
|--------|------------------|-------|-----|--------------|---------------------------------------------------------------------|
| `0x00` | `EPC_CTRL`       | 32    | RW  | `0x0`        | `[0]` EVAL_START (self-clearing); `[1]` FORCE_GATE_ALL; `[2]` SW_TILE_OVERRIDE |
| `0x04` | `EPC_STATUS`     | 32    | RO  | `0x0`        | `[0]` EVAL_DONE; `[1]` EVAL_BUSY; `[10:2]` ACTIVE_TILE_MAP[8:0]  |
| `0x08` | `EPC_GATE_BASE`  | 64    | RW  | `0x0`        | 64-bit byte address of gating weight vector                        |
| `0x10` | `EPC_K_CFG`      | 32    | RW  | `0x2`        | `[1:0]` K value (1 or 2); values 0 and 3 are illegal              |
| `0x14` | `EPC_GATE_OUT`   | 32    | RO  | `0x0`        | `[8:0]` one-hot tile selection bitmap (after EVAL_DONE)            |
| `0x18` | `EPC_TILE_WEIGHT`| **TBD** | RO | `0x0`     | Expert weights per tile *(H-2: 9×8-bit = 72-bit; register width TBD)* |
| `0x1C` | `EPC_BATCH_CFG`  | 32    | RW  | `0x0000_0001`| `[5:0]` batch_size (1–64)                                          |
| `0x20` | `EPC_CLK_GATE`   | 32    | RO  | `0x0`        | `[8:0]` current clock gate state (1=gated off)                    |
| `0x24` | `EPC_ERR_STAT`   | 32    | W1C | `0x0`        | `[0]` invalid_K; `[1]` gate_addr_fault; `[2]` topk_tie           |
| `0x28` | `EPC_LAYER_ID`   | 32    | RW  | `0x0`        | `[4:0]` current transformer layer (0–31)                          |
| `0x2C` | `TILE_RST`       | 32    | WO  | —            | `[8:0]` write 1 to assert `RSTN_TILE[i]` for one cycle            |

> **[⚠ TBD H-2]:** `EPC_TILE_WEIGHT` stores 9 expert weight fractions. At 8-bit
> precision, 9×8 = 72 bits. A 32-bit register is insufficient. Options: (a) use a
> 96-bit or 128-bit register; (b) use two 32-bit reads with `tile_id` index; (c) store
> top-2 weights only in a 16-bit field per expert. Resolution required before RTL.

### 6.3 Gating Evaluation Algorithm

The EPC implements **fixed-point softmax + Top-K** in hardware using Q8.8 format.

| Cycle | Operation                                                                        |
|-------|----------------------------------------------------------------------------------|
| 0     | Latch `EPC_GATE_BASE` and `EPC_K_CFG`; assert `EVAL_BUSY`                      |
| 1–9   | Read 9 gating logit values from `EPC_GATE_BASE + offset` (1 per cycle)         |
| 10    | Find `max_logit` (combinatorial binary tree across 9 values)                    |
| 11    | Compute `exp(logit[i] - max_logit)` for all 9 tiles via LUT-based exp          |
| 12    | Sum all 9 exp values → `sum_exp`                                                 |
| 13    | Compute `softmax[i] = exp[i] / sum_exp` for all 9 tiles                         |
| 14–15 | Sort softmax values; select Top-K tile indices                                  |
| 16    | Enable `CLK_TILE[i]` for selected tiles; gate off all others                   |
| 17    | Write `EPC_GATE_OUT`; clear EVAL_BUSY; assert EVAL_DONE                         |

**Tie-breaking:** Equal scores → lower tile index wins. `EPC_ERR_STAT[2]` set (informational).
**Total EPC latency: 18 cycles = 9 ns.**

### 6.4 Clock Gating Logic

```
CLK_NOC ─────────────────────────┐
                                  │
EPC_GATE_OUT[i] → ICG_LATCH[i] → CLK_TILE[i]
(enable latched on falling CLK_NOC edge)
```

- `EPC_GATE_OUT[i]` must be stable ≥ 1 cycle before the rising CLK_NOC edge that enables the tile.
- Idle tile consumes ≤ 1 mW at 0.6 V (leakage only).

### 6.5 Attention Layer Operation

> **[⚠ TBD H-5]:** v2.0 stated "K=9 via `SW_TILE_OVERRIDE`" for attention layers.
> However, `EPC_K_CFG[1:0]` only encodes K∈{1,2}. A separate mechanism is required.
> **Proposed resolution:** When `EPC_CTRL[2]` (SW_TILE_OVERRIDE) is asserted, firmware
> directly writes `EPC_GATE_OUT[8:0]` to enable all 9 tiles, bypassing the softmax
> evaluation. This requires the register to become writable (RW) in override mode.
> This change must be reflected in the register map and RTL before tape-out.

---

## 7. End-to-End MoE Inference Execution

### 7.1 System-Level Sequence (per MoE Layer)

```
Firmware (Boot ROM)
  │  Jump to inference_loop (layer 0)
  ▼
RISC-V Core
  │  CX_GATE_EVAL: write EPC_GATE_BASE + EPC_K_CFG
  │  EVAL_START=1 (cycle 0)
  ▼
EPC Co-proc
  │  18-cycle softmax + Top-K (cycles 0–17)
  │  EVAL_DONE=1; ICG enables CLK_TILE for Top-K tiles
  ▼
[For each token in batch]
  RISC-V: Build 128-bit micro-op packet (PKT_HI + PKT_LO)
  RISC-V → CLB: CX_DISPATCH to tile[k] (1 cycle, MEM stage)
  CLB → NoC: Inject 128-bit flit (1 cycle after FIFO pop)
  NoC → TLC: Deliver flit (1–4 hops)
  TLC: MAC_LOAD → MAC_EXEC (N cycles for N weight vectors)
  TLC → NoC: Send result flit (ACK + data)
  NoC → CLB: Deliver result to CLB result buffer
  CLB → RISC-V: Assert TILE_STATUS[result_valid]
  RISC-V: CX_COLLECT (poll or timeout)
  RISC-V: CX_SYNC (wait for all active tiles)
[End loop]
  RISC-V: Increment layer_id; loop to next layer
```

### 7.2 Detailed Execution Timeline (7-Token Batch, 2 Active Experts)

| Phase | Cycles  | Description                                                          |
|-------|---------|----------------------------------------------------------------------|
| P1    | 0–17    | EPC evaluates gating → asserts CLK_TILE for tiles {k0, k1}         |
| P2    | 18–19   | Firmware reads `EPC_GATE_OUT`; computes packet fields for token 0   |
| P3    | 20      | `CX_DISPATCH` token 0 to tile k0 (PKT_HI pre-loaded, 1-cycle MEM) |
| P4    | 21      | `CX_DISPATCH` token 0 to tile k1                                    |
| P5    | 22–25   | NoC delivers to tiles k0, k1 (≤ 4 hops each)                       |
| P6    | 26–41   | TLC MAC computation (16 activations × 1 cycle/vector = 16 cycles)  |
| P7    | 42–46   | Result flit travels back through NoC (≤ 4 hops + 1 CLB cycle)      |
| P8    | 47      | `CX_COLLECT` reads result from CLB buffer                           |
| P9    | 48–49   | `CX_SYNC` confirms both tiles done (1–2 poll cycles)                |
| —     | 50–349  | Phases P2–P9 repeat for tokens 1–6 (pipelined, 50 cycles/token)    |
| —     | 350     | Layer done; EPC gates off tiles; move to next layer                 |

**Per-layer latency: 350 cycles = 175 ns @ 2 GHz (7-token batch, 2 experts)**

### 7.3 Error Recovery Flow

| Error Condition        | Detection                | Response                                                     |
|-----------------------|--------------------------|--------------------------------------------------------------|
| Parity error (CLB)    | CLB parity checker       | Drop packet; set `CX_ERR_STAT[2]`; re-dispatch from FW      |
| ECC 1-bit (tile)      | SECDED corrector         | Correct silently; set `TILE_STATUS[3]` (corrected flag)      |
| ECC 2-bit (tile)      | SECDED detector          | Tile → `ERROR` state; set `TILE_STATUS[2]`; FW issues `TILE_RST` |
| CX_COLLECT timeout    | Pipeline timeout counter | `rd` ← `0xDEAD_DEAD`; FW logs and retries or halts          |
| Credit underflow      | CLB credit check         | Stall pipeline; set `CX_ERR_STAT[0]`; never dispatch         |

---

## 8. Top-Level Interface Signal Tables

### 8.1 RISC-V Core Ports

| Signal              | Dir | Width | Clock Domain | Description                                     |
|--------------------|-----|-------|--------------|-------------------------------------------------|
| `CLK_CORE`         | in  | 1     | —            | 2 GHz core clock                                |
| `RSTN_SYNC`        | in  | 1     | CLK_CORE     | Active-low synchronous reset                    |
| `instr_fetch_addr` | out | 64    | CLK_CORE     | Program counter (to I-cache)                    |
| `instr_fetch_data` | in  | 64    | CLK_CORE     | 64-bit instruction word                         |
| `instr_fetch_valid`| in  | 1     | CLK_CORE     | I-cache hit                                     |
| `dmem_addr`        | out | 64    | CLK_CORE     | Data memory address                             |
| `dmem_wdata`       | out | 64    | CLK_CORE     | Write data                                      |
| `dmem_rdata`       | in  | 64    | CLK_CORE     | Read data                                       |
| `dmem_we`          | out | 1     | CLK_CORE     | Write enable                                    |
| `dmem_be`          | out | 8     | CLK_CORE     | Byte enable                                     |
| `dmem_valid`       | in  | 1     | CLK_CORE     | Response valid                                  |
| `mmio_addr`        | out | 64    | CLK_CORE     | MMIO target address (to CLB)                    |
| `mmio_wdata`       | out | 64    | CLK_CORE     | MMIO write data                                 |
| `mmio_we`          | out | 1     | CLK_CORE     | MMIO write enable                               |
| `mmio_ack`         | in  | 1     | CLK_CORE     | MMIO write acknowledged                         |
| `cx_stall`         | in  | 1     | CLK_CORE     | CLB credit stall signal (stalls ID stage)       |
| `epc_eval_start`   | out | 1     | CLK_CORE     | Pulse to EPC: start gating evaluation           |
| `epc_gate_base`    | out | 64    | CLK_CORE     | Gating base address to EPC                      |
| `epc_k_cfg`        | out | 2     | CLK_CORE     | K value to EPC (1 or 2)                         |
| `epc_eval_done`    | in  | 1     | CLK_CORE     | EPC evaluation complete                         |
| `epc_gate_out`     | in  | 9     | CLK_CORE     | One-hot tile bitmap from EPC                    |
| `irq`              | in  | 1     | CLK_CORE     | External interrupt (from host)                  |

### 8.2 Cogni-Link Bridge Ports

| Signal            | Dir | Width | Clock Domain | Description                                    |
|------------------|-----|-------|--------------|------------------------------------------------|
| `CLK_NOC`        | in  | 1     | —            | 2 GHz NoC clock                                |
| `RSTN_SYNC`      | in  | 1     | CLK_NOC      | Active-low synchronous reset                   |
| `mmio_addr`      | in  | 10    | CLK_NOC      | MMIO offset within CLB window `[9:0]`          |
| `mmio_wdata`     | in  | 64    | CLK_NOC      | Write data from RISC-V MEM stage               |
| `mmio_we`        | in  | 1     | CLK_NOC      | Write enable                                   |
| `mmio_ack`       | out | 1     | CLK_NOC      | Acknowledge to RISC-V pipeline                 |
| `clb_stall`      | out | 9     | CLK_NOC      | One-hot stall per tile (credit=0)              |
| `noc_flit_out`   | out | 128   | CLK_NOC      | Flit to NoC injection port                     |
| `noc_flit_out_vld`| out| 1    | CLK_NOC      | Flit valid                                     |
| `noc_flit_out_rdy`| in | 1    | CLK_NOC      | NoC ready                                      |
| `noc_flit_in`    | in  | 128   | CLK_NOC      | Result flit from NoC ejection port             |
| `noc_flit_in_vld`| in  | 1     | CLK_NOC      | Result flit valid                              |
| `noc_flit_in_rdy`| out | 1    | CLK_NOC      | CLB ready to accept result                     |
| `result_valid`   | out | 9     | CLK_NOC      | Per-tile result valid flags                    |
| `result_data`    | out | 128   | CLK_NOC      | Result data (from last valid tile response)    |
| `clb_overflow`   | out | 1     | CLK_NOC      | FIFO overflow error                            |
| `clb_parity_err` | out | 1     | CLK_NOC      | Parity error on incoming packet                |
| `credit_cnt`     | out | 27    | CLK_NOC      | 9 × 3-bit credit counters (debug)             |

### 8.3 Tile (TLC) Ports

| Signal            | Dir | Width | Clock Domain | Description                                     |
|------------------|-----|-------|--------------|-------------------------------------------------|
| `CLK_TILE`       | in  | 1     | —            | Gated tile clock (from ICG)                     |
| `RSTN_TILE`      | in  | 1     | CLK_TILE     | Active-low synchronous tile reset               |
| `noc_flit_in`    | in  | 128   | CLK_TILE     | Incoming flit from NoC router                   |
| `noc_flit_in_vld`| in  | 1     | CLK_TILE     | Incoming flit valid                             |
| `noc_flit_in_rdy`| out | 1     | CLK_TILE     | Tile ready to accept flit                       |
| `noc_flit_out`   | out | 128   | CLK_TILE     | Outgoing result flit to NoC                     |
| `noc_flit_out_vld`|out | 1     | CLK_TILE     | Result flit valid                               |
| `noc_flit_out_rdy`| in | 1     | CLK_TILE     | NoC ready to accept result                      |
| `sram_addr`      | out | 16    | CLK_TILE     | SRAM word address                               |
| `sram_wdata`     | out | 32    | CLK_TILE     | SRAM write data                                 |
| `sram_rdata`     | in  | 32    | CLK_TILE     | SRAM read data (1-cycle latency)                |
| `sram_we`        | out | 1     | CLK_TILE     | SRAM write enable                               |
| `sram_ecc_err_1b`| in  | 1     | CLK_TILE     | SECDED 1-bit correctable error                  |
| `sram_ecc_err_2b`| in  | 1     | CLK_TILE     | SECDED 2-bit uncorrectable error                |
| `tile_done`      | out | 1     | CLK_TILE     | Computation complete for current micro-op set   |
| `tile_error`     | out | 1     | CLK_TILE     | Error flag (ECC 2-bit or parity)               |
| `tlc_state`      | out | 3     | CLK_TILE     | TLC FSM state (for debug scan)                  |

---

## 9. UVM Verification Environment

### 9.1 Testbench Architecture

```
uvm_test_top: cogniv_base_test
  └── cogniv_env (uvm_env)
        ├── rv_orch_agent     (CX ISA sequences)
        ├── clb_agent         (MMIO monitor)
        ├── noc_agent         (flit monitor)
        ├── tile_agent ×9     (TLC monitor)
        ├── cogniv_scoreboard (ref model comparison)
        │     └── C++ Reference Model (Golden MoE)
        └── cogniv_coverage   (functional covergroups)
```

### 9.2 Test Vectors

| TV-ID  | Test Name                  | DUT Boundary       | Pass Criterion                                             |
|--------|---------------------------|--------------------|------------------------------------------------------------|
| TV-001 | `cx_dispatch_basic`       | RISC-V ↔ CLB      | `credit_cnt[0]` decrements by 1; flit at NoC inject port  |
| TV-002 | `cx_dispatch_backpressure`| RISC-V ↔ CLB      | `cx_stall` asserted; no 5th flit injected                 |
| TV-003 | `noc_9tile_congestion`    | CLB ↔ NoC ↔ Tiles | All 9 results received within 50 cycles of first dispatch |
| TV-004 | `epc_gate_eval_k1`        | EPC                | `EPC_GATE_OUT` one-hot; exactly 1 bit set                 |
| TV-005 | `epc_gate_eval_k2`        | EPC                | `EPC_GATE_OUT` has exactly 2 bits set                     |
| TV-006 | `epc_tie_break`           | EPC                | Lower-index tile selected; `EPC_ERR_STAT[2]` set          |
| TV-007 | `tile_mac_bf16_single`    | Tile TLC + MAC     | Result matches golden model ±1 ULP BF16 tolerance         |
| TV-008 | `tile_mac_int8_single`    | Tile TLC + MAC     | Result matches golden model exactly                        |
| TV-009 | `tile_sram_ecc_1bit`      | Tile SRAM          | `sram_ecc_err_1b` asserted; result correct; no tile error |
| TV-010 | `tile_sram_ecc_2bit`      | Tile SRAM          | `tile_error` asserted; TLC FSM = `ERROR`; RSTN_TILE recovery |
| TV-011 | `cx_collect_timeout`      | RISC-V + CLB       | `rd` = `0xDEAD_DEAD`; `CX_ERR_STAT[1]` set              |
| TV-012 | `cx_parity_error`         | CLB                | Packet dropped; `clb_parity_err` asserted                 |
| TV-013 | `moe_full_layer`          | Full chip          | All token results match golden C++ model; total ≤ 400 cycles |
| TV-014 | `cx_sync_all_tiles`       | RISC-V + CLB       | Returns when all tiles assert `tile_done`; no timeout     |
| TV-015 | `clock_gate_idle_power`   | EPC + ICG          | Zero transitions on `CLK_TILE[i]` for gated-off tiles    |

### 9.3 Functional Coverage Groups

| Covergroup        | Items Covered                                                           |
|------------------|-------------------------------------------------------------------------|
| `cg_cx_opcodes`  | All 5 CX instruction types dispatched at least once                    |
| `cg_tile_targets`| Each of the 9 tiles targeted by `CX_DISPATCH` at least 10 times       |
| `cg_credit_levels`| Credit counter transitions: 4→3, 3→2, 2→1, 1→0, 0→1 (after ACK)    |
| `cg_noc_hops`    | Flits routed through 1, 2, 3, and 4 hops                              |
| `cg_epc_k_values`| K=1 and K=2 both exercised                                             |
| `cg_precision`   | Both BF16 and INT8 precision modes exercised per tile                  |
| `cg_tlc_states`  | All 7 TLC FSM states entered at least once                             |
| `cg_error_paths` | All 5 error conditions in TV-009 to TV-012 triggered                  |
| `cg_batch_sizes` | Batch sizes 1, 8, 32, and 64 all exercised                            |

### 9.4 Assertions (SVA) — Corrected

```systemverilog
// CLB: credit never underflows
assert_credit_nuf: assert property (@(posedge CLK_NOC) disable iff (!RSTN_SYNC)
  (credit_cnt[i] == 0) |-> ##1 !mmio_we);

// CLB: PKT_HI must be written before PKT_LO (relaxed — not necessarily 1 cycle prior)
// [⚠ CORRECTED H-6]: Original used $past(...,1) which required exactly 1 cycle.
//   Correct: PKT_HI_written must be TRUE at some point before PKT_LO write.
//   Use a persistent flag cleared on PKT_LO enqueue.
assert_pkt_order: assert property (@(posedge CLK_NOC) disable iff (!RSTN_SYNC)
  (mmio_we && mmio_addr[5:0] == 6'h00) |-> pkt_hi_valid[tile_id]);
// where pkt_hi_valid[tile_id] is a flop set by PKT_HI write, cleared by PKT_LO write.

// EPC: EVAL_DONE deasserts within 1 cycle of being read
assert_eval_done_clr: assert property (@(posedge CLK_CORE) disable iff (!RSTN_SYNC)
  EVAL_DONE |-> ##[1:2] !EVAL_DONE);

// TLC: result flit only sent from RESULT_TX state
assert_result_tx_state: assert property (@(posedge CLK_TILE) disable iff (!RSTN_TILE)
  noc_flit_out_vld |-> (tlc_state == 3'b101));

// NoC: no flit injected when credit==0
assert_noc_credit: assert property (@(posedge CLK_NOC) disable iff (!RSTN_SYNC)
  noc_flit_out_vld |-> (credit_cnt[tile_id] > 0));
```

---

## 10. Clocking and Power Domains

### 10.1 PLL Specification

| Parameter        | Value                        |
|----------------|------------------------------|
| Reference clock  | 100 MHz (off-chip XTAL)      |
| PLL multiplier   | ×20                          |
| PLL output       | 2 000 MHz                    |
| Lock time        | ≤ 10 µs                      |
| Jitter (RMS)     | ≤ 5 ps                       |
| PLL type         | Integer-N, analog loop filter |

### 10.2 Clock Tree

```
XTAL (100 MHz)
    │
   PLL0 (×20 → 2 000 MHz)
    ├──► CLK_CORE  (2 GHz, always-on)
    ├──► CLK_NOC   (2 GHz, always-on)
    └──► CLK_NOC → ICG[0..8] → CLK_TILE[0..8]  (gated per EPC_GATE_OUT)
```

### 10.3 Power Budget

| Domain              | Active Power (typ) | Leakage / Retention   |
|--------------------|--------------------|------------------------|
| RISC-V core         | 100 mW             | 5 mW                   |
| EPC co-processor    | 20 mW              | 2 mW                   |
| Cogni-Link Bridge   | 30 mW              | 3 mW                   |
| NoC (9 routers)     | 50 mW              | 5 mW                   |
| Active tile (×2)    | 2 × 200 mW = 400 mW| —                      |
| Idle tile (×7)      | —                  | 7 × 1 mW = 7 mW        |
| **Total (typical)** | **600 mW**         | **22 mW (idle)**       |

### 10.4 Timing Constraints Summary (STA)

| Path                                      | Budget  | Notes                                     |
|------------------------------------------|---------|-------------------------------------------|
| `CLK_CORE` cycle time                    | 0.50 ns | 2 GHz                                     |
| RISC-V pipeline stage (IF/ID/EX/MEM/WB) | 0.45 ns | 50 ps setup margin                        |
| CLB MMIO write → FIFO push              | 0.40 ns | Combinatorial MMIO path                   |
| CLB parity check                         | 0.40 ns | Parallel with FIFO push                   |
| NoC flit routing (per hop)               | 0.45 ns | 50 ps setup margin                        |
| ICG enable → CLK_TILE valid              | 0.10 ns | ICG cell internal                         |
| EPC combinatorial (max_logit tree)       | 0.45 ns | 50 ps margin; synthesize with retiming    |

---

## 11. Risk Register

| Risk ID | Risk Description                                 | Severity | Probability | Mitigation Strategy                                                       |
|---------|--------------------------------------------------|----------|-------------|---------------------------------------------------------------------------|
| RISK-01 | NoC congestion under full 9-expert load          | High     | Medium      | Deterministic XY routing prevents deadlock; EPC load-balances            |
| RISK-02 | Cogni-Link timing closure at 2 GHz               | High     | Medium      | Register all bridge boundaries; dedicated STA path group                  |
| RISK-03 | SRAM macro availability at TSMC N7               | Medium   | Low         | Engage TSMC N7 HS SRAM compiler early; eDRAM fallback if needed          |
| RISK-04 | ACI-generated CX ISA decoder quality             | Medium   | Medium      | Manual lint review; formal equivalence check vs golden RISC-V ISS        |
| RISK-05 | Expert imbalance at extreme sparsity (K=1)       | Medium   | High        | Firmware monitors `EPC_STATUS.ACTIVE_TILE_MAP`; redistributes batches   |
| RISK-06 | ECC 2-bit fault causing silent data corruption   | High     | Low         | SECDED per 32-bit word; periodic SRAM scrub not implemented (v1)         |
| RISK-07 | CX_SYNC global timeout causing inference stall   | Medium   | Low         | Timeout fixed at 4096 cycles (2 µs); firmware logs and retries           |
| RISK-08 | PLL lock failure at power-on                     | High     | Low         | PLL lock monitor; boot ROM polls `PLL_LOCK` before releasing `RSTN_SYNC` |
| RISK-09 | *(NEW)* Weight streaming bandwidth insufficient  | High     | High        | PCIe x8 @ 16 GT/s = ~16 GB/s; insufficient for large models — must profile streaming schedule per layer |
| RISK-10 | *(NEW)* EPC_TILE_WEIGHT register width mismatch  | Medium   | Confirmed   | 9×8-bit = 72 bits cannot fit in 32-bit register — H-2 must be resolved  |

---

## 12. Glossary

| Term         | Definition                                                                                   |
|-------------|----------------------------------------------------------------------------------------------|
| **ACC**      | Accumulator — 32-bit per-lane register holding partial MAC sums                             |
| **ACT_DATA** | Activation data field in the 128-bit micro-op packet (BF16×2 or INT8×4 packed)            |
| **ACI**      | CogniChip Artificial Chip Intelligence — EDA platform used for RTL generation               |
| **BF16**     | Brain Float 16 — 16-bit floating point (1 sign, 8 exponent, 7 mantissa bits)              |
| **CLB**      | Cogni-Link Bridge — memory-mapped credit-based bridge between core and NoC                  |
| **CLK_CORE** | 2 GHz clock domain for the RISC-V orchestrator                                              |
| **CLK_NOC**  | 2 GHz clock domain for the NoC and CLB                                                      |
| **CLK_TILE** | Per-tile gated clock (ICG-gated from CLK_NOC)                                               |
| **CX ISA**   | Cogni Extension instruction set — 5 custom RISC-V R-type instructions                      |
| **EP**       | Expert Parallelism — dynamic mapping of active MoE experts to tiles                         |
| **EPC**      | Expert Parallelism Controller — hardwired co-processor for gating network evaluation        |
| **ICG**      | Integrated Clock Gate — latch-based glitch-free clock gating cell                           |
| **INT8**     | 8-bit integer data type (signed, 2's complement) used for quantized inference               |
| **K**        | Top-K value in MoE gating; number of expert tiles activated per token per layer             |
| **MAC**      | Multiply-Accumulate unit — computes `acc += weight × activation`                            |
| **MMIO**     | Memory-Mapped I/O — bridge interface accessed by RISC-V store instructions                  |
| **MoE**      | Mixture of Experts — sparse transformer architecture where only K of N experts activate     |
| **NoC**      | Network-on-Chip — 3×3 mesh with XY routing, 128-bit flits                                  |
| **OPCODE**   | 4-bit field in the micro-op packet selecting MAC_START, MAC_ACC, MAC_DRAIN, or TILE_CFG    |
| **Q8.8**     | Fixed-point format: 8-bit integer part + 8-bit fractional part (used in EPC softmax)       |
| **RSTN_SYNC**| Global synchronous active-low reset (2-FF synchronizer output on CLK_CORE)                  |
| **RSTN_TILE**| Per-tile synchronous active-low reset (EPC-controlled)                                      |
| **RV64I**    | RISC-V 64-bit base integer instruction set                                                   |
| **SECDED**   | Single-Error-Correct Double-Error-Detect — ECC scheme applied per 32-bit SRAM word         |
| **TLC**      | Tile Local Controller — FSM sequencing SRAM reads and MAC execution within a tile          |
| **Top-K**    | Algorithm selecting the K highest-scored experts from the gating softmax output             |
| **VC**       | Virtual Channel — independent logical channel within a physical NoC link                    |
| **WEIGHT_TAG**| 32-bit field in micro-op packet specifying the SRAM word offset for weight fetching       |

---

## Appendix A: Requirement Traceability Matrix

| REQ_ID | Requirement                            | Sections         | Test Vectors         |
|--------|----------------------------------------|------------------|----------------------|
| REQ-01 | 2 GHz operation on TSMC N7            | 1.1, 10.1, 10.4  | STA sign-off         |
| REQ-02 | ≤ 5 ns dispatch latency                | 4.1, 4.6, 7.2    | TV-001               |
| REQ-03 | 9-tile 3×3 mesh, 256 KB SRAM each     | 5.1, 5.4, 1.1    | TV-003, TV-007–010   |
| REQ-04 | Top-K MoE gating (K=1 or 2)           | 6.3, 6.5         | TV-004–006           |
| REQ-05 | CX 5-instruction ISA (R-type)          | 3.4              | TV-001, 002, 011–014 |
| REQ-06 | Per-tile clock gating at 0.6 V         | 6.4, 10.3        | TV-015               |
| REQ-07 | Credit-based backpressure (4 credits)  | 4.3              | TV-002               |
| REQ-08 | 128-bit packet with parity protection  | 4.2              | TV-012               |
| REQ-09 | SECDED ECC on tile SRAM                | 5.4              | TV-009, TV-010       |
| REQ-10 | UVM test coverage ≥ 95% functional     | 9.2, 9.3         | TV-001–015           |
| REQ-11 | *(NEW)* Resolve EPC_TILE_WEIGHT width  | 6.2              | Post-resolution STA  |
| REQ-12 | *(NEW)* Define weight streaming model  | 1, 7             | New TV required      |

---

*End of Document — COGNIV-SPEC-001-FULL v3.0*
