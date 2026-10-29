using System;
using System.Collections.Generic;
using System.Collections.ObjectModel;
using System.Threading;
using System.Threading.Tasks;
using Uten.Legacy.Core;

namespace Uten.Legacy.Desktop.Shared
{
    public sealed class SnapshotPage<T>
    {
        public IReadOnlyList<T> Items { get; set; }
        public int Page { get; set; }
        public int Size { get; set; }
        public long Total { get; set; }
        public int TotalPages { get; set; }
    }

    /// <summary>One complete scoped page sequence. Never publish a truncated result as
    /// a complete document, or assume a requested size overrides the server ceiling.</summary>
    public static class CompletePagedSnapshot
    {
        public static async Task<IReadOnlyList<T>> ReadAsync<T>(
            Func<int, int, CancellationToken, Task<SnapshotPage<T>>> read,
            Func<T, string> identity, Func<bool> isCurrent, CancellationToken cancellationToken,
            IProgress<long> progress = null, int maximumRows = 100000,
            Func<T, long> measureBytes = null, long maximumBytes = 64L * 1024 * 1024)
        {
            if (read == null || identity == null || isCurrent == null || maximumRows < 1 || maximumBytes < 1) throw new ArgumentException();
            var items = new List<T>();
            var seen = new HashSet<string>(StringComparer.Ordinal);
            long? total = null; int? totalPages = null, pageSize = null; long measuredBytes = 0;
            for (int page = 1; ; page++)
            {
                Current(isCurrent, cancellationToken);
                var batch = await read(page, 100, cancellationToken).ConfigureAwait(false);
                Current(isCurrent, cancellationToken);
                if (batch == null || batch.Items == null || batch.Page != page || batch.Size < 1
                    || batch.Total < 0 || batch.TotalPages < 0 || batch.Items.Count > batch.Size
                    || batch.TotalPages > 0 && page > batch.TotalPages
                    || batch.Total > maximumRows)
                    throw new ApiException("INVALID_PAGINATION", "完整读取的分页或数量超出安全范围，请缩小筛选后重试。");
                long expectedPages = batch.Total / batch.Size + (batch.Total % batch.Size == 0 ? 0 : 1);
                if (batch.TotalPages != expectedPages || total.HasValue && (total.Value != batch.Total
                    || totalPages.Value != batch.TotalPages || pageSize.Value != batch.Size))
                    throw Changed();
                total = batch.Total; totalPages = batch.TotalPages; pageSize = batch.Size;
                foreach (var item in batch.Items)
                {
                    Current(isCurrent, cancellationToken);
                    string id = identity(item);
                    if (String.IsNullOrEmpty(id) || !seen.Add(id)) throw Changed();
                    if (measureBytes != null)
                    {
                        long bytes = measureBytes(item);
                        if (bytes < 0 || bytes > maximumBytes - measuredBytes)
                            throw new ApiException("SNAPSHOT_TOO_LARGE", "完整结果文字过多，请缩小筛选范围；不会返回截断结果。");
                        measuredBytes += bytes;
                    }
                    items.Add(item);
                    if (items.Count > total.Value || items.Count > maximumRows) throw Changed();
                }
                progress?.Report(items.Count);
                bool more = page < batch.TotalPages;
                if (!more)
                {
                    if (items.Count != batch.Total) throw Changed();
                    Current(isCurrent, cancellationToken);
                    return new ReadOnlyCollection<T>(items);
                }
                if (batch.Items.Count == 0 || page == Int32.MaxValue) throw Changed();
            }
        }
        private static void Current(Func<bool> isCurrent, CancellationToken token)
        {
            token.ThrowIfCancellationRequested();
            if (!isCurrent()) throw new ApiException("READ_SCOPE_CHANGED", "账号、筛选或读取范围已变化，请重新读取完整结果。");
        }
        private static ApiException Changed()
        { return new ApiException("SNAPSHOT_CHANGED", "数据在完整读取期间发生变化或有重复/缺失，请刷新后重新读取。"); }
    }
}
