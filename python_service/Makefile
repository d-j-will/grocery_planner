# Local dev runner for the AI sidecar.
#
# Mirrors the CI "Python AI Service Test" job so the suite runs at the commit
# boundary, not only in CI. Uses uv (fast, already the repo's Python tool) and
# pins the SAME interpreter as CI by reading the repo-root .tool-versions — one
# source of truth, so a version bump there flows here and to CI together.
#
#   make test     # run pytest (what CI runs)
#   make lint     # ruff check .
#   make serve    # run the sidecar locally with autoreload on :8000
#
# The OCR endpoint tests exercise the real Tesseract binary. Install it once:
#   macOS:  brew install tesseract
#   Debian: apt-get install tesseract-ocr tesseract-ocr-eng
# Without it those tests take the "not installed" branch rather than failing.

PYTHON_VERSION := $(shell awk '/^python /{print $$2}' ../.tool-versions)
VENV := .venv
UV := uv

.DEFAULT_GOAL := help

.PHONY: help venv test lint serve clean

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | \
		awk 'BEGIN{FS=":.*?## "}{printf "  \033[36m%-8s\033[0m %s\n", $$1, $$2}'

$(VENV): requirements.txt ## Create the venv and install deps + pytest + ruff
	$(UV) python install $(PYTHON_VERSION)
	$(UV) venv --python $(PYTHON_VERSION) $(VENV)
	$(UV) pip install --python $(VENV) -r requirements.txt pytest ruff
	@touch $(VENV)

venv: $(VENV) ## Create/refresh the local venv on the pinned Python

test: $(VENV) ## Run the test suite (pytest) — same as CI
	$(VENV)/bin/pytest

lint: $(VENV) ## Lint with ruff — same as CI
	$(VENV)/bin/ruff check .

serve: $(VENV) ## Run the sidecar locally with autoreload on :8000
	$(VENV)/bin/uvicorn main:app --reload --host 0.0.0.0 --port 8000

clean: ## Remove the local venv
	rm -rf $(VENV)
