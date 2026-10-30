using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Net.Http;
using System.Security.Cryptography;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using System.Web.Script.Serialization;
using Uten.Legacy.Core;

namespace Uten.Legacy.Desktop.Features.Publish
{
    /// <summary>Offline publish-workbench contract fixtures; the desktop project includes
    /// *Checks only in Debug. They pin the three queue invariants (confirmed rows are never
    /// re-uploaded, unknown outcomes only resolve by reading the original record, a frozen
    /// requestId is never replaced) plus the draft snapshot and DPAPI store contracts.</summary>
    public static class PublishContractChecks
    {
        private static readonly JavaScriptSerializer Serializer = new JavaScriptSerializer();

        public static int Run()
        {
            int assertions = 0;
            Action<bool, string> check = (condition, message) =>
            {
                if (!condition) throw new InvalidOperationException("Publish contract: " + message);
                assertions++;
            };
            Action<Action, string> reject = (action, message) =>
            {
                try { action(); }
                catch (Exception error) when (error is InvalidOperationException || error is FormatException || error is ApiException)
                { assertions++; return; }
                throw new InvalidOperationException("Publish contract (expected rejection): " + message);
            };

            CheckMetadataValidation(check);
            CheckTrustedStore(check);
            CheckQueueLimitsAndExtensions(check, reject);
            CheckEditReplaceRemove(check);
            CheckRunHappyPath(check);
            CheckConfirmedRowsAreNotResent(check);
            CheckFailureClassification(check);
            CheckReconcile(check);
            CheckWithdrawCycle(check);
            CheckValidateRecord(check, reject);
            CheckPairGroups(check);
            CheckDraftSnapshot(check, reject);
            CheckDraftStore(check);
            return assertions;
        }

        /// <summary>Scriptable gateway: prepare/upload/publish/withdraw/read can each be given a
        /// canned record or a failure, and every dispatch is recorded for ordering assertions.</summary>
        private sealed class FakeGateway : IClientReleaseGateway
        {
            public readonly List<string> SentPaths = new List<string>();
            public bool PrepareReturnsSameBytes;
            public Exception PrepareError, PublishError, WithdrawError;
            public string LastFileName = "fixture.zip";
            public string KnownSha, LastSha;
            public long KnownSize, LastSize;
            public string LastPlatform = "windows", LastFamily = "flutter", LastKind = "update", LastInstallMode = "windows_archive", LastContract = "paired_v1", LastArchitecture = "x64";
            public Func<string, Task<string>> OnRead = delegate (string path)
            { throw new InvalidOperationException("unexpected read " + path); };

            public Task<string> ReadAsync(string relativePath) { return OnRead(relativePath); }

            public Task<string> SendAsync(string relativePath, string bodyJson, bool requireStepUp)
            {
                SentPaths.Add(bodyJson == null ? relativePath : relativePath + ":prepare");
                if (bodyJson != null)
                {
                    if (PrepareError != null) throw PrepareError;
                    var body = Serializer.DeserializeObject(bodyJson) as Dictionary<string, object>;
                    KnownSha = Text(body, "expectedSha256");
                    var fileName = Text(body, "fileName");
                    var platform = Text(body, "platform");
                    var family = body.ContainsKey("runtimeFamily") && body["runtimeFamily"] is string ? (string)body["runtimeFamily"] : "flutter";
                    var bytesAlreadyKnown = PrepareReturnsSameBytes;
                    var preparedFileName = fileName;
                    if (fileName != null) LastFileName = fileName;
                    LastPlatform = platform;
                    LastFamily = family;
                    LastKind = Text(body, "packageKind");
                    LastArchitecture = Text(body, "architecture");
                    LastInstallMode = InstallModeOf(platform, family, Text(body, "packageKind"));
                    LastContract = platform == "windows" ? "paired_v1" : "audited_v1";
                    return Task.FromResult(Record(Text(body, "requestId"), "DRAFT",
                        bytesAlreadyKnown ? KnownSha : null, bytesAlreadyKnown ? KnownSize : 0, preparedFileName,
                        platform: platform, architecture: LastArchitecture, family: family, kind: LastKind,
                        installMode: LastInstallMode, contract: LastContract,
                        expected: KnownSha));
                }
                if (relativePath.EndsWith("/publish"))
                {
                    if (PublishError != null) throw PublishError;
                    var id = relativePath.Substring("admin/client-releases/".Length, 36);
                    var sha = LastSha ?? KnownSha;
                    var responseFileName = sha == null ? null : LastFileName;
                    return Task.FromResult(Record(id, "PUBLISHED", sha, LastSha != null ? LastSize : KnownSize, responseFileName,
                        platform: LastPlatform, architecture: LastArchitecture, family: LastFamily, kind: LastKind,
                        installMode: LastInstallMode, contract: LastContract, expected: KnownSha));
                }
                if (relativePath.EndsWith("/withdraw"))
                {
                    if (WithdrawError != null) throw WithdrawError;
                    var id = relativePath.Substring("admin/client-releases/".Length, 36);
                    var withdrawSha = LastSha ?? KnownSha;
                    return Task.FromResult(Record(id, "WITHDRAWN", withdrawSha, LastSha != null ? LastSize : KnownSize,
                        withdrawSha == null ? null : LastFileName,
                        platform: LastPlatform, architecture: LastArchitecture, family: LastFamily, kind: LastKind,
                        installMode: LastInstallMode, contract: LastContract, expected: KnownSha));
                }
                throw new InvalidOperationException("unexpected send " + relativePath);
            }

