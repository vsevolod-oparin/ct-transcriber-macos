#!/usr/bin/env python3
"""
convert_model.py — Downloads and converts a Whisper model to CTranslate2 format.

Called by the Swift app as a subprocess. Reports progress as JSON to stdout.

Usage:
  python convert_model.py \
    --hf-model openai/whisper-large-v3-turbo \
    --output-dir /path/to/models/whisper-large-v3-turbo \
    --quantization float16

Output (stdout):
  {"type": "progress", "step": "download", "message": "Downloading model..."}
  {"type": "progress", "step": "convert", "message": "Converting to CTranslate2 format..."}
  {"type": "done", "output_dir": "/path/to/models/whisper-large-v3-turbo", "message": "Model ready"}
  {"type": "error", "message": "..."}
"""

import argparse
import json
import os
import sys


def emit(obj):
    print(json.dumps(obj, ensure_ascii=False), flush=True)


def progress(step, message):
    emit({"type": "progress", "step": step, "message": message})


def main():
    parser = argparse.ArgumentParser(description="Convert Whisper model to CTranslate2 format")
    parser.add_argument("--hf-model", required=True, help="HuggingFace model ID (e.g. openai/whisper-large-v3-turbo)")
    parser.add_argument("--output-dir", required=True, help="Output directory for converted model")
    parser.add_argument("--quantization", default="float16", help="Quantization type (default: float16)")
    args = parser.parse_args()

    output_dir = args.output_dir

    # Check if model already exists and is valid
    if is_valid_model(output_dir):
        emit({"type": "done", "output_dir": output_dir, "message": "Model already exists and is valid"})
        return

    progress("download", f"Downloading {args.hf_model} from HuggingFace...")

    try:
        import ctranslate2
    except ImportError as e:
        emit({"type": "error", "message": f"ctranslate2 not installed: {e}"})
        sys.exit(1)

    try:
        from ctranslate2.converters.transformers import TransformersConverter
    except ImportError:
        # Fallback: use the CLI converter via subprocess
        progress("convert", "Using ct2-transformers-converter CLI...")
        import subprocess
        result = subprocess.run(
            [
                sys.executable, "-m", "ctranslate2.converters.transformers",
                "--model", args.hf_model,
                "--output_dir", output_dir,
                "--quantization", args.quantization,
                "--copy_files", "tokenizer.json", "preprocessor_config.json",
                "--force",
            ],
            capture_output=True, text=True
        )
        if result.returncode != 0:
            emit({"type": "error", "message": f"Conversion failed: {result.stderr[-500:]}"})
            sys.exit(1)

        if is_valid_model(output_dir):
            emit({"type": "done", "output_dir": output_dir, "message": "Model converted successfully"})
        else:
            emit({"type": "error", "message": "Conversion completed but model validation failed"})
            sys.exit(1)
        return

    # Use the Python API directly
    progress("convert", f"Converting {args.hf_model} to CTranslate2 ({args.quantization})...")

    try:
        converter = TransformersConverter(
            args.hf_model,
            copy_files=["tokenizer.json", "preprocessor_config.json"],
        )
        converter.convert(
            output_dir,
            quantization=args.quantization,
            force=True,
        )
    except Exception as e:
        emit({"type": "error", "message": f"Conversion failed: {e}"})
        sys.exit(1)

    if is_valid_model(output_dir):
        emit({"type": "done", "output_dir": output_dir, "message": "Model converted successfully"})
    else:
        emit({"type": "error", "message": "Conversion completed but model validation failed"})
        sys.exit(1)


def is_valid_model(path):
    """Check if a CTranslate2 whisper model directory is valid."""
    if not os.path.isdir(path):
        return False
    required_files = ["model.bin", "tokenizer.json", "preprocessor_config.json"]
    return all(os.path.isfile(os.path.join(path, f)) for f in required_files)


if __name__ == "__main__":
    main()
