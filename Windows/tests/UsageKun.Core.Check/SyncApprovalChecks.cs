using UsageKun.Core;

// Synthetic providers count the operations that would read logs/credentials or
// send requests. No product app, user profile, sign-in, or network is accessed.
internal static class SyncApprovalChecks
{
    public static async Task RunAsync()
    {
        var root = Path.Combine(Path.GetTempPath(), "usage-kun-sync-check-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(root);
        try
        {
            var configStore = new AppConfigStore(Path.Combine(root, "config.json"));
            var local = new LocalFixture();
            var official = new OfficialFixture();
            var antigravity = new AntigravityFixture();
            var service = new CompositeUsageService(configStore, local, official, antigravity);
            var fresh = configStore.Load();
            Assert(!fresh.SyncApproved && SourcesChecked(fresh),
                "fresh sync selections default ON while approval defaults OFF");
            var initial = await service.SnapshotsAsync(DateTimeOffset.Now);
            Assert(initial.Count == 2 && initial.All(snapshot => snapshot.Percent == null && snapshot.Source == "not started"),
                "a direct service call returns setup guidance before approval");
            AssertNoReads(local, official, antigravity);

            // Legacy onboarding and source choices do not constitute Windows consent.
            File.WriteAllText(configStore.ConfigPath,
                """{"onboardingCompleted":true,"localLogEnabled":false,"codexOfficialUsageEnabled":false,"claudeProviderEnabled":false}""");
            var legacy = configStore.Load();
            Assert(!legacy.SyncApproved && !legacy.LocalLogEnabled && !legacy.CodexOfficialUsageEnabled && !legacy.ClaudeProviderEnabled,
                "legacy explicit OFF choices survive without inferring approval from onboarding");
            await service.SnapshotsAsync(DateTimeOffset.Now);
            AssertNoReads(local, official, antigravity);

            var cachedStartupConfig = new AppConfig { SyncApproved = true, LaunchAtLoginInitialized = false };
            configStore.Save(cachedStartupConfig);
            Assert(!configStore.Load().SyncApproved, "ordinary config persistence cannot create approval");
            configStore.SaveWithSyncApproval(cachedStartupConfig);
            cachedStartupConfig = configStore.Load();
            File.WriteAllText(configStore.ConfigPath, "{");
            cachedStartupConfig.LaunchAtLoginInitialized = true;
            configStore.Save(cachedStartupConfig);
            Assert(!configStore.Load().SyncApproved,
                "startup preference persistence cannot restore cached approval after configuration corruption");
            await service.SnapshotsAsync(DateTimeOffset.Now);
            AssertNoReads(local, official, antigravity);

            var selected = new AppConfig { AntigravityProviderEnabled = true, CodexOfficialUsageEnabled = false };
            configStore.Save(selected);
            var store = new UsageStore(service, configStore);
            Assert(store.UpdatedAt == null, "pending setup must not claim a successful update time");
            foreach (var path in new[] { "startup", "timer", "tray/widget refresh" })
            {
                await store.RefreshAsync();
                Assert(!store.IsRefreshing && !store.Config.SyncApproved, path + " cannot grant approval");
                AssertNoReads(local, official, antigravity);
            }
            var ordinarySave = store.Config.Clone();
            ordinarySave.RefreshIntervalMinutes = 1;
            ordinarySave.SyncApproved = true;
            store.UpdateConfig(ordinarySave);
            await store.RefreshAsync();
            Assert(!store.Config.SyncApproved && !configStore.Load().SyncApproved,
                "ordinary settings Save cannot grant initial approval even if its input flag is true");
            AssertNoReads(local, official, antigravity);

            Assert(store.StartSync(store.Config), "explicit Start sync persists approval");
            await WaitForRefresh(store);
            Assert(configStore.Load().SyncApproved && store.Config.SyncApproved,
                "explicit approval persists across config reload");
            Assert(local.LogReads == 1 && official.CredentialReads == 1 && official.NetworkRequests == 1
                && official.Providers.SequenceEqual([UsageProvider.Claude])
                && antigravity.CredentialDiscoveries == 1 && antigravity.NetworkRequests == 1,
                "only explicit Start sync allows reads and requests, preserving Codex sync OFF");
            Assert(!configStore.Load().CodexOfficialUsageEnabled, "Start sync must preserve an existing source opt-out");

            var allOff = store.Config.Clone();
            allOff.LocalLogEnabled = false;
            allOff.ClaudeOfficialUsageEnabled = false;
            allOff.CodexOfficialUsageEnabled = false;
            allOff.AntigravityUsageEnabled = false;
            store.UpdateConfig(allOff);
            await WaitForRefresh(store);
            var restarted = new UsageStore(service, configStore);
            await restarted.RefreshAsync();
            Assert(restarted.Config.SyncApproved && !restarted.Config.LocalLogEnabled
                && !restarted.Config.ClaudeOfficialUsageEnabled && !restarted.Config.CodexOfficialUsageEnabled
                && !restarted.Config.AntigravityUsageEnabled,
                "all explicit sync OFF choices persist after reconstructing the store");
            Assert(local.LogReads == 1 && official.CredentialReads == 1 && antigravity.CredentialDiscoveries == 1,
                "saved sync OFF choices block subsequent provider access after approval");

            // A running process must stop using even its previously valid approval
            // after the settings file is damaged. Neither Save nor dragging repairs consent.
            File.WriteAllText(configStore.ConfigPath, "{\"syncApproved\":true,");
            await restarted.RefreshAsync();
            await service.SnapshotsAsync(DateTimeOffset.Now);
            Assert(!restarted.Config.SyncApproved && !configStore.Load().SyncApproved,
                "truncated config revokes cached approval and the service fails closed");
            restarted.SaveWidgetPosition(24, 32);
            ordinarySave = restarted.Config.Clone();
            ordinarySave.SyncApproved = true;
            restarted.UpdateConfig(ordinarySave);
            Assert(!configStore.Load().SyncApproved, "widget persistence and settings Save cannot restore lost approval");
            Assert(local.LogReads == 1 && official.CredentialReads == 1 && antigravity.CredentialDiscoveries == 1,
                "corruption and ordinary persistence never cause credential reads or network calls");

            foreach (var damaged in new[]
            {
                "null", "[]", "{}", "{\"syncApproved\":null}", "{\"syncApproved\":\"true\"}",
                "{\"syncApproved\":false,\"SyncApproved\":true}",
                "{\"syncApproved\":true,\"syncApproved\":true}",
                "{\"syncApproved\":true,\"localLogEnabled\":\"bad\"}"
            })
            {
                File.WriteAllText(configStore.ConfigPath, damaged);
                Assert(!configStore.Load().SyncApproved, "missing, invalid, or duplicate approval fails closed");
                await service.SnapshotsAsync(DateTimeOffset.Now);
            }
            Assert(local.LogReads == 1 && official.CredentialReads == 1 && antigravity.CredentialDiscoveries == 1,
                "damaged config cannot authorize provider access");

            var failedSaveConfig = new AppConfigStore(Path.Combine(root, "approved-save-failure.json"));
            failedSaveConfig.SaveWithSyncApproval(new AppConfig { AntigravityProviderEnabled = true });
            var failedSaveService = new CompositeUsageService(failedSaveConfig, local, official, antigravity);
            var failedSaveStore = new UsageStore(failedSaveService, failedSaveConfig);
            var offAfterApproval = failedSaveStore.Config.Clone();
            offAfterApproval.LocalLogEnabled = offAfterApproval.ClaudeOfficialUsageEnabled =
                offAfterApproval.CodexOfficialUsageEnabled = offAfterApproval.AntigravityUsageEnabled = false;
            Directory.CreateDirectory(failedSaveConfig.ConfigPath + ".tmp");
            failedSaveStore.UpdateConfig(offAfterApproval);
            Assert(!failedSaveStore.Config.SyncApproved && !failedSaveConfig.Load().SyncApproved
                && !failedSaveStore.Config.LocalLogEnabled && failedSaveStore.LastErrorMessage != null,
                "failed OFF-setting persistence pauses even previously approved sync in the shared service store");
            await failedSaveStore.RefreshAsync();
            await failedSaveService.SnapshotsAsync(DateTimeOffset.Now);
            Assert(local.LogReads == 1 && official.CredentialReads == 1 && antigravity.CredentialDiscoveries == 1,
                "old saved approval cannot resume providers after an approved settings Save failed");
            Directory.Delete(failedSaveConfig.ConfigPath + ".tmp");
            failedSaveStore.UpdateConfig(offAfterApproval);
            Assert(!failedSaveStore.Config.SyncApproved && !failedSaveConfig.Load().SyncApproved,
                "ordinary Save remains paused after failure even when persistence becomes available");
            Assert(failedSaveStore.StartSync(failedSaveStore.Config), "explicit Start sync retries failed persistence");
            await WaitForRefresh(failedSaveStore);
            Assert(failedSaveConfig.Load().SyncApproved && !failedSaveConfig.Load().LocalLogEnabled
                && local.LogReads == 1 && official.CredentialReads == 1 && antigravity.CredentialDiscoveries == 1,
                "explicit retry preserves all OFF selections without provider reads");

            // A directory cannot be replaced by the config file, without depending
            // on OS permission differences or touching the real user's settings.
            var blockedPath = Path.Combine(root, "directory-not-a-config");
            Directory.CreateDirectory(blockedPath);
            var failedStore = new UsageStore(service, new AppConfigStore(blockedPath));
            Assert(!failedStore.StartSync(failedStore.Config) && !failedStore.Config.SyncApproved
                && failedStore.LastErrorMessage == "Failed to save settings.",
                "failed approval persistence leaves sync paused and reports a safe error");
            await failedStore.RefreshAsync();
            Assert(local.LogReads == 1 && official.CredentialReads == 1 && antigravity.CredentialDiscoveries == 1,
                "failed Start sync does not read credentials or send requests");

            Console.WriteLine("PASS initial sync approval: defaults, startup/timer/refresh/Save, explicit Start sync, opt-outs, corruption, startup persistence, failed approval/approved saves; mocks only");
        }
        finally { Directory.Delete(root, recursive: true); }
    }

    private static bool SourcesChecked(AppConfig config) => config.LocalLogEnabled && config.ClaudeOfficialUsageEnabled
        && config.CodexOfficialUsageEnabled && config.AntigravityUsageEnabled;

    private static void AssertNoReads(LocalFixture local, OfficialFixture official, AntigravityFixture antigravity) =>
        Assert(local.LogReads == 0 && official.CredentialReads == 0 && official.NetworkRequests == 0
            && antigravity.CredentialDiscoveries == 0 && antigravity.NetworkRequests == 0,
            "before approval there are no log reads, credential reads/discovery, or network requests");

    private static async Task WaitForRefresh(UsageStore store)
    {
        using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(5));
        while (store.IsRefreshing) await Task.Delay(10, timeout.Token);
    }

