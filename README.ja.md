# usage-kun

<p align="right">
  <a href="README.md">English</a> |
  <strong>日本語</strong>
</p>

usage-kun は、Claude と Codex の使用量を作業中にすぐ確認するための、privacy-first な macOS メニューバーアプリです。

これは個人用の小さなユーティリティとして作っています。大きな分析ダッシュボードではなく、作業中に一瞬見るための使用量メーターです。初期状態ではローカル CLI ログを読み、必要な場合だけ opt-in で CLI サインイン token を読み取り専用で再利用して公式使用量を取得します。ユーザーが入力する API key は macOS Keychain にのみ保存します。

このプロジェクトは OpenAI、Anthropic、その他 provider の公式アプリではありません。各社による承認・提携・提供を受けたものでもありません。

## スクリーンショット

usage-kun は、作業画面の邪魔をせずに常に見えることを意識しています。固定デスクトップメーターでは主要な残量だけを左上に表示し、メニューバーの popover では provider ごとの詳細を確認できます。

<p align="center">
  <img src="assets/screenshots/pinned-desktop-meter.png" alt="macOS の左上に固定表示された Codex と Claude Code の使用量メーター。" width="680">
</p>

<p align="center">
  <em>デスクトップ左上に固定される、ひと目確認用の使用量メーター。</em>
</p>

<p align="center">
  <img src="assets/screenshots/menu-bar-popover.png" alt="Codex と Claude Code の使用量カード、reset 時刻、sync source、settings tab を表示するメニューバー popover。" width="520">
</p>

<p align="center">
  <em>メニューバーから開く詳細 popover。使用量カードと設定にすぐアクセスできます。</em>
</p>

## 機能

- SwiftPM、AppKit、SwiftUI で作った native macOS メニューバーアプリ
- メニューバーから開く compact な popover
- ひと目確認用の固定デスクトップウィジェット
- Claude / Codex のローカルログに基づく使用量推定
- Claude Code / Codex CLI サインインを利用した opt-in の公式使用量 sync
- OpenAI / Anthropic Admin API cost 表示のための拡張口
- 認証情報は設定ファイルではなく macOS Keychain に保存
- telemetry や analytics SDK は含めない

## 必要環境

- macOS 14 以降
- Swift 6 以降
- Xcode Command Line Tools

## すぐ試す

ソースから実行:

```sh
swift run
```

`.app` bundle を作成:

```sh
./Scripts/package_app.sh
open UsageKun.app
```

軽量な core check を実行:

```sh
swift build
swift run UsageKunCoreCheck
```

この repo には `UsageKunCoreCheck` が含まれています。Command Line Tools だけの環境では `XCTest` や Swift Testing がうまく使えない場合があるため、実行可能 target として最低限の core check を用意しています。

## データソース

usage-kun は段階的なデータ取得モデルを使います。

1. Local logs: Claude Code と Codex の既知のローカル使用量ログを読んで推定します。
2. Official usage sync: opt-in の場合のみ、ローカル CLI サインイン token を読み取り専用で再利用し、provider の使用量 endpoint から値を取得します。
3. Admin API costs: opt-in の場合のみ、macOS Keychain に保存された Admin API key を使って cost を取得します。
4. Browser/OAuth phase: UI と保存枠はありますが、自動 browser cookie 読み取りは実装していません。

詳細は [docs/providers.md](docs/providers.md) を参照してください。

## プライバシー方針

- telemetry はありません。
- cloud sync はありません。
- analytics SDK はありません。
- 会話本文の表示や外部送信はしません。
- browser cookie の自動読み取りはしません。
- CLI sign-in token は refresh せず、app 内に保存せず、log に出しません。
- API key と manual cookie header は macOS Keychain に保存します。

詳しくは [PRIVACY.md](PRIVACY.md) を参照してください。

## リポジトリ構成

```text
Sources/UsageKun/
  main.swift
  Services/
  Views/

Sources/UsageKunCore/
  Config/
  Providers/
  Security/
  UsageSnapshot.swift
  UsageService.swift

Tests/UsageKunCoreCheck/
  main.swift

assets/screenshots/
  pinned-desktop-meter.png
  menu-bar-popover.png

Packaging/
  Info.plist

Scripts/
  package_app.sh
```

## なぜ別の使用量メーターを作るのか

AI 使用量 monitor や menu bar utility はすでに複数あります。usage-kun は、その中で「Claude と Codex の残量を dashboard を開かずに見たい」という 1 つの workflow に絞った、小さく監査しやすい実装です。

重視している点:

- local-first な動作
- provider ごとの境界を混ぜない設計
- 小さな native macOS UI
- 読みやすい Swift code
- privacy-first な credential handling

## 制限

- 公式 usage endpoint は予告なく変わる可能性があります。
- Claude local-log quota 推定は best-effort で、subscription limit と完全一致しない場合があります。
- OpenAI Admin API cost は Codex ChatGPT plan limit とは別です。
- Anthropic Admin API cost data は organization account 向けで、personal account では使えない場合があります。
- 自分で署名しない限り、この app は unsigned です。

## 開発

```sh
swift build
swift run UsageKunCoreCheck
```

release 風の app bundle を作成:

```sh
./Scripts/package_app.sh
```

## ライセンス

MIT。詳細は [LICENSE](LICENSE) を参照してください。