            public Task<string> UploadAsync(string releaseId, string sourcePath, long expectedBytes, string expectedSha256, IProgress<long> progress)
            {
                SentPaths.Add("upload:" + releaseId);
                LastFileName = Path.GetFileName(sourcePath);
                LastSha = expectedSha256;
                LastSize = expectedBytes;
                return Task.FromResult(Record(releaseId, "DRAFT", expectedSha256, expectedBytes, LastFileName,
                    platform: LastPlatform, architecture: LastArchitecture, family: LastFamily, kind: LastKind,
                    installMode: LastInstallMode, contract: LastContract, expected: KnownSha));
            }
        }

        private static string InstallModeOf(string platform, string family, string kind)
        {
            if (platform == "windows")
            {
                if (kind == "installer") return family == "wpf_legacy" ? "windows_wpf_setup" : "windows_setup";
                return family == "wpf_legacy" ? "windows_wpf_archive" : "windows_archive";
            }
            if (platform == "android") return "android_package";
            return "store";
        }

        private static string Text(Dictionary<string, object> body, string key)
        { object value; return body.TryGetValue(key, out value) && value is string ? (string)value : null; }

        internal static string NewId() { return Guid.NewGuid().ToString("D"); }

        private static string ShaOf(byte[] bytes)
        { return BitConverter.ToString(SHA256.Create().ComputeHash(bytes)).Replace("-", "").ToLowerInvariant(); }

        private const string ShaText = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";

        private static string Record(string id, string state, string sha, long size, string fileName,
            string platform = "windows", string architecture = "x64", string version = "2.5.37",
            string buildNumber = "2537", string kind = "update", string family = "flutter",
            string installMode = "windows_archive", string contract = "paired_v1", string expected = null)
        {
            var value = new Dictionary<string, object>
            {
                { "id", id }, { "platform", platform }, { "architecture", architecture },
                { "version", version }, { "buildNumber", Int64.Parse(buildNumber) },
                { "releaseNotes", "" }, { "installMode", installMode }, { "mandatory", false },
                { "state", state }, { "packageKind", kind }, { "fileName", fileName },
                { "runtimeFamily", family }, { "deliveryContract", contract },
                { "expectedSha256", expected ?? sha ?? ShaText }
            };
            if (sha != null) { value["sha256"] = sha; value["sizeBytes"] = size; }
            if (fileName == null) { value.Remove("fileName"); value["storeUrl"] = "https://apps.apple.com/app/id123"; }
            return Serializer.Serialize(value);
        }

        private static ClientReleasePublishMetadata WindowsUpdate()
        {
            return new ClientReleasePublishMetadata
            {
                Platform = "windows", RuntimeFamily = "flutter", Architecture = "x64",
                PackageKind = "update", Version = "2.5.37", BuildNumber = "2537",
                ReleaseNotes = "", StoreUrl = null
            };
        }

        private static string FixtureFile(out long size, out string sha)
        {
            var bytes = Encoding.UTF8.GetBytes("uten publish fixture");
            var path = Path.Combine(Path.GetTempPath(), "uten-publish-" + Guid.NewGuid().ToString("N") + ".zip");
            File.WriteAllBytes(path, bytes);
            size = bytes.Length;
            sha = ShaOf(bytes);
            return path;
        }

        private static ClientReleasePublishQueue Queue(FakeGateway gateway)
        { return new ClientReleasePublishQueue(gateway, delegate { return true; }); }

