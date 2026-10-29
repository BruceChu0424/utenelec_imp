using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Security.Cryptography;
using System.Threading;
using System.Threading.Tasks;

namespace Uten.Legacy.Core
{
    public sealed partial class SessionCoordinator
    {
        public DraftWriteLease CreateDraftLease(MutationAction action, string draftId, MutationOwnerSnapshot owner,
            string resourceId = null, string observedStatus = null)
        {
            CanonicalCommandId(draftId);
            ValidateDraftMetadata(action, resourceId, observedStatus);
            lock (gate)
            {
                RequireMutationOwnerLocked(owner);
                RequireMutationPermissionsLocked(IsUnitPlatformMutation(action) ? UnitPlatformPermissions(action) : action == MutationAction.UnitInlineEdit ? new[] { "unit:view", "unit:edit" }
                    : new[] { action == MutationAction.UnitCreate ? "unit:create" : action == MutationAction.UnitUpdate ? "unit:edit"
                        : action == MutationAction.UnitBatchDelete ? "unit:delete" : "unit:status" });
                RequireBusinessStateStore();
                return new DraftWriteLease(mutationIdentity, action, draftId, owner, resourceId, observedStatus);
            }
        }

        /// <summary>LOCAL preservation only, deliberately usable after a page's auth/read owner
        /// retires. This lease can write only its original namespace/action/resource/draft ID.
        /// A failed save throws and leaves the caller responsible for retaining unsaved input.</summary>
        public Task<BusinessDraft> SaveDraftAsync(DraftWriteLease lease, long expectedRevision, string bodyJson, CancellationToken ct)
        {
            if (lease == null || !Object.ReferenceEquals(lease.CoordinatorIdentity, mutationIdentity)) throw InvalidAction();
            if (expectedRevision < 0) throw InvalidAction();
            ValidateDraftBody(lease.Action, bodyJson);
            RequireBusinessStateStore();
            return Task.Run(() => BusinessPersist(() => businessStateStore.SaveDraft(lease, expectedRevision, bodyJson)), ct);
        }

        public async Task<IReadOnlyList<BusinessDraft>> ListDraftsAsync(MutationOwnerSnapshot owner, CancellationToken ct)
        {
            RequireBusinessReader(owner);
            var result = await Task.Run(() => BusinessPersist(() => businessStateStore.ListDrafts(owner)), ct).ConfigureAwait(false);
            RequireBusinessReader(owner); return result;
        }
        public async Task<BusinessDraft> LoadDraftAsync(string draftId, MutationOwnerSnapshot owner, CancellationToken ct)
        {
            CanonicalCommandId(draftId); RequireBusinessReader(owner);
            var result = await Task.Run(() => BusinessPersist(() => businessStateStore.LoadDraft(owner, draftId)), ct).ConfigureAwait(false);
            RequireBusinessReader(owner); return result;
        }
        public async Task DeleteDraftAsync(string draftId, long expectedRevision, MutationOwnerSnapshot owner, CancellationToken ct)
        {
            CanonicalCommandId(draftId); RequireBusinessReader(owner);
            await Task.Run(() =>
            {
                // Recheck before this local removal, not only before queuing the worker.
                RequireBusinessReader(owner);
                BusinessPersist(() => businessStateStore.DeleteDraft(owner, draftId, expectedRevision));
            }, ct).ConfigureAwait(false);
        }
        public async Task<MutationRequest> PrepareMutationFromDraftAsync(string requestId, string draftId, long draftRevision,
            MutationOwnerSnapshot owner, CancellationToken ct, string observedStatus = null)
        {
            var draft = await LoadDraftAsync(draftId, owner, ct).ConfigureAwait(false);
            if (draft == null || draft.Revision != draftRevision)
                throw new ApiException("DRAFT_CONFLICT", "草稿已被另一个编辑器更新，请先核对完整内容。");
            var request = PrepareMutation(draft.Action, requestId, draft.BodyJson, owner, draft.ResourceId,
                draft.Action == MutationAction.UnitUpdate ? observedStatus : null);
            lock (gate)
            {
                RequireMutationOwnerLocked(owner);
                if (request.OriginDraftId == null) request.LinkDraft(draftId, draftRevision);
                else if (request.OriginDraftId != draftId || request.OriginDraftRevision != draftRevision)
                    throw new ApiException("MUTATION_INTENT_CHANGED", "同一提交编号不能更换草稿或草稿版本。");
            }
            return request;
        }

