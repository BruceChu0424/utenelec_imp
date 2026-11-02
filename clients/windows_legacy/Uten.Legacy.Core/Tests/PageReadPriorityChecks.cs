using System;
using System.Net.Http;
using System.Threading;
using System.Threading.Tasks;

namespace Uten.Legacy.Core.Tests
{
    public static class PageReadPriorityChecks
    {
        public static void Run() { Check().GetAwaiter().GetResult(); }
        private static async Task Check()
        {
            var gate = new PageReadPriorityGate();
            using (var optional = new HttpRequestMessage(HttpMethod.Get, "https://fixture.test/api/master/goods/facets"))
            using (var row = new HttpRequestMessage(HttpMethod.Get, "https://fixture.test/api/master/goods/page?scopeWarehouseId=a"))
            using (var count = new HttpRequestMessage(HttpMethod.Get, "https://fixture.test/api/documents/status-counts?scopeWarehouseId=b"))
            using (var write = new HttpRequestMessage(HttpMethod.Put, "https://fixture.test/api/master/goods/facets"))
            using (var first = await gate.EnterAsync(optional, CancellationToken.None))
            using (var second = await gate.EnterAsync(optional, CancellationToken.None))
            using (var cancellation = new CancellationTokenSource())
            {
                var blocked = gate.EnterAsync(optional, cancellation.Token);
                if (blocked.IsCompleted) throw new InvalidOperationException("Third auxiliary read occupied a connection");
                if (await gate.EnterAsync(row, CancellationToken.None) != null ||
                    await gate.EnterAsync(count, CancellationToken.None) != null ||
                    await gate.EnterAsync(write, CancellationToken.None) != null)
                    throw new InvalidOperationException("Rows, exact-scope counts or commands were delayed by auxiliary reads");
                cancellation.Cancel();
                try { await blocked; throw new InvalidOperationException("Cancelled auxiliary read dispatched"); }
                catch (OperationCanceledException) { }
            }
            using (var optional = new HttpRequestMessage(HttpMethod.Get, "https://fixture.test/api/master/goods/lookup"))
            using (var lease = await gate.EnterAsync(optional, CancellationToken.None))
            {
                if (lease == null) throw new InvalidOperationException("Lookup bypassed the auxiliary budget");
                lease.Dispose(); // Releases are idempotent, including nested finally paths.
            }
        }
    }
}
