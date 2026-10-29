using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Security.Cryptography;
using System.Text;
using System.Threading;

namespace Uten.Legacy.Core
{
    /// <summary>Separate CurrentUser DPAPI draft and mutation envelopes. A short namespace lock
    /// serializes cross-process CAS. A held attempt lease distinguishes a live Sending from a
    /// crashed process; only an unlocked Sending recovers as Unknown. No auth record is read.</summary>
    public sealed partial class DpapiBusinessStateStore : IBusinessStateStore, IUnitExportReceiptStore
    {
        private const int MaximumPlainBytes = 8388608;
        private const int MaximumEncryptedBytes = MaximumPlainBytes + 65536;
        private readonly object gate = new object();
        private readonly string root;
        private readonly Action<string> writeFault;
        private readonly Dictionary<string, FileStream> activeAttempts = new Dictionary<string, FileStream>(StringComparer.Ordinal);
        private bool disposed;

        public DpapiBusinessStateStore() : this(Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
            "Uten", "UIMP-Win7-WPF", "business-state", "v1"), null) { }
        internal DpapiBusinessStateStore(string rootDirectory, Action<string> writeFault = null)
        { root = Path.GetFullPath(rootDirectory); this.writeFault = writeFault; }

        public BusinessDraft SaveDraft(DraftWriteLease lease, long expectedRevision, string bodyJson)
        {
            if (lease == null || expectedRevision < 0) throw new ArgumentException();
            SessionCoordinator.ValidateDraftMetadata(lease.Action, lease.ResourceId, lease.ObservedStatus);
            SessionCoordinator.ValidateDraftBody(lease.Action, bodyJson);
            CanonicalId(lease.DraftId);
            lock (gate) using (NamespaceLock(lease.Owner))
            {
                var drafts = ReadDrafts(lease.Owner);
                BusinessDraft before;
                drafts.TryGetValue(lease.DraftId, out before);
                if ((before?.Revision ?? 0) != expectedRevision || before?.Revision == Int64.MaxValue)
                    throw Conflict("DRAFT_CONFLICT", "草稿已经变化，请保留当前输入并核对新旧内容。");
                if (before != null && (before.Action != lease.Action || before.ResourceId != lease.ResourceId))
                    throw Conflict("DRAFT_INTENT_CHANGED", "同一草稿不能更换动作或目标记录。");
                if (ReadJournal(lease.Owner, true).Values.Any(value => value.OriginDraftId == lease.DraftId && value.MayNeedManualReconciliation))
                    throw Conflict("DRAFT_PENDING_SUBMISSION", "原草稿已有结果待确认提交，不能覆盖；请保留未保存输入并先核对原操作。");
                if (before == null && drafts.Count >= 128) throw new IOException("本机草稿数量已到保全上限。");
                // Identical autosave cannot manufacture a fresh revision for an already
                // confirmed original. CAS still applies before this idempotent return.
                if (before != null && before.BodyJson == bodyJson && before.ObservedStatus == lease.ObservedStatus) return before;
                var after = new BusinessDraft(lease.DraftId, expectedRevision + 1, lease.Action, lease.ResourceId,
                    bodyJson, lease.ObservedStatus, DateTime.UtcNow, lease.Owner);
                drafts[after.DraftId] = after;
                WriteDocument(lease.Owner, "drafts", drafts.Values.Select(DraftValue).ToArray());
                return after;
            }
        }
        public IReadOnlyList<BusinessDraft> ListDrafts(MutationOwnerSnapshot owner)
        { lock (gate) using (NamespaceLock(owner)) return ReadDrafts(owner).Values.OrderByDescending(value => value.UpdatedAtUtc).ToList().AsReadOnly(); }
        public BusinessDraft LoadDraft(MutationOwnerSnapshot owner, string draftId)
        { CanonicalId(draftId); return ListDrafts(owner).FirstOrDefault(value => value.DraftId == draftId); }
        public void DeleteDraft(MutationOwnerSnapshot owner, string draftId, long expectedRevision)
        {
            CanonicalId(draftId);
            lock (gate) using (NamespaceLock(owner))
            {
                var drafts = ReadDrafts(owner);
                BusinessDraft before;
                if (!drafts.TryGetValue(draftId, out before) || before.Revision != expectedRevision)
                    throw Conflict("DRAFT_CONFLICT", "草稿已经变化，未删除原内容。");
                if (ReadJournal(owner, true).Values.Any(value => value.OriginDraftId == draftId && value.MayNeedManualReconciliation))
                    throw Conflict("DRAFT_PENDING_SUBMISSION", "此草稿有关联的结果待确认提交，不能删除保全内容。");
                drafts.Remove(draftId);
                WriteDocument(owner, "drafts", drafts.Values.Select(DraftValue).ToArray());
            }
        }

