# Git worktree / Herdr タブ管理スクリプト 実装計画

## 目的

指定された名前で Git worktree を作成し、その worktree をカレントディレクトリとする Herdr タブを新規作成してフォーカスするシェルスクリプトを実装する。

また、対象 worktree 内から `--release` / `-r` を実行することで、その worktree を安全に削除する。release 後の Herdr タブは自動では閉じず、利用者が `Control-D` で閉じる。

開発物はすべてリポジトリのルートディレクトリ以下に配置する。

## 成果物

初期実装では以下を作成する。

- `bin/worktree`: 本体となる Bash スクリプト
- `tests/worktree-test.sh`: 一時 Git リポジトリと偽 Herdr CLI を使う自動テスト
- `README.md`: インストール方法、環境変数、使用例、制約を記載

外部のテストフレームワークには依存せず、macOS 標準の Bash 3.2 でも動作する範囲で実装する。

## コマンドライン仕様

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
  -h, --help       Show help.
```

対応する呼び出し例:

```bash
worktree feature/login
worktree -b "$HOME/worktrees" feature/login
worktree --base "$HOME/worktrees" feature/login
worktree --base="$HOME/worktrees" feature/login
worktree -r
worktree --release
worktree -r -f
worktree --release --force
```

`worktree` は独立したローカルコマンドであり、`git worktree` サブコマンドとは別物である。この違いと、`bin/worktree` を `PATH` に追加する方法を README に明記する。

引数解析は `while` と `case` で実装する。以下は対応しない。

- `-bDIR` のような短いオプションと値の結合
- `-rbDIR` のような短いオプションのクラスタリング
- `--release` / `-r` における `NAME` 指定
- 作成モードにおける `--force` / `-f`

次の場合は使用法エラーとして終了コード 2 を返す。

- 通常モードなのに `NAME` がない
- 位置引数が複数ある
- release モードで位置引数が指定された
- release モードと `--base` / `-b` が併用された
- 作成モードで `--force` / `-f` が指定された
- `--base` / `-b` の値が空、または欠落している
- 未知のオプションが指定された

## ベースディレクトリの決定

作成時のベースディレクトリは次の優先順位で決定する。

1. `--base DIR` / `-b DIR`
2. 環境変数 `PROJECT_WORKTREE_DIR`
3. どちらもなければエラー終了

ベースディレクトリは絶対パスへ正規化する。存在しない場合は `mkdir -p` で作成するが、対象 worktree 自体がすでに存在する場合は上書きしない。

release は現在位置から対象を決定するため、ベースディレクトリを使用しない。

## `NAME` とブランチの扱い

`NAME` は次の二つを兼ねる。

- ベースディレクトリからの worktree 相対パス
- checkout するローカルブランチ名

例:

```text
NAME: feature/login
BASE: /path/to/worktrees
TARGET: /path/to/worktrees/feature/login
BRANCH: feature/login
```

作成前に以下を検証する。

- `git check-ref-format --branch "$name"` が成功する
- 絶対パスではない
- パス正規化後の対象がベースディレクトリ配下にある
- 対象パスがまだ存在しない

同名のローカルブランチが存在する場合はそれを checkout する。

```bash
git worktree add "$target" "$name"
```

存在しない場合は、呼び出し元リポジトリの現在の `HEAD` から新規ブランチを作成する。

```bash
git branch -- "$name" HEAD
git worktree add "$target" "$name"
```

ブランチ作成とworktree追加を分けることで、`git worktree add` が副作用を残して失敗した場合も、今回作成したブランチを識別してロールバックできるようにする。

ブランチがすでに別の worktree で checkout されている場合は Git の通常のエラーとして失敗させ、`--force` は使用しない。

## 作成フロー

作成処理は、不要な worktree を残さないように以下の順序で実行する。

1. `git` と `herdr` が利用可能か確認する。
2. `HERDR_ENV=1` であることを確認する。
3. `HERDR_WORKSPACE_ID` が設定されていることを確認する。
4. Git リポジトリ内であることを確認する。
5. 有効な `HEAD` があることを確認する。
6. オプションまたは環境変数からベースディレクトリを決定する。
7. `NAME` と対象パスを検証する。
8. ブランチの既存・新規を記録し、新規ならブランチを明示的に作成してから `git worktree add` を実行する。
9. 呼び出し元worktreeにある対応済みのローカルAIエージェント設定をコピーする。
10. 現在の Herdr workspace に、対象パスを cwd とするタブを作成してフォーカスする。
11. 作成された worktree パスとブランチ名を表示する。

Herdr タブの作成には、暗黙の UI フォーカスではなく呼び出し元の workspace ID を明示する。

```bash
herdr tab create \
  --workspace "$HERDR_WORKSPACE_ID" \
  --cwd "$target" \
  --label "$name" \
  --focus
