using System;
using System.Net.Http;

namespace Uten.Legacy.Core
{
    /// <summary>Only reviewed unit output uses these limits. Ordinary writes/reads retain theirs.</summary>
    public static class UnitExportBudget
    {
        public const int RequestBytes = 16 * 1024 * 1024;
        public const int JobReplyBytes = RequestBytes + 65536;
        internal const int SelectionNodes = RequestBytes / 36 + 2;
        internal const int JournalBytes = 64 * 1024 * 1024;
        internal const int RetainedRequestBytes = 32 * 1024 * 1024;
    }

    // Created only by the permission-checked, canonical single-job read entry point.
    internal sealed class UnitExportReplyPermit
    {
        private const string Property = "Uten.UnitExportOriginalReceipt";
        private readonly Uri uri;
        internal UnitExportReplyPermit(Uri uri) { this.uri = uri; }
        internal void Attach(HttpRequestMessage request)
        {
            if (request.Method != HttpMethod.Get || request.RequestUri != uri) throw new InvalidOperationException();
            request.Properties.Add(Property, this);
        }
        internal static int ResponseLimit(HttpRequestMessage request, int ordinary)
        {
            object value;
            var permit = request.Properties.TryGetValue(Property, out value) ? value as UnitExportReplyPermit : null;
            var mutation = MutationWirePermit.From(request);
            return permit != null && request.Method == HttpMethod.Get && request.RequestUri == permit.uri
                || mutation != null && mutation.Owns(request) && mutation.IsUnitExport
                ? UnitExportBudget.JobReplyBytes : ordinary;
        }
    }
}