        private static ClientReleaseQueueItem AddReadyItem(ClientReleasePublishQueue queue, out string sha, out long size)
        {
            var path = FixtureFile(out size, out sha);
            return queue.AddFile(path, size, WindowsUpdate());
        }

        /// <summary>Builds a row through the draft contract itself (snapshot → validate →
        /// restore). Tests never bypass the contract with direct property writes.</summary>
        private static ClientReleaseQueueItem RowViaSnapshot(string requestId, string stage, string pending,
            string sha, long size, string fileName, bool publishAcknowledged = false)
        {
            var row = new Dictionary<string, object>
            {
                { "localId", NewId() }, { "metadata", WindowsUpdate().ToDictionary() },
                { "fileName", fileName }, { "sizeBytes", size }, { "requestId", requestId },
                { "sha256", sha }, { "releaseId", requestId }, { "stage", stage },
                { "pendingOperation", pending }, { "retentionPending", false }, { "publishAcknowledged", publishAcknowledged }
            };
            var json = Serializer.Serialize(new Dictionary<string, object>
            {
                { "schemaVersion", 1 }, { "rows", new object[] { row } },
                { "context", WindowsUpdate().ToDictionary() }, { "withdrawals", new object[0] },
                { ClientReleasePublishContract.UnknownSubmissionKey, true }
            });
            return ClientReleasePublishContract.ValidateAndRestore(json).Rows[0];
        }

        private static ClientReleaseQueueItem RestoreInto(ClientReleasePublishQueue queue,
            string requestId, string stage, string pending, string sha, long size, string fileName,
            bool publishAcknowledged = false)
        {
            var row = RowViaSnapshot(requestId, stage, pending, sha, size, fileName, publishAcknowledged);
            queue.Restore(new ClientReleasePublishContract.ValidatedSnapshot
            {
                Rows = new List<ClientReleaseQueueItem> { row },
                Withdrawals = new Dictionary<string, ClientReleaseWithdrawState>(),
                Context = null,
                HasUnknownSubmission = true
            });
            return queue.Items[0];
        }

        private static void Await(Task task) { task.GetAwaiter().GetResult(); }

        private static ApiException Definite(string code, int status)
        { return new ApiException(code, "明确拒绝", status, false, true); }

        private static ApiException UnknownTransport()
        { return new ApiException("SUBMISSION_UNKNOWN", "操作已发送，但结果尚未确认。", null, true, false); }

        private static void CheckMetadataValidation(Action<bool, string> check)
        {
            var valid = WindowsUpdate();
            check(valid.ValidationError() == null, "valid windows update target passes");
            check(valid.GroupKey == "windows/flutter/x64/2.5.37/2537" && valid.KindKey.EndsWith("/update"), "group and kind keys pin the full target");
            var badPlatform = WindowsUpdate(); badPlatform.Platform = "linux";
            check(badPlatform.ValidationError() == "此平台尚未提供发布服务。", "unpublished platform rejected");
            var badVersion = WindowsUpdate(); badVersion.Version = "2.5";
            check(badVersion.ValidationError() == "版本号使用三段数字，例如 2.5.34。", "version needs three numeric segments");
            var badBuild = WindowsUpdate(); badBuild.BuildNumber = "0";
            check(badBuild.ValidationError() == "请填写有效的构建号。", "build number range enforced");
            var badArch = WindowsUpdate(); badArch.RuntimeFamily = "wpf_legacy"; badArch.Architecture = "arm64";
            check(badArch.ValidationError() == "客户端类型与架构不匹配。", "legacy family has no arm64");
            var badKind = WindowsUpdate(); badKind.PackageKind = "bundle";
            check(badKind.ValidationError() == "Windows 必须使用安装包或更新 ZIP。", "windows package kind restricted");
            var foreign = WindowsUpdate(); foreign.Platform = "android"; foreign.PackageKind = "installer";
            check(foreign.ValidationError() == "该平台不支持此运行时或安装类型。", "installer is windows-only");
            var badForeignArch = WindowsUpdate(); badForeignArch.Platform = "ios"; badForeignArch.Architecture = "x64";
            check(badForeignArch.ValidationError() == "此平台不支持所选架构。", "ios architecture whitelist");
            var badStore = WindowsUpdate(); badStore.Platform = "android"; badStore.PackageKind = "update"; badStore.Architecture = "arm64";
            badStore.StoreUrl = "https://evil.example.com/store/apps/details?id=x";
            check(badStore.ValidationError() == "请填写该平台的官方商店链接。", "store link must be the official host");
            var longNotes = WindowsUpdate(); longNotes.ReleaseNotes = new string('字', 10001);
            check(longNotes.ValidationError() == "发布说明最多 10000 字。", "release notes length");
            var body = WindowsUpdate().ToRequestBody("request-id", "file.zip", ShaText);
            check(body["mandatory"].Equals(false) && body["packageKind"].Equals("update")
                && !body.ContainsKey("runtimeFamily") && body["expectedSha256"].Equals(ShaText),
                "prepare body omits default flutter family and freezes idempotent intent");
            var legacy = WindowsUpdate(); legacy.RuntimeFamily = "wpf_legacy"; legacy.PackageKind = "installer";
            var legacyBody = legacy.ToRequestBody("request-id", "setup.exe", ShaText);
            check(legacyBody["runtimeFamily"].Equals("wpf_legacy") && legacyBody["packageKind"].Equals("installer"),
                "non-default runtime family is sent explicitly");
        }

