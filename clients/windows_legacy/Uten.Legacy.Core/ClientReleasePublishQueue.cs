using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Security.Cryptography;
using System.Threading;
using System.Threading.Tasks;

namespace Uten.Legacy.Core
{
    /// <summary>The single publish gateway contract. Implementations must freeze the publish
    /// identity (token/scope) for the whole operation and report transport failures through
    /// ApiException so the queue can classify definite rejections versus unknown outcomes.</summary>
    public interface IClientReleaseGateway
    {
        Task<string> ReadAsync(string relativePath);
        /// <summary>POST prepare/publish/withdraw. requireStepUp routes the call through the
        /// step-up re-authentication entry; callers never see that handshake.</summary>
        Task<string> SendAsync(string relativePath, string bodyJson, bool requireStepUp);
        Task<string> UploadAsync(string releaseId, string sourcePath, long expectedBytes,
            string expectedSha256, IProgress<long> progress);
    }

    /// <summary>Native port of the reviewed Flutter publish queue state machine. Three invariants
    /// hold everywhere: confirmed rows are never re-uploaded, unknown outcomes are only resolved
    /// by reading the original record, and a frozen requestId is never replaced.</summary>
    public sealed class ClientReleasePublishQueue
    {
        private readonly IClientReleaseGateway gateway;
        private readonly Func<bool> saveDraft;
        private readonly List<ClientReleaseQueueItem> items = new List<ClientReleaseQueueItem>();
        private readonly Dictionary<string, ClientReleaseWithdrawState> withdrawals = new Dictionary<string, ClientReleaseWithdrawState>(StringComparer.Ordinal);
        private List<ClientReleaseRecord> releases = new List<ClientReleaseRecord>();

        public event Action Changed;
        public bool Busy { get; private set; }
        public bool Retired { get; private set; }
        public string Error { get; private set; }
        public IReadOnlyList<ClientReleaseQueueItem> Items { get { return items; } }
        public IReadOnlyList<ClientReleaseRecord> Releases { get { return releases; } }
        public IReadOnlyDictionary<string, ClientReleaseWithdrawState> Withdrawals { get { return withdrawals; } }

        public ClientReleasePublishQueue(IClientReleaseGateway gateway, Func<bool> saveDraft)
        {
            if (gateway == null) throw new ArgumentNullException("gateway");
            this.gateway = gateway;
            this.saveDraft = saveDraft ?? delegate { return true; };
        }

        public bool HasUnknown
        {
            get
            {
                return items.Any(item => item.Uncertain)
                    || withdrawals.Values.Any(state => state == ClientReleaseWithdrawState.Sending || state == ClientReleaseWithdrawState.Unknown);
            }
        }
        public int ConfirmedCount { get { return items.Count(item => item.Stage == ClientReleaseQueueStage.Published); } }
        public int WithdrawnCount { get { return items.Count(item => item.Stage == ClientReleaseQueueStage.Withdrawn); } }
        public int UncertainCount { get { return items.Count(item => item.Uncertain); } }
        public int RemainingCount { get { return items.Count(item => !item.Terminal && !item.Uncertain); } }

        private bool Current { get { return !Retired; } }
        private void Notify()
        {
            var changed = Changed;
            if (changed != null) changed();
        }
        private void SaveOrFlag()
        {
            if (!saveDraft()) Error = "本机草稿尚未保存，请保留此页面并重试保全。";
        }

        public ClientReleaseQueueItem AddFile(string sourcePath, long sizeBytes, ClientReleasePublishMetadata metadata)
        {
            if (!Current || Busy) return null;
            if (items.Count >= ClientReleasePublishLimits.MaximumFiles)
                throw new InvalidOperationException("一个发布队列最多100项，请分批添加；原队列未变更。");
            if (String.IsNullOrEmpty(sourcePath) || sizeBytes <= 0 || sizeBytes > ClientReleasePublishLimits.MaxClientPackageBytes)
                throw new InvalidOperationException("文件必须非空且不超过512 MiB；原队列未变更。");
            var clone = metadata.Clone();
            // The extension only suggests a package kind; the server inspection stays authoritative.
            if (clone.Platform == "windows")
            {
                var extension = Path.GetExtension(sourcePath);
                if (String.Equals(extension, ".exe", StringComparison.OrdinalIgnoreCase)) clone.PackageKind = "installer";
                else if (String.Equals(extension, ".zip", StringComparison.OrdinalIgnoreCase)) clone.PackageKind = "update";
            }
            var item = new ClientReleaseQueueItem
            {
                LocalId = NewLocalId(),
                Metadata = clone,
                SourcePath = sourcePath,
                SourceSize = sizeBytes,
                FileName = Path.GetFileName(sourcePath),
                SizeBytes = sizeBytes,
                Stage = ClientReleaseQueueStage.Ready
            };
            items.Add(item);
            Notify();
            return item;
        }

