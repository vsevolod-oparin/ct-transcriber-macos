#!/usr/bin/env python3
"""
transcribe.py — CLI wrapper for faster-whisper transcription.

Outputs JSON to stdout (one line per segment as they complete),
progress info to stderr. Designed to be called from the Swift app
as a subprocess.

Usage:
  python transcribe.py \
    --model /path/to/whisper-model-dir \
    --audio /path/to/audio.mp3 \
    --device mps \
    --beam-size 5 \
    --temperature 0.0 \
    --language "" \
    --vad-filter \
    --no-condition-on-previous-text

Output (stdout):
  {"type": "info", "language": "en", "language_probability": 0.98, "duration": 62.5}
  {"type": "segment", "start": 0.0, "end": 3.5, "text": "Hello world"}
  {"type": "segment", "start": 3.5, "end": 7.2, "text": "This is a test"}
  {"type": "done", "num_segments": 2, "elapsed": 4.32}

Progress (stderr):
  [progress] Loading model...
  [progress] Transcribing... 45%
"""

import argparse
import json
import sys
import time


def emit(obj):
    """Write a JSON object to stdout and flush."""
    print(json.dumps(obj, ensure_ascii=False), flush=True)


def progress(msg):
    """Write a progress message to stderr."""
    print(f"[progress] {msg}", file=sys.stderr, flush=True)


def main():
    parser = argparse.ArgumentParser(description="Transcribe audio with faster-whisper")
    parser.add_argument("--model", required=True, help="Path to CTranslate2 whisper model directory")
    parser.add_argument("--audio", required=True, help="Path to audio file")
    parser.add_argument("--device", default="mps", choices=["mps", "cpu"],
                        help="Device: mps (Metal GPU) or cpu (default: mps)")
    parser.add_argument("--beam-size", type=int, default=5, help="Beam size (default: 5)")
    parser.add_argument("--temperature", type=float, default=0.0, help="Temperature (default: 0.0)")
    parser.add_argument("--language", default="", help="Language code or empty for auto-detect")
    parser.add_argument("--vad-filter", action="store_true", default=True, help="Enable VAD filter")
    parser.add_argument("--no-vad-filter", action="store_false", dest="vad_filter")
    parser.add_argument("--condition-on-previous-text", action="store_true", default=False)
    parser.add_argument("--no-condition-on-previous-text", action="store_false",
                        dest="condition_on_previous_text")
    parser.add_argument("--flash-attention", action="store_true", default=True,
                        help="Enable flash attention (default: True)")
    parser.add_argument("--no-flash-attention", action="store_false", dest="flash_attention")
    parser.add_argument("--skip-timestamps", action="store_true", default=False,
                        help="Skip timestamp generation (faster transcription)")
    parser.add_argument("--no-skip-timestamps", action="store_false", dest="skip_timestamps")
    args = parser.parse_args()

    compute_type = "float16" if args.device == "mps" else "float32"
    language = args.language if args.language else None

    progress(f"Loading model from {args.model} ({args.device}, {compute_type}, flash_attn={args.flash_attention})...")

    try:
        from faster_whisper import WhisperModel
    except ImportError as e:
        emit({"type": "error", "message": f"Failed to import faster_whisper: {e}"})
        sys.exit(1)

    try:
        model = WhisperModel(args.model, device=args.device, compute_type=compute_type,
                             flash_attention=args.flash_attention)
    except Exception as e:
        emit({"type": "error", "message": f"Failed to load model: {e}"})
        sys.exit(1)

    progress("Transcribing...")

    t0 = time.monotonic()

    try:
        segments_iter, info = model.transcribe(
            args.audio,
            beam_size=args.beam_size,
            language=language,
            temperature=args.temperature,
            condition_on_previous_text=args.condition_on_previous_text,
            vad_filter=args.vad_filter,
            without_timestamps=args.skip_timestamps,
        )

        emit({
            "type": "info",
            "language": info.language,
            "language_probability": round(info.language_probability, 3),
            "duration": round(info.duration, 2),
        })

        num_segments = 0
        for seg in segments_iter:
            num_segments += 1
            emit({
                "type": "segment",
                "start": round(seg.start, 2),
                "end": round(seg.end, 2),
                "text": seg.text.strip(),
            })

            # Report progress based on position in audio
            if info.duration > 0:
                pct = min(100, int(seg.end / info.duration * 100))
                progress(f"Transcribing... {pct}%")

        elapsed = time.monotonic() - t0
        emit({
            "type": "done",
            "num_segments": num_segments,
            "elapsed": round(elapsed, 2),
        })

        progress(f"Done — {num_segments} segments in {elapsed:.1f}s")

    except Exception as e:
        emit({"type": "error", "message": f"Transcription failed: {e}"})
        sys.exit(1)
    finally:
        del model
        import gc
        gc.collect()
        if args.device == "mps":
            try:
                import ctranslate2
                ctranslate2.clear_device_cache("mps")
            except Exception:
                pass


if __name__ == "__main__":
    main()
