using System;
using System.IO;
using System.Linq;
using System.Threading;
using System.Threading.Tasks;

namespace Uten.Legacy.Core
{
    public sealed partial class SessionCoordinator
    {
        /// <summary>Read-only HTTP reconciliation for an original export creation command.
        /// GET metadata alone is insufficient: the authorized server must disclose its persisted
        /// original request and that request must match the exact frozen filter and typed DTO.</summary>
        public async Task<MutationResult> ReconcileUnitExportAsync(string originalRequestId, MutationOwnerSnapshot owner, CancellationToken ct)
        {
            CanonicalCommandId(originalRequestId); RequireExportReceiptOwner(owner);
            var entry = await Task.Run(() => BusinessPersist(() => businessStateStore.LoadJournal(owner, originalRequestId)), ct).ConfigureAwait(false);
            RequireExportReceiptOwner(owner);
            if (entry == null || entry.Action != MutationAction.UnitExportSubmit)
                throw new ApiException("EXPORT_RECEIPT_NOT_APPLICABLE", "只有原单位导出创建任务可使用此回执核对；不会把普通业务写或取消请求当作创建回执。");
            var request = BuildMutationRequest(entry.Action, entry.RequestId, entry.BodyJson, owner, entry.ResourceId, entry.ObservedStatus);
            if (entry.OriginDraftId != null) request.LinkDraft(entry.OriginDraftId, entry.OriginDraftRevision.Value);
            if (entry.State == MutationJournalState.Confirmed)
            {
                var known = new MutationResult(MutationOutcome.Confirmed, request, null, entry.ResultJson)
                { ExportJob = entry.ExportJob, ConfirmedByReceiptQuery = entry.ConfirmedByReceiptQuery };
                known.RecordPersistence(true, null); return known;
            }
            if (entry.State == MutationJournalState.NotSent || entry.State == MutationJournalState.Rejected)
            {
                var known = new MutationResult(entry.State == MutationJournalState.NotSent ? MutationOutcome.NotSent : MutationOutcome.Rejected, request,
                    new ApiException(entry.ErrorCode ?? "EXPORT_NOT_ACCEPTED", "原提交已有明确的未发送或拒绝记录；本次未重新发送。", entry.StatusCode));
                known.RecordPersistence(true, null); return known;
            }
            if (entry.State == MutationJournalState.Sending)
                return ExportUnverified(request, "EXPORT_SUBMISSION_IN_PROGRESS", "原提交仍在处理，请等待原操作完成核对；不会并发重发。", false);
            string json;
            try { json = await GetAsync(request.ReceiptPath, ct).ConfigureAwait(false); }
            catch (ApiException error)
            {
                RequireExportReceiptOwner(owner);
                return ExportUnverified(request, error.StatusCode == 404 ? "EXPORT_RECEIPT_NOT_FOUND" : "EXPORT_RECEIPT_QUERY_FAILED",
                    error.StatusCode == 404 ? "按原编号尚未查到任务；原提交仍待确认，不能换编号盲重试。" : "读取原任务回执未完成，原提交仍待核对。");
            }
            RequireExportReceiptOwner(owner);
            MutationExportJob job;
            try { UnitExportMutationContract.RequireCreationProof(request, json); job = UnitExportMutationContract.ReadJob(request, json); }
            catch (Exception invalid) when (invalid is FormatException || invalid is ArgumentException || invalid is InvalidOperationException)
            { return ExportUnverified(request, "EXPORT_RECEIPT_UNVERIFIED", "服务器尚未返回与冻结条件一致的完整原请求证据；原任务仍待核对。"); }
            var result = new MutationResult(MutationOutcome.Confirmed, request, null, json) { ExportJob = job, ConfirmedByReceiptQuery = true };
            var receiptStore = businessStateStore as IUnitExportReceiptStore;
            if (receiptStore == null)
                result.RecordPersistence(false, new ApiException("EXPORT_RECEIPT_STORAGE_UNSUPPORTED", "原任务已获得有效回执，但注入的本机存储尚不支持回执保存；原记录仍保留。"));
            else
            {
                try
                {
                    await Task.Run(() => BusinessPersist(() => receiptStore.ConfirmUnitExportReceipt(request, json))).ConfigureAwait(false);
                    result.RecordPersistence(true, null);
                }
                catch (ApiException error) { result.RecordPersistence(false, error); }
            }
            RequireExportReceiptOwner(owner); return result;
        }
        private void RequireExportReceiptOwner(MutationOwnerSnapshot owner)
        {
            lock (gate) { RequireMutationOwnerLocked(owner); RequireMutationPermissionsLocked(new[] { "unit:export" }); RequireBusinessStateStore(); }
        }
        private static MutationResult ExportUnverified(MutationRequest request, string code, string message, bool durablyUnknown = true)
        {
            var result = new MutationResult(MutationOutcome.Unknown, request, new ApiException(code, message, isSubmissionUnknown: true));
            result.RecordPersistence(durablyUnknown, null); return result;
        }
    }

    public sealed partial class DpapiBusinessStateStore
    {
        public void ConfirmUnitExportReceipt(MutationRequest original, string verifiedJobJson)
        {
            UnitExportMutationContract.RequireCreationProof(original, verifiedJobJson);
            lock (gate) using (NamespaceLock(original.Owner))
            {
                var records = ReadJournal(original.Owner, true);
                MutationJournalRecord entry;
                if (!records.TryGetValue(original.RequestId, out entry) || entry.Action != MutationAction.UnitExportSubmit
                    || entry.BodyJson != original.BodyJson || entry.ResourceId != original.ResourceId || entry.BodySha256 != original.BodySha256)
                    throw new InvalidDataException("原导出创建台账不一致。");
                if (entry.State == MutationJournalState.Confirmed) return;
                if (entry.State != MutationJournalState.Unknown) throw new InvalidDataException("原提交尚未处于可核对的未知状态。");
                records[entry.RequestId] = new MutationJournalRecord(original, MutationJournalState.Confirmed, entry.CreatedAtUtc, DateTime.UtcNow,
                    200, null, original.ResourceId, entry.ReviewNote, verifiedJobJson, true);
                WriteDocument(original.Owner, "mutations", records.Values.Select(JournalValue).ToArray());
            }
        }
    }
}