        public ClientReleaseQueueItem AddStore(ClientReleasePublishMetadata metadata)
        {
            if (!Current || Busy) return null;
            if (items.Count >= ClientReleasePublishLimits.MaximumFiles)
                throw new InvalidOperationException("发布队列已满。");
            var item = new ClientReleaseQueueItem
            {
                LocalId = NewLocalId(),
                Metadata = metadata.Clone(),
                Stage = ClientReleaseQueueStage.Ready
            };
            items.Add(item);
            Notify();
            return item;
        }

        public void Edit(ClientReleaseQueueItem item, ClientReleasePublishMetadata metadata)
        {
            if (item == null || !Current || Busy || item.Frozen || !items.Contains(item)) return;
            item.Metadata = metadata.Clone();
            item.Error = null;
            item.Stage = item.SourcePath == null && !item.Metadata.IsStore
                ? ClientReleaseQueueStage.NeedsFile
                : ClientReleaseQueueStage.Ready;
            Notify();
        }

        public void ReplaceFile(ClientReleaseQueueItem item, string sourcePath, long sizeBytes)
        {
            if (item == null || !Current || Busy || item.Terminal || item.Uncertain || !items.Contains(item)) return;
            if (String.IsNullOrEmpty(sourcePath) || sizeBytes <= 0 || sizeBytes > ClientReleasePublishLimits.MaxClientPackageBytes)
                throw new InvalidOperationException("文件必须非空且不超过512 MiB。");
            item.SourcePath = sourcePath;
            item.SourceSize = sizeBytes;
            // A frozen row keeps its original name and size: the intent must not be rewritten.
            if (!item.Frozen)
            {
                item.FileName = Path.GetFileName(sourcePath);
                item.SizeBytes = sizeBytes;
            }
            item.Error = null;
            Notify();
        }

        public void Remove(ClientReleaseQueueItem item)
        {
            if (item == null || !Current || Busy || item.Uncertain || item.Published
                || (item.Frozen && item.Stage != ClientReleaseQueueStage.Rejected && item.Stage != ClientReleaseQueueStage.Withdrawn))
                return;
            items.Remove(item);
            Notify();
        }

        /// <summary>Runs prepare, then upload, then publish for every eligible row. Confirmed or
        /// already-uploaded rows are skipped; one row's failure never rolls back the others.</summary>
        public async Task RunAsync(CancellationToken cancellationToken)
        {
            if (!Current || Busy) return;
            Busy = true;
            Error = null;
            Notify();
            try
            {
                foreach (var item in items.ToList())
                {
                    if (!Current) return;
                    if (item.Terminal || item.Uncertain || item.Stage == ClientReleaseQueueStage.Uploaded) continue;
                    try { await PrepareAndUploadAsync(item, cancellationToken).ConfigureAwait(true); }
                    catch (Exception error) { RecordFailure(item, error); }
                }
                foreach (var item in items.ToList())
                {
                    if (!Current) return;
                    if (item.Stage != ClientReleaseQueueStage.Uploaded || item.Uncertain) continue;
                    item.Stage = ClientReleaseQueueStage.Publishing;
                    item.PendingOperation = ClientReleaseQueueOperation.Publish;
                    item.Dispatched = false;
                    Notify();
                    SaveOrFlag();
                    item.Dispatched = true;
                    try
                    {
                        var json = await gateway.SendAsync("admin/client-releases/" + item.ReleaseId + "/publish", null, true).ConfigureAwait(true);
                        var record = ClientReleaseAdminContract.ParseRecord(json);
                        ClientReleaseAdminContract.ValidateRecord(record, item.Metadata, item.RequestId, item.FileName, item.Sha256, item.SizeBytes);
                        if (record.State != "PUBLISHED") throw new FormatException("服务器未返回明确的已发布状态");
                        item.PublishedRelease = record;
                        item.Stage = ClientReleaseQueueStage.Published;
                        item.PendingOperation = null;
                        item.SourcePath = null;
                        item.Progress = 1;
                        item.RetentionPending = false;
                        item.PublishAcknowledged = true;
                        SaveOrFlag();
                        Notify();
                    }
                    catch (Exception error) { RecordFailure(item, error); }
                }
                if (Current)
                {
                    try { await LoadAsync(cancellationToken).ConfigureAwait(true); }
                    catch (Exception) { Error = "发布结果已逐项保留，列表刷新暂未完成。"; }
                }
            }
            catch (Exception error) { Error = Describe(error); }
            finally
            {
                Busy = false;
                Notify();
            }
        }

