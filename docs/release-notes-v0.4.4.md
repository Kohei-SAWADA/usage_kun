# usage kun v0.4.4

Login startup is enabled once for fresh installations. Settings can turn it on or off and reports OS approval, disabled status, and registration failures. Existing explicit off choices and OS-disabled entries survive upgrades. Legacy installations without a startup item stay off. macOS requires the app in Applications before automatic registration; Windows uses a single current-user Run entry. No repeated registration on launch or usage refresh. Enabled moved installations repair the existing entry once, without changing OS approval controls.

Only startup handling and its documentation/tests changed. The Windows v0.4.3 quota fixes and macOS usage measurement remain unchanged.

## 日本語

新規インストール時に一度だけ自動起動を登録し、設定画面から変更できます。既存のオフ選択と OS の無効化を更新時に保持します。旧版で登録がない場合はオフを維持します。macOS は Applications への配置後に登録します。OS の承認待ち・失敗を設定画面に表示し、承認を回避しません。起動や使用量更新のたびに再登録しません。

## Validation limits

Automated checks cover fresh installation, no repeated registration, explicit off, OS removal/approval, relocation, failures, and persisted settings reconstruction. macOS build/core checks and Windows build/core/WPF checks are required before the release workflow publishes. No logout, reboot, real login cycle, or physical Windows startup is claimed. macOS assets are Apple Silicon, ad-hoc signed and not notarized; Windows x64 assets remain unsigned and self-contained.
