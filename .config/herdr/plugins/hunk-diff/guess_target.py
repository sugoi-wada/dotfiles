#!/usr/bin/env python3
"""起動元ペインのエージェント会話ログから、レビュー対象を推定する。

Claude Code のセッションログ (~/.claude/projects/<proj>/<session-id>.jsonl) を
末尾から走査し、最後に言及されたワークツリー/リポジトリを返す。

出現回数で判定すると過去の作業に引きずられる (実測: all_day_events 365回 >
cs_sender 172回 だが、実際の作業対象は cs_sender) ため、必ず末尾優先で見る。

出力: "docker:<container>:<path>" / "host:<path>" を順位順に最大2行。
推定できなければ終了コード 1。
"""
import json
import os
import re
import subprocess
import sys
from pathlib import Path

HERDR = os.environ.get("HERDR_BIN_PATH") or "herdr"
HOME = Path.home()
PROJECTS = HOME / ".claude/projects"
WT_ROOT = "/workspaces/.claude/worktrees"
TAIL_BYTES = 2 * 1024 * 1024  # 末尾だけ読む (ログは 10MB を超える)

CONTAINER_WT = re.compile(re.escape(WT_ROOT) + r"/([A-Za-z0-9._-]+)")
HOST_REPO = re.compile(re.escape(str(HOME)) + r"/ghq/[A-Za-z0-9._/-]+")


def pane_session_id(pane_id: str) -> str | None:
    r = subprocess.run(
        [HERDR, "pane", "get", pane_id], text=True,
        stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
    )
    if r.returncode != 0:
        return None
    try:
        pane = json.loads(r.stdout)["result"]["pane"]
    except (json.JSONDecodeError, KeyError):
        return None
    if pane.get("agent") != "claude":
        return None
    return (pane.get("agent_session") or {}).get("value")


def transcript_for(session_id: str) -> Path | None:
    """プロジェクトディレクトリ名のエンコード規則に依存せず総当たりで探す。"""
    if not PROJECTS.is_dir():
        return None
    for proj in PROJECTS.iterdir():
        cand = proj / f"{session_id}.jsonl"
        if cand.is_file():
            return cand
    return None


def tail_text(path: Path) -> str:
    size = path.stat().st_size
    with path.open("rb") as fh:
        if size > TAIL_BYTES:
            fh.seek(size - TAIL_BYTES)
        return fh.read().decode("utf-8", errors="replace")


def workspace_containers() -> list[str]:
    env = os.environ.get("HUNK_DOCKER_CONTAINERS")
    if env:
        return env.split()
    r = subprocess.run(
        ["docker", "ps", "--format", "{{.Names}}"], text=True,
        stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
    )
    if r.returncode != 0:
        return []
    return [n for n in r.stdout.split() if "workspace" in n.lower()]


def container_having(path: str) -> str | None:
    for c in workspace_containers():
        r = subprocess.run(
            ["docker", "exec", c, "test", "-d", path],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
        )
        if r.returncode == 0:
            return c
    return None


def guesses(text: str) -> list[str]:
    """推定候補を順位付きで返す (最大2件)。

    コンテナのワークツリーを優先する。ホスト側の ghq パスは、コンテナで作業
    していても push や clone のために出てくるため (実測: 最後のホスト一致は
    `cd ~/ghq/.../mf-admin && git push origin claude/...` だった)、位置が後ろ
    でもワークツリーより上位には置かない。
    """
    out: list[str] = []

    wt = list(CONTAINER_WT.finditer(text))
    if wt:
        path = f"{WT_ROOT}/{wt[-1].group(1)}"
        c = container_having(path)
        if c:
            out.append(f"docker:{c}:{path}")

    host = list(HOST_REPO.finditer(text))
    if host:
        p = Path(host[-1].group(0))
        while p != p.parent and not (p / ".git").exists():
            p = p.parent
        if (p / ".git").exists():
            loc = f"host:{p}"
            if loc not in out:
                out.append(loc)

    return out


def main() -> int:
    if len(sys.argv) < 2 or not sys.argv[1]:
        return 1
    sid = pane_session_id(sys.argv[1])
    if not sid:
        return 1
    tr = transcript_for(sid)
    if not tr:
        return 1
    found = guesses(tail_text(tr))
    if not found:
        return 1
    for g in found:
        print(g)
    return 0


if __name__ == "__main__":
    sys.exit(main())
