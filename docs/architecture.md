# architecture

## 現在の判断

usage_kun は SwiftPM + AppKit + SwiftUI の macOS メニューバーアプリです。

目的は、Claude Code と Codex の 5 hour / 1 week usage を、作業中にクリックなしでも把握できる常駐メーターとして見せることです。

## 現在の構成

```text
Sources/UsageKun/
  main.swift
  Services/
    LaunchAtLoginService.swift
    UsageNotifier.swift
  Views/
    AppTheme.swift
    DesktopWidgetView.swift
    ProviderLogo.swift
    SettingsView.swift
    StatusIconRenderer.swift
    StatusPill.swift
    UsageCardView.swift
    UsageDashboardView.swift
Sources/UsageKunCore/
  Config/
    AppConfig.swift
    ClaudeCalibrationStore.swift
  OnboardingDetector.swift
  Providers/
    CLIOAuthUsageService.swift
    LocalLogUsageService.swift
  UsageNotificationPlanner.swift
  UsageSnapshot.swift
  UsageService.swift
Tests/UsageKunCoreCheck/
  main.swift
```

## 境界

- `UsageKunCore`: 使用量モデル、取得 service、表示用 store
- `UsageService`: 使用量取得の抽象インターフェイス
- `CompositeUsageService`: 設定に応じてローカルログと公式 CLI 同期を統合
- `CLIOAuthUsageService`: Claude Code / Codex の既存 CLI サインインを読み取り専用で使い、公式使用量を取得
- `LocalLogUsageService`: `~/.codex` / `~/.claude` の既知ログから集計
- `ClaudeCalibrationStore`: Claude 公式同期から学習した 5 hour cap 推定値を Application Support に保存
- `OnboardingDetector`: Keychain に触らず CLI サインインのファイル存在だけを検出
- `UsageNotificationPlanner`: 前回/今回の snapshot 差分から通知イベントを返す pure 関数
- `UsageNotifier`: packaged app のときだけ macOS 通知センターにイベントを渡す薄いシェル
- `UsageStore`: UI が購読する表示状態
- `UsageSnapshot`: Claude / Codex 共通の正規化済み表示モデル。`UsageWindow` で weekly window を構造化する
- `DesktopWidgetView`: ホーム / デスクトップ左上に置く固定ミニパネル。メニューバーの詳細パネルとは別に、最小限の状態だけを表示

## 同期ソース

### 公式使用量同期

`CLIOAuthUsageService` が Claude Code / Codex の CLI サインインを読み取り専用で再利用します。トークンは保存・refresh・ログ出力せず、送信先は各ベンダーの公式使用量エンドポイントだけです。

Claude の `five_hour` / `seven_day`、Codex の `rate_limits.primary` / `secondary` を `UsageSnapshot.percent` と `UsageSnapshot.weekly` に正規化します。status は 5 hour と weekly のうち残量が少ない方で決めます。

### ローカルログ

Codex は `~/.codex/logs_2.sqlite` の `codex.rate_limits` websocket event を優先して読みます。`rate_limits.primary.window_minutes == 300` を 5 hour usage limit として扱い、`used_percent` は使用済み%なので UI では `100 - used_percent` を left% として表示します。`rate_limits.secondary` は 7 day left として `UsageWindow` に入れます。

ライブログがない場合は `~/.codex/sessions/**/*.jsonl` の `token_count` イベントを fallback として使います。`~/.codex/state_5.sqlite` の `threads` テーブルは、今日・今週の `tokens_used` とスレッド数の補助情報として使います。

Claude は `~/.claude/projects/**/*.jsonl` の `message.usage` を読み、`requestId` と `message.id` のペアで重複排除してから input/output/cache token を集計します。Claude の概算コストはローカルログ内の model 名と公開価格表に基づく参考値です。公式同期が成功したときは、同時点のローカル weighted 使用量と公式 used% から 5 hour cap 推定値を保存し、以後のローカル推定に使います。

## 表示と通知

UI は正規化済み `UsageSnapshot` だけを表示します。Provider ごとのファイル形式、API レスポンス、重複排除、cap 推定は Core 側に閉じます。

メニューバー表示は `UsageStore.menuBarEntries(snapshots:)` で作る pure な配列を使います。通知判定は `UsageNotificationPlanner.plan(previous:current:alreadyNotified:)` に閉じ、AppKit / UserNotifications への依存は `UsageNotifier` だけに置きます。

## 検証

この環境では Xcode 本体がなく、Command Line Tools 側に `XCTest` がありません。また Swift 6 の `Testing.framework` も依存モジュール不足で `swift test` からは使えません。

そのため、現時点では `swift run UsageKunCoreCheck` を軽量なコアロジック検証として使います。

## 公開前チェック

公開前は `./Scripts/preflight_publication.sh` を実行します。このスクリプトはローカル専用資料や build artifacts の混入チェック、`swift build`、`swift run UsageKunCoreCheck`、`.app` 作成、bundle version の整合性確認を行います。