        public void BeginSending(MutationRequest request)
        {
            if (request == null) throw new ArgumentNullException(nameof(request));
            lock (gate) using (NamespaceLock(request.Owner))
            {
                var journal = ReadJournal(request.Owner, true);
                MutationJournalRecord prior;
                if (journal.TryGetValue(request.RequestId, out prior))
                {
                    if (prior.Action != request.Action || prior.ResourceId != request.ResourceId || prior.BodyJson != request.BodyJson
                        || prior.ObservedStatus != request.ObservedStatus || prior.OriginDraftId != request.OriginDraftId
                        || prior.OriginDraftRevision != request.OriginDraftRevision)
                        throw Conflict("MUTATION_INTENT_CHANGED", "此提交编号已经冻结为另一份原始内容，不能替换或重发。");
                    throw Conflict("MUTATION_ALREADY_RECORDED", "本机已有此提交编号的台账，未重新发送；请先核对原记录。");
                }
                if (request.Action == MutationAction.UnitExportSubmit && journal.Values.Any(value => value.Action == MutationAction.UnitExportSubmit
                    && value.ResourceId == request.ResourceId && value.BodyJson != request.BodyJson))
                    throw Conflict("MUTATION_SERVER_KEY_CHANGED", "原导出任务编号已经绑定另一份冻结条件；请保留原任务，新条件必须建立明确的新任务意图。");
                if (journal.Count >= 512) throw new IOException("本机提交台账已到保全上限。");
                if (request.OriginDraftId != null)
                {
                    var related = journal.Values.Where(value => value.OriginDraftId == request.OriginDraftId).ToList();
                    if (related.Any(value => value.MayNeedManualReconciliation))
                        throw Conflict("DRAFT_PENDING_SUBMISSION", "此草稿已有结果待确认提交，不能以新编号再次发送。");
                    if (related.Any(value => value.State == MutationJournalState.Confirmed && value.OriginDraftRevision == request.OriginDraftRevision))
                        throw Conflict("DRAFT_ALREADY_CONFIRMED", "此草稿版本已确认提交，不能以新编号重复发送；请核对原结果。");
                    BusinessDraft draft;
                    if (!ReadDrafts(request.Owner).TryGetValue(request.OriginDraftId, out draft)
                        || draft.Revision != request.OriginDraftRevision || draft.BodySha256 != request.BodySha256
                        || draft.Action != request.Action || draft.ResourceId != request.ResourceId)
                        throw Conflict("DRAFT_CONFLICT", "发送前草稿已变化，未发送旧编辑内容。");
                }
                if (journal.Values.Any(value => SessionCoordinator.PendingUnitCommandConflicts(request, value)))
                    throw Conflict("MUTATION_PENDING_RECONCILIATION", "关联单位的原提交结果尚未确认，本次未发送；请先核对原记录，不能通过更换提交编号重试。");
                // Lease exists before Sending is committed; another process may not mistake a
                // still-live network operation for a crashed attempt.
                var attemptPath = AttemptPath(request.Owner, request.RequestId);
                RejectExistingLink(attemptPath);
                var lease = new FileStream(attemptPath, FileMode.OpenOrCreate, FileAccess.ReadWrite, FileShare.None);
                var key = AttemptKey(request.Owner, request.RequestId);
                try
                {
                    var now = DateTime.UtcNow;
                    journal.Add(request.RequestId, new MutationJournalRecord(request, MutationJournalState.Sending, now, now));
                    WriteDocument(request.Owner, "mutations", journal.Values.Select(JournalValue).ToArray());
                    activeAttempts.Add(key, lease);
                    lease = null;
                }
                finally { lease?.Dispose(); }
            }
        }

