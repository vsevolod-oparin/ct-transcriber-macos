#!/usr/bin/env bash
#
# setup_env.sh — Sets up the whisper-metal conda environment with
# CTranslate2 Metal backend and faster-whisper.
#
# Usage:
#   ./setup_env.sh <conda_env_name> <ctranslate2_source_path>
#
# Example:
#   ./setup_env.sh whisper-metal /Users/me/projects/CTranslate2
#
# Prerequisites:
#   - macOS on Apple Silicon (M1–M4)
#   - Anaconda or Miniconda installed
#   - Xcode Command Line Tools: xcode-select --install
#
# Each step prints a JSON status line to stdout for the Swift app to parse:
#   {"step": "name", "status": "start|done|error", "message": "..."}

set -euo pipefail

CONDA_ENV_NAME="${1:?Usage: setup_env.sh <conda_env_name> <ctranslate2_source_path>}"
CT2_SOURCE="${2:?Usage: setup_env.sh <conda_env_name> <ctranslate2_source_path>}"

emit() {
    local step="$1" status="$2" message="${3:-}"
    printf '{"step":"%s","status":"%s","message":"%s"}\n' "$step" "$status" "$message"
}

# --- Step 0: Check Xcode Command Line Tools ---
emit "check_xcode" "start" "Checking for Xcode Command Line Tools"

if ! xcode-select -p &>/dev/null; then
    emit "check_xcode" "error" "Xcode Command Line Tools not installed. Run: xcode-select --install"
    exit 1
fi

if ! command -v cmake &>/dev/null; then
    emit "check_xcode" "error" "cmake not found. Install via: brew install cmake"
    exit 1
fi

emit "check_xcode" "done" "Xcode CLT and cmake found"

# --- Step 1: Check conda ---
emit "check_conda" "start" "Checking for conda installation"

if ! command -v conda &>/dev/null; then
    # Try common conda paths
    for p in "$HOME/miniconda3/bin/conda" "$HOME/anaconda3/bin/conda" "/opt/homebrew/Caskroom/miniconda/base/bin/conda"; do
        if [ -x "$p" ]; then
            eval "$("$p" shell.bash hook)"
            break
        fi
    done
fi

if ! command -v conda &>/dev/null; then
    emit "check_conda" "error" "conda not found. Install Miniconda from https://docs.anaconda.com/miniconda/"
    exit 1
fi

emit "check_conda" "done" "Found conda at $(which conda)"

# --- Step 2: Check CTranslate2 source ---
emit "check_source" "start" "Checking CTranslate2 source at $CT2_SOURCE"

if [ ! -f "$CT2_SOURCE/CMakeLists.txt" ]; then
    emit "check_source" "error" "CTranslate2 source not found at $CT2_SOURCE (no CMakeLists.txt)"
    exit 1
fi

emit "check_source" "done" "CTranslate2 source found"

# --- Step 3: Create/verify conda env ---
emit "create_env" "start" "Creating conda environment: $CONDA_ENV_NAME (Python 3.12)"

# Initialize conda for this shell
eval "$(conda shell.bash hook)"

if conda env list | grep -q "^${CONDA_ENV_NAME} "; then
    emit "create_env" "done" "Environment $CONDA_ENV_NAME already exists"
else
    conda create -n "$CONDA_ENV_NAME" python=3.12 -y 2>&1 | tail -1
    emit "create_env" "done" "Environment $CONDA_ENV_NAME created"
fi

conda activate "$CONDA_ENV_NAME"

# --- Step 4: Install Python dependencies ---
emit "install_deps" "start" "Installing Python dependencies (torch, transformers, faster-whisper)"

pip install --quiet torch transformers sentencepiece faster-whisper 2>&1 | tail -3

emit "install_deps" "done" "Python dependencies installed"

# --- Step 5: Build CTranslate2 ---
emit "build_ct2" "start" "Building CTranslate2 with Metal backend"

cd "$CT2_SOURCE"

git submodule update --init --recursive 2>&1 | tail -1

python3 tools/gen_msl_strings.py

CMAKE_PREFIX=$(python -c "import sys; print(sys.prefix)")

cmake -B build \
    -DCMAKE_BUILD_TYPE=Release \
    -DWITH_METAL=ON \
    -DWITH_ACCELERATE=ON \
    -DWITH_MKL=OFF \
    -DWITH_DNNL=OFF \
    -DOPENMP_RUNTIME=NONE \
    -DCMAKE_INSTALL_PREFIX="$CMAKE_PREFIX" \
    2>&1 | tail -3

NCPU=$(sysctl -n hw.logicalcpu)
cmake --build build -j"$NCPU" 2>&1 | tail -5

emit "build_ct2" "done" "CTranslate2 built successfully"

# --- Step 6: Install CTranslate2 ---
emit "install_ct2" "start" "Installing CTranslate2 C++ library and Python bindings"

cmake --install build 2>&1 | tail -3

cd python
pip install . 2>&1 | tail -3
cd ..

emit "install_ct2" "done" "CTranslate2 installed"

# --- Step 7: Validate ---
emit "validate" "start" "Validating installation"

CT2_VERSION=$(python -c "import ctranslate2; print(ctranslate2.__version__)" 2>&1)
FW_OK=$(python -c "import faster_whisper; print('ok')" 2>&1)

if [ "$FW_OK" != "ok" ]; then
    emit "validate" "error" "faster_whisper import failed: $FW_OK"
    exit 1
fi

emit "validate" "done" "CTranslate2 $CT2_VERSION + faster_whisper ready"

echo '{"step":"complete","status":"done","message":"Environment setup complete"}'
