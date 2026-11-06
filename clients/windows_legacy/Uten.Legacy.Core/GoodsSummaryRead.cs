using System;
using System.Collections.Generic;
using System.Net.Http;
using System.Text.RegularExpressions;
using System.Threading;
using System.Threading.Tasks;

namespace Uten.Legacy.Core
{
    public sealed partial class SessionCoordinator
    {
        /// <summary>Only the owning read-only goods summary POST. It cannot send a
        /// business command or enter the mutation journal; each request stays bounded.</summary>
        public Task<string> ReadGoodsSummariesAsync(string categoryId, string keyword, int page, int size,
            string readSnapshotRevision, CancellationToken cancellationToken)
        {
            if (page < 1 || size < 1 || size > 100) throw new ArgumentOutOfRangeException(nameof(page));
            Guid category;
            if (!String.IsNullOrWhiteSpace(categoryId) && !Guid.TryParse(categoryId, out category))
                throw new ArgumentException("分类关系必须是 UUID。", nameof(categoryId));
            if (readSnapshotRevision != null && (readSnapshotRevision.Length != 64 || !Regex.IsMatch(readSnapshotRevision, "^[0-9a-f]{64}$", RegexOptions.CultureInvariant))
                || page > 1 && readSnapshotRevision == null)
                throw new ArgumentException("请保留首批货品摘要的真实读取版本。", nameof(readSnapshotRevision));
            var filter = new Dictionary<string, object>();
            if (!String.IsNullOrWhiteSpace(categoryId)) filter.Add("categoryId", categoryId);
            if (!String.IsNullOrWhiteSpace(keyword)) filter.Add("keyword", keyword.Trim());
            // Omitted filters/sort/order retain the exact defaults of the original GET.
            var body = new Dictionary<string, object> { { "filter", filter }, { "page", page }, { "size", size } };
            string path = "master/goods/summaries" + (readSnapshotRevision == null ? ""
                : "?readSnapshotRevision=" + Uri.EscapeDataString(readSnapshotRevision));
            return ReadJsonAsync(HttpMethod.Post, path, body, cancellationToken, "goods:view");
        }
    }
}
