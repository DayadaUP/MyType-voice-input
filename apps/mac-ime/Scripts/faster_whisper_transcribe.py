#!/usr/bin/env python3
import argparse
import json
import os
import re
import sys
import time


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Local faster-whisper transcription")
    parser.add_argument("--audio", required=True, help="Path to recorded audio file")
    parser.add_argument("--model", default="small", help="Model size/name, e.g. tiny, base, small")
    parser.add_argument("--device", default="auto", help="compute device")
    parser.add_argument("--compute-type", default="int8", help="faster-whisper compute type")
    parser.add_argument("--beam-size", default=5, type=int, help="beam size")
    parser.add_argument("--language", default=None, help="forced language, e.g. zh")
    parser.add_argument("--model-dir", default=None, help="directory to cache/download models")
    parser.add_argument(
        "--chinese-script",
        default="simplified",
        choices=["simplified", "traditional"],
        help="output Chinese script mode",
    )
    return parser.parse_args()


def fail(msg: str, code: int = 1) -> None:
    sys.stderr.write(msg + "\n")
    sys.exit(code)


def main() -> None:
    args = parse_args()

    if not os.path.exists(args.audio):
        fail(f"audio file not found: {args.audio}", code=3)

    try:
        from faster_whisper import WhisperModel
    except Exception as exc:  # pragma: no cover - dependency error path
        fail(
            "faster-whisper is not installed in the selected Python environment.\n"
            "Set MYTYPE_ASR_PYTHON to a Python that has the required packages installed,\n"
            "or create a venv and install:\n"
            "python3 -m venv .venv && source .venv/bin/activate && "
            "pip install faster-whisper opencc-python-reimplemented\n"
            f"import error: {exc}",
            code=2,
        )

    started = time.time()
    model = WhisperModel(
        args.model,
        device=args.device,
        compute_type=args.compute_type,
        download_root=args.model_dir,
    )

    transcribe_kwargs = {
        "beam_size": args.beam_size,
        "vad_filter": True,
    }
    if args.language:
        transcribe_kwargs["language"] = args.language

    segments, info = model.transcribe(args.audio, **transcribe_kwargs)
    segment_list = list(segments)
    text = "".join(segment.text for segment in segment_list).strip()
    text = strip_prompt_artifacts(text)
    text = convert_chinese_script(text, args.chinese_script)
    latency_ms = int((time.time() - started) * 1000)

    payload = {
        "text": text,
        "latency_ms": latency_ms,
        "language": getattr(info, "language", None),
    }
    sys.stdout.write(json.dumps(payload, ensure_ascii=False))


def convert_chinese_script(text: str, mode: str) -> str:
    if not text:
        return text
    if mode not in {"simplified", "traditional"}:
        return text

    config = "t2s" if mode == "simplified" else "s2t"
    try:
        from opencc import OpenCC  # type: ignore
    except Exception:
        # OpenCC is optional at runtime; fallback to original text if unavailable.
        return text

    try:
        converter = OpenCC(config)
        return converter.convert(text)
    except Exception:
        return text


def strip_prompt_artifacts(text: str) -> str:
    if not text:
        return text

    # Defensive cleanup in case model leaks guidance text into transcript prefix.
    prefixes = [
        "中英混合转写，英文单词保持原文拼写，不要翻译为中文",
        "中英混合转写",
        "中英文混合输入",
        "中英混合输入",
    ]

    cleaned = text.lstrip()
    for prefix in prefixes:
        pattern = rf"^{re.escape(prefix)}[\s,，。.!！？:：;；、-]*"
        cleaned = re.sub(pattern, "", cleaned)

    return cleaned.strip()


if __name__ == "__main__":
    main()
