# Use an official lightweight Python image.
# https://hub.docker.com/_/python
FROM python:3.11-slim-bullseye

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
# (CPU torch's manylinux_2_28 wheel needs glibc >= 2.28; bullseye has 2.31.)
RUN pip install --index-url https://download.pytorch.org/whl/cpu torch \
 && pip install -r requirements.txt

# Copy the rest of the application code
COPY . .

# Create a non-root user and switch to it. /data holds the SQLite DB
# (AI_DATABASE_URL=sqlite:////data/ai_data.db) and is backed by the ai-data
# volume. Create + own it here so that when Docker first-populates the empty
# named volume from the image, the volume root inherits appuser ownership —
# otherwise it mounts as root:root and SQLite can't open the DB file (the
# sidecar crash-loops on "unable to open database file").
RUN useradd -m appuser && mkdir -p /data && chown -R appuser /app /data
USER appuser

# Expose the port the app runs on
EXPOSE 8000

# Run the application using uvicorn
CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8000"]
