# usage_kun v0.3.1

This patch release publishes the responsive layout polish for single-provider mode.

## Changed

- The popover now adjusts its height based on the visible provider count, so Claude-only or Codex-only mode no longer keeps the full two-provider layout.
- The pinned home meter uses the same provider-aware sizing and compacts when only one provider is enabled.
- The header metric and desktop next-action label follow the currently visible provider set.

## Notes

- There are no changes to credential storage, official sync, or local usage parsing.
- Both providers are still enabled by default after updating.

---

日本語:

- Claude だけ / Codex だけの single-provider 表示で、popover の高さが自動で小さくなるようにしました。
- 固定ホームメーターも provider 数に合わせて高さが変わり、1 provider 表示では余白を抑えます。
- 上部の 5h メトリックと desktop の next-action label は、表示中 provider に合わせて切り替わります。
- credential storage、公式 sync、local usage parsing の挙動は変更していません。