    private static void Assert(bool condition, string message)
    {
        if (!condition) throw new InvalidOperationException("Sync approval check failed: " + message);
    }

    private sealed class LocalFixture : ILocalLogUsageService
    {
        public string ClaudePlanOverride { get; set; } = "auto";
        public int LogReads { get; private set; }
        public Task<IReadOnlyList<UsageSnapshot>> SnapshotsAsync(DateTimeOffset now) => SnapshotsAsync(now, true, true);
        public Task<IReadOnlyList<UsageSnapshot>> SnapshotsAsync(DateTimeOffset now, bool codexEnabled, bool claudeEnabled)
        {
            LogReads++;
            return Task.FromResult<IReadOnlyList<UsageSnapshot>>([]);
        }
    }

    private sealed class OfficialFixture : IOfficialUsageService
    {
        public int CredentialReads { get; private set; }
        public int NetworkRequests { get; private set; }
        public List<UsageProvider> Providers { get; } = [];
        public Task<OfficialUsageResult> SnapshotAsync(UsageProvider provider, DateTimeOffset now)
        {
            CredentialReads++;
            NetworkRequests++;
            Providers.Add(provider);
            return Task.FromResult(new OfficialUsageResult(null, "Synthetic sign-in fixture only."));
        }
    }

    private sealed class AntigravityFixture : IAntigravityUsageService
    {
        public int CredentialDiscoveries { get; private set; }
        public int NetworkRequests { get; private set; }
        public Task<UsageSnapshot> SnapshotAsync(DateTimeOffset now)
        {
            CredentialDiscoveries++;
            NetworkRequests++;
            return Task.FromResult(new UsageSnapshot
            {
                Provider = UsageProvider.Antigravity, Status = UsageStatus.Unknown, UpdatedAt = now,
                Source = "synthetic", Message = "Synthetic local-service fixture only."
            });
        }
    }
}
