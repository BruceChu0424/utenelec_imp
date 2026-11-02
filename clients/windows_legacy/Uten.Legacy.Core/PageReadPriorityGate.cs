using System;
using System.Net.Http;
using System.Text.RegularExpressions;
using System.Threading;
using System.Threading.Tasks;

namespace Uten.Legacy.Core
{
    // Leave the existing eight-connection native TLS budget intact. Optional
    // facets/lookups/dictionaries may occupy only two of those connections.
    // Session cancellation, origin checks and all read proofs remain mandatory.
    internal sealed class PageReadPriorityGate
    {
        private readonly SemaphoreSlim auxiliary = new SemaphoreSlim(2, 2);
        internal static bool IsAuxiliary(HttpRequestMessage request)
        {
            var path = request.RequestUri.AbsolutePath;
            return (request.Method == HttpMethod.Get ||
                request.Method == HttpMethod.Post && path.EndsWith("/facets", StringComparison.Ordinal))
                && Regex.IsMatch(path, @"/(facets|lookup|dict)(/|$)");
        }
        internal async Task<IDisposable> EnterAsync(HttpRequestMessage request, CancellationToken cancellation)
        {
            if (!IsAuxiliary(request)) return null;
            await auxiliary.WaitAsync(cancellation).ConfigureAwait(false);
            return new Release(auxiliary);
        }
        private sealed class Release : IDisposable
        {
            private SemaphoreSlim owner;
            internal Release(SemaphoreSlim owner) { this.owner = owner; }
            public void Dispose() { Interlocked.Exchange(ref owner, null)?.Release(); }
        }
    }
}