        private static void CheckTrustedStore(Action<bool, string> check)
        {
            check(TrustedClientStore.Parse("https://apps.apple.com/app/id123", "ios") != null, "apple store link accepted");
            check(TrustedClientStore.Parse("https://play.google.com/store/apps/details?id=com.uten.uten_imp", "android") != null, "play details link accepted");
            check(TrustedClientStore.Parse("https://play.google.com/about", "android") == null, "play non-details path rejected");
            check(TrustedClientStore.Parse("http://apps.apple.com/app/id123", "ios") == null, "plain http store link rejected");
            check(TrustedClientStore.Parse("https://apps.apple.com/app/id123", "android") == null, "store host is platform specific");
        }

        private static void CheckQueueLimitsAndExtensions(Action<bool, string> check, Action<Action, string> reject)
        {
            var queue = Queue(new FakeGateway());
            string path = FixtureFile(out long size, out string sha);
            var first = queue.AddFile(path, size, WindowsUpdate());
            check(first != null && first.Stage == ClientReleaseQueueStage.Ready, "file row starts ready");
            check(first.Metadata.PackageKind == "update", "zip extension suggests update kind");
            var exePath = Path.ChangeExtension(path, ".exe");
            File.Copy(path, exePath, true);
            var second = queue.AddFile(exePath, size, WindowsUpdate());
            check(second.Metadata.PackageKind == "installer", "exe extension suggests installer kind");
            reject(delegate { queue.AddFile(path, 0, WindowsUpdate()); }, "empty file rejected");
            reject(delegate { queue.AddFile(path, ClientReleasePublishLimits.MaxClientPackageBytes + 1, WindowsUpdate()); }, "oversize file rejected");
            var full = Queue(new FakeGateway());
            for (var index = 0; index < ClientReleasePublishLimits.MaximumFiles; index++)
                full.AddFile(path, size, WindowsUpdate());
            reject(delegate { full.AddFile(path, size, WindowsUpdate()); }, "queue keeps at most 100 rows");
        }

        private static void CheckEditReplaceRemove(Action<bool, string> check)
        {
            var queue = Queue(new FakeGateway());
            string path = FixtureFile(out long size, out string sha);
            var frozen = RestoreInto(queue, NewId(), "Rejected", null, sha, size, "original.zip");
            string otherPath = FixtureFile(out long otherSize, out string otherSha);
            queue.ReplaceFile(frozen, otherPath, new FileInfo(otherPath).Length);
            check(frozen.FileName == "original.zip" && frozen.SizeBytes == size, "frozen row keeps original name and size");
            var plain = queue.AddFile(path, size, WindowsUpdate());
            var edited = WindowsUpdate(); edited.Version = "2.5.38";
            queue.Edit(plain, edited);
            check(plain.Metadata.Version == "2.5.38", "unfrozen row target editable");
            var uncertain = RestoreInto(queue, NewId(), "Unknown", "Prepare", sha, size, "fixture.zip");
            queue.Remove(uncertain);
            check(queue.Items.Contains(uncertain), "uncertain rows can never be removed");
            var withdrawn = RestoreInto(queue, NewId(), "Withdrawn", null, sha, size, "fixture.zip");
            queue.Remove(withdrawn);
            check(!queue.Items.Contains(withdrawn), "confirmed withdrawn rows may be cleared from the queue");
            var rejected = RestoreInto(queue, NewId(), "Rejected", null, sha, size, "fixture.zip");
            queue.Remove(rejected);
            check(!queue.Items.Contains(rejected), "rejected frozen rows can be cleared");
        }

