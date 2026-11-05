using System;
using System.Collections.Generic;
using System.Linq;
using System.Threading;
using System.Threading.Tasks;
using Uten.Legacy.Core;
using Uten.Legacy.Desktop.Shared;

namespace Uten.Legacy.Desktop.Features.Units
{
    public sealed class UnitPrintSnapshot
    {
        public UnitReadOwner Owner { get; private set; }
        public IReadOnlyList<UnitRecord> Rows { get; private set; }
        public UnitQuery Query { get; private set; }
        private UnitPrintSnapshot(UnitReadOwner owner, IReadOnlyList<UnitRecord> rows, UnitQuery query)
        { Owner = owner; Rows = rows; Query = query; }
        public bool IsCurrent(SessionCoordinator session) { return Owner.IsCurrent(session); }
        public static async Task<UnitPrintSnapshot> LoadAsync(SessionCoordinator session, UnitQuery query,
            CancellationToken token, IProgress<long> progress = null, IReadOnlyList<string> selectedIds = null)
        {
            if (query == null) throw new ArgumentNullException(nameof(query));
            var owner = new UnitReadOwner(session);
            var service = new UnitService(session);
            var filters = new Dictionary<string, UnitFilter>(StringComparer.Ordinal);
            foreach (var item in query.Filters) filters.Add(item.Key, item.Value);
            var rows = await CompletePagedSnapshot.ReadAsync(async (page, size, cancellation) =>
            {
                var result = await service.ListAsync(new UnitQuery(page, size, query.Keyword, filters), cancellation).ConfigureAwait(false);
                if (!result.IsCurrent(session) || !owner.IsCurrent(session))
                    throw new ApiException("READ_SCOPE_CHANGED", "打印数据的读取范围已变化，请重新打开预览。");
                return new SnapshotPage<UnitRecord> { Items = result.Value.Items, Page = result.Value.Page,
                    Size = result.Value.Size, Total = result.Value.TotalElements, TotalPages = result.Value.TotalPages };
            }, row => row.Id, () => owner.IsCurrent(session), token, progress,
                measureBytes: row => ((long)(row.Code?.Length ?? 0) + (row.Name?.Length ?? 0) + (row.Status?.Length ?? 0)) * 2).ConfigureAwait(false);
            if (!owner.IsCurrent(session)) throw new ApiException("READ_SCOPE_CHANGED", "打印数据的读取范围已变化。");
            if (selectedIds != null)
            {
                var ids = new HashSet<string>(selectedIds, StringComparer.Ordinal);
                if (ids.Count == 0 || ids.Count != selectedIds.Count) throw new ApiException("PRINT_SELECTION_INVALID", "请选择不重复的有效单位资料。");
                rows = Array.AsReadOnly(rows.Where(row => ids.Contains(row.Id)).ToArray());
                if (rows.Count != ids.Count) throw new ApiException("PRINT_SELECTION_CHANGED", "已选资料已变化或不在当前筛选及权限范围内，请刷新并重新选择。");
            }
            return new UnitPrintSnapshot(owner, rows, query);
        }
    }
}
