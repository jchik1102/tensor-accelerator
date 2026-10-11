# Tensor Accelerator

A programmable INT8 inference accelerator for the Terasic DE10-Lite, using the MAX 10 `10M50DAF484C7G`. Draw a digit in the browser, run the neural network on the FPGA, and see the prediction on the page and HEX0. The host independently checks every intermediate layer against an integer reference before displaying a successful result.

The selected image uses an 8x8 systolic array at 75 MHz; a 4x4 build is also supported. The network is `784 -> 64 -> 32 -> 10`, with two ReLU layers. Weights and activations reside on chip and are loaded at runtime. One inference runs at a time. No external SDRAM or separate CPU project is required.

## Requirements

- Windows, PowerShell 7, and WSL Ubuntu.
- Project: `C:\projects\tensor-accelerator`, visible in WSL as `/mnt/c/projects/tensor-accelerator`.
- Dedicated WSL Python 3.12 environment: `/home/jonat/.venvs/tensor-accelerator`. Package versions are in `requirements-lock.txt`.
- Quartus Prime Lite 24.1std, MAX 10 support, System Console, and USB-Blaster drivers at `C:\intelFPGA_lite\24.1std`.
- For RTL simulation only: Vivado 2025.2 at `C:\AMDDesignTools\2025.2\Vivado`, including its bundled UVM 1.2.
- A powered DE10-Lite connected through its USB-Blaster programming port.

The existing environment is ready to use. On a fresh WSL installation:

```bash
python3.12 -m venv ~/.venvs/tensor-accelerator
~/.venvs/tensor-accelerator/bin/python -m pip install \
  --extra-index-url https://download.pytorch.org/whl/cpu \
  -r /mnt/c/projects/tensor-accelerator/requirements-lock.txt
```

The wrappers use the local tool paths above. Adjust them and the native System Console path in `host/ta/board_session.py` if your installation differs. The RTL browser backend uses PowerShell 7 from PATH or the installed Codex runtime; `TA_POWERSHELL` can specify another WSL-visible `pwsh.exe` path.

## Run with the DE10-Lite

### 1. Load the supplied image

Stop any previous drawing server with Ctrl+C and close other System Console sessions. In PowerShell 7:

```powershell
Set-Location C:\projects\tensor-accelerator
& 'C:\intelFPGA_lite\24.1std\quartus\bin64\jtagconfig.exe'
& 'C:\intelFPGA_lite\24.1std\quartus\bin64\quartus_pgm.exe' --list
Get-FileHash .\artifacts\board-n8-75-hex-v2\output_files\de10_lite.sof -Algorithm SHA256
```

Confirm the connected device is the DE10-Lite/MAX 10. The supplied 8x8 image SHA-256 is:

```text
3F09CFC5C36673CBBCA56968BAAB58A11D510EEC37F9AEF13C11F586EB6C5437
```

In Quartus Programmer, select the discovered USB-Blaster cable, choose JTAG mode, add `artifacts/board-n8-75-hex-v2/output_files/de10_lite.sof`, select Program/Configure, and click Start. This is volatile configuration: power loss requires loading the SOF again. Do not select a core-only synthesis image or the tool-diagnostic counter image.

For the previously tested `USB-Blaster [USB-0]` cable, the equivalent command is:

```powershell
& 'C:\intelFPGA_lite\24.1std\quartus\bin64\quartus_pgm.exe' -c 'USB-Blaster [USB-0]' -m JTAG -o 'p;artifacts/board-n8-75-hex-v2/output_files/de10_lite.sof@1'
```

Use the cable and device position actually reported by discovery if they differ.

### 2. Discover and check the master service

Open System Console from Quartus's Tools menu:

```tcl
get_service_paths master
```

Copy the exact path for the loaded accelerator, then run:

```tcl
set env(TA_MASTER_PATH) {paste the discovered master path here}
set env(TA_BOARD_IMAGE_CONFIRMED) TA01
source C:/projects/tensor-accelerator/fpga/board/qualify-runtime.tcl
```

The check verifies identity and idle status, tests four scratch patterns, and restores scratch contents. For the display-register check, run `source C:/projects/tensor-accelerator/fpga/board/qualify-hex.tcl` in the same console. This also performs software reset, so run it before starting the demo. Close System Console afterward so the drawing server can own the connection.