        private async Task PrepareAndUploadAsync(ClientReleaseQueueItem item, CancellationToken cancellationToken)
        {
            var validation = item.Metadata.ValidationError();
            if (validation != null) throw new InvalidOperationException(validation);
            var duplicate = items.FirstOrDefault(other => other != item && !other.Published && other.Metadata.KindKey == item.Metadata.KindKey);
            if (duplicate != null) throw new InvalidOperationException("同一组合、版本和包类型存在多个项目，请核对后保留一个。");
            if (!item.Metadata.IsStore)
            {
                var allowed = AllowedExtensions(item.Metadata);
                var extension = Path.GetExtension(item.SourcePath ?? "");
                if (!allowed.Contains(extension.ToLowerInvariant()))
                    throw new InvalidOperationException("所选文件格式与声明的目标类型不匹配。");
                item.Stage = ClientReleaseQueueStage.Validating;
                Notify();
                var loaded = await ReadFileAsync(item, cancellationToken).ConfigureAwait(true);
                if (item.Sha256 != null && item.Sha256 != loaded.Sha256)
                    throw new InvalidOperationException("重选文件与原SHA-256不同，不能替换原发布意图。");
                item.Sha256 = loaded.Sha256;
                item.SizeBytes = loaded.SizeBytes;
            }
            if (item.RequestId == null) item.RequestId = NewLocalId();
            item.PendingOperation = ClientReleaseQueueOperation.Prepare;
            item.Dispatched = false;
            SaveOrFlag();
            item.Dispatched = true;
            var body = JsonValue.Serialize(item.Metadata.ToRequestBody(item.RequestId, item.FileName, item.Sha256));
            var prepareJson = await gateway.SendAsync("admin/client-releases", body, false).ConfigureAwait(true);
            var raw = JsonValue.ParseObject(prepareJson);
            var draft = ClientReleaseRecord.Parse(raw);
            ClientReleaseAdminContract.ValidateRecord(draft, item.Metadata, item.RequestId, item.FileName, item.Sha256, item.SizeBytes);
            ClientReleaseAdminContract.ValidateDeliveryContract(draft, item.Metadata);
            item.ReleaseId = draft.Id;
            item.PendingOperation = null;
            if (draft.State == "WITHDRAWN")
            {
                item.PublishedRelease = draft;
                item.Stage = ClientReleaseQueueStage.Withdrawn;
                item.RetentionPending = false;
                item.SourcePath = null;
                SaveOrFlag();
                return;
            }
            if (draft.State == "PUBLISHED")
            {
                item.PublishedRelease = draft;
                item.RetentionPending = item.Metadata.Platform == "windows" && !item.PublishAcknowledged;
                item.Stage = item.RetentionPending ? ClientReleaseQueueStage.Uploaded : ClientReleaseQueueStage.Published;
                item.SourcePath = null;
                item.Progress = 1;
                SaveOrFlag();
                return;
            }
            if (!item.Metadata.IsStore && draft.Sha256 == item.Sha256 && draft.SizeBytes == item.SizeBytes)
            {
                item.Stage = ClientReleaseQueueStage.Uploaded;
                item.SourcePath = null;
                SaveOrFlag();
                return;
            }
            item.Stage = ClientReleaseQueueStage.Prepared;
            SaveOrFlag();
            if (item.Metadata.IsStore)
            {
                item.Stage = ClientReleaseQueueStage.Uploaded;
                SaveOrFlag();
                return;
            }
            item.Stage = ClientReleaseQueueStage.Uploading;
            item.PendingOperation = ClientReleaseQueueOperation.Upload;
            item.Dispatched = false;
            Notify();
            SaveOrFlag();
            item.Dispatched = true;
            var progress = new UploadProgress(this, item);
            var uploadJson = await gateway.UploadAsync(item.ReleaseId, item.SourcePath, item.SizeBytes, item.Sha256, progress).ConfigureAwait(true);
            var uploadedRaw = JsonValue.ParseObject(uploadJson);
            var uploaded = ClientReleaseRecord.Parse(uploadedRaw);
            ClientReleaseAdminContract.ValidateRecord(uploaded, item.Metadata, item.RequestId, item.FileName, item.Sha256, item.SizeBytes);
            if (uploaded.Sha256 != item.Sha256 || uploaded.SizeBytes != item.SizeBytes)
                throw new FormatException("服务器尚未确认原文件的大小和SHA-256");
            item.PendingOperation = null;
            item.Stage = ClientReleaseQueueStage.Uploaded;
            item.SourcePath = null;
            SaveOrFlag();
            Notify();
        }