        private static void CheckRunHappyPath(Action<bool, string> check)
        {
            var gateway = new FakeGateway();
            var queue = Queue(gateway);
            string sha; long size;
            var item = AddReadyItem(queue, out sha, out size);
            Await(queue.RunAsync(CancellationToken.None));
            check(item.Stage == ClientReleaseQueueStage.Published && item.PendingOperation == null,
                "prepare→upload→publish reaches published");
            check(item.Sha256 == sha && item.SourcePath == null && item.PublishAcknowledged, "row keeps its hash and drops the local file");
            check(gateway.SentPaths.Count(value => value.EndsWith(":prepare")) == 1
                && gateway.SentPaths.Contains("upload:" + item.ReleaseId)
                && gateway.SentPaths.Any(value => value.EndsWith("/publish")), "all three phases dispatched once");
            check(gateway.SentPaths.FindIndex(value => value.EndsWith(":prepare")) < gateway.SentPaths.FindIndex(value => value.StartsWith("upload:", StringComparison.Ordinal))
                && gateway.SentPaths.FindIndex(value => value.StartsWith("upload:", StringComparison.Ordinal)) < gateway.SentPaths.FindIndex(value => value.EndsWith("/publish")),
                "prepare precedes upload precedes publish");
            queue.Remove(item);
            check(queue.Items.Contains(item), "published rows are never removed from the queue");
        }

        private static void CheckConfirmedRowsAreNotResent(Action<bool, string> check)
        {
            var sameBytesGateway = new FakeGateway { PrepareReturnsSameBytes = true };
            var sameBytesQueue = Queue(sameBytesGateway);
            string sameSha; long sameSize;
            var sameBytesItem = AddReadyItem(sameBytesQueue, out sameSha, out sameSize);
            sameBytesGateway.KnownSize = sameSize;
            Await(sameBytesQueue.RunAsync(CancellationToken.None));
            check(sameBytesGateway.SentPaths.Count(value => value.StartsWith("upload:", StringComparison.Ordinal)) == 0,
                "a server draft with the same bytes is never re-uploaded");
            check(sameBytesItem.Stage == ClientReleaseQueueStage.Published, "same-byte draft publishes directly");

            var storeGateway = new FakeGateway();
            var storeQueue = Queue(storeGateway);
            var storeMetadata = WindowsUpdate();
            storeMetadata.Platform = "ios";
            storeMetadata.Architecture = "arm64";
            storeMetadata.StoreUrl = "https://apps.apple.com/app/id123";
            var storeItem = storeQueue.AddStore(storeMetadata);
            Await(storeQueue.RunAsync(CancellationToken.None));
            check(storeGateway.SentPaths.Count(value => value.StartsWith("upload:", StringComparison.Ordinal)) == 0,
                "store rows never upload binaries");
            check(storeItem.Stage == ClientReleaseQueueStage.Published,
                "store row publishes from metadata alone (stage=" + storeItem.Stage + " error=" + storeItem.Error + ")");
        }

        private static void CheckFailureClassification(Action<bool, string> check)
        {
            var gateway = new FakeGateway { PrepareError = UnknownTransport() };
            var queue = Queue(gateway);
            string sha; long size;
            var item = AddReadyItem(queue, out sha, out size);
            Await(queue.RunAsync(CancellationToken.None));
            check(item.Stage == ClientReleaseQueueStage.Unknown && item.PendingOperation == ClientReleaseQueueOperation.Prepare,
                "dispatched transport failure stays unknown with its pending operation");
            check(item.SourcePath == null && item.Error != null, "failed row drops the local file and records the message");

            var definiteGateway = new FakeGateway { PrepareError = Definite("VALIDATION_FAILED", 422) };
            var definiteQueue = Queue(definiteGateway);
            string definiteSha; long definiteSize;
            var definiteItem = AddReadyItem(definiteQueue, out definiteSha, out definiteSize);
            Await(definiteQueue.RunAsync(CancellationToken.None));
            check(definiteItem.Stage == ClientReleaseQueueStage.Rejected && definiteItem.PendingOperation == null,
                "definite 4xx rejection lands in rejected");

            var publishGateway = new FakeGateway { PublishError = Definite("CONFLICT", 409) };
            var publishQueue = Queue(publishGateway);
            string publishSha; long publishSize;
            var publishItem = AddReadyItem(publishQueue, out publishSha, out publishSize);
            Await(publishQueue.RunAsync(CancellationToken.None));
            check(publishItem.Stage == ClientReleaseQueueStage.Uploaded,
                "definite publish rejection falls back to uploaded, ready to republish the same id");
        }

