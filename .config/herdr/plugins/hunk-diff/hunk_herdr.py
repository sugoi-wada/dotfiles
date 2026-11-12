#!/usr/bin/env python3
"""Hunk の diff を Herdr のペイン/タブで開く。

edmundmiller/herdr-plugin-hunk を参考にしつつ、対象ディレクトリを fzf で
選ぶ "pick" モードを追加している。~/tasks に常駐して各プロダクトへ指示を
出すワークフローでは、フォーカス中ペインの cwd が常にタスク管理リポジトリに
なってしまい、cwd 依存では目的の diff が出せないため。
"""
from __future__ import annotations

import json
import os
import shlex
import shutil
import subprocess
import sys
from pathlib import Path
from typing import Any

VALID_MODES = {"worktree", "staged", "branch", "pick", "feedback"}
VALID_TARGETS = {"overlay", "split", "tab"}

PLUGIN_DIR = Path(__file__).resolve().parent
PANE_SCRIPT = PLUGIN_DIR / "hunk-pane.sh"


def herdr_bin() -> str:
    return os.environ.get("HERDR_BIN_PATH") or "herdr"


def context() -> dict[str, Any]:
    try:
        return json.loads(os.environ.get("HERDR_PLUGIN_CONTEXT_JSON") or "{}")
    except json.JSONDecodeError:
        return {}


def run_json(args: list[str]) -> dict[str, Any]:
    result = subprocess.run(
        [herdr_bin(), *args], text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE
    )
    if result.returncode != 0:
        raise SystemExit(result.stderr or result.stdout or f"herdr {' '.join(args)} failed")
    try:
        payload = json.loads(result.stdout)
    except json.JSONDecodeError as err:
        raise SystemExit(f"herdr {' '.join(args)} did not return JSON: {err}\n{result.stdout}") from err
    if "error" in payload:
        raise SystemExit(json.dumps(payload["error"], indent=2))
    return payload


def run_ok(args: list[str]) -> None:
    """JSON を返さないコマンド用。終了コードだけ見る。"""
    result = subprocess.run(
        [herdr_bin(), *args], text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE
    )
    if result.returncode != 0:
        raise SystemExit(result.stderr or result.stdout or f"herdr {' '.join(args)} failed")


def response_path(payload: dict[str, Any], *path: str) -> Any:
    cursor: Any = payload
    for part in path:
        cursor = cursor[part]
    return cursor


def git_output(cwd: str, args: list[str]) -> str | None:
    result = subprocess.run(
        ["git", *args], cwd=cwd, text=True, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL
    )
    if result.returncode != 0:
        return None
    return result.stdout.strip() or None


def default_base_ref(cwd: str) -> str:
    for candidate in ("origin/main", "origin/master", "main", "master"):
        if git_output(cwd, ["rev-parse", "--verify", candidate]):
            return candidate
    return "origin/main"


def hunk_executable() -> list[str]:
    if shutil.which("hunk"):
        return ["hunk"]
    return ["bunx", "hunkdiff"]


def theme_args() -> list[str]:
    args = ["--no-transparent-bg"]
    theme = os.environ.get("HUNK_THEME")
    if theme:
        return ["--theme", theme, *args]
    return args


def hunk_args(cwd: str, mode: str) -> list[str]:
    if mode == "staged":
        args = ["diff", "--staged"]
    elif mode == "branch":
        branch = git_output(cwd, ["branch", "--show-current"]) or "HEAD"
        upstream = git_output(
            cwd, ["rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{upstream}"]
        ) or default_base_ref(cwd)
        args = ["diff", f"{upstream}..{branch}"]
    else:
        args = ["diff"]
    return [*args, *theme_args()]


def shell_command(cwd: str, mode: str, origin_pane: str | None = None) -> str:
    """split/tab のペインで実行するコマンド文字列。overlay では使わない。"""
    return " ".join(
        shlex.quote(part)
        for part in [
            "env",
            f"HUNK_MODE={mode}",
            f"HUNK_DIR={cwd}",
            f"HUNK_ORIGIN_PANE={origin_pane or ''}",
            str(PANE_SCRIPT),
        ]
    )


def target_context() -> tuple[str, str | None, str]:
    ctx = context()
    workspace_id = str(ctx.get("workspace_id") or os.environ.get("HERDR_WORKSPACE_ID") or "")
    pane_id = ctx.get("focused_pane_id") or os.environ.get("HERDR_PANE_ID")
    cwd = ctx.get("focused_pane_cwd") or ctx.get("workspace_cwd") or os.getcwd()
    if not workspace_id:
        raise SystemExit("missing Herdr workspace id")
    return workspace_id, str(pane_id) if pane_id else None, str(cwd)


def open_target(mode: str, target: str) -> None:
    workspace_id, pane_id, cwd = target_context()
    if not PANE_SCRIPT.is_file():
        raise SystemExit(f"pane script not found: {PANE_SCRIPT}")

    if target == "overlay":
        # 一時的な全画面。hunk を抜けるとペインが閉じる。
        args = [
            "plugin", "pane", "open",
            "--plugin", "hunk",
            "--entrypoint", "feedback" if mode == "feedback" else "diff",
            "--placement", "overlay",
            "--cwd", cwd,
            "--env", f"HUNK_MODE={mode}",
            "--env", f"HUNK_DIR={cwd}",
            # フィードバックの送信先を自動判定するため起動元ペインを引き継ぐ
            "--env", f"HUNK_ORIGIN_PANE={pane_id or ''}",
            "--focus",
        ]
        # overlay/popup は active pane を対象にするため --workspace は渡せない
        # (invalid_params: overlay and popup plugin panes target the active pane)
        run_ok(args)
        return

    if target == "tab":
        payload = run_json(
            ["tab", "create", "--workspace", workspace_id, "--cwd", cwd, "--label", "hunk", "--focus"]
        )
        hunk_pane = response_path(payload, "result", "root_pane", "pane_id")
    else:
        if not pane_id:
            raise SystemExit("missing focused Herdr pane id")
        payload = run_json(
            ["pane", "split", pane_id, "--direction", "right", "--cwd", cwd, "--focus"]
        )
        hunk_pane = response_path(payload, "result", "pane", "pane_id")
    run_ok(["pane", "rename", hunk_pane, "hunk"])
    run_ok(["pane", "run", hunk_pane, shell_command(cwd, mode, pane_id)])


def parse_args(argv: list[str]) -> tuple[str, str]:
    if len(argv) != 2 or argv[0] not in VALID_MODES or argv[1] not in VALID_TARGETS:
        modes = "|".join(sorted(VALID_MODES))
        targets = "|".join(sorted(VALID_TARGETS))
        raise SystemExit(f"usage: hunk_herdr.py {modes} {targets}")
    return argv[0], argv[1]


def main() -> None:
    mode, target = parse_args(sys.argv[1:])
    open_target(mode, target)


if __name__ == "__main__":
    main()