        private static string[] AllowedExtensions(ClientReleasePublishMetadata metadata)
        {
            if (metadata.Platform == "windows") return metadata.PackageKind == "installer" ? new[] { ".exe" } : new[] { ".zip" };
            return new[] { ".apk" };
        }

        /// <summary>Reads the picked file to hash it before prepare. The size must match the
        /// picker's observation and stay inside the package budget.</summary>
        public static async Task<LoadedFile> ReadFileAsync(ClientReleaseQueueItem item, CancellationToken cancellationToken)
        {
            if (String.IsNullOrEmpty(item.SourcePath)) throw new InvalidOperationException("请重新选择原文件后继续。");
            return await Task.Run(delegate
            {
                using (var sha = SHA256.Create())
                using (var stream = new FileStream(item.SourcePath, FileMode.Open, FileAccess.Read, FileShare.Read, 65536, FileOptions.SequentialScan))
                {
                    if (stream.Length > ClientReleasePublishLimits.MaxClientPackageBytes || stream.Length != item.SourceSize)
                        throw new FormatException("文件实际大小与选择结果不一致");
                    var buffer = new byte[65536];
                    long count = 0;
                    int read;
                    while ((read = stream.Read(buffer, 0, buffer.Length)) != 0)
                    {
                        cancellationToken.ThrowIfCancellationRequested();
                        count += read;
                        if (count > item.SourceSize || count > ClientReleasePublishLimits.MaxClientPackageBytes)
                            throw new FormatException("文件实际大小与选择结果不一致");
                        sha.TransformBlock(buffer, 0, read, null, 0);
                    }
                    if (count != item.SourceSize) throw new FormatException("原文件读取不完整，请重新选择");
                    sha.TransformFinalBlock(new byte[0], 0, 0);
                    return new LoadedFile { Sha256 = BitConverter.ToString(sha.Hash).Replace("-", "").ToLowerInvariant(), SizeBytes = count };
                }
            }, cancellationToken).ConfigureAwait(true);
        }

        public sealed class LoadedFile
        {
            public string Sha256 { get; internal set; }
            public long SizeBytes { get; internal set; }
        }

        private sealed class UploadProgress : IProgress<long>
        {
            private readonly ClientReleaseQueueItem item;
            private readonly ClientReleasePublishQueue owner;
            internal UploadProgress(ClientReleasePublishQueue owner, ClientReleaseQueueItem item)
            { this.owner = owner; this.item = item; }
            public void Report(long value)
            {
                if (item.Stage == ClientReleaseQueueStage.Uploading && item.SizeBytes > 0)
                {
                    item.Progress = Math.Max(0, Math.Min(1, (double)value / item.SizeBytes));
                    owner.Notify();
                }
            }
        }

