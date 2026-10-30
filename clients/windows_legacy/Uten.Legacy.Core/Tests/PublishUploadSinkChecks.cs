using System;
using System.IO;
using System.Net.Http;
using System.Security.Cryptography;
using System.Threading;

namespace Uten.Legacy.Core
{
    /// <summary>Offline upload-sink fixtures inside the Core assembly: the sink is internal, so
    /// its frozen-path ownership contract is pinned next to the wire codec that enforces it.</summary>
    public static class PublishUploadSinkChecks
    {
        public static int Run()
        {
            int assertions = 0;
            Action<bool, string> check = (condition, message) =>
            {
                if (!condition) throw new InvalidOperationException("Publish upload sink contract: " + message);
                assertions++;
            };
            var releaseId = Guid.NewGuid().ToString("D");
            var path = Path.Combine(Path.GetTempPath(), "uten-upload-sink-" + Guid.NewGuid().ToString("N") + ".zip");
            File.WriteAllBytes(path, new byte[] { 1, 2, 3, 4 });
            var sha = BitConverter.ToString(SHA256.Create().ComputeHash(new byte[] { 1, 2, 3, 4 }))
                .Replace("-", "").ToLowerInvariant();
            long reported = -1;
            var sink = new ClientReleaseUploadSink(releaseId, path, 4, sha,
                new InlineProgress(value => reported = value), delegate { });
            var good = new HttpRequestMessage(new HttpMethod("PUT"),
                new Uri("https://company.example.test/api/admin/client-releases/" + releaseId + "/package"));
            check(sink.Owns(good), "sink owns its frozen PUT path");
            check(sink.Length == 4, "declared length comes from the frozen contract");
            var wrongId = new HttpRequestMessage(new HttpMethod("PUT"),
                new Uri("https://company.example.test/api/admin/client-releases/" + Guid.NewGuid().ToString("D") + "/package"));
            check(!sink.Owns(wrongId), "another record's upload is not owned");
            var post = new HttpRequestMessage(HttpMethod.Post,
                new Uri("https://company.example.test/api/admin/client-releases/" + releaseId + "/package"));
            check(!sink.Owns(post), "only PUT is an upload");
            var queried = new HttpRequestMessage(new HttpMethod("PUT"),
                new Uri("https://company.example.test/api/admin/client-releases/" + releaseId + "/package?x=1"));
            check(!sink.Owns(queried), "query strings are not part of the upload contract");
            using (var output = new MemoryStream())
            {
                sink.WriteTo(output, CancellationToken.None);
                check(output.Length == 4 && sink.Completed && sink.Written == 4, "streaming write completes the whole file");
            }
            check(reported >= 0, "progress reports while streaming");
            try { File.Delete(path); } catch (IOException) { }
            return assertions;
        }

        /// <summary>Progress callbacks captured synchronously so the offline check can assert
        /// them right after the streaming write.</summary>
        private sealed class InlineProgress : IProgress<long>
        {
            private readonly Action<long> store;
            internal InlineProgress(Action<long> store) { this.store = store; }
            public void Report(long value) { store(value); }
        }
    }
}
