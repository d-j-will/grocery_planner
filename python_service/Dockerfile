# Use an official lightweight Python image.
# https://hub.docker.com/_/python
FROM python:3.12-slim-bookworm

# Set environment variables
ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=off \
    PIP_DISABLE_PIP_VERSION_CHECK=on \
    PIP_DEFAULT_TIMEOUT=100

# Install system dependencies (e.g., for cv2, z3, build tools)
RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential \
    curl \
    tesseract-ocr \
    tesseract-ocr-eng \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

# Create and set working directory
WORKDIR /app

# Copy requirements file (we will create this next)
COPY requirements.txt .

# CPU torch for v1. The default PyPI torch wheel drags in ~1GB of NVIDIA
# CUDA/cuDNN — useless here (the homelab GPU is AMD, and v1 runs the sidecar on
# CPU by choice) and heavy. GPU/ROCm IS viable on the headless Proxmox host
# (org-brain: headless-amd-apu-blacklist-amdgpu-for-cpu-only-ml), but ROCm torch
# is a ~30GB image on a modest 680M iGPU — deferred to grocery_planner-89l.
# Install the CPU wheel from the PyTorch CPU index FIRST; the subsequent
# `-r requirements.txt` sees torch satisfied and resolves everything else from PyPI.
# (CPU torch's manylinux_2_28 wheel needs glibc >= 2.28; bookworm has 2.36.)
RUN pip install --index-url https://download.pytorch.org/whl/cpu torch \
 && pip install -r requirements.txt

# Copy the rest of the application code
COPY . .

# Create a non-root user and switch to it. The sidecar is stateless now — Oban
# (Elixir) owns all job state — so there is no SQLite DB and no /data volume to
# own (AI-006 Arc 4, grocery_planner-4x6.3). Only /app needs appuser ownership.
RUN useradd -m appuser && chown -R appuser /app
USER appuser

# Expose the port the app runs on
EXPOSE 8000

# Run the application using uvicorn
CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8000"]