        /// <summary>Resolves one unknown row by reading its original server record. A 404 during
        /// an unknown prepare only allows continuing the same UUID, never a fresh identity.</summary>
        public async Task ReconcileAsync(ClientReleaseQueueItem item, CancellationToken cancellationToken)
        {
            if (item == null || !Current || Busy || item.RequestId == null || item.Terminal) return;
            Busy = true;
            Error = null;
            Notify();
            try
            {
                var json = await gateway.ReadAsync("admin/client-releases/" + (item.ReleaseId ?? item.RequestId)).ConfigureAwait(true);
                var record = ClientReleaseAdminContract.ParseRecord(json);
                ClientReleaseAdminContract.ValidateRecord(record, item.Metadata, item.RequestId, item.FileName, item.Sha256, item.SizeBytes);
                if (record.State == "PUBLISHED")
                {
                    item.PublishedRelease = record;
                    item.RetentionPending = item.Metadata.Platform == "windows" && !item.PublishAcknowledged;
                    item.Stage = item.RetentionPending ? ClientReleaseQueueStage.Uploaded : ClientReleaseQueueStage.Published;
                    if (item.RetentionPending)
                        item.Error = "文件已发布，保留检查尚待完成。请明确继续原发布，不会重新创建或上传。";
                    item.Progress = 1;
                    item.SourcePath = null;
                }
                else if (record.State == "DRAFT")
                {
                    item.Stage = item.Metadata.IsStore || (record.Sha256 == item.Sha256 && record.SizeBytes == item.SizeBytes)
                        ? ClientReleaseQueueStage.Uploaded
                        : ClientReleaseQueueStage.Prepared;
                }
                else if (record.State == "WITHDRAWN")
                {
                    item.PublishedRelease = record;
                    item.Stage = ClientReleaseQueueStage.Withdrawn;
                    item.RetentionPending = false;
                    item.SourcePath = null;
                }
                else throw new InvalidOperationException("原发布记录已撤回或状态不匹配，请人工核对，不能复用。");
                item.PendingOperation = null;
                SaveOrFlag();
            }
            catch (ApiException error)
            {
                if (error.HasResponseCode && error.StatusCode == 404
                    && item.Stage == ClientReleaseQueueStage.Unknown && item.PendingOperation == ClientReleaseQueueOperation.Prepare)
                {
                    // An unread record cannot prove the timed-out create did not commit; only the
                    // same UUID with the same intent may continue.
                    item.PendingOperation = null;
                    item.Stage = ClientReleaseQueueStage.Prepared;
                    item.Error = "原编号暂未找到记录。可重选同SHA原文件，再明确继续原准备；不会更换编号。";
                    SaveOrFlag();
                }
                else item.Error = Describe(error);
            }
            catch (Exception error) { item.Error = Describe(error); }
            finally
            {
                Busy = false;
                Notify();
            }
        }

        public async Task LoadAsync(CancellationToken cancellationToken)
        {
            if (!Current) return;
            var json = await gateway.ReadAsync("admin/client-releases").ConfigureAwait(true);
            cancellationToken.ThrowIfCancellationRequested();
            releases = ClientReleaseAdminContract.ParseRecordList(json).ToList();
            Notify();
        }

        public async Task WithdrawAsync(ClientReleaseRecord record, CancellationToken cancellationToken)
        {
            if (record == null || !Current || Busy || record.State != "PUBLISHED") return;
            ClientReleaseAdminContract.RequireUuid(record.Id, "发布记录编号无效");
            ClientReleaseWithdrawState existing;
            if (withdrawals.TryGetValue(record.Id, out existing) && existing == ClientReleaseWithdrawState.Unknown) return;
            Busy = true;
            Error = null;
            Notify();
            var dispatched = false;
            try
            {
                withdrawals[record.Id] = ClientReleaseWithdrawState.Sending;
                Notify();
                SaveOrFlag();
                dispatched = true;
                var json = await gateway.SendAsync("admin/client-releases/" + record.Id + "/withdraw", null, true).ConfigureAwait(true);
                var response = ClientReleaseAdminContract.ParseRecord(json);
                if (response.Id != record.Id || response.State != "WITHDRAWN")
                    throw new FormatException("服务器未确认原版本已撤回");
                withdrawals[record.Id] = ClientReleaseWithdrawState.Confirmed;
                UpdateRecord(response);
                SaveOrFlag();
            }
            catch (Exception error)
            {
                ClientReleaseWithdrawState state;
                if (!withdrawals.TryGetValue(record.Id, out state) || state != ClientReleaseWithdrawState.Confirmed)
                {
                    var definite = IsDefinite(error);
                    withdrawals[record.Id] = definite || !dispatched
                        ? ClientReleaseWithdrawState.Ready
                        : ClientReleaseWithdrawState.Unknown;
                }
                Error = Describe(error);
                SaveOrFlag();
            }
            finally
            {
                Busy = false;
                Notify();
            }
        }