        private static void CheckReconcile(Action<bool, string> check)
        {
            var gateway = new FakeGateway();
            var queue = Queue(gateway);
            string sha; long size;
            AddReadyItem(queue, out sha, out size);
            var requestId = NewId();
            var item = RestoreInto(queue, requestId, "Unknown", "Publish", sha, size, "fixture.zip");
            gateway.OnRead = delegate (string path)
            { return Task.FromResult(Record(requestId, "PUBLISHED", sha, size, "fixture.zip")); };
            Await(queue.ReconcileAsync(item, CancellationToken.None));
            check(item.Stage == ClientReleaseQueueStage.Uploaded && item.PendingOperation == null && item.RetentionPending
                && item.Error != null && item.Error.Contains("保留检查"),
                "an unacknowledged published record waits for an explicit same-id continuation");

            var acknowledgedGateway = new FakeGateway();
            var acknowledgedQueue = Queue(acknowledgedGateway);
            string ackSha; long ackSize;
            AddReadyItem(acknowledgedQueue, out ackSha, out ackSize);
            var ackRequest = NewId();
            var acknowledgedItem = RestoreInto(acknowledgedQueue, ackRequest, "Unknown", "Publish", ackSha, ackSize,
                "fixture.zip", true);
            acknowledgedGateway.OnRead = delegate (string path)
            { return Task.FromResult(Record(ackRequest, "PUBLISHED", ackSha, ackSize, "fixture.zip")); };
            Await(acknowledgedQueue.ReconcileAsync(acknowledgedItem, CancellationToken.None));
            check(acknowledgedItem.Stage == ClientReleaseQueueStage.Published && acknowledgedItem.PendingOperation == null,
                "published original record resolves the unknown outcome once acknowledged");

            var draftGateway = new FakeGateway();
            var draftQueue = Queue(draftGateway);
            string draftSha; long draftSize;
            AddReadyItem(draftQueue, out draftSha, out draftSize);
            var draftRequest = NewId();
            var draftItem = RestoreInto(draftQueue, draftRequest, "Unknown", "Upload", draftSha, draftSize, "fixture.zip");
            draftGateway.OnRead = delegate (string path)
            { return Task.FromResult(Record(draftRequest, "DRAFT", draftSha, draftSize, "fixture.zip")); };
            Await(draftQueue.ReconcileAsync(draftItem, CancellationToken.None));
            check(draftItem.Stage == ClientReleaseQueueStage.Uploaded,
                "draft with identical bytes resolves to uploaded without re-upload");

            var missingGateway = new FakeGateway();
            missingGateway.OnRead = delegate (string path)
            { throw new ApiException("NOT_FOUND", "客户端版本不存在", 404, false, true); };
            var missingQueue = Queue(missingGateway);
            string missingSha; long missingSize;
            AddReadyItem(missingQueue, out missingSha, out missingSize);
            var missingRequest = NewId();
            var missingItem = RestoreInto(missingQueue, missingRequest, "Unknown", "Prepare", missingSha, missingSize, "fixture.zip");
            Await(missingQueue.ReconcileAsync(missingItem, CancellationToken.None));
            check(missingItem.Stage == ClientReleaseQueueStage.Prepared && missingItem.PendingOperation == null
                && missingItem.RequestId == missingRequest, "404 during unknown prepare keeps the same UUID for an explicit retry");
        }

        private static void CheckWithdrawCycle(Action<bool, string> check)
        {
            var gateway = new FakeGateway();
            var queue = Queue(gateway);
            var record = ClientReleaseAdminContract.ParseRecord(Record(NewId(), "PUBLISHED", ShaText, 64, "fixture.zip"));
            Await(queue.WithdrawAsync(record, CancellationToken.None));
            check(queue.Withdrawals[record.Id] == ClientReleaseWithdrawState.Confirmed, "successful withdrawal confirmed");

            var unknownGateway = new FakeGateway { WithdrawError = UnknownTransport() };
            var unknownQueue = Queue(unknownGateway);
            var unknownRecord = ClientReleaseAdminContract.ParseRecord(Record(NewId(), "PUBLISHED", ShaText, 64, "fixture.zip"));
            Await(unknownQueue.WithdrawAsync(unknownRecord, CancellationToken.None));
            check(unknownQueue.Withdrawals[unknownRecord.Id] == ClientReleaseWithdrawState.Unknown,
                "dispatched withdrawal without a reply stays unknown");
            Await(unknownQueue.WithdrawAsync(unknownRecord, CancellationToken.None));
            check(unknownQueue.Withdrawals[unknownRecord.Id] == ClientReleaseWithdrawState.Unknown,
                "an unknown withdrawal is never repeated before reconciliation");
            unknownGateway.WithdrawError = null;
            unknownGateway.OnRead = delegate (string path)
            { return Task.FromResult(Record(unknownRecord.Id, "WITHDRAWN", ShaText, 64, "fixture.zip")); };
            Await(unknownQueue.ReconcileWithdrawalAsync(unknownRecord.Id, CancellationToken.None));
            check(unknownQueue.Withdrawals[unknownRecord.Id] == ClientReleaseWithdrawState.Confirmed,
                "reading the original record confirms the withdrawal");
        }