```

タブ ID は後続処理で使わないため、Herdr の返却 JSON は解析しない。タブ作成コマンドの終了ステータスだけを確認し、標準出力の JSON は抑制する。このため `jq` には依存しない。

## ローカルAIエージェント設定のコピー

`git worktree add`の後、Herdrタブを開く前に、呼び出し元worktreeから次のファイルをコピーする。

- `.claude/settings.local.json`
- `.codex/config.toml`

通常ファイルだけを対象とし、symbolic linkはコピーしない。コピー先にtrackedファイルなどがすでに存在する場合は上書きしない。コピー後のファイルがGitでignoreされていなければ、将来のcommitへの混入を防ぐため警告する。

コピー途中またはHerdrタブ作成時に失敗した場合、コピーしたファイルを削除してからworktreeと新規ブランチをロールバックする。

## 作成失敗時のロールバック

worktree 作成後の設定コピーまたは Herdr タブの作成が失敗した場合は、作成途中の状態を残さない。

状態フラグと EXIT trap を使い、逆順に次を試みる。

1. 今回コピーしたローカル設定ファイルを削除する。
2. 作成した worktree を `git worktree remove` で削除する。
3. 今回の実行で新規作成し、作成時点から先端が更新されていないブランチだけを削除する。

既存ブランチはロールバック時にも削除しない。`git worktree add` 自体が非ゼロで終了した場合も、作成済みのworktreeやブランチが残っていればロールバックする。ロールバック自体に失敗した場合は、残った worktree とブランチを stderr に明示する。

## release 対象の決定と安全確認

release モードでは、現在のディレクトリが属する worktree だけを対象にする。

```bash
git rev-parse --show-toplevel
```

対象を削除する前に以下を確認する。

- 現在位置が Git worktree 内である
- 対象のトップレベルパスが `git worktree list --porcelain` に登録されている
- 対象がメイン worktree ではない
- detached HEADの場合、そのcommitがいずれかのrefから到達可能である

メイン worktree の判定には `.git` がファイルかディレクトリかといった近似判定を使わず、`git worktree list --porcelain` の最初の worktree パスと対象パスを正規化して比較する。

対象がメイン worktree、または Git に登録されていないディレクトリの場合は削除しない。

## release フロー

1. 現在の worktree ルートを取得する。
2. `git worktree list --porcelain` からメイン worktree と登録済み worktree を取得する。
3. 対象が削除可能な linked worktree であることを検証する。
4. 未参照のdetached HEAD commitがないことを検証する。
5. スクリプト自身の cwd をメイン worktree へ移す。
6. メイン worktree 側から `git worktree remove "$target"` を実行する。`--force` / `-f`指定時は`git worktree remove --force "$target"`を実行する。
7. 削除した worktree、保持したブランチ、メイン worktree のパスを表示する。
8. 呼び出し元シェルの cwd が削除済みであることと、`Control-D` または `cd` で抜ける方法を表示する。

通常は`git worktree remove`に`--force`を付けない。未コミット変更や通常の未追跡ファイルによってGitが削除を拒否した場合は、そのエラーを利用者へ返す。利用者が`--force` / `-f`を明示した場合だけGitへ`--force`を渡し、未コミット変更を含むworktreeを削除する。Gitが削除を許可するignoredファイルはworktreeとともに削除されるため、必要なデータは別の場所に原本を保持する運用とする。

強制削除でも、メインworktreeの保護と未参照detached HEADの保護は解除しない。`--force`が変更するのは、Gitによるdirty worktreeの削除可否だけとする。

release ではブランチを削除しない。worktree の削除とブランチの削除は別の操作として扱う。

## release 後のターミナルの扱い

release は Herdr タブやシェルを自動終了しない。また、通常の実行ファイルとして起動されたスクリプトは子プロセスなので、呼び出し元の対話シェルの cwd を変更できない。

Unix では、シェルが worktree を cwd として参照している状態でも `git worktree remove` によるディレクトリ削除は成功する。削除後もターミナルとシェルは動作し続けるが、呼び出し元シェルの cwd はパスとして存在しない状態になる。その状態では `git status` や外部の `pwd` などが `No such file or directory` で失敗する可能性がある。

成功時に次の復帰方法を案内する。

- タブを閉じる場合は、シェルプロンプトで `Control-D` を入力する。
- タブを再利用する場合は、表示されたメイン worktree へ `cd` する。

タブ終了をスクリプトの責務から外すことで、Herdr タブ ID の管理、pane の照合、別 pane を含むタブの誤終了を避ける。

## 終了コードと出力

終了コードは次を基本とする。

- `0`: 成功
- `1`: Git、Herdr、ファイルシステムなどの実行時エラー
- `2`: オプションまたは引数の使用法エラー

通常の結果は stdout、警告とエラーは stderr に出力する。

作成成功時の例:

```text
Created worktree: /path/to/worktrees/feature/login
Branch: feature/login
Opened Herdr tab for: /path/to/worktrees/feature/login
```

release 成功時の例:

```text
Removed worktree: /path/to/worktrees/feature/login
Branch retained: feature/login
The current shell is now inside a removed directory.
Press Control-D to close this tab, or run:
  cd /path/to/project