        public void Complete(MutationResult result)
        {
            if (result == null) throw new ArgumentNullException(nameof(result));
            var request = result.Request;
            lock (gate)
            {
                var key = AttemptKey(request.Owner, request.RequestId);
                FileStream lease;
                if (!activeAttempts.TryGetValue(key, out lease)) throw new IOException("本机发送门没有本次操作的有效租约。");
                try
                {
                    using (NamespaceLock(request.Owner))
                    {
                        var journal = ReadJournal(request.Owner, false);
                        MutationJournalRecord before;
                        if (!journal.TryGetValue(request.RequestId, out before) || before.State != MutationJournalState.Sending
                            || before.BodySha256 != request.BodySha256) throw new InvalidDataException("冻结的提交记录不一致。");
                        var state = result.Outcome == MutationOutcome.Confirmed ? MutationJournalState.Confirmed
                            : result.Outcome == MutationOutcome.Rejected ? MutationJournalState.Rejected
                            : result.Outcome == MutationOutcome.NotSent ? MutationJournalState.NotSent : MutationJournalState.Unknown;
                        string confirmedId = null;
                        if (result.Outcome == MutationOutcome.Confirmed)
                        {
                            MutationResponseContract.Validate(request, result.ResponseJson);
                            if (request.ResponseKind == MutationResponseKind.UnitDetail || request.ResponseKind == MutationResponseKind.ExportJob
                                || request.ResponseKind == MutationResponseKind.PlatformDefinition || request.ResponseKind == MutationResponseKind.PlatformRow)
                            {
                                confirmedId = request.ResponseKind == MutationResponseKind.ExportJob
                                    ? UnitExportMutationContract.ReadJob(request, result.ResponseJson).Id
                                    : MutationJsonTree.Uuid(MutationJsonTree.Required(MutationJsonTree.Parse(result.ResponseJson, 2097152, true, 65536, true).Object,
                                        request.ResponseKind == MutationResponseKind.PlatformRow ? "recordId" : "id"));
                            }
                        }
                        journal[request.RequestId] = new MutationJournalRecord(request, state, before.CreatedAtUtc, DateTime.UtcNow,
                            result.Outcome == MutationOutcome.Confirmed ? (int?)200 : result.Error?.StatusCode,
                            SafeErrorCode(result.Error?.Code), confirmedId, before.ReviewNote,
                            result.Outcome == MutationOutcome.Confirmed && (request.ResponseKind == MutationResponseKind.BatchResult
                                || request.ResponseKind == MutationResponseKind.OperationHistory || request.ResponseKind == MutationResponseKind.ExportJob
                                || request.ResponseKind == MutationResponseKind.PlatformDefinition || request.ResponseKind == MutationResponseKind.PlatformRow) ? result.ResponseJson : null);
                        WriteDocument(request.Owner, "mutations", journal.Values.Select(JournalValue).ToArray());
                    }
                }
                finally { activeAttempts.Remove(key); lease.Dispose(); }
            }
        }
        public IReadOnlyList<MutationJournalRecord> ListJournal(MutationOwnerSnapshot owner)
        { lock (gate) using (NamespaceLock(owner)) return ReadJournal(owner, true).Values.OrderByDescending(value => value.CreatedAtUtc).ToList().AsReadOnly(); }
        public MutationJournalRecord LoadJournal(MutationOwnerSnapshot owner, string requestId)
        { CanonicalId(requestId); return ListJournal(owner).FirstOrDefault(value => value.RequestId == requestId); }
        public MutationJournalRecord AppendReviewNote(MutationOwnerSnapshot owner, string requestId, string note)
        {
            CanonicalId(requestId);
            if (String.IsNullOrWhiteSpace(note) || note.Length > 2000) throw new ArgumentException();
            lock (gate) using (NamespaceLock(owner))
            {
                var journal = ReadJournal(owner, true);
                MutationJournalRecord before;
                if (!journal.TryGetValue(requestId, out before)) throw Conflict("MUTATION_RECORD_NOT_FOUND", "未找到原始提交台账。");
                var notes = (before.ReviewNote == null ? "" : before.ReviewNote + "\n") + DateTime.UtcNow.ToString("O", CultureInfo.InvariantCulture) + " " + note;
                if (notes.Length > 8000) throw new IOException("人工核对记录已到保全上限。");
                var request = RecreateRequest(before, owner);
                var after = new MutationJournalRecord(request, before.State, before.CreatedAtUtc, DateTime.UtcNow,
                    before.StatusCode, before.ErrorCode, before.ConfirmedResourceId, notes, before.ResultJson, before.ConfirmedByReceiptQuery);
                journal[requestId] = after;
                WriteDocument(owner, "mutations", journal.Values.Select(JournalValue).ToArray());
                return after;
            }
        }

