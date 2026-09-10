# worktree

`worktree` は、Git worktree の作成と Herdr タブの開始をひとつの操作にまとめるローカル用コマンドです。

指定した名前のローカルブランチと worktree を用意し、そのディレクトリをカレントディレクトリとする新しい Herdr タブを開いてフォーカスします。`git worktree` サブコマンドとは別の独立したコマンドです。

## 必要なもの

- Bash 3.2以降
- Git
- Herdr

`jq` は不要です。

## インストール

リポジトリのルートディレクトリで、スクリプトへ実行権限を付け、`PATH` に含まれるディレクトリから参照できるようにします。

```bash
chmod +x bin/worktree
mkdir -p "$HOME/.local/bin"
ln -s "$(pwd -P)/bin/worktree" "$HOME/.local/bin/worktree"
```

`$HOME/.local/bin` が `PATH` に含まれていない場合は、シェル設定へ追加します。

```bash
export PATH="$HOME/.local/bin:$PATH"
```

## 設定

worktree の保存先を環境変数で設定できます。

```bash
export PROJECT_WORKTREE_DIR="$HOME/worktrees"
```

コマンドごとに `--base` / `-b` を指定した場合は、環境変数よりもオプションが優先されます。

## 使い方

新しいブランチと worktree を作る場合:

```bash
worktree feature/login
```

同名のローカルブランチがすでに存在する場合は、そのブランチを使います。存在しない場合は、現在の `HEAD` から新しいブランチを作ります。

保存先を一時的に変更する場合:

```bash
worktree --base "$HOME/other-worktrees" feature/login
worktree -b "$HOME/other-worktrees" feature/login
```

作成されたタブには `NAME` がラベルとして設定され、対象 worktree に移動した状態でフォーカスされます。作成操作は Herdr 管理下のpaneから実行する必要があります。

### ローカルAIエージェント設定のコピー

呼び出し元worktreeに次のローカル設定ファイルがあれば、新しいworktreeへコピーします。

- `.claude/settings.local.json`
- `.codex/config.toml`

Codexでは、個人の既定設定は`~/.codex/config.toml`、プロジェクト単位の上書きは`.codex/config.toml`です。後者は信頼済みプロジェクトでのみ読み込まれます。詳細は[OpenAIのCodex設定ドキュメント](https://learn.chatgpt.com/docs/config-file/config-basic)を参照してください。

コピー元はコマンドを実行したworktreeです。通常ファイルだけを対象とし、symbolic linkはコピーしません。新しいworktree側にtrackedファイルなどがすでに存在する場合も上書きしません。

コピーされた設定がGitでignoreされていない場合は警告します。ローカル設定には権限、コマンド、マシン固有パスなどが含まれる可能性があるため、公開リポジトリへ誤ってcommitしないよう、必要に応じて`.gitignore`または`.git/info/exclude`へ追加してください。

### worktree の解放

削除したいlinked worktree内で実行します。サブディレクトリからでも構いません。

```bash
worktree --release
# または
worktree -r
```

release は現在位置のlinked worktreeだけを対象にし、メインworktreeは削除しません。ブランチも残します。また、通常の変更や未追跡ファイルが残っているworktreeはGitによって削除を拒否されます。変更を破棄して強制的に削除する場合は、`--force` / `-f`を併用します。

```bash
worktree --release --force
# または
worktree -r -f
```

`--force`を指定すると、trackedファイルの変更と未追跡ファイルはworktreeとともに失われます。`.gitignore`などで除外されたignoredファイルは、`--force`の有無にかかわらずworktreeとともに削除されます。必要なローカル設定やデータは、別の場所に原本を保持してください。detached HEADの場合、そのcommitがいずれのrefからも到達できなければ、`--force`を指定してもcommit消失を防ぐため削除を拒否します。

release 後も Herdr タブと呼び出し元のシェルは残りますが、シェルのカレントディレクトリは削除済みです。シェルプロンプトで `Control-D` を入力してタブを閉じるか、成功メッセージに表示されたメインworktreeへ移動してください。

```bash
cd /path/to/main-worktree
```

release 自体は Herdr 管理外でも使用できます。

## オプション

```text
Usage:
  worktree [OPTIONS] NAME
  worktree --release [--force]
  worktree -r [-f]

Options:
  -b, --base DIR   Base directory for new worktrees.
                   Defaults to PROJECT_WORKTREE_DIR.
  -r, --release    Remove the worktree containing the current directory.
  -f, --force      Remove it even when it has uncommitted changes.
  -h, --help       Show this help.
```

`--release` / `-r` に `NAME` は指定できません。`--base` / `-b` とreleaseの併用、および作成モードでの`--force` / `-f`はエラーになります。

## テスト

実際の Herdr セッションには触れず、偽の `herdr` コマンドと一時 Git リポジトリを使ってテストします。

```bash
./tests/worktree-test.sh
```