```

## テスト計画

テストでは一時ディレクトリに Git リポジトリを作成し、`PATH` の先頭へログ記録型の偽 `herdr` コマンドを配置する。実際の Herdr セッションや利用者の worktree は変更しない。

### 引数と設定

- `-b DIR`、`--base DIR`、`--base=DIR` を受理する
- `--base` が `PROJECT_WORKTREE_DIR` より優先される
- オプションがなければ `PROJECT_WORKTREE_DIR` を使用する
- ベース未指定で失敗する
- `-r` と `--release` が同じ動作をする
- `-f` と `--force` がdirty worktreeを強制削除する
- release で `NAME` を指定すると失敗する
- release と `--base` / `-b` の併用が失敗する
- 作成モードと`--force` / `-f`の併用が失敗する
- 不明なオプション、余分な位置引数、欠落した値が失敗する

### 作成

- 新規ブランチと worktree を作成する
- 既存ローカルブランチを使用できる
- 対象パスが存在する場合は上書きしない
- 無効なブランチ名とベース外へ脱出する名前を拒否する
- 別 worktree で使用中のブランチに対して失敗する
- Herdr 管理外では Git worktree を作る前に失敗する
- `herdr tab create` に正しい workspace、cwd、label、focus が渡る
- Herdr 失敗時に worktree と今回作成したブランチをロールバックする
- 既存ブランチはロールバック時も残る
- `git worktree add` が副作用を残して失敗してもworktreeと新規ブランチをロールバックする
- 呼び出し元のClaude・Codexローカル設定を新しいworktreeへコピーする
- コピー先に既存の設定がある場合は上書きしない
- ローカル設定コピー後の失敗でもworktreeをロールバックする

### release

- worktree 直下とそのサブディレクトリの両方から対象を特定できる
- メイン worktree の削除を拒否する
- `--force` / `-f`でもメインworktreeの削除を拒否する
- Git worktree ではないディレクトリからの実行を拒否する
- dirty worktree の削除に失敗する
- `--force` / `-f`でdirty worktreeを削除できる
- ignoredファイルを含むworktreeを削除できる
- 未参照commitを指すdetached worktreeの削除を拒否する
- `--force` / `-f`でも未参照commitを指すdetached worktreeの削除を拒否する
- refから到達可能なdetached worktreeは削除できる
- clean worktree を削除してブランチを残す
- release は Herdr 管理外でも同じ Git 操作として成功する
- 成功時に `Control-D` とメイン worktree への `cd` を案内する

## 実装順序

1. CLI パーサー、usage、エラー出力を実装する。
2. パス正規化、Git リポジトリ情報取得、worktree 判定の小さな関数を実装する。
3. worktree 作成とブランチ分岐を実装する。
4. ローカルAIエージェント設定のコピーを実装する。
5. Herdr タブ作成と終了ステータスの確認を実装する。
6. 作成失敗時のロールバックを実装する。
7. 現在位置限定の release と安全確認を実装する。
8. release 後の cwd 消失に関する案内を実装する。
9. 偽 Herdr CLI を使うテストを追加する。
10. README と使用例を追加する。
11. ShellCheck が利用可能なら静的検査を行い、全テストを実行する。

## 完了条件

- 作成と release の正常系が仕様どおり動作する
- 誤ったworktreeとメインworktreeを削除せず、dirty worktreeは明示的な`--force` / `-f`なしでは削除しない
- Herdr 操作失敗時に不要な作成物を可能な限りロールバックする
- release 後の呼び出し元シェルの状態と復帰方法が明確に案内される
- Bash 3.2 互換のテストがすべて成功する
- README の手順だけで環境変数設定、作成、release を実行できる
