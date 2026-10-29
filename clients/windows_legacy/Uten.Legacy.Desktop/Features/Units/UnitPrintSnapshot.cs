using System;
using System.Collections.Generic;
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
            CancellationToken token, IProgress<long> progress = null)
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
            return new UnitPrintSnapshot(owner, rows, query);
        }
    }
}
