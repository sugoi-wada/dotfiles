# Enable Powerlevel10k instant prompt. Should stay close to the top of ~/.zshrc.
# Initialization code that may require console input (password prompts, [y/n]
# confirmations, etc.) must go above this block; everything else may go below.
if [[ -r "${XDG_CACHE_HOME:-$HOME/.cache}/p10k-instant-prompt-${(%):-%n}.zsh" ]]; then
  source "${XDG_CACHE_HOME:-$HOME/.cache}/p10k-instant-prompt-${(%):-%n}.zsh"
fi

export LC_ALL=ja_JP.UTF-8
export LANG=ja_JP.UTF-8
export SSH_AUTH_SOCK=$HOME/Library/Containers/com.maxgoedjen.Secretive.SecretAgent/Data/socket.ssh

PATH=/usr/local/bin:$PATH
PATH=$HOME/.local/bin:$PATH
PATH=/usr/local/sbin:$PATH
PATH=$PATH/usr/bin:$HOME/bin:/sbin:$PATH
PATH=$HOME/.deno/bin:$PATH
PATH="${AQUA_ROOT_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/aquaproj-aqua}/bin:$PATH"

export PATH

#履歴
HISTSIZE=100000
SAVEHIST=100000

#重複する履歴はignoreに
setopt hist_ignore_dups

#重複コマンドの保存時には古い方を削除する
setopt hist_save_no_dups

#先頭がスペースの場合は履歴追加しない
setopt hist_ignore_space

#余分な空白は詰めて記録
setopt hist_reduce_blanks

#historyコマンドは記録しない
setopt hist_no_store

#履歴をシェア
setopt share_history

#履歴検索機能のショートカット設定
autoload history-search-end
zle -N history-beginning-search-backward-end history-search-end
zle -N history-beginning-search-forward-end history-search-end
bindkey "^P" history-beginning-search-backward-end
bindkey "^N" history-beginning-search-forward-end

#bck-i-searchでAND検索
bindkey '^R' history-incremental-pattern-search-backward
bindkey '^S' history-incremental-pattern-search-forward

#^sでfwd-i-search
#stty -ixon

#Emacsモードのキーバインド
bindkey -e

#undoとredoのキーバインド
bindkey "^[u" undo
bindkey "^[r" redo

#cdなしでcdする
setopt auto_cd

#beep音を出さない
setopt nolistbeep
setopt no_beep

#aliaseでも補完してくれる
setopt complete_aliases

#ワイルドカード等をescapeする
setopt nonomatch

#移動したディレクトリを記録（cd -[TAB]）
setopt auto_pushd

#間違ったコマンド名を修正確認してくれる
setopt correct

#補完候補を詰めて表示
setopt list_packed

#補完候補一覧をカラー表示
zstyle ':completion:*' list-colors ''

#補完候補をカーソルで選択できる
zstyle ':completion:*:default' menu select=1

#パスの最後のスラッシュを自動的に削除させない
setopt noautoremoveslash

#コマンド実行時に右プロンプトを消す
setopt transient_rprompt

#補完候補の一覧表示
setopt auto_list

#auto_listの一覧でファイル種別をマーク表示
setopt list_types

#補完キーを連打するだけで順に自動で補完する
setopt auto_menu

#複数のzsh使用時に上書きせず追記する
setopt append_history

#補完候補のメニュー選択で、矢印キーの代わりにhjklで移動出来るようにする。
zmodload zsh/complist
bindkey -M menuselect 'h' vi-backward-char
bindkey -M menuselect 'j' vi-down-line-or-history
bindkey -M menuselect 'k' vi-up-line-or-history
bindkey -M menuselect 'l' vi-forward-char

#ターミナルの左右設定
#PROMPT=$'%{\e[33m%}%n$ '
#RPROMPT=$'%{\e[32m%}[%~]%{\e[m%}'

#lsした時の色設定
#export LSCOLORS=gxfxcxdxbxegedabagacad

alias ls="ls -G"
alias ll="ls -al"
alias la="ls -a"
alias rmdss="find . -name '.DS_Store' -type f -delete"

alias be='bundle exec'

alias lg='lazygit'
alias ld='lazydocker'

# zplug section

export ZPLUG_HOME=$(brew --prefix)/opt/zplug
source $ZPLUG_HOME/init.zsh

zplug "b4b4r07/enhancd", use:init.sh
zplug romkatv/powerlevel10k, as:theme, depth:1

