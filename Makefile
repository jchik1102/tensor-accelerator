# Thin wrapper around the existing flows. Run from WSL in the repository root:
#   make test     offline regression (scripts/regress.ps1): Python tests, the
#                 System Console mock, Tcl checks, XSim 4x4 and 8x8, mutations,
#                 replay and display checks; no board access
#   make fpga     75 MHz board build into artifacts/board-n$(ARRAY_N)-75-$(VARIANT)
#   make asic     OpenLane 2 / sky130 flow on asic/ta_asic_tile.sv (Docker)
#   make asic-sim the tile's RTL and gate-level simulations (Icarus)
#   make formal   SymbiYosys checks (not added yet)
# XSim and Quartus run on Windows through PowerShell 7. Console output is saved
# under results/.

SHELL := /bin/bash
.SHELLFLAGS := -o pipefail -c

PWSH_FALLBACK := /mnt/c/Users/jonat/.cache/codex-runtimes/codex-primary-runtime/dependencies/native/powershell/pwsh.exe
PWSH ?= $(or $(shell command -v pwsh.exe 2>/dev/null),$(PWSH_FALLBACK))
PS := "$(PWSH)" -NoProfile -File
VENV ?= /home/jonat/.venvs/tensor-accelerator
ARRAY_N ?= 8
# A new variant name keeps the qualified hex-v2 images untouched.
VARIANT ?= repro
RESULTS := results
# pwsh.exe launched from WSL reports exit code 0 even when a script fails, so
# every PowerShell step is judged by the pass marker it prints, like the
# XSim logs are.
require = grep -qE '$(1)' $(2) || { echo "FAIL: '$(1)' not found in $(2)"; exit 1; }
LOG = 2>&1 | tee $(RESULTS)/$@.log

.PHONY: help models test accuracy fpga results formal asic asic-pe asic-sim results-dir

help:
	@echo "make models   Python tests (WSL only, seconds)"
	@echo "make test     scripts/regress.ps1"
	@echo "make accuracy MNIST INT8 accuracy (original and synthetic variants), float and validation accuracy"
	@echo "make results  copy logs that back the README into results/"
	@echo "make fpga     scripts/build-upgrade.ps1 -ArrayN $(ARRAY_N) -CoreMHz 75 -Variant $(VARIANT)"
	@echo "make asic     OpenLane 2 flow on the compute tile (RUN_TAG=$(RUN_TAG)), then collect reports"
	@echo "make asic-pe  OpenLane 2 flow on one processing element (10 ns)"
	@echo "make asic-sim tile RTL and gate-level simulation against the Python reference"
	@echo "make formal   not available yet"

# Not "$(RESULTS):": that is the same target as "results:" below, whose
# recipe would then run before every target.
results-dir:
	@mkdir -p $(RESULTS)

models: | results-dir
	$(VENV)/bin/python -m pytest tests -q $(LOG)

test: | results-dir
	$(PS) scripts/regress.ps1 $(LOG)
	bash scripts/collect-results.sh
	@$(call require,^REGRESSION_PASS,$(RESULTS)/$@.log)

accuracy: | results-dir
	$(VENV)/bin/python -m host.ta.evaluate_accuracy $(LOG)
	$(VENV)/bin/python -m host.ta.evaluate_float 2>&1 | tee $(RESULTS)/float-accuracy.log
	bash scripts/collect-results.sh

results:
	bash scripts/collect-results.sh

fpga: | results-dir
	$(PS) scripts/build-upgrade.ps1 -ArrayN $(ARRAY_N) -CoreMHz 75 -Variant $(VARIANT) 2>&1 | tee $(RESULTS)/fpga-n$(ARRAY_N).log
	@$(call require,^TIMING_PASS,$(RESULTS)/fpga-n$(ARRAY_N).log)

formal:
	@echo "No formal flow yet."; exit 1

# OpenLane 2.3.10 in Docker on the ASIC compute tile (asic/config.json). The
# run goes to asic/runs/$(RUN_TAG); its reports are copied to results/asic/.
# script gives OpenLane the terminal it expects when run from a script.
OPENLANE ?= $(HOME)/.venvs/openlane/bin/openlane
PDK_ROOT ?= $(HOME)/.volare
RUN_TAG ?= d20
asic: | results-dir
	script -qec "$(OPENLANE) --dockerized --pdk-root $(PDK_ROOT) --run-tag $(RUN_TAG) --overwrite asic/config.json" /dev/null
	bash asic/collect.sh $(RUN_TAG)

asic-pe: | results-dir
	script -qec "$(OPENLANE) --dockerized --pdk-root $(PDK_ROOT) --run-tag pe10d --overwrite asic/pe/config.json" /dev/null
	bash asic/collect.sh pe10d asic/pe

asic-sim: | results-dir
	bash asic/run-tile-sim.sh rtl
	cp artifacts/asic/sim-rtl/sim.log $(RESULTS)/asic/$(RUN_TAG)/sim-rtl.log
	bash asic/run-tile-sim.sh gl asic/runs/$(RUN_TAG)/final/nl/ta_asic_tile.nl.v
	cp artifacts/asic/sim-gl/sim.log $(RESULTS)/asic/$(RUN_TAG)/sim-gl.log