        private static void CheckValidateRecord(Action<bool, string> check, Action<Action, string> reject)
        {
            var metadata = WindowsUpdate();
            var good = ClientReleaseAdminContract.ParseRecord(Record(NewId(), "DRAFT", null, 0, "fixture.zip"));
            ClientReleaseAdminContract.ValidateRecord(good, metadata, good.Id, "fixture.zip", ShaText, 64);
            check(true, "matching record validates");
            reject(delegate
            { ClientReleaseAdminContract.ValidateRecord(good, metadata, NewId(), "fixture.zip", ShaText, 64); },
                "record id must equal the frozen requestId");
            reject(delegate
            { ClientReleaseAdminContract.ValidateRecord(good, metadata, good.Id, "other.zip", ShaText, 64); },
                "file name must match the frozen intent");
            reject(delegate
            {
                var wrongMode = ClientReleaseAdminContract.ParseRecord(Record(NewId(), "DRAFT", null, 0, "fixture.zip", installMode: "windows_setup"));
                ClientReleaseAdminContract.ValidateRecord(wrongMode, metadata, wrongMode.Id, "fixture.zip", ShaText, 64);
            }, "install mode must match the declared package kind");
            reject(delegate
            {
                var wrongBytes = ClientReleaseAdminContract.ParseRecord(Record(NewId(), "PUBLISHED", ShaText, 63, "fixture.zip"));
                ClientReleaseAdminContract.ValidateRecord(wrongBytes, metadata, wrongBytes.Id, "fixture.zip", ShaText, 64);
            }, "published bytes must match the local hash and size");
            reject(delegate
            {
                var legacyContract = ClientReleaseAdminContract.ParseRecord(Record(NewId(), "DRAFT", null, 0, "fixture.zip", contract: null));
                ClientReleaseAdminContract.ValidateDeliveryContract(legacyContract, metadata);
            }, "windows rows require the paired_v1 contract");
            var android = WindowsUpdate();
            android.Platform = "android"; android.Architecture = "arm64";
            var androidRecord = ClientReleaseAdminContract.ParseRecord(Record(NewId(), "DRAFT", null, 0, "fixture.apk",
                platform: "android", architecture: "arm64", installMode: "android_package", contract: "audited_v1"));
            ClientReleaseAdminContract.ValidateDeliveryContract(androidRecord, android);
            check(true, "android rows satisfy audited_v1");
        }

        private static void CheckPairGroups(Action<bool, string> check)
        {
            var installer = ClientReleaseAdminContract.ParseRecord(Record(NewId(), "PUBLISHED", ShaText, 64, "setup.exe", kind: "installer", installMode: "windows_setup"));
            var update = ClientReleaseAdminContract.ParseRecord(Record(NewId(), "PUBLISHED", ShaText, 64, "fixture.zip", kind: "update", installMode: "windows_archive"));
            var complete = ClientReleaseAdminContract.BuildPairGroups(new[] { installer, update }, null);
            check(complete.Count == 1 && complete[0].Complete, "installer plus update of one build is a complete group");
            var half = ClientReleaseAdminContract.BuildPairGroups(new[] { installer }, null);
            check(half.Count == 1 && !half[0].Complete, "a lone installer waits for its pair");
            var withdrawnUpdate = ClientReleaseAdminContract.ParseRecord(Record(NewId(), "WITHDRAWN", ShaText, 64, "old.zip", buildNumber: "2530"));
            var mixed = ClientReleaseAdminContract.BuildPairGroups(new[] { installer, withdrawnUpdate }, null);
            check(mixed.Count == 1 && !mixed[0].Complete, "withdrawn records never complete a group");
        }

