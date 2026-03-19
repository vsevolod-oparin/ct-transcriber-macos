#!/usr/bin/env bash
#
# setup_env.sh — Sets up the whisper-metal conda environment with
# CTranslate2 Metal backend and faster-whisper.
#
# Two modes:
#   Wheel mode (default): Downloads pre-built package, no compilation needed.
#   Source mode: Builds CTranslate2 from source (requires Xcode CLT + cmake).
#
# Usage:
#   ./setup_env.sh <conda_env_name> [--package-url URL] [--source PATH]
#
# If neither --package-url nor --source is given, only installs faster-whisper
# (assumes CTranslate2 is already available or will be installed separately).
#
# Each step prints a JSON status line to stdout for the Swift app to parse:
#   {"step": "name", "status": "start|done|error", "message": "..."}

set -euo pipefail

CONDA_ENV_NAME=""
CT2_PACKAGE_URL=""
CT2_SOURCE=""
DOWNLOAD_MODEL_HF=""
DOWNLOAD_MODEL_ID=""
DOWNLOAD_MODEL_QUANT="float16"
MINICONDA_DIR="$HOME/.ct-transcriber/miniconda"

# Parse arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        --package-url) CT2_PACKAGE_URL="$2"; shift 2 ;;
        --source) CT2_SOURCE="$2"; shift 2 ;;
        --download-model) DOWNLOAD_MODEL_HF="$2"; shift 2 ;;
        --model-id) DOWNLOAD_MODEL_ID="$2"; shift 2 ;;
        --model-quantization) DOWNLOAD_MODEL_QUANT="$2"; shift 2 ;;
        *)
            if [ -z "$CONDA_ENV_NAME" ]; then
                CONDA_ENV_NAME="$1"; shift
            else
                echo "Unknown argument: $1" >&2; exit 1
            fi
            ;;
    esac
done

if [ -z "$CONDA_ENV_NAME" ]; then
    echo "Usage: setup_env.sh <conda_env_name> [--package-url URL] [--source PATH] [--download-model HF_ID --model-id ID]" >&2
    exit 1
fi

emit() {
    local step="$1" status="$2" message="${3:-}"
    printf '{"step":"%s","status":"%s","message":"%s"}\n' "$step" "$status" "$message"
}

# ==========================================================================
# Step 1: Ensure conda is available (install Miniconda if needed)
# ==========================================================================
emit "prepare" "start" "Preparing environment setup"
emit "prepare" "done" "Environment setup started"

CONDA_BIN="$MINICONDA_DIR/bin/conda"

if [ -x "$CONDA_BIN" ]; then
    emit "check_conda" "done" "Conda found"
else
    # Install Miniconda automatically
    MINICONDA_INSTALLER="/tmp/ct-transcriber-miniconda.sh"
    MINICONDA_URL="https://repo.anaconda.com/miniconda/Miniconda3-latest-MacOSX-arm64.sh"

    emit "download_miniconda" "start" "Downloading Miniconda (~60 MB)"
    curl -fSL "$MINICONDA_URL" -o "$MINICONDA_INSTALLER" >&2 2>&1

    if [ ! -f "$MINICONDA_INSTALLER" ]; then
        emit "download_miniconda" "error" "Failed to download Miniconda installer"
        exit 1
    fi
    emit "download_miniconda" "done" "Miniconda downloaded"

    emit "install_miniconda" "start" "Installing Miniconda (unpacking Python runtime)"
    bash "$MINICONDA_INSTALLER" -b -p "$MINICONDA_DIR" >&2 2>&1
    rm -f "$MINICONDA_INSTALLER"

    CONDA_BIN="$MINICONDA_DIR/bin/conda"
    if [ ! -x "$CONDA_BIN" ]; then
        emit "install_miniconda" "error" "Miniconda installation failed"
        exit 1
    fi

    emit "install_miniconda" "done" "Miniconda installed"
fi

# Initialize conda for this shell
eval "$("$CONDA_BIN" shell.bash hook)"

# Accept Terms of Service (required for recent Miniconda versions)
conda tos accept --override-channels --channel https://repo.anaconda.com/pkgs/main 2>/dev/null || true
conda tos accept --override-channels --channel https://repo.anaconda.com/pkgs/r 2>/dev/null || true

# Helper: run a command inside the conda env without needing conda activate
run_in_env() {
    "$CONDA_BIN" run -n "$CONDA_ENV_NAME" "$@"
}

# ==========================================================================
# Step 2: Create/verify conda environment
# ==========================================================================
emit "create_env" "start" "Setting up conda environment: $CONDA_ENV_NAME"

if "$CONDA_BIN" env list 2>/dev/null | grep -q "^${CONDA_ENV_NAME} "; then
    emit "create_env" "done" "Environment $CONDA_ENV_NAME already exists"
