#!/usr/bin/env python3
"""hunk session comment list --json を読み、エージェントへ渡す Markdown に整形する。

コメントが無いときは終了コード 3 を返す。
"""
import json
import sys

HEADER = "hunk でのコードレビューのフィードバックです。各項目に対応してください。"


def main() -> int:
    data = json.load(sys.stdin)
    comments = data.get("comments") or []
    if not comments:
        return 3
    out = [HEADER, ""]
    for i, c in enumerate(comments, 1):
        path = c.get("filePath") or "?"
        rng = c.get("newRange") or c.get("oldRange") or []
        where = f"{path}:{rng[0]}" if rng else path
        out.append(f"## {i}. {where}")
        out.append("")
        body = (c.get("body") or "").splitlines() or [""]
        out.extend(f"> {line}" for line in body)
        out.append("")
    print("\n".join(out))
    return 0


if __name__ == "__main__":
    sys.exit(main())
