#!/usr/bin/env python3
"""hunk のレビューを開いた「起動元ペイン」を割り出す。

hunk-pane.sh が記録した origins.jsonl から、対象セッションに対応する
起動元ペインを返す。優先順位:
  1. セッションの pid と記録の pid が一致するもの (exec で置き換わる経路)
  2. 記録のうち最も新しいもの

見つからなければ終了コード 1。
"""
import json
import os
import sys
from pathlib import Path

STATE_DIR = Path(
    os.environ.get("HERDR_PLUGIN_STATE_DIR")
    or Path.home() / ".config/herdr/plugins/config/hunk"
)
RECORD = STATE_DIR / "origins.jsonl"


def records() -> list[dict]:
    if not RECORD.is_file():
        return []
    out = []
    for line in RECORD.read_text().splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            out.append(json.loads(line))
        except json.JSONDecodeError:
            continue
    return out


def main() -> int:
    session_pid = None
    if len(sys.argv) > 1 and sys.argv[1].isdigit():
        session_pid = int(sys.argv[1])

    rs = records()
    if not rs:
        return 1

    if session_pid is not None:
        for r in reversed(rs):
            if r.get("pid") == session_pid and r.get("origin"):
                print(r["origin"])
                return 0

    for r in reversed(rs):
        if r.get("origin"):
            print(r["origin"])
            return 0
    return 1


if __name__ == "__main__":
    sys.exit(main())
