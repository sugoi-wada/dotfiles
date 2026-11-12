#!/bin/zsh
# overlay/split/tab のペイン内で実行される本体。
#
# HUNK_MODE: pick | worktree | staged | branch
# HUNK_DIR : 対象ディレクトリ (pick 以外で使用)
#
# 候補にはホストのリポジトリ/ワークツリーに加えて、devcontainer 内の
# ワークツリー (/workspaces/.claude/worktrees/*) も含める。コンテナ内の
# 差分は `docker exec ... git diff | hunk patch` でホストの hunk に流す。
set -u

MODE="${HUNK_MODE:-branch}"
DIR="${HUNK_DIR:-$PWD}"
WT_ROOT="/workspaces/.claude/worktrees"

HUNK=(hunk)
command -v hunk >/dev/null || HUNK=(bunx hunkdiff)

# フィードバックの送信先を自動判定するため、起動元ペインを記録しておく。
# hunk 側のセッションは pid で引けるので、この shell の pid ($$) を添えておく
# (exec で hunk に置き換わるため、$$ がそのまま hunk の pid になる)。
STATE_DIR="${HERDR_PLUGIN_STATE_DIR:-$HOME/.config/herdr/plugins/config/hunk}"
mkdir -p "$STATE_DIR"
record_origin() {
  [[ -z "${HUNK_ORIGIN_PANE:-}" ]] && return 0
  printf '{"ts":"%s","pid":%d,"origin":"%s","target":"%s"}\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$$" "$HUNK_ORIGIN_PANE" "${1:-}" \
    >> "$STATE_DIR/origins.jsonl"
}
ARGS=(--no-transparent-bg)
[[ -n "${HUNK_THEME:-}" ]] && ARGS=(--theme "$HUNK_THEME" $ARGS)

# ---------------------------------------------------------------- git 実行
# ロケーション表記: "host:<path>" / "docker:<container>:<path>"
loc_kind() { print -r -- "${1%%:*}" }
loc_path() { print -r -- "${1##*:}" }
loc_container() { local r="${1#docker:}"; print -r -- "${r%%:*}" }

gitloc() {  # gitloc <loc> <git args...>
  local loc="$1"; shift
  if [[ "$(loc_kind "$loc")" == docker ]]; then
    docker exec "$(loc_container "$loc")" git -C "$(loc_path "$loc")" "$@" 2>/dev/null
  else
    git -C "$(loc_path "$loc")" "$@" 2>/dev/null
  fi
}

# .gitattributes の linguist-generated が付いたファイルを除外する pathspec を返す。
# 値付き (linguist-generated=true) で設定されることが多く、その場合 check-attr は
# "set" ではなく "true" を返すため、両方を拾う。
# HUNK_NO_EXCLUDE=1 で無効化できる。
generated_excludes() {
  local loc="$1"; shift
  [[ "${HUNK_NO_EXCLUDE:-}" == 1 ]] && return 0
  local names
  names=$(gitloc "$loc" diff --name-only "$@") || return 0
  [[ -z "$names" ]] && return 0
  if [[ "$(loc_kind "$loc")" == docker ]]; then
    print -r -- "$names" | docker exec -i "$(loc_container "$loc")" \
      git -C "$(loc_path "$loc")" check-attr --stdin linguist-generated 2>/dev/null \
      | grep -E ': (set|true)$' | sed 's/: linguist-generated: .*//' | sed 's|^|:(exclude)|'
  else
    print -r -- "$names" | git -C "$(loc_path "$loc")" check-attr --stdin linguist-generated 2>/dev/null \
      | grep -E ': (set|true)$' | sed 's/: linguist-generated: .*//' | sed 's|^|:(exclude)|'
  fi
}

# 比較対象 (<base>...<branch>) を決める
diff_target() {
  local loc="$1"
  local br up
  br=$(gitloc "$loc" branch --show-current)
  [[ -z "$br" ]] && br=HEAD
  up=$(gitloc "$loc" rev-parse --abbrev-ref --symbolic-full-name '@{upstream}')
  # upstream が自分自身を指す場合 (origin/feat_x) はベースにならないので除外
  if [[ -z "$up" || "$up" == "origin/$br" ]]; then
    up=""
    local c
    for c in origin/main origin/master main master; do
      gitloc "$loc" rev-parse --verify "$c" >/dev/null && { up="$c"; break; }
    done
  fi
  [[ -z "$up" ]] && return 1
  print -r -- "$up...$br"
}

# ---------------------------------------------------------------- 候補列挙
container_candidates() {
  local cs c
  if [[ -n "${HUNK_DOCKER_CONTAINERS:-}" ]]; then
    cs=(${=HUNK_DOCKER_CONTAINERS})
  else
    command -v docker >/dev/null || return 0
    cs=(${(f)"$(docker ps --format '{{.Names}}' 2>/dev/null | grep -i workspace)"})
  fi
  for c in $cs; do
    docker exec "$c" ls "$WT_ROOT" 2>/dev/null | while read -r w; do
      [[ -n "$w" ]] && print -r -- "docker:$c:$WT_ROOT/$w"
    done
  done
}

host_candidates() {
  local repo
  find "$HOME/ghq" -maxdepth 4 -name .git 2>/dev/null | sed 's|/\.git$||' | while read -r repo; do
    print -r -- "host:$repo"
    git -C "$repo" worktree list --porcelain 2>/dev/null \
      | awk '/^worktree /{print substr($0,10)}' | while read -r w; do
          [[ -d "$w" ]] && print -r -- "host:$w"
        done
  done
  [[ -d "$HOME/tasks" ]] && print -r -- "host:$HOME/tasks"
}

