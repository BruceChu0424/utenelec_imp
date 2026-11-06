using System;
using System.Collections.Generic;
using System.Collections.ObjectModel;
using System.Linq;
using System.Runtime.ExceptionServices;
using System.Text.RegularExpressions;
using System.Threading;
using System.Threading.Tasks;
using System.Web.Script.Serialization;
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
        public string ReadScopeVersion { get; set; }
        public string ReadDataVersion { get; set; }
        public string ReadSnapshotRevision { get; set; }
    }

    /// <summary>One complete scoped page sequence. Never publish a truncated result as
    /// a complete document, or assume a requested size overrides the server ceiling.</summary>
    public static class CompletePagedSnapshot
    {
        public const int MaximumRows = 100000;
        public const long MaximumTextBytes = CompleteSummaryResponse.MaximumTextBytes;
        public static async Task<SnapshotPage<T>> ReadCompleteStreamAsync<T>(CompleteSummaryResponse response,
            Func<string, SnapshotPage<T>> parse, Func<T, string> identity, Func<bool> isCurrent, CancellationToken token)
        {
            if (response == null || response.Pages == null || response.Pages.Count == 0 || response.ErrorCode != null) throw Changed();
            SnapshotPage<T> first = null;
            var rows = await ReadAsync<T>((page, size, ct) =>
            {
                StrongCurrent(isCurrent, ct);
                if (page > response.Pages.Count) throw Changed();
                var batch = parse(response.Pages[page - 1]);
                if (first == null) first = batch;
                StrongBatch(batch, page, first);
                return Task.FromResult(batch);
            }, identity, isCurrent, token, maximumRows: Int32.MaxValue).ConfigureAwait(false);
            if (response.Pages.Count != Math.Max(1, first.TotalPages)) throw Changed();
            var final = new JavaScriptSerializer { MaxJsonLength = 8388608, RecursionLimit = 64 }
                .DeserializeObject(response.CompletionJson) as Dictionary<string, object>;
            object value;
            if (final == null || !final.TryGetValue("type", out value) || !Equals(value, "complete")
                || !final.TryGetValue("total", out value) || !(value is int || value is long) || Convert.ToInt64(value) != first.Total
                || !final.TryGetValue("readScopeVersion", out value) || !Equals(value, first.ReadScopeVersion)
                || !final.TryGetValue("readDataVersion", out value) || !Equals(value, first.ReadDataVersion)
                || !final.TryGetValue("readSnapshotRevision", out value) || !Equals(value, first.ReadSnapshotRevision)) throw Changed();
            StrongCurrent(isCurrent, token);
            return new SnapshotPage<T> { Items = rows, Page = 1, Size = first.Size, Total = first.Total,
                TotalPages = first.TotalPages, ReadScopeVersion = first.ReadScopeVersion,
                ReadDataVersion = first.ReadDataVersion, ReadSnapshotRevision = first.ReadSnapshotRevision };
        }
        public static async Task<IReadOnlyList<T>> ReadAsync<T>(
            Func<int, int, CancellationToken, Task<SnapshotPage<T>>> read,
            Func<T, string> identity, Func<bool> isCurrent, CancellationToken cancellationToken,
            IProgress<long> progress = null, int maximumRows = MaximumRows,
            Func<T, long> measureBytes = null, long maximumBytes = MaximumTextBytes,
            int maximumConcurrentBatches = 1)
        {
            if (read == null || identity == null || isCurrent == null || maximumRows < 1 || maximumBytes < 1) throw new ArgumentException();
            if (maximumConcurrentBatches < 1 || maximumConcurrentBatches > 4) throw new ArgumentOutOfRangeException(nameof(maximumConcurrentBatches));
            if (maximumConcurrentBatches > 1)
                return await ReadBoundedAsync(read, identity, isCurrent, cancellationToken, progress,
                    maximumRows, measureBytes, maximumBytes, maximumConcurrentBatches).ConfigureAwait(false);
            var items = new List<T>();
            var seen = new HashSet<string>(StringComparer.Ordinal);
            long? total = null; int? totalPages = null, pageSize = null; long measuredBytes = 0;
            string readScopeVersion = null;
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
                    || totalPages.Value != batch.TotalPages || pageSize.Value != batch.Size
                    || !String.Equals(readScopeVersion, batch.ReadScopeVersion, StringComparison.Ordinal)))
                    throw Changed();
                total = batch.Total; totalPages = batch.TotalPages; pageSize = batch.Size; readScopeVersion = batch.ReadScopeVersion;
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
        private static async Task<IReadOnlyList<T>> ReadBoundedAsync<T>(
            Func<int, int, CancellationToken, Task<SnapshotPage<T>>> read,
            Func<T, string> identity, Func<bool> isCurrent, CancellationToken cancellationToken,
            IProgress<long> progress, int maximumRows, Func<T, long> measureBytes,
            long maximumBytes, int concurrency)
        {
            using (var owned = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken))
            {
                var window = new Dictionary<int, Task<SnapshotPage<T>>>();
                var failed = new TaskCompletionSource<Exception>(TaskCreationOptions.RunContinuationsAsynchronously);
                StrongCurrent(isCurrent, owned.Token);
                var first = await read(1, 100, owned.Token).ConfigureAwait(false);
                StrongCurrent(isCurrent, owned.Token);
                StrongBatch(first, 1, first);
                var proofIds = new HashSet<string>(StringComparer.Ordinal);
                var proofGate = new object();
                Action<SnapshotPage<T>> verifyIdentities = batch =>
                {
                    var ids = batch.Items.Select(identity).ToArray();
                    lock (proofGate)
                        foreach (var id in ids)
                            if (String.IsNullOrEmpty(id) || !proofIds.Add(id)) throw Changed();
                };
                verifyIdentities(first);
                int next = 2;
                Func<int, Task<SnapshotPage<T>>> fetch = async page =>
                {
                    try
                    {
                        StrongCurrent(isCurrent, owned.Token);
                        var response = await read(page, 100, owned.Token).ConfigureAwait(false);
                        StrongCurrent(isCurrent, owned.Token);
                        StrongBatch(response, page, first);
                        // A later overlap is a failure now, even while the ordered
                        // collector is waiting for an earlier page's response.
                        verifyIdentities(response);
                        return response;
                    }
                    catch (Exception error) { failed.TrySetResult(error); throw; }
                };
                Func<int, int, CancellationToken, Task<SnapshotPage<T>>> ordered = async (page, size, token) =>
                {
                    if (page == 1) return first;
                    while (window.Count < concurrency && next <= first.TotalPages && !failed.Task.IsCompleted)
                    { int requested = next++; window.Add(requested, fetch(requested)); }
                    if (failed.Task.IsCompleted) ExceptionDispatchInfo.Capture(await failed.Task.ConfigureAwait(false)).Throw();
                    var current = window[page];
                    await Task.WhenAny(current, failed.Task).ConfigureAwait(false);
                    if (failed.Task.IsCompleted) ExceptionDispatchInfo.Capture(await failed.Task.ConfigureAwait(false)).Throw();
                    StrongCurrent(isCurrent, owned.Token);
                    var response = await current.ConfigureAwait(false);
                    window.Remove(page);
                    // The original serial validator consumes the result next; at most four
                    // active or completed-but-unconsumed batches can exist at any time.
                    return response;
                };
                try
                {
                    // Reuse the one existing collector for IDs, order, totals, text/row
                    // budgets and final atomic publication. Other callers stay serial.
                    return await ReadAsync(ordered, identity, isCurrent, owned.Token, progress,
                        maximumRows, measureBytes, maximumBytes).ConfigureAwait(false);
                }
                catch
                {
                    try { owned.Cancel(); } catch (AggregateException) { }
                    try { await Task.WhenAll(window.Values).ConfigureAwait(false); } catch (Exception) { }
                    throw;
                }
            }
        }
        private static void StrongBatch<T>(SnapshotPage<T> batch, int page, SnapshotPage<T> first)
        {
            if (batch == null || first == null || batch.Items == null || batch.Page != page || batch.Size != 100
                || batch.Total < 0 || batch.TotalPages < 0 || batch.TotalPages != batch.Total / 100 + (batch.Total % 100 == 0 ? 0 : 1)
                || batch.Items.Count != Math.Max(0L, Math.Min(100L, batch.Total - ((long)page - 1) * 100))
                || String.IsNullOrEmpty(batch.ReadScopeVersion) || batch.ReadScopeVersion.Length > 256 || batch.ReadScopeVersion.Any(Char.IsControl)
                || batch.ReadDataVersion == null || batch.ReadDataVersion.Length != 64 || !Regex.IsMatch(batch.ReadDataVersion, "^[0-9a-f]{64}$", RegexOptions.CultureInvariant)
                || batch.ReadSnapshotRevision == null || batch.ReadSnapshotRevision.Length != 64 || !Regex.IsMatch(batch.ReadSnapshotRevision, "^[0-9a-f]{64}$", RegexOptions.CultureInvariant))
                throw Changed();
            if (!String.Equals(batch.ReadScopeVersion, first.ReadScopeVersion, StringComparison.Ordinal))
                throw new ApiException("READ_SCOPE_CHANGED", "账号或读取范围已变化，请重新读取完整结果。", 403);
            if (batch.Total != first.Total || batch.TotalPages != first.TotalPages
                || !String.Equals(batch.ReadDataVersion, first.ReadDataVersion, StringComparison.Ordinal)
                || !String.Equals(batch.ReadSnapshotRevision, first.ReadSnapshotRevision, StringComparison.Ordinal)) throw Changed();
        }
        private static void StrongCurrent(Func<bool> isCurrent, CancellationToken token)
        {
            token.ThrowIfCancellationRequested();
            if (!isCurrent()) throw new ApiException("READ_SCOPE_CHANGED", "账号、筛选或读取范围已变化，请重新读取完整结果。", 403);
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
