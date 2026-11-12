#!/bin/zsh
# hunk のライブセッションに書いたコメントを、Herdr のエージェントペインへ
# フィードバックとして送る。
#
# hunk 自体に「送信」の仕組みはなく、コメントはライブセッションに溜まって
# エージェント側が CLI で読み取る設計なので、その受け渡しをここで行う。
set -u

HERDR="${HERDR_BIN_PATH:-herdr}"
HERE="${0:A:h}"

# ---------------------------------------------------------------- セッション選択
SESSIONS=$(hunk session list --json 2>/dev/null)
if [[ -z "$SESSIONS" ]]; then
  print "hunk のライブセッションがありません。先に hunk を開いてください。"
  read -k 1; exit 1
fi

SID=$(print -r -- "$SESSIONS" | python3 "$HERE/list_sessions.py" | fzf \
  --prompt="コメントを取り出すセッション> " --with-nth=2 --delimiter=$'\t' \
  --height=40% --reverse --border --select-1 | cut -f1)
[[ -z "$SID" ]] && exit 0

# ---------------------------------------------------------------- コメント整形
BODY=$(hunk session comment list "$SID" --type user --json 2>/dev/null \
  | python3 "$HERE/format_comments.py")
RC=$?
if (( RC == 3 )); then
  print "このセッションにユーザーのコメントがありません。"
  read -k 1; exit 0
fi
if [[ $RC -ne 0 || -z "$BODY" ]]; then
  print "コメントの取得に失敗しました。"
  read -k 1; exit 1
fi

COUNT=$(print -r -- "$BODY" | grep -cE '^## [0-9]+\. ')

# ---------------------------------------------------------------- 送信先ペイン
# 通常は hunk を開いた元のペインへ返す。hunk-pane.sh がその ID を記録している。
SESSION_PID=$(print -r -- "$SESSIONS" | python3 -c '
import json, sys
sid = sys.argv[1]
d = json.load(sys.stdin)
for s in (d.get("sessions") if isinstance(d, dict) else d) or []:
    if (s.get("sessionId") or s.get("id")) == sid:
        print(s.get("pid") or "")
        break
' "$SID" 2>/dev/null)

TARGET=$(python3 "$HERE/resolve_origin.py" "$SESSION_PID" 2>/dev/null)

# 記録がない / そのペインにエージェントがいない場合は選ばせる
PICK_NEEDED=0
if [[ -z "$TARGET" ]]; then
  PICK_NEEDED=1
else
  if ! "$HERDR" agent get "$TARGET" >/dev/null 2>&1; then
    print "記録された起動元ペイン ($TARGET) にエージェントがいません。選び直します。"
    PICK_NEEDED=1
  fi
fi

BODY_FILE=$(mktemp -t hunk-feedback)
print -r -- "$BODY" > "$BODY_FILE"
trap 'rm -f "$BODY_FILE"' EXIT

PREVIEW_PANE="$HERDR pane read {1} --source recent-unwrapped --lines 400 2>/dev/null | grep -v '^[[:space:]]*\$' | tail -60"

if (( PICK_NEEDED == 0 )); then
  print "送信先: $TARGET (hunk を開いた元のペイン)"
  print ""
  "$HERDR" pane read "$TARGET" --source recent-unwrapped --lines 400 2>/dev/null \
    | grep -v '^[[:space:]]*$' | tail -12
  print ""
  print -n "コメント ${COUNT} 件をここへ送ります。[Enter=送信 / e=選び直す / q=中止] "
  read -k 1 ans; print ""
  case "$ans" in
    q|Q) exit 0 ;;
    e|E) PICK_NEEDED=1 ;;
  esac
fi

if (( PICK_NEEDED == 1 )); then
  LIST=$(HERDR_BIN_PATH="$HERDR" python3 "$HERE/list_agent_panes.py")
  if [[ -z "$LIST" ]]; then
    print "送信先のエージェントペインが見つかりません。"
    read -k 1; exit 1
  fi
  TARGET=$(print -r -- "$LIST" | fzf \
    --prompt="フィードバックの送信先> " --with-nth=2 --delimiter=$'\t' \
    --height=100% --reverse --border \
    --header="コメント ${COUNT} 件 | プレビュー=ペインの現在の表示 | ctrl-b:送信内容 ctrl-p:ペイン表示" \
    --preview="$PREVIEW_PANE" \
    --preview-window=right,65%,wrap \
    --bind="ctrl-b:change-preview(cat $BODY_FILE)" \
    --bind="ctrl-p:change-preview($PREVIEW_PANE)" \
    | cut -f1)
  [[ -z "$TARGET" ]] && exit 0
fi

# ---------------------------------------------------------------- 送信
if ! "$HERDR" agent prompt "$TARGET" "$BODY" >/dev/null 2>&1; then
  print "送信に失敗しました。ペインの状態:"
  "$HERDR" agent get "$TARGET" 2>&1 | head -8
  print ""
  print "何かキーを押すと閉じます"; read -k 1; exit 1
fi

print "$TARGET へコメント ${COUNT} 件を送信しました。"
print ""
print -n "送信済みのコメントをセッションから消しますか? [y/N] "
read -k 1 ans; print ""
if [[ "$ans" == (y|Y) ]]; then
  if hunk session comment clear "$SID" --include-user --yes >/dev/null 2>&1; then
    print "コメントを消去しました。"
  else
    print "消去に失敗しました。"
  fi
fi
print ""
print "何かキーを押すと閉じます"; read -k 1
