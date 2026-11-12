#!/usr/bin/env python3
"""hunk session list --json を "session_id<TAB>表示用文字列" で列挙する。"""
import json
import sys


def main() -> int:
    data = json.load(sys.stdin)
    sessions = data.get("sessions") if isinstance(data, dict) else data
    for s in sessions or []:
        sid = s.get("sessionId") or s.get("id") or ""
        title = s.get("title") or s.get("sourceLabel") or ""
        cwd = s.get("cwd") or ""
        count = s.get("fileCount")
        if count is None:
            files = s.get("files")
            count = len(files) if isinstance(files, list) else None
        parts = [title]
        if count is not None:
            parts.append(f"{count} files")
        if cwd:
            parts.append(cwd)
        print(f"{sid}\t{'  |  '.join(parts)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