else
    "$CONDA_BIN" create -n "$CONDA_ENV_NAME" python=3.12 -y >&2 2>&1
    emit "create_env" "done" "Environment $CONDA_ENV_NAME created"
fi

# ==========================================================================
# Step 3: Install Python dependencies
# ==========================================================================
emit "install_deps" "start" "Installing Python dependencies (~400 MB)"

# Install torch and other deps in parallel
run_in_env pip install --quiet torch >&2 2>&1 &
TORCH_PID=$!

run_in_env pip install --quiet transformers sentencepiece faster-whisper >&2 2>&1 &
FW_PID=$!

# Install ffmpeg in parallel with pip deps
FFMPEG_PID=""
ENV_FFMPEG="$MINICONDA_DIR/envs/$CONDA_ENV_NAME/bin/ffmpeg"
if [ ! -x "$ENV_FFMPEG" ]; then
    "$CONDA_BIN" install -n "$CONDA_ENV_NAME" -c conda-forge --override-channels ffmpeg -y >&2 2>&1 &
    FFMPEG_PID=$!
fi

# Wait for pip installs
wait "$TORCH_PID" 2>/dev/null
emit "install_torch" "done" "PyTorch installed"
wait "$FW_PID" 2>/dev/null
emit "install_deps" "done" "Python dependencies installed"

# ==========================================================================
# Step 3b: Pre-download model files in background (if requested)
# ==========================================================================
HF_PREFETCH_PID=""
if [ -n "$DOWNLOAD_MODEL_HF" ] && [ -n "$DOWNLOAD_MODEL_ID" ]; then
    MODELS_DIR="$HOME/Library/Application Support/CTTranscriber/models"
    MODEL_OUTPUT="$MODELS_DIR/$DOWNLOAD_MODEL_ID"

    if [ -f "$MODEL_OUTPUT/model.bin" ] && [ -f "$MODEL_OUTPUT/tokenizer.json" ]; then
        # Model already exists, skip prefetch
        true
    else
        emit "prefetch_model" "start" "Pre-downloading model files in background"
        run_in_env python -c "
from huggingface_hub import snapshot_download
snapshot_download('$DOWNLOAD_MODEL_HF', ignore_patterns=['*.safetensors.index.json'])
" >&2 2>&1 &
        HF_PREFETCH_PID=$!
    fi
fi

# ==========================================================================
# Step 3c: Wait for ffmpeg (started in parallel with pip deps)
# ==========================================================================
if [ -x "$ENV_FFMPEG" ]; then
    emit "install_ffmpeg" "done" "ffmpeg already installed"
elif [ -n "$FFMPEG_PID" ]; then
    emit "install_ffmpeg" "start" "Waiting for ffmpeg install"
    wait "$FFMPEG_PID" 2>/dev/null || true
    if [ -x "$ENV_FFMPEG" ]; then
        emit "install_ffmpeg" "done" "ffmpeg installed"
    else
        emit "install_ffmpeg" "done" "ffmpeg not available (video conversion will be skipped)"
    fi
else
    emit "install_ffmpeg" "done" "ffmpeg already installed"
fi

# ==========================================================================
# Step 4: Install CTranslate2 Metal backend
# ==========================================================================

if [ -n "$CT2_PACKAGE_URL" ]; then
    # --- Wheel mode: download pre-built package ---
    CT2_TMPDIR="/tmp/ct2-metal-package"
    rm -rf "$CT2_TMPDIR"
    mkdir -p "$CT2_TMPDIR"

    emit "download_ct2" "start" "Downloading CTranslate2 Metal package"
    if ! curl -fSL "$CT2_PACKAGE_URL" -o "$CT2_TMPDIR/package.tar.gz" 2>&2; then
        emit "download_ct2" "error" "Failed to download CTranslate2 package from $CT2_PACKAGE_URL"
        exit 1
    fi
    emit "download_ct2" "done" "CTranslate2 package downloaded"

    emit "install_ct2" "start" "Installing CTranslate2 Metal backend"

    cd "$CT2_TMPDIR"
    tar xzf package.tar.gz

    # Install the wheel
    WHL=$(ls ctranslate2-*.whl 2>/dev/null | head -1)
    if [ -z "$WHL" ]; then
        emit "install_ct2" "error" "No .whl file found in package"
        exit 1
    fi

    run_in_env pip install --force-reinstall "$WHL" >&2 2>&1

    rm -rf "$CT2_TMPDIR"

    emit "install_ct2" "done" "CTranslate2 Metal package installed"