# ---------------------------------------------------------------- preview
if [[ "${1:-}" == "--preview" ]]; then
  loc="$2"
  print "== $loc"
  print ""
  t=$(diff_target "$loc") && {
    print "ブランチ差分 ($t):"
    gitloc "$loc" diff --stat "$t" | tail -20
    print ""
  }
  print "未コミット (git status --short):"
  gitloc "$loc" status --short | head -15
  print ""
  print "直近のコミット:"
  gitloc "$loc" log --oneline -5
  exit 0
fi

# ---------------------------------------------------------------- pick
if [[ "$MODE" == "pick" ]]; then
  print "候補を収集中..."
  ALL=$( { host_candidates; container_candidates } | sort -u )
  if [[ -z "$ALL" ]]; then
    print "候補が見つかりません"; read -k 1; exit 0
  fi

  # 起動元ペインの会話ログからレビュー対象を推定し、先頭に出す。
  # 自動で確定はしない (外したときに気付けず別の差分を見てしまうため)。
  GUESS=""
  if [[ -n "${HUNK_ORIGIN_PANE:-}" ]]; then
    GUESS=$(HERDR_BIN_PATH="${HERDR_BIN_PATH:-herdr}" \
      python3 "${0:A:h}/guess_target.py" "$HUNK_ORIGIN_PANE" 2>/dev/null)
  fi

  # "loc<TAB>表示" の形に整える。推定は ★ を付けて上に置き、本体からは除く。
  ROWS=""
  if [[ -n "$GUESS" ]]; then
    i=1
    for g in ${(f)GUESS}; do
      ROWS="$ROWS$g"$'\t'"★ 推定$i  ${g/#host:/}"$'\n'
      (( i++ ))
    done
  fi
  for c in ${(f)ALL}; do
    if [[ -n "$GUESS" ]] && print -r -- "$GUESS" | grep -qxF -- "$c"; then
      continue
    fi
    ROWS="$ROWS$c"$'\t'"   ${c/#host:/}"$'\n'
  done

  SEL=$(print -r -- "$ROWS" | grep -v '^[[:space:]]*$' | fzf \
    --prompt="hunk で開く対象> " \
    --with-nth=2 --delimiter=$'\t' \
    --height=100% --reverse --border \
    --header="★ = 起動元ペインの作業ログからの推定" \
    --preview="$0 --preview {1}" \
    --preview-window=right,60%)
  [[ -z "$SEL" ]] && exit 0
  LOC="${SEL%%$'\t'*}"
  MODE="branch"
else
  LOC="host:$DIR"
fi

# ---------------------------------------------------------------- 対象決定
case "$MODE" in
  staged)   TARGET=(--staged) ;;
  worktree) TARGET=() ;;
  branch)
    if t=$(diff_target "$LOC"); then
      TARGET=("$t")
    else
      print "比較対象のベースブランチが見つかりません。未コミット差分にフォールバックします。"
      TARGET=()
    fi
    ;;
esac

# 生成ファイル (.gitattributes の linguist-generated) を除外する
EXCLUDES=(${(f)"$(generated_excludes "$LOC" "${TARGET[@]}")"})
SPEC=()
if (( ${#EXCLUDES[@]} > 0 )); then
  SPEC=(-- . "${EXCLUDES[@]}")
fi

# 差分が空なら理由を出す (無言で閉じると原因が分からない)
STAT=$(gitloc "$LOC" diff --stat "${TARGET[@]}" "${SPEC[@]}")
if [[ -z "$STAT" && ${#TARGET[@]} -gt 0 ]]; then
  print "指定対象 (${TARGET[*]}) に差分なし。未コミット差分を試します。"
  TARGET=()
  EXCLUDES=(${(f)"$(generated_excludes "$LOC")"})
  SPEC=()
  (( ${#EXCLUDES[@]} > 0 )) && SPEC=(-- . "${EXCLUDES[@]}")
  STAT=$(gitloc "$LOC" diff --stat "${SPEC[@]}")
fi

if [[ -z "$STAT" ]]; then
  print "差分がありません"
  print "  対象: $LOC"
  print "  モード: $MODE"
  print ""
  print "git status --short:"
  gitloc "$LOC" status --short | head -20
  print ""
  print "直近のコミット:"
  gitloc "$LOC" log --oneline -5
  print ""
  print "何かキーを押すと閉じます"; read -k 1
  exit 0
fi

# ---------------------------------------------------------------- 表示
if (( ${#EXCLUDES[@]} > 0 )); then
  print "生成ファイル ${#EXCLUDES[@]} 件を除外しました (.gitattributes の linguist-generated)"
fi

record_origin "$LOC"

if [[ "$(loc_kind "$LOC")" == docker ]]; then
  # コンテナ内の差分はパッチとしてホストの hunk に流す
  gitloc "$LOC" diff "${TARGET[@]}" "${SPEC[@]}" | "${HUNK[@]}" patch $ARGS
else
  cd "$(loc_path "$LOC")" || { print "cd 失敗"; read -k 1; exit 1; }
  exec "${HUNK[@]}" diff "${TARGET[@]}" $ARGS "${SPEC[@]}"
fi
