# Release Notes: v0.1.1

This release updates usage-kun from `v0.1.0`.

## English

### What's changed since v0.1.0

`v0.1.0` was the initial public release of usage-kun: a macOS menu bar usage meter for Claude and Codex, with an optional pinned desktop widget, local-first usage display, and privacy-first credential handling through macOS Keychain.

This update focuses on making the Claude Code 5-hour estimate much more reliable while preserving the existing Codex behavior.

### Improvements

- Improved Claude Code local-log accuracy by deduplicating repeated JSONL usage rows with the `(requestId, message.id)` pair.
- Recalibrated the initial Claude 5-hour cap estimates for deduplicated weighted tokens:
  - Pro: 2.0M weighted tokens
  - Max 5x: 10M weighted tokens
  - Max 20x: 40M weighted tokens
- Added automatic Claude cap calibration when opt-in official Claude usage sync succeeds. Calibration is saved locally at:

```text
~/Library/Application Support/usage_kun/claude_calibration.json
```

- Added a local debug command for checking Claude's estimated 5-hour remaining percentage:

```sh
swift run UsageKunCoreCheck --claude-estimate
```

- Fixed Claude cost estimation:
  - corrected Opus/Fable/Mythos pricing detection
  - avoided double-counting cache write tokens when 5-minute / 1-hour cache write breakdowns are present

### Validation

- Added core checks for Claude JSONL deduplication.
- Added core checks for Claude cap calibration.
- Added core checks for Claude pricing behavior.
- Verified:

```sh
swift build
swift run UsageKunCoreCheck
swift run UsageKunCoreCheck --claude-estimate
./Scripts/package_app.sh
```

### Notes

- Codex 5-hour logic was intentionally left unchanged.
- No new network API call was added. Claude calibration reuses results from the existing opt-in official sync path.
- The app remains unsigned unless the user signs it manually.

## 日本語

### v0.1.0 からの変更点

`v0.1.0` は usage-kun の初回公開版で、Claude / Codex の macOS メニューバー使用量メーター、固定デスクトップウィジェット、local-first な使用量表示、macOS Keychain による privacy-first な認証情報管理が中心でした。

今回の更新では、既存の Codex 表示ロジックは維持したまま、Claude Code の 5-hour 使用量推定の精度を重点的に改善しました。

### 改善点

- Claude Code のローカル JSONL に同じ API 応答が複数行として記録される問題に対応し、`requestId` と `message.id` のペアで重複排除するようにしました。
- 重複排除後の weighted token に合わせて、Claude の 5-hour cap 初期値を再較正しました:
  - Pro: 2.0M weighted tokens
  - Max 5x: 10M weighted tokens
  - Max 20x: 40M weighted tokens
- opt-in の Claude 公式使用量同期が成功したときに、公式 used% とローカル weighted 使用量から cap を自動較正する仕組みを追加しました。較正値は次に保存されます:

```text
~/Library/Application Support/usage_kun/claude_calibration.json
```

- Claude のローカル推定値を確認するための debug command を追加しました:

```sh
swift run UsageKunCoreCheck --claude-estimate
```

- Claude の概算コスト計算を修正しました:
  - Opus / Fable / Mythos の価格判定を修正
  - 5分 / 1時間 cache write の内訳がある場合に cache write token を二重計上しないよう修正

### 検証

- Claude JSONL 重複排除の core check を追加しました。
- Claude cap 自動較正の core check を追加しました。
- Claude pricing の core check を追加しました。
- 次を実行して確認済みです:

```sh
swift build
swift run UsageKunCoreCheck
swift run UsageKunCoreCheck --claude-estimate
./Scripts/package_app.sh
```

### 補足

- Codex の 5-hour 表示ロジックは意図的に変更していません。
- 新しい network API 呼び出しは追加していません。Claude の較正は、既存の opt-in 公式同期の結果を再利用します。
- アプリは引き続き、ユーザーが自分で署名しない限り unsigned です。