        private Dictionary<string, BusinessDraft> ReadDrafts(MutationOwnerSnapshot owner)
        {
            var values = new Dictionary<string, BusinessDraft>(StringComparer.Ordinal);
            foreach (var item in ReadEntries(owner, "drafts", 128))
            {
                var value = ObjectValue(item);
                var action = ActionValue(value);
                var draftKeys = new List<string> { "id", "revision", "action", "resourceId", "bodyJson", "bodySha256", "observedStatus", "updatedTicks" };
                if ((int)action >= 4) draftKeys.Add("contractVersion");
                Keys(value, draftKeys.ToArray());
                if ((int)action >= 4 && Integer(value, "contractVersion", 2, 4) != MutationRequest.ContractVersionFor(action)) throw new InvalidDataException();
                var id = Text(value, "id", 36); CanonicalId(id);
                var resource = NullableText(value, "resourceId", 36);
                var status = NullableText(value, "observedStatus", 16);
                var body = Text(value, "bodyJson", SessionCoordinator.UnitDraftBudget(action), true);
                try { SessionCoordinator.ValidateDraftMetadata(action, resource, status); SessionCoordinator.ValidateDraftBody(action, body); }
                catch (ApiException) { throw new InvalidDataException(); }
                var draft = new BusinessDraft(id, Integer(value, "revision", 1, Int64.MaxValue), action, resource, body, status,
                    Time(value, "updatedTicks"), owner);
                if (Text(value, "bodySha256", 64) != draft.BodySha256 || values.ContainsKey(id)) throw new InvalidDataException();
                values.Add(id, draft);
            }
            return values;
        }
        private Dictionary<string, MutationJournalRecord> ReadJournal(MutationOwnerSnapshot owner, bool recover)
        {
            var values = new Dictionary<string, MutationJournalRecord>(StringComparer.Ordinal);
            var changed = false;
            foreach (var item in ReadEntries(owner, "mutations", 512))
            {
                var value = ObjectValue(item);
                var contractVersion = Integer(value, "contractVersion", 1, 4);
                var journalKeys = new List<string> { "id", "action", "method", "path", "resourceId", "bodyJson", "bodySha256", "observedStatus", "state", "draftId", "draftRevision",
                    "createdTicks", "updatedTicks", "statusCode", "errorCode", "confirmedResourceId", "reviewNote",
                    "contractVersion", "versionStrategy", "receiptStrategy", "serverIdempotencyAvailable", "enforcesExpectedVersion" };
                if (contractVersion >= 2) journalKeys.AddRange(new[] { "responseKind", "resultJson" });
                if (contractVersion == 3) journalKeys.AddRange(new[] { "serverIdempotencyKey", "serverIdempotencyBodyField", "receiptPath", "confirmedByReceiptQuery" });
                Keys(value, journalKeys.ToArray());
                MutationRequest request;
                var action = ActionValue(value);
                try { request = SessionCoordinator.BuildMutationRequest(action, Text(value, "id", 36), NullableText(value, "bodyJson", action == MutationAction.UnitPlatformValuesWrite ? 524288 : 65536, true), owner,
                    NullableText(value, "resourceId", 36), NullableText(value, "observedStatus", 16)); }
                catch (ApiException) { throw new InvalidDataException(); }
                if (Text(value, "method", 8) != request.Method || Text(value, "path", 128) != request.RelativePath
                    || Text(value, "bodySha256", 64) != request.BodySha256) throw new InvalidDataException();
                if (contractVersion != request.ContractVersion
                    || Integer(value, "versionStrategy", 0, 5) != (int)request.VersionStrategy
                    || Integer(value, "receiptStrategy", 0, 2) != (int)request.ReceiptStrategy
                    || !(value["serverIdempotencyAvailable"] is bool) || (bool)value["serverIdempotencyAvailable"] != request.ServerIdempotencyAvailable
                    || !(value["enforcesExpectedVersion"] is bool) || (bool)value["enforcesExpectedVersion"] != request.EnforcesExpectedVersion) throw new InvalidDataException();
                string resultJson = null;
                var confirmedByReceiptQuery = false;
                if (contractVersion >= 2)
                {
                    if (Integer(value, "responseKind", 0, 6) != (int)request.ResponseKind) throw new InvalidDataException();
                    resultJson = NullableText(value, "resultJson", 2097152, true);
                }
                if (contractVersion == 3)
                {
                    if (NullableText(value, "serverIdempotencyKey", 36) != request.ServerIdempotencyKey
                        || NullableText(value, "serverIdempotencyBodyField", 32) != request.ServerIdempotencyBodyField
                        || NullableText(value, "receiptPath", 128) != request.ReceiptPath
                        || !(value["confirmedByReceiptQuery"] is bool)) throw new InvalidDataException();
                    confirmedByReceiptQuery = (bool)value["confirmedByReceiptQuery"];
                }
                var draftId = NullableText(value, "draftId", 36);
                var draftRevision = NullableInteger(value, "draftRevision", 1, Int64.MaxValue);
                if (draftId != null) { CanonicalId(draftId); if (!draftRevision.HasValue) throw new InvalidDataException(); request.LinkDraft(draftId, draftRevision.Value); }
                else if (draftRevision.HasValue) throw new InvalidDataException();
                var state = (MutationJournalState)Integer(value, "state", 1, 5);
                var updated = Time(value, "updatedTicks");
                if (recover && state == MutationJournalState.Sending && !AttemptIsLive(owner, request.RequestId))
                { state = MutationJournalState.Unknown; updated = DateTime.UtcNow; changed = true; }
                var confirmedId = NullableText(value, "confirmedResourceId", 36);
                if (confirmedId != null) CanonicalId(confirmedId);
                if (request.ResponseKind == MutationResponseKind.UnitDetail || request.ResponseKind == MutationResponseKind.ExportJob
                    || request.ResponseKind == MutationResponseKind.PlatformDefinition || request.ResponseKind == MutationResponseKind.PlatformRow)
                { if ((state == MutationJournalState.Confirmed) != (confirmedId != null)) throw new InvalidDataException(); }
                else if (confirmedId != null) throw new InvalidDataException();
                var hasStructuredResult = request.ResponseKind == MutationResponseKind.BatchResult || request.ResponseKind == MutationResponseKind.OperationHistory
                    || request.ResponseKind == MutationResponseKind.ExportJob || request.ResponseKind == MutationResponseKind.PlatformDefinition || request.ResponseKind == MutationResponseKind.PlatformRow;
                if (state == MutationJournalState.Confirmed && hasStructuredResult && resultJson == null) throw new InvalidDataException();
                if (resultJson != null && (state != MutationJournalState.Confirmed || !hasStructuredResult)) throw new InvalidDataException();
                if (confirmedByReceiptQuery && (state != MutationJournalState.Confirmed || request.Action != MutationAction.UnitExportSubmit || resultJson == null)) throw new InvalidDataException();
                var record = new MutationJournalRecord(request, state, Time(value, "createdTicks"), updated,
                    (int?)NullableInteger(value, "statusCode", 100, 599), SafeErrorCode(NullableText(value, "errorCode", 80)), confirmedId,
                    NullableText(value, "reviewNote", 8000, true), resultJson, confirmedByReceiptQuery);
                if (values.ContainsKey(record.RequestId)) throw new InvalidDataException(); values.Add(record.RequestId, record);
            }
            if (changed) WriteDocument(owner, "mutations", values.Values.Select(JournalValue).ToArray());
            return values;
        }
        private bool AttemptIsLive(MutationOwnerSnapshot owner, string id)
        {
            if (activeAttempts.ContainsKey(AttemptKey(owner, id))) return true;
            var path = AttemptPath(owner, id); RejectExistingLink(path);
            try { using (new FileStream(path, FileMode.OpenOrCreate, FileAccess.ReadWrite, FileShare.None)) return false; }
            catch (IOException error) when (SharingViolation(error)) { return true; }
        }

