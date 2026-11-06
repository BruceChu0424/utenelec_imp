using System;
using System.Collections.Generic;
using System.Linq;
using System.Threading;
using System.Threading.Tasks;
using Uten.Legacy.Core;

namespace Uten.Legacy.Desktop.Shared
{
    public static class CompletePagedSnapshotChecks
    {
        private static readonly string Data = new string('d', 64), Revision = new string('a', 64);
        public static int Run() { return RunAsync().GetAwaiter().GetResult(); }
        private static async Task<int> RunAsync()
        {
            int assertions = 0;
            Action<bool, string> check = (value, text) => { if (!value) throw new InvalidOperationException("Bounded complete read: " + text); Interlocked.Increment(ref assertions); };
            var entered = Signal(); var release = Enumerable.Range(2, 4).ToDictionary(page => page, page => Signal());
            var requested = new List<int>(); int active = 0, maximum = 0;
            var pending = CompletePagedSnapshot.ReadAsync<int>(async (page, size, token) =>
            {
                lock (requested) { requested.Add(page); active++; maximum = Math.Max(maximum, active); if (requested.Count == 5) entered.TrySetResult(true); }
                try
                {
                    check(size == 100, "every request uses the same bounded 100 rows");
                    if (page >= 2 && page <= 5) await release[page].Task.ConfigureAwait(false);
                    else if (page > 5) await Task.Delay((5 - page % 4) * 2, token).ConfigureAwait(false);
                    token.ThrowIfCancellationRequested(); return Page(page, 2414);
                }
                finally { lock (requested) active--; }
            }, value => value.ToString(), () => true, CancellationToken.None, maximumConcurrentBatches: 4);
            await Wait(entered.Task).ConfigureAwait(false);
            check(requested.SequenceEqual(Enumerable.Range(1, 5)) && !pending.IsCompleted, "seed is accepted before exactly four tail reads");
            release[5].SetResult(true); release[4].SetResult(true); release[3].SetResult(true);
            await Task.Delay(20).ConfigureAwait(false);
            check(requested.Count == 5, "out-of-order completed pages occupy the same bounded window");
            release[2].SetResult(true);
            var complete = await Wait(pending).ConfigureAwait(false);
            check(complete.SequenceEqual(Enumerable.Range(1, 2414)) && requested.Count == 25 && maximum == 4 && active == 0,
                "all 2414 rows including the 14-row final batch retain server order with at most four requests");

            int serialActive = 0, serialMaximum = 0;
            var serial = await CompletePagedSnapshot.ReadAsync<int>(async (page, size, token) =>
            {
                serialActive++; serialMaximum = Math.Max(serialMaximum, serialActive);
                await Task.Delay(1, token).ConfigureAwait(false); serialActive--;
                return new SnapshotPage<int> { Page = page, Size = 2, Total = 5, TotalPages = 3,
                    Items = page == 1 ? new[] { 1, 2 } : page == 2 ? new[] { 3, 4 } : new[] { 5 } };
            }, value => value.ToString(), () => true, CancellationToken.None).ConfigureAwait(false);
            check(serial.Count == 5 && serialMaximum == 1, "default caller retains its serial/clamped/no-proof contract");

            foreach (string defect in new[] { "missing", "uppercase", "newline", "short", "size", "total", "duplicate", "data", "snapshot", "scope" })
            {
                try
                {
                    await CompletePagedSnapshot.ReadAsync<int>((page, size, token) =>
                    {
                        var batch = Page(page, 314);
                        if (defect == "missing") batch.ReadDataVersion = null;
                        if (defect == "uppercase") batch.ReadSnapshotRevision = new string('A', 64);
                        if (defect == "newline") batch.ReadSnapshotRevision += "\n";
                        if (page == 2)
                        {
                            if (defect == "short") batch.Items = batch.Items.Take(99).ToArray();
                            if (defect == "size") batch.Size = 99;
                            if (defect == "total") batch.Total++;
                            if (defect == "duplicate") batch.Items = new[] { 1 }.Concat(batch.Items.Skip(1)).ToArray();
                            if (defect == "data") batch.ReadDataVersion = new string('e', 64);
                            if (defect == "snapshot") batch.ReadSnapshotRevision = new string('b', 64);
                            if (defect == "scope") batch.ReadScopeVersion = "other-owner";
                        }
                        return Task.FromResult(batch);
                    }, value => value.ToString(), () => true, CancellationToken.None, maximumConcurrentBatches: 4).ConfigureAwait(false);
                    throw new InvalidOperationException("Accepted malformed proof: " + defect);
                }
                catch (ApiException error) { check(error.Code == (defect == "scope" ? "READ_SCOPE_CHANGED" : "SNAPSHOT_CHANGED"), "no partial result for " + defect); }
            }
            foreach (string failure in new[] { "http", "owner", "duplicate" })
            {
                bool current = true; int cancelled = 0, started = 0;
                try
                {
                    await Wait(CompletePagedSnapshot.ReadAsync<int>(async (page, size, token) =>
                    {
                        Interlocked.Increment(ref started);
                        if (page == 1) return Page(page, 600);
                        if (page == 3)
                        {
                            await Task.Delay(20, token).ConfigureAwait(false);
                            if (failure == "owner") { current = false; return Page(page, 600); }
                            if (failure == "duplicate") { var overlap = Page(page, 600); overlap.Items = new[] { 1 }.Concat(overlap.Items.Skip(1)).ToArray(); return overlap; }
                            throw new ApiException("NOT_FOUND", "fixture endpoint missing", 404);
                        }
                        try { await Task.Delay(Timeout.Infinite, token).ConfigureAwait(false); }
                        catch (OperationCanceledException) { Interlocked.Increment(ref cancelled); throw; }
                        return Page(page, 600);
                    }, value => value.ToString(), () => current, CancellationToken.None, maximumConcurrentBatches: 4)).ConfigureAwait(false);
                    throw new InvalidOperationException("Expected tail failure.");
                }
                catch (ApiException error)
                {
                    check(error.Code == (failure == "owner" ? "READ_SCOPE_CHANGED" : failure == "duplicate" ? "SNAPSHOT_CHANGED" : "NOT_FOUND")
                        && error.StatusCode == (failure == "owner" ? (int?)403 : failure == "duplicate" ? null : (int?)404),
                        "a later failure wakes the blocked earlier page and preserves the original error type");
                    check(cancelled == 3 && started == 5, "cancel/drain only the owned four-batch window without starting page six");
                }
            }
            using (var cancel = new CancellationTokenSource())
            {
                int started = 0, drained = 0; var allStarted = Signal();
                var running = CompletePagedSnapshot.ReadAsync<int>(async (page, size, token) =>
                {
                    if (page == 1) return Page(page, 600);
                    if (Interlocked.Increment(ref started) == 4) allStarted.TrySetResult(true);
                    try { await Task.Delay(Timeout.Infinite, token).ConfigureAwait(false); }
                    finally { Interlocked.Increment(ref drained); }
                    return Page(page, 600);
                }, value => value.ToString(), () => true, cancel.Token, maximumConcurrentBatches: 4);
                await Wait(allStarted.Task).ConfigureAwait(false); cancel.Cancel();
                try { await Wait(running).ConfigureAwait(false); throw new InvalidOperationException("Expected owned cancellation."); }
                catch (OperationCanceledException) { check(drained == 4, "cancellation drains every owned tail and returns no prefix"); }
            }
            return assertions;
        }
        private static SnapshotPage<int> Page(int page, int total)
        {
            int offset = (page - 1) * 100;
            return new SnapshotPage<int> { Page = page, Size = 100, Total = total, TotalPages = (total + 99) / 100,
                Items = Enumerable.Range(offset + 1, Math.Max(0, Math.Min(100, total - offset))).ToArray(),
                ReadScopeVersion = "owning-goods-authority", ReadDataVersion = Data, ReadSnapshotRevision = Revision };
        }
        private static TaskCompletionSource<bool> Signal() { return new TaskCompletionSource<bool>(TaskCreationOptions.RunContinuationsAsynchronously); }
        private static async Task Wait(Task task)
        {
            if (await Task.WhenAny(task, Task.Delay(5000)).ConfigureAwait(false) != task) throw new InvalidOperationException("Bounded read did not settle.");
            await task.ConfigureAwait(false);
        }
        private static async Task<T> Wait<T>(Task<T> task) { await Wait((Task)task).ConfigureAwait(false); return await task.ConfigureAwait(false); }
    }
}