        public async Task ReconcileWithdrawalAsync(string recordId, CancellationToken cancellationToken)
        {
            ClientReleaseAdminContract.RequireUuid(recordId, "发布记录编号无效");
            if (!Current || Busy) return;
            Busy = true;
            Error = null;
            Notify();
            try
            {
                var json = await gateway.ReadAsync("admin/client-releases/" + recordId).ConfigureAwait(true);
                var response = ClientReleaseAdminContract.ParseRecord(json);
                if (response.Id != recordId || (response.State != "PUBLISHED" && response.State != "WITHDRAWN"))
                    throw new FormatException("原撤回记录状态不匹配");
                withdrawals[recordId] = response.State == "WITHDRAWN"
                    ? ClientReleaseWithdrawState.Confirmed
                    : ClientReleaseWithdrawState.Ready;
                UpdateRecord(response);
                SaveOrFlag();
            }
            catch (Exception error) { Error = Describe(error); }
            finally
            {
                Busy = false;
                Notify();
            }
        }

        private void UpdateRecord(ClientReleaseRecord response)
        {
            foreach (var item in items.Where(value => value.ReleaseId == response.Id && value.PublishedRelease != null))
            {
                item.PublishedRelease = response;
                if (response.State == "WITHDRAWN")
                {
                    item.Stage = ClientReleaseQueueStage.Withdrawn;
                    item.PendingOperation = null;
                    item.RetentionPending = false;
                }
            }
            for (var index = 0; index < releases.Count; index++)
                if (releases[index].Id == response.Id) releases[index] = response;
        }

        /// <summary>Classifies a failed or interrupted operation. A dispatched non-definite
        /// failure stays unknown with its pending operation; a definite 4xx rejection either
        /// falls back to uploaded (publish failed) or rejected. Confirmed rows only record the
        /// error and are never re-entered.</summary>
        private void RecordFailure(ClientReleaseQueueItem item, Exception failure)
        {
            if (item.Published)
            {
                item.Error = Describe(failure);
                return;
            }
            var definite = IsDefinite(failure);
            if (item.PendingOperation != null && item.Dispatched && !definite) item.Stage = ClientReleaseQueueStage.Unknown;
            else if (item.PendingOperation == ClientReleaseQueueOperation.Publish) item.Stage = ClientReleaseQueueStage.Uploaded;
            else item.Stage = ClientReleaseQueueStage.Rejected;
            if (definite || !item.Dispatched) item.PendingOperation = null;
            item.Error = Describe(failure);
            item.SourcePath = null;
            SaveOrFlag();
        }

        private static bool IsDefinite(Exception failure)
        {
            var api = failure as ApiException;
            return api != null && api.HasResponseCode && api.StatusCode >= 400 && api.StatusCode < 500;
        }

        public static string Describe(Exception failure)
        {
            var api = failure as ApiException;
            if (api != null) return api.UserMessage;
            if (failure is InvalidOperationException || failure is FormatException) return failure.Message;
            return "操作未确认完成，请先核对原记录；不要换编号重复提交。";
        }

        /// <summary>Retires the queue after an identity/permission/server change. Pending
        /// operations become unknown, in-memory file handles and errors are dropped, and the
        /// metadata is preserved once more so it can be saved under the original namespace.</summary>
        public void Retire()
        {
            Retired = true;
            foreach (var item in items)
            {
                item.SourcePath = null;
                item.PublishedRelease = null;
                item.Error = null;
                if (item.PendingOperation != null) item.Stage = ClientReleaseQueueStage.Unknown;
            }
            releases = new List<ClientReleaseRecord>();
            foreach (var key in withdrawals.Keys.ToList())
                if (withdrawals[key] == ClientReleaseWithdrawState.Sending) withdrawals[key] = ClientReleaseWithdrawState.Unknown;
            saveDraft();
        }

        /// <summary>Adopts rows and withdrawal states from a validated draft snapshot. The
        /// snapshot's own restore downgrades have already been applied by the contract.</summary>
        public void Restore(ClientReleasePublishContract.ValidatedSnapshot snapshot)
        {
            if (snapshot == null) throw new ArgumentNullException("snapshot");
            items.Clear();
            items.AddRange(snapshot.Rows);
            withdrawals.Clear();
            foreach (var entry in snapshot.Withdrawals) withdrawals.Add(entry.Key, entry.Value);
            Notify();
        }

        private static string NewLocalId() { return Guid.NewGuid().ToString("D"); }
    }
}
