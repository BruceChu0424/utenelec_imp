using System;
using System.Collections.Generic;
using System.Globalization;
using System.Threading;
using System.Threading.Tasks;
using Uten.Legacy.Core;

namespace Uten.Legacy.Desktop.Features.Units
{
    /// <summary>History reads and commands use the same authenticated Core transport and durable journal.</summary>
    public sealed class UnitHistoryService
    {
        private readonly SessionCoordinator session;
        public UnitHistoryService(SessionCoordinator session) { this.session = session ?? throw new ArgumentNullException(nameof(session)); }
        public Task<UnitReadSnapshot<UnitOperationHistory>> OperationsAsync(CancellationToken ct)
        { return ReadAsync(UnitHistoryContract.OperationsPath, UnitHistoryContract.ParseOperations, ct); }
        public Task<UnitReadSnapshot<UnitRecordHistoryPage>> RecordsAsync(UnitHistoryQuery query, CancellationToken ct)
        {
            if (query == null) throw new ArgumentNullException(nameof(query));
            return ReadAsync(query.ToRelativePath(), json =>
            {
                var page = UnitHistoryContract.ParseRecordPage(json); long boundary = query.Cursor ?? Int64.MaxValue;
                if (page.Entries.Count > query.Size) throw new FormatException("历史响应超出所选页大小。");
                foreach (var row in page.Entries)
                {
                    if (row.Id >= boundary || query.RecordId != null && !String.Equals(row.RecordId, query.RecordId, StringComparison.OrdinalIgnoreCase))
                        throw new FormatException("历史响应的版本顺序或当前单位范围无效。");
                    boundary = row.Id;
                }
                if (page.NextCursor.HasValue && (page.Entries.Count == 0 || page.NextCursor.Value != boundary))
                    throw new FormatException("历史响应的后续游标无效。");
                return page;
            }, ct);
        }
        public Task<UnitReadSnapshot<UnitRecordRevision>> DetailAsync(long id, CancellationToken ct)
        {
            return ReadAsync(UnitHistoryContract.RecordDetailPath(id), json =>
            {
                var detail = UnitHistoryContract.ParseRecordDetail(json);
                if (detail.Id != id) throw new FormatException("历史详情与所选版本不一致，请刷新后重新选择。");
                return detail;
            }, ct);
        }
        public async Task<UnitReadSnapshot<IReadOnlyList<MutationJournalRecord>>> JournalAsync(CancellationToken ct)
        {
            DemandRead(); var fence = new UnitReadOwner(session); var owner = session.CaptureMutationOwner();
            if (!fence.Matches(owner)) throw Changed();
            var entries = await session.ListMutationJournalAsync(owner, ct).ConfigureAwait(false);
            Require(fence); ct.ThrowIfCancellationRequested();
            return new UnitReadSnapshot<IReadOnlyList<MutationJournalRecord>>(entries, fence, "local:unit-history-journal");
        }
        private async Task<UnitReadSnapshot<T>> ReadAsync<T>(string path, Func<string, T> parser, CancellationToken ct)
        {
            DemandRead(); var owner = new UnitReadOwner(session);
            string json = await session.GetAsync(path, ct).ConfigureAwait(false); Require(owner);
            T value = await Task.Run(() => parser(json), ct).ConfigureAwait(false); Require(owner); ct.ThrowIfCancellationRequested();
            return new UnitReadSnapshot<T>(value, owner, path);
        }
        public MutationRequest PrepareReplay(string requestId, UnitReadSnapshot<UnitOperationHistory> source, string operationId, bool redo)
        {
            if (source == null) throw new ArgumentNullException(nameof(source)); Require(source.Owner);
            UnitOperationEntry target = null;
            foreach (var entry in source.Value.Entries) if (entry.Id == operationId) { target = entry; break; }
            if (target == null || !(redo ? target.CanRedo : target.CanUndo))
                throw new ApiException("HISTORY_BLOCKED", target?.BlockedReason ?? "当前操作不能撤回或取消撤回，请刷新历史核对。");
            var owner = session.CaptureMutationOwner(); if (!source.Owner.Matches(owner)) throw Changed();
            return session.PrepareMutation(redo ? MutationAction.UnitRedo : MutationAction.UnitUndo, requestId,
                UnitHistoryContract.ReplayBody(target.Version), owner, target.Id);
        }
        public MutationRequest PrepareRestore(string requestId, UnitReadSnapshot<UnitRecordRevision> source, bool before)
        {
            if (source == null) throw new ArgumentNullException(nameof(source)); Require(source.Owner);
            if (!(before ? source.Value.CanRestoreBefore : source.Value.CanRestoreAfter))
                throw new ApiException("HISTORY_BLOCKED", source.Value.BlockedReason ?? "此版本暂不能恢复，请刷新详情核对。");
            var owner = session.CaptureMutationOwner(); if (!source.Owner.Matches(owner)) throw Changed();
            return session.PrepareMutation(MutationAction.UnitRecordRestore, requestId, UnitHistoryContract.RestoreBody(source.Value.ExpectedHead, before),
                owner, source.Value.Id.ToString(CultureInfo.InvariantCulture));
        }
        public Task<MutationResult> SendAsync(MutationRequest request, CancellationToken ct)
        {
            if (request == null || !IsHistoryAction(request.Action)) throw new ArgumentException("只能发送已审核的单位历史动作。", nameof(request));
            return session.MutateAsync(request, ct);
        }
        public static bool IsHistoryAction(MutationAction action)
        { return action == MutationAction.UnitUndo || action == MutationAction.UnitRedo || action == MutationAction.UnitRecordRestore; }
        public static bool HasUnresolved(IReadOnlyList<MutationJournalRecord> entries)
        { foreach (var entry in entries) if (IsHistoryAction(entry.Action) && entry.MayNeedManualReconciliation) return true; return false; }
        private void DemandRead()
        { if (session.CurrentUser?.HasPermission("unit:view") != true) throw new ApiException("FORBIDDEN", "当前没有单位历史查看权限。", 403); }
        private void Require(UnitReadOwner owner) { DemandRead(); if (owner == null || !owner.IsCurrent(session)) throw Changed(); }
        private static ApiException Changed() { return new ApiException("READ_SCOPE_CHANGED", "账号、权限或数据范围已变化，请重新打开单位历史。", 403); }
    }
}