        public async Task<IReadOnlyList<MutationJournalRecord>> ListMutationJournalAsync(MutationOwnerSnapshot owner, CancellationToken ct)
        {
            RequireBusinessReader(owner);
            var result = await Task.Run(() => BusinessPersist(() => businessStateStore.ListJournal(owner)), ct).ConfigureAwait(false);
            RequireBusinessReader(owner); return result;
        }
        public async Task<MutationJournalRecord> LoadMutationJournalAsync(string requestId, MutationOwnerSnapshot owner, CancellationToken ct)
        {
            CanonicalCommandId(requestId); RequireBusinessReader(owner);
            var result = await Task.Run(() => BusinessPersist(() => businessStateStore.LoadJournal(owner, requestId)), ct).ConfigureAwait(false);
            RequireBusinessReader(owner); return result;
        }
        public async Task<MutationJournalRecord> AppendMutationReviewNoteAsync(string requestId, string note,
            MutationOwnerSnapshot owner, CancellationToken ct)
        {
            CanonicalCommandId(requestId); RequireBusinessReader(owner);
            ValidateReviewNote(note);
            var result = await Task.Run(() =>
            {
                RequireBusinessReader(owner);
                return BusinessPersist(() => businessStateStore.AppendReviewNote(owner, requestId, note));
            }, ct).ConfigureAwait(false);
            RequireBusinessReader(owner); return result;
        }

        private void RequireBusinessReader(MutationOwnerSnapshot owner)
        {
            lock (gate)
            {
                RequireMutationOwnerLocked(owner);
                RequireMutationPermissionsLocked(new[] { "unit:view" });
                RequireBusinessStateStore();
            }
        }
        private void RequireBusinessStateStore()
        {
            if (businessStateStore == null)
                throw new ApiException("DURABLE_MUTATION_STORE_REQUIRED", "尚未配置独立的本机持久业务存储，本次客户端不会发送业务写入。");
        }
        private async Task<MutationResult> PersistMutationCompletionAsync(MutationResult result, bool checkpointCommitted)
        {
            if (!checkpointCommitted)
            {
                if (result.Error?.Code == "LOCAL_BUSINESS_STORAGE") result.RecordPersistence(false, result.Error);
                return result;
            }
            try
            {
                // Do not link finalization to page/caller cancellation: the frozen original
                // attempt must be accounted for in its original namespace after retirement.
                await Task.Run(() => BusinessPersist(() => businessStateStore.Complete(result))).ConfigureAwait(false);
                result.RecordPersistence(true, null);
            }
            catch (ApiException error)
            {
                // A known server success stays Confirmed. The durable Sending entry remains
                // and will recover as Unknown; never report NotSent or invite a retry here.
                result.RecordPersistence(false, error);
            }
            return result;
        }
        private static T BusinessPersist<T>(Func<T> action)
        {
            try { return action(); }
            catch (Exception error) when (error is IOException || error is InvalidDataException || error is UnauthorizedAccessException || error is CryptographicException
                || error is FormatException || error is ArgumentException || error is InvalidOperationException || error is TimeoutException)
            { throw new ApiException("LOCAL_BUSINESS_STORAGE", "本机业务草稿或提交台账未能安全保存/读取。请保留原输入并核对存储；不能将本次操作视为已完成本机保全。"); }
        }
        private static void BusinessPersist(Action action) { BusinessPersist(() => { action(); return true; }); }

        internal static void ValidateDraftMetadata(MutationAction action, string resourceId, string observedStatus)
        {
            if (IsUnitPlatformMutation(action))
            {
                if (observedStatus != null || action == MutationAction.UnitPlatformDefinitionDelete || action == MutationAction.UnitPlatformDefinitionUse) throw InvalidAction();
                if (action == MutationAction.UnitPlatformValuesWrite) CanonicalCommandId(resourceId);
                else if (resourceId != null) throw InvalidAction();
                return;
            }
            if (action == MutationAction.UnitCreate || action == MutationAction.UnitBatchStatus || action == MutationAction.UnitBatchDelete)
            { if (resourceId != null || observedStatus != null) throw InvalidAction(); }
            else if (action == MutationAction.UnitUpdate || action == MutationAction.UnitStatus || action == MutationAction.UnitInlineEdit)
            {
                CanonicalCommandId(resourceId);
                if (((action == MutationAction.UnitStatus || action == MutationAction.UnitInlineEdit) && observedStatus != null)
                    || (observedStatus != null && observedStatus != "使用" && observedStatus != "禁用")) throw InvalidAction();
            }
            else throw InvalidAction();
        }
        internal static void ValidateDraftBody(MutationAction action, string body)
        {
            try
            {
                if (IsUnitPlatformMutation(action)) { ValidateUnitPlatformBody(action, body, true); return; }
                if (IsSupplementalUnitAction(action)) { ValidateSupplementalBody(action, body, true); return; }
                var fields = MutationFlatJson.Parse(body, 65536, true);
                if (action == MutationAction.UnitStatus) RequireFields(fields, "status", "version");
                else if (action == MutationAction.UnitCreate || action == MutationAction.UnitUpdate)
                    RequireFields(fields, "name", "code", "status", "measurementDimension", "massUnitCode");
                else throw InvalidAction();
                foreach (var field in fields)
                    if (field.Value.Value != null && !(field.Value.Value is string)
                        && !(field.Key == "version" && field.Value.Value is long)) throw InvalidAction();
            }
            catch (Exception error) when (error is FormatException || error is ArgumentException || error is InvalidOperationException)
            { throw new ApiException("DRAFT_BODY_INVALID", "草稿只能保存单位表单的原始业务字段；不能包含密码、令牌、任意附加字段或认证材料。"); }
        }
    }
}
