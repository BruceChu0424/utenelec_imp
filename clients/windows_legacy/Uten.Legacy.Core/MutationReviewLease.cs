using System;
using System.Threading;
using System.Threading.Tasks;

namespace Uten.Legacy.Core
{
    /// <summary>Local append-only capability. It can preserve a human note after retirement,
    /// but cannot read the original body, change an outcome, or issue any HTTP request.</summary>
    public sealed class MutationReviewLease
    {
        internal readonly object CoordinatorIdentity;
        internal readonly MutationOwnerSnapshot Owner;
        public string RequestId { get; private set; }
        internal MutationReviewLease(object identity, MutationOwnerSnapshot owner, string requestId)
        { CoordinatorIdentity = identity; Owner = owner; RequestId = requestId; }
    }
    public sealed class MutationReviewNoteSaveResult
    {
        public string RequestId { get; private set; }
        public DateTime RecordedAtUtc { get; private set; }
        internal MutationReviewNoteSaveResult(string requestId, DateTime time) { RequestId = requestId; RecordedAtUtc = time; }
    }
    public sealed partial class SessionCoordinator
    {
        public async Task<MutationReviewLease> CreateMutationReviewLeaseAsync(string requestId, MutationOwnerSnapshot owner, CancellationToken ct)
        {
            CanonicalCommandId(requestId); RequireBusinessReader(owner);
            var record = await Task.Run(() => BusinessPersist(() => businessStateStore.LoadJournal(owner, requestId)), ct).ConfigureAwait(false);
            ct.ThrowIfCancellationRequested(); RequireBusinessReader(owner);
            if (record == null) throw new ApiException("MUTATION_RECORD_NOT_FOUND", "未找到原始提交台账，不能创建核对说明。");
            return new MutationReviewLease(mutationIdentity, owner, record.RequestId);
        }
        public Task<MutationReviewNoteSaveResult> AppendMutationReviewNoteAsync(MutationReviewLease lease, string note, CancellationToken ct)
        {
            if (lease == null || !Object.ReferenceEquals(lease.CoordinatorIdentity, mutationIdentity)) throw InvalidAction();
            ValidateReviewNote(note); RequireBusinessStateStore();
            return Task.Run(() =>
            {
                var saved = BusinessPersist(() => businessStateStore.AppendReviewNote(lease.Owner, lease.RequestId, note));
                // Return no old-owner business fields. The caller already owns its entered text.
                return new MutationReviewNoteSaveResult(lease.RequestId, saved.UpdatedAtUtc);
            }, ct);
        }
        private static void ValidateReviewNote(string note)
        {
            if (String.IsNullOrWhiteSpace(note) || note.Length > 2000
                || System.Linq.Enumerable.Any(note, value => Char.IsControl(value) && value != '\n' && value != '\r' && value != '\t'))
                throw new ApiException("REVIEW_NOTE_INVALID", "请填写不含认证材料的有界人工核对说明；它不会把未知提交改成成功。");
        }
    }
}
