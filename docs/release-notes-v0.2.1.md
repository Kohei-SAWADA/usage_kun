# usage_kun v0.2.1

This is a packaging and hardening release. There are no feature changes.

## Fixed

- The release `UsageKun-macOS.zip` now contains a properly signed app bundle. Previous releases shipped a binary that only carried the linker's bare ad-hoc signature (no sealed resources, `Info.plist` not bound), so Gatekeeper rejected downloaded copies as "damaged and can't be opened". `Scripts/package_app.sh` now strips extended attributes and re-signs the whole bundle with a full ad-hoc signature (hardened runtime enabled), and verifies it with `codesign --verify --strict`.
- The release zip no longer archives filesystem extended attributes as AppleDouble `._*` files, which could invalidate the sealed signature after extraction. `Scripts/package_release_zip.sh` also round-trips the archive and re-verifies the signature before publishing.

## Hardening

- The Codex local databases (`~/.codex/state_5.sqlite`, `~/.codex/logs_2.sqlite`) are now opened with `sqlite3 -readonly -batch`, so usage_kun can never write to, or leave lock/journal files next to, another app's database.
- The CI workflow's `GITHUB_TOKEN` is now restricted to `contents: read`.

## Docs

- README (English and Japanese) now documents installing from the release zip, including the expected one-time Gatekeeper approval for a non-notarized app.

## First Launch: "Apple could not verify UsageKun is free of malware"

The app is signed but not notarized, so the first launch of a downloaded copy still shows a Gatekeeper warning ("Apple could not verify "UsageKun" is free of malware..."). This is expected for any non-notarized app and is different from the previous "damaged" error, which prevented the app from being opened at all. Approve it once:

1. In the warning dialog, click **Done** (do NOT click "Move to Trash").
2. Open **System Settings** > **Privacy & Security**.
3. Scroll down to the **Security** section, where "UsageKun" is listed as blocked.
4. Click **Open Anyway**, then confirm with **Open Anyway** again and authenticate.

日本語: 初回起動時に「Apple は、"UsageKun" にマルウェアが含まれていないことを確認できませんでした」と表示された場合:

1. 警告 dialog で **「完了」** を押します(「ゴミ箱に入れる」は押さないでください)。
2. **システム設定** > **プライバシーとセキュリティ** を開きます。
3. 下にスクロールし、**セキュリティ** 欄の「"UsageKun" はブロックされました」の横の **「このまま開く」** を押します。
4. 確認 dialog でもう一度 **「このまま開く」** を押し、Touch ID または password で認証します。

Alternatively, from Terminal: `xattr -d com.apple.quarantine /Applications/UsageKun.app`

The approval is needed only once per downloaded version.
