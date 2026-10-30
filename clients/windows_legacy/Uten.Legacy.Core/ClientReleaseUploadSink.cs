using System;
using System.Diagnostics;
using System.IO;
using System.Net.Http;
using System.Security.Cryptography;
using System.Text.RegularExpressions;
using System.Threading;

namespace Uten.Legacy.Core
{
    /// <summary>Streaming request body for the one package upload route. The codec writes the
    /// announced Content-Length from this sink and streams the file in bounded chunks while
    /// hashing, so a 512 MiB package never enters managed memory. Never a second transport.</summary>
    internal sealed class ClientReleaseUploadSink
    {
        internal const string RequestProperty = "Uten.OwnedClientPackageUpload";
        internal const long MaximumPackageBytes = 512 * 1024 * 1024;
        private static readonly Regex PathPattern = new Regex(
            "^/api/admin/client-releases/([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})/package$",
            RegexOptions.Compiled | RegexOptions.CultureInvariant);

        private readonly string sourcePath;
        private readonly string expectedSha256;
        private readonly IProgress<long> progress;
        private readonly Action checkScope;

        internal string ReleaseId { get; private set; }
        internal long Length { get; private set; }
        internal long Written { get; private set; }
        internal bool Completed { get; private set; }

        internal ClientReleaseUploadSink(string releaseId, string sourcePath, long length, string expectedSha256,
            IProgress<long> progress, Action checkScope)
        {
            if (String.IsNullOrEmpty(sourcePath) || !PathPattern.IsMatch("/api/admin/client-releases/" + releaseId + "/package")
                || expectedSha256 == null || !Regex.IsMatch(expectedSha256, "^[0-9a-fA-F]{64}$")
                || length < 1 || length > MaximumPackageBytes)
                throw new ArgumentException("上传信息无效。");
            ReleaseId = releaseId;
            this.sourcePath = sourcePath;
            this.expectedSha256 = expectedSha256.ToLowerInvariant();
            this.progress = progress;
            this.checkScope = checkScope;
            Length = length;
        }

        internal static ClientReleaseUploadSink FromRequest(HttpRequestMessage request)
        {
            object value;
            return request != null && request.Properties.TryGetValue(RequestProperty, out value)
                ? value as ClientReleaseUploadSink : null;
        }

        internal bool Owns(HttpRequestMessage request)
        {
            return request != null && request.Method.Method == "PUT" && request.RequestUri != null
                && PathPattern.IsMatch(request.RequestUri.AbsolutePath)
                && request.RequestUri.AbsolutePath.EndsWith("/" + ReleaseId + "/package", StringComparison.Ordinal)
                && request.RequestUri.Query.Length == 0;
        }

        /// <summary>Streams the file to the TLS stream while hashing. A changed source file
        /// aborts the upload as an IO failure; the server's own SHA check stays authoritative.</summary>
        internal void WriteTo(Stream target, CancellationToken cancellationToken)
        {
            using (var hash = SHA256.Create())
            using (var source = new FileStream(sourcePath, FileMode.Open, FileAccess.Read, FileShare.Read, 65536, FileOptions.SequentialScan))
            {
                if (source.Length != Length) throw new IOException("原文件大小与发布信息不一致。");
                var buffer = new byte[65536];
                var reporting = Stopwatch.StartNew();
                if (progress != null) progress.Report(0);
                int read;
                while ((read = source.Read(buffer, 0, buffer.Length)) != 0)
                {
                    cancellationToken.ThrowIfCancellationRequested();
                    if (checkScope != null) checkScope();
                    if (Written + read > Length) throw new IOException("原文件内容超过发布信息的大小。");
                    target.Write(buffer, 0, read);
                    hash.TransformBlock(buffer, 0, read, null, 0);
                    Written += read;
                    if (progress != null && (Written == Length || reporting.ElapsedMilliseconds >= 100))
                    {
                        reporting.Restart();
                        progress.Report(Written);
                    }
                }
                if (Written != Length) throw new IOException("原文件读取不完整，上传未完成。");
                hash.TransformFinalBlock(new byte[0], 0, 0);
                var actual = BitConverter.ToString(hash.Hash).Replace("-", "").ToLowerInvariant();
                if (actual != expectedSha256) throw new IOException("上传文件与准备阶段的SHA-256不一致，已中止。");
                Completed = true;
            }
        }
    }
}
