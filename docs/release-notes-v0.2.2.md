# usage_kun v0.2.2

This release fixes plan detection so the local Claude estimate is right for Max plans, adds a manual plan setting, and makes the Codex live rate-limit reader tolerant of plan differences.

## Fixed

- **Max 20x plans were treated as Max 5x in the local Claude estimate.** Real accounts report `organizationType` as plain `claude_max` for both Max tiers; the 5x/20x distinction only appears in the rate-limit tier strings (e.g. `default_claude_max_20x`), which usage_kun did not read. Every Max user therefore got the Max 5x cap, and Max 20x users saw their 5-hour usage overstated by roughly 4x. Plan detection now also reads `userRateLimitTier` and `organizationRateLimitTier` from `~/.claude.json`.
- The Codex live rate-limit reader required the primary window to be exactly 300 minutes and silently dropped rows otherwise. It now accepts a range of short windows, so plan or rollout differences in the window length no longer blank out the Codex meter. (Codex percentages themselves come from the server and are plan-independent.)

## Added

- **Settings > Sync > Claude plan**: choose Auto / Pro / Max 5x / Max 20x. Auto reads the plan from `~/.claude.json`; pick your plan manually if the local estimate looks off. This only affects the local estimate — official usage sync is always exact regardless of plan.
- Team / Enterprise accounts are now labeled as such and start from the Pro cap until official-sync calibration adjusts it.

## Notes

- The plan caps used by the local estimate are initial estimates (Pro 2M / Max 5x 10M / Max 20x 40M deduplicated weighted tokens). Enabling official Claude usage sync once lets usage_kun calibrate the cap against the exact numbers for your account.

---

日本語:

- **Max 20x プランがローカル推定で Max 5x として扱われていた問題を修正しました。** 実際のアカウントでは Max 5x / 20x のどちらも `organizationType` が `claude_max` で、5x/20x の区別は rate-limit tier 文字列 (例: `default_claude_max_20x`) にしか現れないため、Max 20x の使用率が約 4 倍過大に表示されていました。`~/.claude.json` の `userRateLimitTier` / `organizationRateLimitTier` も読むようにしました。
- Codex の live rate-limit 読み取りが「primary window = ちょうど 300 分」を要求していたのを範囲判定に緩和しました (Codex の percent はサーバー由来でプラン非依存です)。
- **Settings > Sync > Claude plan** を追加しました。Auto / Pro / Max 5x / Max 20x から選べます。自動検出が外れる場合に手動で指定してください。この設定はローカル推定にのみ影響し、公式同期の数値は常に正確です。