### 3. Start the drawing website

In PowerShell 7, substitute the exact discovered master path:

```powershell
& .\scripts\run-python.ps1 -m host.ta.demo --port 8766 --fpga-clock-mhz 75 --fpga-master '/devices/10M50DA(.|ES)|10M50DC@1#USB-0/(link)/JTAG/(110:132 v1 #0)/phy_0/master'
```

Open [localhost:8766](http://localhost:8766), select **Physical FPGA**, click **Example**, then **Run inference**. Next, clear the canvas and draw a digit. The normalized preview shows the actual 28x28 input.

The first inference starts System Console and loads the model; allow roughly one minute. Later requests reuse the connection and weights. Successful FPGA results report all three layers matching and the display register being updated. HEX0 shows the prediction; HEX1 through HEX5 are blank. A dash is the reset/cleared state. The host performs final argmax and writes HEX0 only after the independent comparison passes.

Keep the board powered and avoid accessing it from another console while the server owns it. Stop the server with Ctrl+C. After reset, disconnect, timeout, or reprogramming, stop the server, rediscover and check the endpoint, then restart to reload the model. There is no automatic retry of an uncertain inference. A disconnected display can retain its last digit.

`--fpga-clock-mhz` changes cycle-to-time reporting only; the SOF determines the actual clock. Older images without the HEX1 capability are rejected.

## Software, simulation, tests, and rebuilding

For software-only drawing:

```powershell
& .\scripts\run-python.ps1 -m host.ta.demo --port 8766
```

Run software/mocked tests and generate test inputs:

```powershell
& .\scripts\run-python.ps1 -m pytest tests -q
& .\scripts\run-python.ps1 -m tests.check_persistent_console
& .\scripts\run-python.ps1 -m host.ta.vectors
& .\scripts\run-python.ps1 -m host.ta.board_plan --sample 0
& 'C:\intelFPGA_lite\24.1std\quartus\bin64\tclsh86.exe' .\tests\check_board_tcl.tcl
```

The separately retained `tests/check_physical_http.py` deliberately uses the physical backend of an already running server on port 8766. Run it only when intending to exercise the board; it checks ten MNIST examples and blank-input rejection.

Rebuild clean simulator snapshots before selecting the browser's RTL backend:

```powershell
& .\scripts\run-sim.ps1 -ArrayN 4 -Seeds 42
& .\scripts\run-sim.ps1 -ArrayN 8 -Seeds 42
& .\scripts\replay-sim.ps1 -ArrayN 4
& .\scripts\run-hex-check.ps1 -ArrayN 8
& .\scripts\run-hex-check.ps1 -ArrayN 4 -InjectDefect
```

The browser RTL backend uses the clean 4x4 snapshot. The default regression runs seeds 1, 42, and 20261008. `run-sim.ps1 -Mutation pe`, `-Mutation round`, and `-ArrayN 8 -Mutation bank` deliberately corrupt separate snapshots and require a detected mismatch. Run simulator wrappers and browser RTL jobs sequentially because they share output directories. Rebuild after RTL edits.

Rebuild exact-device board images:

```powershell
& .\scripts\build-upgrade.ps1 -ArrayN 8 -CoreMHz 75 -Variant hex-v2
& .\scripts\build-upgrade.ps1 -ArrayN 4 -CoreMHz 75 -Variant hex-v2
```

The upgrade runner generates missing JTAG IP automatically, compiles the board, checks timing summaries, and rejects source changes during a build. Rebuilding replaces that variant's SOF and produces a new hash. `build-board.ps1` builds the original 4x4/50 MHz configuration. `run-synthesis.ps1 -ArrayN 4` or `8` performs core-only feasibility builds.

Retrain/export to the candidate directory without replacing the selected model:

```powershell
& .\scripts\run-python.ps1 -m host.ta.train --epochs 35 --augment --output artifacts/model-candidate
& .\scripts\run-python.ps1 -m host.ta.evaluate_accuracy
```

After validating a candidate, copy its `model.json`, `model.onnx`, `weights.pt`, and `samples.npz` into `artifacts/model`, regenerate vectors, rerun tests and RTL checks, and restart the demo. The comparison script retains the previous model JSON as an input. Training uses 55,000 training images, 5,000 validation images, and 1,024 training images for calibration. Test images are excluded from training and checkpoint selection. Seed: 20261008.

## Results

These measurements were recorded before the documentation cleanup. Historical logs, screenshots, build databases, and reports have been removed; the selected model and qualified images are retained unchanged. New runs regenerate their own logs and reports.

| Measurement | Result |
| --- | --- |
| Selected model validation accuracy | 97.76% |
| MNIST test accuracy, 10,000 images | Float 97.41%; INT8 97.49% |
| Previous INT8 model test accuracy | 96.75% |
| Current 4x4 / 8x8 model compute cycles | 32,045 / 17,337 |
| 8x8 compute time calculated from cycles at 75 MHz | 0.23116 ms; excludes host/JTAG overhead |
| Physical cold inference, October 10, 2026 | 46.132 s, including 45.325 s setup |
| Four physical warm inferences | 0.834, 0.775, 0.772, 0.774 s |
| Physical scratch-transfer check | Four patterns passed; 2,080 bus bytes in 356 ms |
| Physical inference/display | Predictions 7, 2, 3, 9, 8; all three layers exact and display ACKs received |
| User display observation | HEX0 matched the website; other five displays blank |

Both 75 MHz board builds targeted the exact `10M50DAF484C7G`:

| Resource/check | 4x4 | 8x8 |
| --- | ---: | ---: |
| Logic elements / 49,760 | 8,901 | 14,067 |
| Registers | 4,453 | 7,412 |
| M9K blocks / 182 | 113 | 137 |
| 9-bit multiplier elements / 288 | 29 | 77 |
| Worst setup slack | +0.728 ns | +0.409 ns |
| Worst hold slack | +0.134 ns | +0.131 ns |

All reported internal setup, hold, recovery, removal, and pulse-width checks passed. Reserved JTAG ports lack external delay specifications; static HEX outputs are excluded from output timing. This qualifies constrained internal timing, not every external interface path.

Offline qualification passed 34 Python tests, 21,264 core checks for each array size at seed 42, 2,070 requantization cases, and 56 adapter/display checks. All eight model samples matched intermediate outputs and final accumulators. Declared functional coverage bins reached 100%; this is not exhaustive coverage. Deliberate arithmetic, operand-bank, and display defects were detected.

On deterministic variants of 2,000 MNIST test images, old/new pipeline accuracy was 16.80%/95.90% for smaller shifted digits, 15.85%/96.65% for larger shifted digits, 79.65%/92.05% for thicker strokes, 95.20%/96.20% for thinner strokes, and 91.65%/94.75% for 12-degree rotation. These compare whole preprocessing/model pipelines, not independent effects or real user handwriting accuracy.

Physical reset-button and disconnect recovery, individual visual inspection of all ten glyphs and the decimal point, and a labeled real-drawing accuracy study remain unexecuted. Software reset and display-register readback were tested.

Retained model JSON SHA-256: `8e25d12fbab0bda949b0243287e833a7c3e9b948e2e712da6115933dcb11eb80`.
Retained 4x4/75 MHz SOF SHA-256: `42F919A7DDAF5C7623D2F5BD54C7F5CBD6D6E4A9F9132D61AE7C5BD6AFBC30E0`.

## Five problems encountered during development

1. **Requantization missed timing.** The original board build had -2.200 ns setup slack through the requantizer. Registering magnitude, rounding, and clamp stages repaired that path. Later banked operand delivery and PE pipelining supported the measured 75 MHz builds.
2. **Drawing position and scale hurt recognition.** Resizing the whole canvas left small or shifted digits unlike training inputs. Shared crop/scale/centroid normalization and augmented retraining raised accuracy on shifted test variants. The browser now previews the normalized input.
3. **Repeated setup dominated latency.** Starting System Console and loading weights for every click produced an approximately 47-second example run. A persistent session, one model load, and block transfers reduced measured warm requests to approximately 0.8 seconds.
4. **Native tool launching and exit codes were misleading.** AMD's batch loader split a named plusarg at `=`, so the wrapper uses an options file. Some fatal XSim mismatches still returned exit code zero, so runners inspect explicit pass/mismatch markers. System Console needs stdin held open to avoid early exit.
5. **A source file changed during a build.** Editing `session.tcl` during the initial display-version compile invalidated its manifest. The runner rejected that result; a rerun with unchanged sources produced the accepted image.

## File layout and implementation

| Location | Purpose |
| --- | --- |
| `rtl/` | Reusable PE, array, banked RAM, requantizer, and programmable core |
| `fpga/board/` | DE10-Lite integration, Avalon/display interface, JTAG generation, and physical checks |
| `fpga/quartus/` | Core build and timing constraints/report scripts |
| `host/ta/` | Reference arithmetic, model tools, preprocessing, host transport, and demo server |
| `demo/index.html` | Drawing interface |
| `scripts/` | PowerShell build, simulation, and execution runners |
| `tb/`, `tests/` | RTL testbenches, Python tests, and Tcl mock/physical checks |
| `artifacts/model/` | Selected model JSON, ONNX, checkpoint, and example inputs |
| `artifacts/model-candidate/model.json` | Candidate for accuracy comparison |
| `artifacts/baseline-pre-hex/model/model.json` | Previous model for accuracy comparison |
| `artifacts/board-n{4,8}-75-hex-v2/output_files/` | Retained qualified SOFs |
| `artifacts/vectors/` | Executable test stimuli and their manifest |
| `artifacts/qualification/` | Retained environment diagnostic scripts and test sources |
| `data/MNIST/` | Dataset for training, evaluation, and physical sample tests |

Result-collection modules and environment diagnostic runners are retained as tools. Their report/log inputs must be regenerated by the corresponding training, test, and build commands; historical reports are not bundled. Simulator state is rebuilt before use. Git stays local.

Arithmetic uses signed INT8 operands, INT16 products, and INT32 accumulation. Bias is applied once, optional ReLU precedes requantization, multiplication uses INT64, division by a power of two rounds ties to even, and the result saturates to INT8. Bias bounds prevent INT32 overflow. Multipliers are 1..2147483647 and shifts are 0..62. Host argmax chooses the first maximum.

The core supports M=1..32, K=1..1024, N=1..128, eight layer descriptors, 8,192 activation bytes, 65,536 weight bytes, 1,024 parameter channels, and 4,096 debug accumulators. Activations are row-major; weights are output-major `[N,K]`. Descriptor words are M, K, N, source, destination, weight offset, parameter offset, flags; flag bit 0 enables ReLU. Source/destination cannot overlap. ONNX support is a fixed float32 opset-18 Gemm/Relu chain with constant weights/biases, `alpha=beta=1`, `transA=0`, and `transB=1`.

Input is white ink on black. `ink20-com-v1` crops values above 16, fits ink into a 20x20 box, and centers its intensity centroid in 28x28. Pixels are quantized with nearest-even rounding of `pixel*127/255`. Empty inputs fail.

TA01 uses aligned 32-bit accesses with one byte per bus word for byte memories:

| Address | Meaning |
| --- | --- |
| `0x0000` | ID `0x54413031` |
| `0x0004` | Status: bit 0 busy, bit 1 done, bit 2 error |
| `0x0008` | Commands: 1 start, 2 clear done/error, 4 software reset |
| `0x000C` | Layer count |
| `0x0010` | Error: 1 access, 2 busy, 3 descriptor, 4 parameter |
| `0x0014`, `0x0018` | Compute cycles and current descriptor |
| `0x0020`, `0x0024` | Display digit/dash and HEX1 capability `0x48455831` |
| `0x0100..0x01FC` | Eight descriptors of eight words |
| `0x1000..0x3FFC` | Bias, multiplier, shift channel parameters |
| `0x10000..0x17FFC` | Activation bytes |
| `0x20000..0x5FFFC` | Weight bytes |
| `0x60000..0x63FFC` | Read-only pre-ReLU accumulators |

Reset aborts work and clears control/descriptors but does not erase RAM; reload all required data. Configuration writes while busy are rejected. Display values 0..9 show digits; other values show a dash. HEX outputs are active low, bit 0 is segment a, and bit 7 is the decimal point, held off. Pin assignments follow the [Terasic DE10-Lite manual](https://www.mouser.com/datasheet/2/598/DE10_Lite_User_Manual-1100361.pdf), tables 3-2, 3-3, and 3-6.
