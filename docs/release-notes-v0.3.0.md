# usage_kun v0.3.0

This release adds per-provider visibility so you can show only Claude, only Codex, or both.

## Added

- **Settings > Providers**: checkboxes for Claude and Codex. Only checked providers appear in the menu bar, the popover, and the pinned desktop meter. Unchecked providers are not fetched at all — no local log reads and no official-sync requests are made for them, and no notifications fire for them.
- The desktop meter's next-action label now reflects the overall status of whichever providers are visible, instead of always following Codex.

## Notes

- Both providers are checked by default, so existing setups keep their current behavior after updating.
- If you uncheck both providers, the meters show an empty state until one is re-enabled in Settings.

---

日本語:

- **Settings > Providers** に Claude / Codex のチェック欄を追加しました。チェックしたプロバイダだけがメニューバー、popover、固定デスクトップメーターに表示されます。チェックを外したプロバイダは表示されないだけでなく、ローカルログの読み取りも公式同期のリクエストも行わず、通知も出ません。
- デスクトップメーターの next-action ラベルが、Codex 固定ではなく表示中プロバイダ全体の状態を反映するようになりました。
- 既定では両方チェック済みなので、アップデート後も今までの表示のままです。
