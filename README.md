## Dify CLI

ローカルにワンファイルで配置して、ログイン、アプリ一覧、DSLの export/import、公開、ログ取得、ツール取得/登録/更新、親子関係（Workflowツール → 元Workflow）解析までを実行できます。`bash + curl + jq` 前提です。

### 前提
- macOS/Linux の bash
- curl, jq がインストール済み

### セットアップ
1. `.env` を作成
   ```bash
   CONSOLE_API_BASE=https://..../console/api
   EMAIL=あなたのメールアドレス
   PASSWORD='あなたのパスワード'
   ```

2. PATH にインストール（推奨）
   ```bash
   mkdir -p "$HOME/bin"
   ln -s "${PWD}/dify-cli.sh" "$HOME/bin/dify"
   echo 'export PATH="$HOME/bin:$PATH"' >> "$HOME/.zshrc"
   source "$HOME/.zshrc"
   # 以後はどこからでも `dify <subcommand>`
   ```

3. ログイン（トークンは `.dify_token` に保存）
   ```bash
   dify login
   ```

### よく使うコマンド
- 認証・メタ
  ```bash
  dify me
  dify apps [page] [limit]
  dify app <APP_ID>
  ```

- DSL 出力/投入
  ```bash
  # export（基本は include_secret=false 推奨）
  dify export <APP_ID> [include_secret=false]

  # import（新規アプリ作成; YAMLから）
  dify import ./dsl/sample.yml
  ```

- 公開
  ```bash
  dify publish <WORKFLOW_APP_ID> [marked_name] [marked_comment]
  dify publish-info <WORKFLOW_APP_ID>
  ```

- ログ取得
  ```bash
  # Workflow実行ログ（期間: created_at__after / created_at__before）
  dify logs-workflow <APP_ID> '2025-06-04T11:00:00-04:00' '2025-06-12T10:59:59-04:00' 1 10

  # チャット会話ログ（JSTの日時文字列も可; sort_by デフォルト -created_at）
  dify logs-chat <APP_ID> '2025-06-19 00:00' '2025-06-26 23:59' 1 10 -created_at
  ```

- ツール管理（workflow ツールプロバイダ）
  ```bash
  dify tool-get <WORKFLOW_APP_ID>
  dify tool-create ./payloads/tool-create.json
  dify tool-update ./payloads/tool-update.json
  ```

### 親子関係デバッグ（Workflowツール → 元Workflow）
Workflow をツール化したノード（`type=tool` かつ `provider_type="workflow"`）から、元の Workflow アプリの DSL を収集します。

- 親アプリに使われている Workflow ツールノードを列挙
  ```bash
  dify tool-refs-in-app <PARENT_APP_ID>
  # 例: dify tool-refs-in-app b1f6b331-11c5-4ce9-b0e7-5331eb13d192
  ```

- ワークスペース全体をスキャンして、Workflow ツールを含む親アプリ候補を列挙
  ```bash
  dify find-apps-with-workflow-tools
  ```

- 親アプリにぶら下がる「ツールの中身（元ワークフロー DSL）」を一括保存
  ```bash
  dify export-tools-of-app <PARENT_APP_ID> [include_secret=false]
  # 例: dify export-tools-of-app b1f6b331-11c5-4ce9-b0e7-5331eb13d192 false
  # 出力先: ./dsl/tools/<ツール名slug>.yml（日本語等で slug 化できなければ tool_id フォールバック）
  ```

仕組み:
- 親アプリのドラフトワークフロー `GET /apps/{id}/workflows/draft` から `provider_type="workflow"` ノードを抽出。
- 全 `mode=workflow` アプリに対し `GET /workspaces/current/tool-provider/workflow/get?workflow_app_id=...` を照会し、`workflow_tool_id → workflow_app_id` の辞書を構築。
- 辞書を使って `/apps/{workflow_app_id}/export?include_secret=false` を叩き、DSL を保存。

### include_secret について
- 既定は `include_secret=false`（レポジトリ持ち込み事故を防止）。
- `true` を渡すと API が許す範囲で含めますが、環境・権限によりマスク/返却無しのことがあります。
  ```bash
  dify export <APP_ID> true
  dify export-tools-of-app <PARENT_APP_ID> true
  ```

### ベストプラクティス / トラブルシューティング
- ヘッダは慣例どおり `Authorization: Bearer <token>` を使用。
- エラー本文を見やすくするには `curl -fS --fail-with-body` を活用。
- URL エンコードは CLI 内で `jq -rn '$v|@uri'` を利用（手動の場合も `%3A` 等を忘れない）。
- export レスポンスは環境により `{data:"<yaml>"}` または `{dsl:"<yaml>"}`。CLI は両対応。
- タイムスタンプはオフセット付き（例: `2025-06-04T11:00:00-04:00`）が安全。
- トークンが失効したら `dify login` を再実行（必要なら自動更新に拡張可）。
- jq の古いバージョンでも動くよう、インデックスのマージは `--argfile` 非依存で実装済み。

### 例: 一連の操作
```bash
# 1) ログイン
dify login

# 2) アプリ一覧
dify apps

# 3) DSLを出力（保存先: ./dsl/apps/<slug>.yml）
dify export <APP_ID> false

# 4) DSLをインポート（新規作成）
dify import ./dsl/sample.yml

# 5) 公開
dify publish <WORKFLOW_APP_ID> "nightly" "auto publish"
dify publish-info <WORKFLOW_APP_ID>

# 6) Workflowログ（期間絞り）
dify logs-workflow <APP_ID> '2025-06-04T11:00:00-04:00' '2025-06-12T10:59:59-04:00' 1 10

# 7) 親子関係（ツール→元Workflow）を解決してツールの中身を保存
dify export-tools-of-app <PARENT_APP_ID> false
```

### 注意事項
- 機密情報（APIキー等）の取り扱いには十分ご注意ください。`include_secret=true` の使用は推奨しません。
- 出力ファイルは `./dsl/apps/*.yml` に統一。必要に応じて `.gitignore` へ追加してください。
- 依存関係は別途 index（例: `./dsl/deps.json`）で管理（生成コマンドで出力予定）。

---
質問や追加機能の要望（Python 版 CLI、GitHub Actions バッチ等）があれば、Issue/PR 歓迎です。