elif [ -n "$CT2_SOURCE" ]; then
    # --- Source mode: build from source ---
    emit "check_build_tools" "start" "Checking build tools"

    if ! xcode-select -p &>/dev/null; then
        emit "check_build_tools" "error" "Xcode Command Line Tools not installed. Run: xcode-select --install"
        exit 1
    fi
    if ! command -v cmake &>/dev/null; then
        emit "check_build_tools" "error" "cmake not found. Install via: brew install cmake"
        exit 1
    fi

    emit "check_build_tools" "done" "Build tools available"

    if [ ! -f "$CT2_SOURCE/CMakeLists.txt" ]; then
        emit "install_ct2" "error" "CTranslate2 source not found at $CT2_SOURCE"
        exit 1
    fi

    emit "install_ct2" "start" "Building CTranslate2 from source (this may take several minutes)"

    cd "$CT2_SOURCE"
    git submodule update --init --recursive >&2 2>&1
    run_in_env python3 tools/gen_msl_strings.py

    CMAKE_PREFIX=$(run_in_env python -c "import sys; print(sys.prefix)")
    cmake -B build \
        -DCMAKE_BUILD_TYPE=Release \
        -DWITH_METAL=ON \
        -DWITH_ACCELERATE=ON \
        -DWITH_MKL=OFF \
        -DWITH_DNNL=OFF \
        -DOPENMP_RUNTIME=NONE \
        -DCMAKE_INSTALL_PREFIX="$CMAKE_PREFIX" \
        >&2 2>&1

    NCPU=$(sysctl -n hw.logicalcpu)
    cmake --build build -j"$NCPU" >&2 2>&1
    cmake --install build >&2 2>&1

    cd python
    run_in_env pip install . >&2 2>&1
    cd ..

    emit "install_ct2" "done" "CTranslate2 built and installed from source"
else
    emit "install_ct2" "start" "Skipping CTranslate2 install (no package URL or source path)"
    emit "install_ct2" "done" "CTranslate2 not installed — configure package URL or source path in Settings"
fi

# ==========================================================================
# Step 5: Validate
# ==========================================================================
emit "validate" "start" "Validating installation"

CT2_VERSION=$(run_in_env python -c "import ctranslate2; print(ctranslate2.__version__)" 2>&1) || CT2_VERSION="not found"
FW_OK=$(run_in_env python -c "import faster_whisper; print('ok')" 2>&1)

if [ "$FW_OK" != "ok" ]; then
    emit "validate" "error" "faster_whisper import failed: $FW_OK"
    exit 1
fi

if [ "$CT2_VERSION" = "not found" ]; then
    emit "validate" "error" "ctranslate2 import failed — install via package URL or source build"
    exit 1
fi

emit "validate" "done" "CTranslate2 $CT2_VERSION + faster_whisper ready"

# ==========================================================================
# Step 6: Download default whisper model (if requested)
# ==========================================================================
if [ -n "$DOWNLOAD_MODEL_HF" ] && [ -n "$DOWNLOAD_MODEL_ID" ]; then
    MODELS_DIR="$HOME/Library/Application Support/CTTranscriber/models"
    MODEL_OUTPUT="$MODELS_DIR/$DOWNLOAD_MODEL_ID"

    if [ -f "$MODEL_OUTPUT/model.bin" ] && [ -f "$MODEL_OUTPUT/tokenizer.json" ]; then
        emit "download_model" "done" "Model $DOWNLOAD_MODEL_ID already downloaded"
    else
        # Wait for background prefetch to finish (downloads HF files in parallel with CT2/ffmpeg)
        if [ -n "$HF_PREFETCH_PID" ]; then
            emit "download_model" "start" "Waiting for model download to complete (~1.6 GB)"
            wait "$HF_PREFETCH_PID" 2>/dev/null || true
            emit "prefetch_model" "done" "Model files downloaded"
        fi

        emit "convert_model" "start" "Converting model to CTranslate2 format"

        SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
        CONVERT_SCRIPT="$SCRIPT_DIR/convert_model.py"
        if [ ! -f "$CONVERT_SCRIPT" ]; then
            # When running from app bundle, script is in Resources
            CONVERT_SCRIPT="$(dirname "$SCRIPT_DIR")/Resources/convert_model.py"
        fi

        mkdir -p "$MODELS_DIR"
        run_in_env python "$CONVERT_SCRIPT" \
            --hf-model "$DOWNLOAD_MODEL_HF" \
            --output-dir "$MODEL_OUTPUT" \
            --quantization "$DOWNLOAD_MODEL_QUANT" >&2 2>&1 || true

        if [ -f "$MODEL_OUTPUT/model.bin" ]; then
            emit "convert_model" "done" "Model $DOWNLOAD_MODEL_ID ready"
        else
            emit "convert_model" "done" "Model setup failed (you can download it later from Settings)"
        fi
    fi
fi

echo '{"step":"complete","status":"done","message":"Environment setup complete"}'