if ! zplug check --verbose; then
    printf "インストールしますか？[y/N]: "
    if read -q; then
        echo; zplug install
    fi
fi
 
zplug load

# To customize prompt, run `p10k configure` or edit ~/.p10k.zsh.
[[ ! -f ~/.p10k.zsh ]] || source ~/.p10k.zsh
function gi() { curl -sLw n https://www.toptal.com/developers/gitignore/api/$@ ;}


function ghq-fzf() {
  # ghq rootの取得とエラーチェック
  local ghq_root=$(ghq root 2>/dev/null)
  if [[ -z "$ghq_root" ]]; then
    echo "Error: ghq is not properly configured" >&2
    zle reset-prompt
    return 1
  fi

  # ローカルのghqリポジトリリストを取得
  local local_repos=$(ghq list 2>/dev/null || true)
  
  # GitHub上のリポジトリリストを取得（エラーハンドリング付き）
  echo "🔍 Fetching GitHub repositories..." >&2
  local github_repos=$(gh api --paginate /user/repos --jq '.[].full_name' 2>/dev/null || true)
  
  # 連想配列を使った効率的な重複チェック
  typeset -A local_repo_map
  local -a all_repos_array=()
  
  # ローカルリポジトリを配列に追加し、マップに記録
  if [[ -n "$local_repos" ]]; then
    while IFS= read -r repo; do
      [[ -n "$repo" ]] || continue
      local_repo_map[$repo]=1
      all_repos_array+=("[LOCAL] $repo")
    done <<< "$local_repos"
  fi
  
  # リモートリポジトリを追加（重複チェック付き）
  if [[ -n "$github_repos" ]]; then
    while IFS= read -r repo; do
      [[ -n "$repo" ]] || continue
      if [[ -z "${local_repo_map[$repo]}" ]]; then
        all_repos_array+=("[REMOTE] $repo")
      fi
    done <<< "$github_repos"
  fi

  # 配列が空の場合の処理
  if [[ ${#all_repos_array[@]} -eq 0 ]]; then
    echo "No repositories found" >&2
    zle reset-prompt
    return 1
  fi

  # fzfで選択
  local selected=$(printf '%s\n' "${all_repos_array[@]}" | fzf --query="$LBUFFER" --preview 'echo {}' --preview-window=up:1)

  if [[ -n "$selected" ]]; then
    local repo_path=$(echo "$selected" | sed 's/^\[LOCAL\] //; s/^\[REMOTE\] //')
    
    # リポジトリ名の検証（セキュリティ対策）
    if [[ ! "$repo_path" =~ ^[a-zA-Z0-9._/-]+$ ]]; then
      echo "Error: Invalid repository path: $repo_path" >&2
      zle reset-prompt
      return 1
    fi
    
    local full_path="$ghq_root/$repo_path"
    
    if [[ "$selected" == "[LOCAL]"* ]]; then
      # ローカルに存在する場合は直接移動（安全なクォート処理）
      BUFFER="cd $(printf '%q' "$full_path")"
    else
      # リモートの場合はghq getしてから移動（安全なクォート処理）
      # ghqは github.com/owner/repo の形式でディレクトリを作成するため、実際のパスを取得
      BUFFER="ghq get $(printf '%q' "$repo_path") && cd \"\$(ghq root)/github.com/$(printf '%q' "$repo_path")\""
    fi
    zle accept-line
    zle reset-prompt
  else
    zle reset-prompt
  fi
}

zle -N ghq-fzf
bindkey "^]" ghq-fzf

alias bunx="bun x"
export PATH="/opt/homebrew/bin:/opt/homebrew/sbin:$PATH"
eval "$(mise activate zsh)"



# The next line updates PATH for the Google Cloud SDK.
if [ -f '/opt/homebrew/share/google-cloud-sdk/path.zsh.inc' ]; then . '/opt/homebrew/share/google-cloud-sdk/path.zsh.inc'; fi

# The next line enables shell command completion for gcloud.
if [ -f '/opt/homebrew/share/google-cloud-sdk/completion.zsh.inc' ]; then . '/opt/homebrew/share/google-cloud-sdk/completion.zsh.inc'; fi
export PATH="/opt/homebrew/opt/postgresql@15/bin:$PATH"

# aqua がプライベートリポジトリ(monicle/aqua-registry)にアクセスするために必要
export GITHUB_TOKEN=$(gh auth token 2>/dev/null)