        private object[] ReadEntries(MutationOwnerSnapshot owner, string kind, int maximumCount)
        {
            var path = Path.Combine(NamespaceDirectory(owner), kind + ".dpapi");
            if (!File.Exists(path)) return new object[0];
            RejectExistingLink(path);
            if (new FileInfo(path).Length > MaximumEncryptedBytes) throw new InvalidDataException();
            byte[] plain = null;
            try
            {
                plain = ProtectedData.Unprotect(File.ReadAllBytes(path), Entropy(owner, kind), DataProtectionScope.CurrentUser);
                if (plain.Length > MaximumPlainBytes) throw new InvalidDataException();
                var document = JsonValue.ParseObject(new UTF8Encoding(false, true).GetString(plain), MaximumPlainBytes);
                Keys(document, "schema", "owner", "entries");
                if (Integer(document, "schema", 1, 1) != 1) throw new InvalidDataException();
                var identity = ObjectValue(document["owner"]);
                Keys(identity, "issuer", "userId", "datasetId", "resetGeneration");
                if (Text(identity, "issuer", 2048) != owner.IssuerApiBaseUrl || Text(identity, "userId", 128) != owner.UserId
                    || Text(identity, "datasetId", 36) != owner.BusinessDatasetId
                    || Integer(identity, "resetGeneration", 0, Int64.MaxValue) != owner.BusinessResetGeneration) throw new InvalidDataException();
                var entries = document["entries"] as object[];
                if (entries == null || entries.Length > maximumCount) throw new InvalidDataException();
                return entries;
            }
            finally { if (plain != null) Array.Clear(plain, 0, plain.Length); }
        }
        private void WriteDocument(MutationOwnerSnapshot owner, string kind, object[] entries)
        {
            var directory = NamespaceDirectory(owner);
            var path = Path.Combine(directory, kind + ".dpapi"); RejectExistingLink(path);
            var value = new Dictionary<string, object> { { "schema", 1 }, { "owner", OwnerValue(owner) }, { "entries", entries } };
            var plain = new UTF8Encoding(false, true).GetBytes(JsonValue.Serialize(value));
            byte[] encrypted;
            try
            {
                if (plain.Length > MaximumPlainBytes) throw new IOException("本机业务保全文件已到大小上限。");
                encrypted = ProtectedData.Protect(plain, Entropy(owner, kind), DataProtectionScope.CurrentUser);
            }
            finally { Array.Clear(plain, 0, plain.Length); }
            var temporary = Path.Combine(directory, kind + "-" + Guid.NewGuid().ToString("N") + ".tmp");
            try
            {
                using (var stream = new FileStream(temporary, FileMode.CreateNew, FileAccess.Write, FileShare.None, 4096, FileOptions.WriteThrough))
                {
                    stream.Write(encrypted, 0, encrypted.Length);
                    writeFault?.Invoke(kind + ":before-flush"); stream.Flush(true);
                }
                writeFault?.Invoke(kind + ":before-replace");
                RejectExistingLink(path);
                if (File.Exists(path)) File.Replace(temporary, path, null); else File.Move(temporary, path);
            }
            finally { if (File.Exists(temporary)) File.Delete(temporary); }
        }
        private FileStream NamespaceLock(MutationOwnerSnapshot owner)
        {
            if (disposed) throw new ObjectDisposedException(nameof(DpapiBusinessStateStore));
            var directory = NamespaceDirectory(owner);
            Directory.CreateDirectory(root); RejectExistingLink(root);
            Directory.CreateDirectory(directory); RejectExistingLink(directory);
            var path = Path.Combine(directory, "namespace.lock"); RejectExistingLink(path);
            var timer = Stopwatch.StartNew();
            while (true)
            {
                try { return new FileStream(path, FileMode.OpenOrCreate, FileAccess.ReadWrite, FileShare.None); }
                catch (IOException error) when (SharingViolation(error) && timer.ElapsedMilliseconds < 2500) { Thread.Sleep(15); }
            }
        }
        private string NamespaceDirectory(MutationOwnerSnapshot owner)
        {
            if (owner == null || String.IsNullOrWhiteSpace(owner.UserId) || String.IsNullOrEmpty(owner.BusinessDatasetId)
                || owner.BusinessResetGeneration < 0) throw new InvalidDataException();
            return Path.Combine(root, MutationRequest.Hash(Encoding.UTF8.GetBytes(JsonValue.Serialize(OwnerValue(owner)))));
        }
        private byte[] Entropy(MutationOwnerSnapshot owner, string kind)
        { return Encoding.UTF8.GetBytes("Uten/UIMP-Win7-WPF/business-state/v1/" + kind + "/" + Path.GetFileName(NamespaceDirectory(owner))); }
        private string AttemptPath(MutationOwnerSnapshot owner, string id) { CanonicalId(id); return Path.Combine(NamespaceDirectory(owner), "attempt-" + id + ".lock"); }
        private string AttemptKey(MutationOwnerSnapshot owner, string id) { return NamespaceDirectory(owner) + "/" + id; }
        private static bool SharingViolation(IOException error) { var code = error.HResult & 0xffff; return code == 32 || code == 33; }
        private static void RejectExistingLink(string path)
        { if ((File.Exists(path) || Directory.Exists(path)) && (File.GetAttributes(path) & FileAttributes.ReparsePoint) != 0) throw new IOException("业务保全目录或文件不能是链接。"); }
        private static Dictionary<string, object> OwnerValue(MutationOwnerSnapshot owner)
        { return new Dictionary<string, object> { { "issuer", owner.IssuerApiBaseUrl }, { "userId", owner.UserId }, { "datasetId", owner.BusinessDatasetId }, { "resetGeneration", owner.BusinessResetGeneration } }; }
        private static Dictionary<string, object> DraftValue(BusinessDraft value)
        { var result = new Dictionary<string, object> { { "id", value.DraftId }, { "revision", value.Revision }, { "action", (int)value.Action }, { "resourceId", value.ResourceId },
            { "bodyJson", value.BodyJson }, { "bodySha256", value.BodySha256 }, { "observedStatus", value.ObservedStatus }, { "updatedTicks", value.UpdatedAtUtc.Ticks } };
            if (value.ContractVersion >= 2) result.Add("contractVersion", value.ContractVersion); return result; }
        private static Dictionary<string, object> JournalValue(MutationJournalRecord value)
        { var result = new Dictionary<string, object> { { "id", value.RequestId }, { "action", (int)value.Action }, { "method", value.Method }, { "path", value.RelativePath }, { "resourceId", value.ResourceId },
            { "bodyJson", value.BodyJson }, { "bodySha256", value.BodySha256 }, { "observedStatus", value.ObservedStatus }, { "state", (int)value.State },
            { "draftId", value.OriginDraftId }, { "draftRevision", value.OriginDraftRevision }, { "createdTicks", value.CreatedAtUtc.Ticks }, { "updatedTicks", value.UpdatedAtUtc.Ticks },
            { "statusCode", value.StatusCode }, { "errorCode", value.ErrorCode }, { "confirmedResourceId", value.ConfirmedResourceId }, { "reviewNote", value.ReviewNote },
            { "contractVersion", value.ContractVersion }, { "versionStrategy", (int)value.VersionStrategy }, { "receiptStrategy", (int)value.ReceiptStrategy },
            { "serverIdempotencyAvailable", value.ServerIdempotencyAvailable }, { "enforcesExpectedVersion", value.EnforcesExpectedVersion } };
            if (value.ContractVersion >= 2) { result.Add("responseKind", (int)value.ResponseKind); result.Add("resultJson", value.ResultJson); }
            if (value.ContractVersion == 3) { result.Add("serverIdempotencyKey", value.ServerIdempotencyKey); result.Add("serverIdempotencyBodyField", value.ServerIdempotencyBodyField);
                result.Add("receiptPath", value.ReceiptPath); result.Add("confirmedByReceiptQuery", value.ConfirmedByReceiptQuery); } return result; }
        private static MutationRequest RecreateRequest(MutationJournalRecord record, MutationOwnerSnapshot owner)
        {
            var request = SessionCoordinator.BuildMutationRequest(record.Action, record.RequestId, record.BodyJson, owner, record.ResourceId, record.ObservedStatus);
            if (record.OriginDraftId != null) request.LinkDraft(record.OriginDraftId, record.OriginDraftRevision.Value);
            return request;
        }
        private static ApiException Conflict(string code, string message) { return new ApiException(code, message); }
        private static void CanonicalId(string id)
        { Guid value; if (id == null || !Guid.TryParseExact(id, "D", out value) || value == Guid.Empty || value.ToString("D") != id) throw new InvalidDataException(); }
        private static Dictionary<string, object> ObjectValue(object value) { return value as Dictionary<string, object> ?? throw new InvalidDataException(); }
        private static void Keys(Dictionary<string, object> value, params string[] names)
        { if (value.Count != names.Length || value.Keys.Any(name => !names.Contains(name, StringComparer.Ordinal))) throw new InvalidDataException(); }
        private static string Text(Dictionary<string, object> value, string name, int max, bool controls = false)
        { var result = NullableText(value, name, max, controls); if (result == null) throw new InvalidDataException(); return result; }
        private static string NullableText(Dictionary<string, object> value, string name, int max, bool controls = false)
        { object entry; if (!value.TryGetValue(name, out entry)) throw new InvalidDataException(); if (entry == null) return null;
            var result = entry as string; if (result == null || result.Length > max || (!controls && result.Any(Char.IsControl))) throw new InvalidDataException(); return result; }
        private static long Integer(Dictionary<string, object> value, string name, long min, long max)
        { var result = NullableInteger(value, name, min, max); if (!result.HasValue) throw new InvalidDataException(); return result.Value; }
        private static long? NullableInteger(Dictionary<string, object> value, string name, long min, long max)
        { object entry; if (!value.TryGetValue(name, out entry)) throw new InvalidDataException(); if (entry == null) return null;
            if (!(entry is int) && !(entry is long)) throw new InvalidDataException(); var result = Convert.ToInt64(entry); if (result < min || result > max) throw new InvalidDataException(); return result; }
        private static DateTime Time(Dictionary<string, object> value, string name) { return new DateTime(Integer(value, name, 1, DateTime.MaxValue.Ticks), DateTimeKind.Utc); }
        private static MutationAction ActionValue(Dictionary<string, object> value) { return (MutationAction)Integer(value, "action", 1, 16); }
        private static string SafeErrorCode(string value)
        { if (value != null && !System.Text.RegularExpressions.Regex.IsMatch(value, "^[A-Z][A-Z0-9_]{0,79}$")) throw new InvalidDataException(); return value; }
        public void Dispose()
        { lock (gate) { if (disposed) return; disposed = true; foreach (var lease in activeAttempts.Values) lease.Dispose(); activeAttempts.Clear(); } }
    }
}
