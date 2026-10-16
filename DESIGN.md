# Design decisions

> **How to read this.** Each entry states what the RTL and host code do, with
> file references, and then answers the design questions. The answers were
> **inferred from the code, tests and logs**, not taken from the author's
> notes, so they explain why the design works as it does, not a recorded
> history of the decision. Where the repository holds no evidence, the answer
> says so.

## 1. Output-stationary systolic array

**What the RTL does.** `ta_array` is an N x N grid of `ta_pe` (`rtl/ta_array.sv`).
Activations move right and weights move down one PE per `advance`. Each PE
keeps its own INT32 running sum (`rtl/ta_pe.sv`), so an output tile stays in
place while the K dimension streams through. The product is registered before
it is accumulated (`product_valid`).

**Why output-stationary?** Every layer of this network is a matrix-vector or
small matrix product with a long reduction (K = 784, 64 and 32) and few output
rows (M is the batch, up to 32). Output-stationary keeps each partial sum in
its PE for the whole K loop, so INT32 sums never move through the array or
back to memory between steps. Only the INT8 operands stream, at 8 bits a hop.
A weight-stationary array would have to pass 32-bit partial sums between PEs
and reload weights for every output tile.

**Why register the product?** It splits the 8x8 multiply and the 32-bit
accumulate into separate pipeline stages, so the path inside a PE is one
multiplier or one adder, not both. The README's problem list records that
requantization was the original timing failure and that PE pipelining later
supported the 75 MHz builds. The repository has no timing report from before
and after this register.

