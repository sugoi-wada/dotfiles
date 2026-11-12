#!/usr/bin/env python3
"""Herdr のエージェントペインを "pane_id<TAB>表示用文字列" で列挙する。

~/tasks で複数の Claude を回すと title も cwd も同じになり名前では区別できない。
ここでは workspace ラベル・ペインID・エージェント種別・状態を並べ、実際の識別は
呼び出し側 (fzf) のプレビューでペインの表示内容を出して行う。
"""
import json
import os
import subprocess
import sys

HERDR = os.environ.get("HERDR_BIN_PATH") or "herdr"
HOME = os.path.expanduser("~")


def herdr_json(args: list[str]) -> dict:
    r = subprocess.run([HERDR, *args], text=True, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
    if r.returncode != 0:
        return {}
    try:
        return json.loads(r.stdout)
    except json.JSONDecodeError:
        return {}


def main() -> int:
    ws = herdr_json(["workspace", "list"]).get("result", {}).get("workspaces", [])
    rows = 0
    for w in ws:
        wid = w["workspace_id"]
        label = w.get("label") or wid
        panes = herdr_json(["pane", "list", "--workspace", wid]).get("result", {}).get("panes", [])
        for p in panes:
            if not p.get("agent"):
                continue
            pid = p["pane_id"]
            title = (p.get("terminal_title_stripped") or p.get("label") or "")[:40]
            cwd = (p.get("cwd") or "").replace(HOME, "~")
            disp = (
                f"[{label:<9}] {pid:<7} {p['agent']:<8} "
                f"{p.get('agent_status') or '':<8} {cwd:<26} {title}"
            )
            print(f"{pid}\t{disp}")
            rows += 1
    return 0 if rows else 4


if __name__ == "__main__":
    sys.exit(main())