        private static void CheckDraftSnapshot(Action<bool, string> check, Action<Action, string> reject)
        {
            var publishedRow = RowViaSnapshot(NewId(), "Published", null, ShaText, 64, "fixture.zip");
            var queueWithPublished = Queue(new FakeGateway());
            queueWithPublished.Restore(new ClientReleasePublishContract.ValidatedSnapshot
            {
                Rows = new List<ClientReleaseQueueItem> { publishedRow },
                Withdrawals = new Dictionary<string, ClientReleaseWithdrawState>(),
                Context = null,
                HasUnknownSubmission = true
            });
            var snapshot = ClientReleasePublishContract.BuildSnapshot(queueWithPublished.Items,
                WindowsUpdate().ToDictionary(), queueWithPublished.Withdrawals);
            var json = Serializer.Serialize(snapshot);
            var parsed = Serializer.DeserializeObject(json) as Dictionary<string, object>;
            check(Convert.ToBoolean(parsed[ClientReleasePublishContract.UnknownSubmissionKey]),
                "a stored published row always carries the unknown-submission flag");
            var restored = ClientReleasePublishContract.ValidateAndRestore(json);
            check(restored.Rows.Count == 1 && restored.Rows[0].Stage == ClientReleaseQueueStage.Unknown
                && restored.Rows[0].PendingOperation == ClientReleaseQueueOperation.Publish,
                "restore never trusts a stored published stage");
            check(restored.Rows[0].SourcePath == null, "drafts never contain local file paths");

            var clean = Queue(new FakeGateway());
            string cleanSha; long cleanSize;
            var cleanItem = AddReadyItem(clean, out cleanSha, out cleanSize);
            var cleanJson = Serializer.Serialize(ClientReleasePublishContract.BuildSnapshot(clean.Items,
                WindowsUpdate().ToDictionary(), clean.Withdrawals));
            var cleanRestored = ClientReleasePublishContract.ValidateAndRestore(cleanJson);
            check(cleanRestored.Rows[0].Stage == ClientReleaseQueueStage.NeedsFile,
                "a row without requestId re-enters needing its file re-selected");

            var tampered = Serializer.DeserializeObject(cleanJson) as Dictionary<string, object>;
            tampered["extra"] = "value";
            reject(delegate { ClientReleasePublishContract.ValidateAndRestore(Serializer.Serialize(tampered)); },
                "unknown top-level keys are rejected");

            var uncertainRow = RowViaSnapshot(NewId(), "Uploaded", "Upload", ShaText, 64, "fixture.zip");
            var noFlag = Serializer.Serialize(ClientReleasePublishContract.BuildSnapshot(
                new[] { uncertainRow }, WindowsUpdate().ToDictionary(), null));
            var noFlagRoot = Serializer.DeserializeObject(noFlag) as Dictionary<string, object>;
            noFlagRoot[ClientReleasePublishContract.UnknownSubmissionKey] = false;
            reject(delegate { ClientReleasePublishContract.ValidateAndRestore(Serializer.Serialize(noFlagRoot)); },
                "an uncertain row without the unknown flag is rejected");
        }

        private static void CheckDraftStore(Action<bool, string> check)
        {
            var root = Path.Combine(Path.GetTempPath(), "uten-publish-store-" + Guid.NewGuid().ToString("N"));
            var store = new DpapiPublishDraftStore(root);
            const string key = "aaaa1111bbbb2222cccc3333dddd4444eeee/11111111-2222-3333-4444-555555555555";
            check(store.Read(key) == null, "a fresh namespace has no drafts");
            check(store.CompareAndSet(key, null, "{\"schemaVersion\":1}"), "first save wins the CAS");
            check(store.Read(key) == "{\"schemaVersion\":1}", "draft reads back verbatim");
            check(!store.CompareAndSet(key, null, "{\"schemaVersion\":2}"), "a second editor cannot claim the same draft");
            check(store.CompareAndSet(key, "{\"schemaVersion\":1}", "{\"schemaVersion\":2}"), "owner updates by CAS");
            check(!store.CompareAndDelete(key, "{\"schemaVersion\":1}"), "stale delete refuses");
            check(store.CompareAndDelete(key, "{\"schemaVersion\":2}"), "owner deletes by CAS");
            check(store.Read(key) == null, "deleted draft is gone");
            store.CompareAndSet(key, null, "{}");
            var listing = store.List("aaaa1111bbbb2222cccc3333dddd4444eeee");
            check(listing.Count == 1 && listing[0].DraftId == "11111111-2222-3333-4444-555555555555", "namespace listing finds the draft");
            try { Directory.Delete(root, true); } catch (IOException) { }
        }

    }
}