**What does reading out a tile cost?** Readout is serial. After the operands
drain (`STREAM_DRAIN`, `MAC_DRAIN`), each of the N x N outputs is fetched,
requantized by the single shared `ta_requant` and stored, one at a time
(`P_BIAS` ... `STORE`, `NEXT_OUTPUT`, `rtl/ta_core.sv:191-193`), taking
several FSM states per output. Both array sizes requantize the same number of
outputs (every element of every layer's output), so this readout is a fixed
cost that a larger array doesn't shrink. That is consistent with the 8x8 array,
at four times the PEs, needing 17,337 cycles against the 4x4's 32,045
([4x4](results/sim-n4/core-42.log), [8x8](results/sim-n8/core-42.log)) rather
than a quarter of them. The repository has no per-phase cycle breakdown that
would confirm how much of the difference is readout.

## 2. INT32 accumulation and ties-to-even requantization

**What the RTL does.** Products are INT8 x INT8 = INT16, accumulated in INT32
(`ta_pe.sv`). `ta_requant` adds the bias, applies the optional ReLU,
multiplies by a 31-bit multiplier in 64 bits, shifts right and rounds half to
even (`rtl/ta_requant.sv:18`, `:37`), then saturates to [-128, 127]
(`:45-48`). It runs as a small sequence of phases (`:26-43`).

**Why ties-to-even?** It is unbiased: exact halves round up and down equally
often, so the error doesn't accumulate across layers. It also matches the
host's exact integer reference (`host/ta/numeric.py`), which every RTL result
is compared against bit for bit, and the input quantization, which uses
nearest-even rounding of `pixel*127/255` (README). The `round` mutation
(half-up rounding, `ta_requant.sv:39`) is detected by the requantization bench
([mutation-round.log](results/sim-n4/mutation-round.log)), so the bench really
distinguishes the two.

**Is INT32 enough for K up to 1024?** Each INT8 x INT8 product is at most
128 x 128 = 16,384 in magnitude, so a K = 1024 sum is at most 2^24 in
magnitude, far below 2^31. The host rejects any layer whose bias magnitude
exceeds `I32_MAX - K*16384` (`host/ta/numeric.py:47`), so bias plus
accumulator always fits in INT32 by construction, and the RTL needs no
overflow detection.

**Why phases?** The requantizer handles one value at a time anyway (see
readout above), so spreading the 64-bit multiply, the shift with rounding and
the saturation across clock cycles costs a few cycles per output and removes
the long combinational path. The README records that a combinational
requantizer had negative setup slack and that registering its magnitude,
rounding and clamp stages fixed it.

## 3. Banked operand memories with per-lane skew caches

**What the RTL does.** Activations and weights live in `ta_vector_ram`, which
interleaves bytes across N banks and returns an N-byte vector starting at any
byte address. Banks below the start offset read the next row
(`rtl/ta_vector_ram.sv:16`), and the outputs are rotated back into order
(`:22`). Each array lane then has its own `a_cache`/`b_cache`
(`rtl/ta_core.sv:66-80`), addressed by `wave - lane`, so lane *i* sees its
operands *i* cycles later, which is the diagonal skew a systolic array needs.

**Why skewed per-lane caches rather than delay lines?** A tile's operands are
loaded once into the lane caches and then replayed for every wave. Indexing
each lane's cache with `wave - lane` produces the skew from the address alone,
with no shift registers on the array edges and no per-lane FIFOs to fill and
drain.

**What M9K budget drove the bank layout?** The repository doesn't record the
sizing decision, and the board build logs that listed M9K usage were deleted
(see the README's "Not yet backed by a log").

**What does the `bank` mutation corrupt?** `TA_MUTATE_BANK` removes the
rotation, so a vector read that doesn't start on a bank boundary comes back
with its bytes in the wrong lanes. Aligned reads still work, so only a bench
that exercises unaligned operand rows catches it. The 8x8 core bench does
([mutation-bank.log](results/sim-n8/mutation-bank.log)).

## 4. Programmable layer descriptors, all weights on chip

**What the RTL does.** Up to eight descriptors of eight words each (M, K, N,
source, destination, weight offset, parameter offset, flags) drive the layer
FSM in `ta_core` (`desc[0:63]`, `ta_core.sv:22`). Configuration writes while
busy are rejected, and source and destination may not overlap (README register
map).

**Why descriptors rather than a fixed three-layer FSM?** The network shape
lives in the model file, not in the RTL. Retraining or changing layer sizes
(any M ≤ 32, K ≤ 1024, N ≤ 128) needs no new bitstream, and the same core runs
the test vectors, the MNIST model and the shape coverage in the UVM bench.

**Why reject overlapping source and destination?** A layer reads its whole
input tile by tile while writing outputs. If outputs could overwrite inputs
that a later tile still needs, the result would depend on tile order.
Rejecting overlap keeps every layer a pure function of its input buffer, which
is what the host's integer reference assumes.

**Why keep everything on chip?** The whole model fits: 64 KiB of weights and
8 KiB of activations. Using only on-chip RAM avoids an SDRAM controller and
its timing, keeps the board image independent of the RISC-V project, and
makes cycle counts deterministic, so a simulation replay can check exact
activity and gap counts
([core-replay-42.log](results/sim-n4/core-replay-42.log)).

## 5. Host verifies every layer before showing a result

**What the host does.** The host talks to the board through JTAG-to-Avalon in
System Console (`host/ta/board_session.py`). It compares every intermediate
layer against the integer reference (`host/ta/numeric.py`), computes the
argmax itself, and writes HEX0 only after all layers match (README).

**Why JTAG and System Console rather than UART?** The DE10-Lite has no
USB-serial adapter (the RISC-V project's README notes the same limitation),
but its USB-Blaster is always connected. JTAG-to-Avalon gives the host direct
memory-mapped access to every register and buffer without a CPU or a protocol
on the FPGA.

**Why compare every layer?** A wrong final digit can come from a hardware
fault in any layer, and a correct digit can hide a wrong intermediate result.
Checking each layer bit-exactly against the integer reference proves the
whole computation, not just the outcome. It also tells you which layer failed.

**Why argmax on the host?** It is ten comparisons, and the host needs the
logits anyway to check them. Keeping it in software keeps the RTL a generic
layer engine and lets the host refuse to display anything unless the check
passed.

## 6. ASIC flow on the compute tile only

**What was built.** `asic/ta_asic_tile.sv` wraps the unchanged `ta_array`
(8x8) and `ta_requant` with `ta_core`'s output stage and registers every port
once. OpenLane 2.3.10 takes it to a routed sky130 layout (`asic/config.json`,
README "ASIC flow"). A single `ta_pe` was run first (`asic/pe/config.json`) and
closes at 10 ns with delay-oriented synthesis. Nothing has been fabricated.

**Why not the whole `ta_core`?** About 100 KiB of `ta_core`'s state is RAM:
activations, weights, parameters, outputs and the per-lane skew caches, all
inferred as M9K blocks on the MAX 10. In sky130 that would either be flops
(far too large) or SRAM macros, which need macro placement and a new memory
interface in `ta_core`. The datapath is the part whose timing and area are
specific to this accelerator, and it can be taken through the flow without
changing any RTL.

**Why register the ports?** The tile's inputs stand in for memories and a
controller that are not there. Registering them at the boundary gives every
path a register at both ends, so the reported timing is the datapath's own and
does not depend on unknown input and output delays.

**Why Synlig?** `ta_array` uses unpacked-array ports and a two-dimensional
wire array. Yosys's built-in SystemVerilog frontend rejects them (it fails on
`rtl/ta_array.sv:4`). OpenLane's `USE_SYNLIG` reads the same files through
Surelog/UHDM, so the RTL that runs on the FPGA is the RTL that was hardened.

**Why 20 ns and delay-oriented synthesis?** 20 ns matches the 50 MHz clock
of the other designs. With OpenLane's default area-oriented synthesis the slow
corner failed by 2.6 ns. The worst path was `ta_requant`'s phase 1, a
single-cycle 64-bit two's-complement negate that ABC built as a ripple chain.
`SYNTH_STRATEGY "DELAY 1"` closed every corner, at the cost of 19% more cell
area (run n20 against the first run). Splitting the negate over two cycles would also
fix it, but would change the requantizer's latency, which the FPGA build and
its tests depend on ([runs.txt](results/asic/runs.txt)).

**Why so many antenna diodes?** Heuristic diode insertion with its default
threshold added 38,697 diode cells and left 2 antenna nets. Without it, the
router's own repair left 60 antenna nets; a higher threshold left 17. The
selected run keeps the fewest antenna violations. The diodes are why its
slew, cap and fanout warnings are higher than the other runs'. None of the
four runs is clean on every check, and the README lists what remains.
