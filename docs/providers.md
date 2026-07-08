# providers

## 公式使用量同期 (CLI sign-in)

初回バナーまたは Settings の `Official usage` でプロバイダごとに opt-in できます。CLI が保存しているサインイントークンを読み取り専用で再利用し、各ベンダー公式の使用量エンドポイントから CLI 表示と同じ数値を取得します。

### Claude

- token: macOS Keychain の `Claude Code-credentials`(なければ `~/.claude/.credentials.json`)
- endpoint: `GET https://api.anthropic.com/api/oauth/usage`
- headers: `Authorization: Bearer`, `anthropic-beta: oauth-2025-04-20`, `User-Agent: claude-code/<version>`(この UA がないと厳しい 429 バケットに入る)
- response: `five_hour.utilization` / `five_hour.resets_at`, `seven_day.utilization` / `seven_day.resets_at`
- 表示: 5 hour left と 7 day left をそれぞれバー表示。weekly が先に尽きる場合は status も weekly に従う
- Claude Code の `/usage` と同じ数値

### Codex

- token: `~/.codex/auth.json` の `tokens.access_token` と `tokens.account_id`
- endpoint: `GET https://chatgpt.com/backend-api/wham/usage`
- headers: `Authorization: Bearer`, `ChatGPT-Account-Id`
- response: `rate_limits.primary` / `secondary`(`used_percent`, `resets_in_seconds` など。フィールド名のゆれはパーサで正規化)
- 表示: primary を 5 hour left、secondary を 7 day left としてバー表示。weekly が先に尽きる場合は status も weekly に従う
- Codex の `/status` と同じ数値

### 安全性

- トークンは更新 (refresh) しない。期限切れなら CLI を一度起動するよう促す
- トークンは保存・ログ出力しない。送信先は各ベンダーの公式エンドポイントのみ
- 取得に失敗したらローカルログ推定にフォールバックし、理由をメッセージに表示する
- どちらも非公開エンドポイントのため、予告なく変わる可能性がある

## Codex ローカルログ

現在の同期方法:

- `~/.codex/logs_2.sqlite`
- 読む内容: `codex.rate_limits` websocket event の `rate_limits.primary`
- 表示: General usage limits の `5 hour left`、reset、7 day left

補助的に読む内容:

- `~/.codex/state_5.sqlite`
- `threads.tokens_used`, `threads.updated_at`
- 表示補助: 今日のスレッド数、直近5時間/今週 token

ローカルログ連携で読まないもの:

- 認証トークン
- 会話本文

注意:

- `rate_limits.primary.window_minutes == 300` を 5 hour usage limit として扱います。
- Codex内部値の `used_percent` は使用済み%なので、UIでは `100 - used_percent` を left% として表示します。
- `rate_limits.secondary` は 7 day left としてサブ表示します。
- ライブログがない場合は `~/.codex/sessions/**/*.jsonl` の `token_count` を fallback として読みます。
- rate limit がまだ出ていない場合だけ、ローカルDBの token 集計を参考値として表示します。

## Claude ローカルログ

現在の同期方法:

- `~/.claude/projects/**/*.jsonl`
- 読む内容: `message.usage`, `message.model`, `timestamp`, `sessionId`, `requestId`, `message.id`
- 表示: General usage limits の `5 hour left`、reset、今週の token、概算コスト

ローカルログ連携で読まないもの:

- Claude の認証情報
- 会話本文の表示や外部送信

5 hour ブロックの算出方法:

- JSONL の `timestamp` を時系列に並べて、5 時間以上のブランクが空いた次のメッセージを新しいブロックの開始点として扱います。
- ブロックの開始時刻は時単位に切り捨て、そこから 5 時間で `reset` を表します。
- 同一 API 応答が複数行に記録されるため、`requestId` と `message.id` が両方ある行はこのペアで重複排除します。
- ブロック内の weighted token は `input + output + cache_creation_input_tokens + cache_read_input_tokens * 0.1` で計算します。`cache_creation_input_tokens` は `ephemeral_5m + ephemeral_1h` と同じ合計値なので二重に加算しません。
- プランは `~/.claude.json` の `oauthAccount.organizationType` と `oauthAccount.userRateLimitTier` / `oauthAccount.organizationRateLimitTier` から検出します。実際のアカウントでは Max 5x と 20x のどちらも `organizationType` は `claude_max` で、5x/20x の区別は rate-limit tier 文字列 (例: `default_claude_max_20x`) にだけ現れます:
  - Pro (`claude_pro`) → 2,000,000 weighted tok cap
  - Max + tier に `5x` → 10,000,000 weighted tok cap
  - Max + tier に `20x` → 40,000,000 weighted tok cap
  - Max で tier 不明 → 10,000,000 weighted tok cap (5x 相当を仮定)
  - Team / Enterprise → 2,000,000 tok から開始し較正に任せます
  - 未検出時は 2,000,000 tok (Pro 相当) を仮置きします
- 自動検出が外れる場合は、Settings の「Claude plan」で Pro / Max 5x / Max 20x を手動指定できます (local 推定にのみ影響し、公式同期の数値には影響しません)。
- 各プランの cap は重複排除後の初期推定値です。公式使用量同期が成功したときは、同時点のローカル weighted 使用量と公式 used% から `~/Library/Application Support/usage_kun/claude_calibration.json` に cap を自動較正します。
- `left% = 100 - used / cap * 100` を percent として表示します。Codex と同じく 35% 以下で warning、15% 以下で critical 扱いです。
- weekly cap はローカル推定ではまだ percent 化せず、今週 token の detail として表示します。公式同期が有効な場合は `seven_day` の left% を 7 day バーに表示します。

注意:

- 概算コストは公開価格をもとにした参考値です。
- 実請求やサブスクリプション残量とは一致しない場合があります。
- 5 時間ブロックの cap は公開された公式値ではなく、ローカルログから推定した参考値です。実際の Claude Code プラン上限と完全には一致しない場合があります。
- 手動確認には `swift run UsageKunCoreCheck --claude-estimate` を使い、その直後の Claude Code `/usage` と比べます。大きくずれる場合は公式使用量同期を一度有効にすると自動較正されます。
