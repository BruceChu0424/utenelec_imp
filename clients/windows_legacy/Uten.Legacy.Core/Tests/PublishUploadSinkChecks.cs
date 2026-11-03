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
                check(output.Length == 4 && sink.Started && sink.Completed && sink.Written == 4, "streaming write completes the whole file");
            }
            check(reported >= 0, "progress reports while streaming");
            var normal = TimeSpan.FromSeconds(45);
            using (var publish = new HttpRequestMessage(HttpMethod.Post,
                new Uri("https://company.example.test/api/admin/client-releases/" + releaseId + "/publish")))
            {
                ClientReleaseReceiveBudget.Bind(publish);
                check(ClientReleaseReceiveBudget.ForRequest(publish, normal) == TimeSpan.FromMinutes(5),
                    "only the owned publish response has a five-minute budget");
                foreach (var relative in new[] { "admin/client-releases", "admin/client-releases/" + releaseId + "/withdraw" })
                using (var ordinary = new HttpRequestMessage(HttpMethod.Post, new Uri("https://company.example.test/api/" + relative)))
                    check(ClientReleaseReceiveBudget.ForRequest(ordinary, normal) == normal,
                        "prepare and withdraw retain the normal transport budget");
                using (var copied = new HttpRequestMessage(HttpMethod.Post, publish.RequestUri))
                {
                    copied.Properties[ClientReleaseReceiveBudget.RequestProperty] = publish.Properties[ClientReleaseReceiveBudget.RequestProperty];
                    try { ClientReleaseReceiveBudget.ForRequest(copied, normal); throw new InvalidOperationException("Copied publish budget accepted"); }
                    catch (HttpRequestException) { assertions++; }
                }
                publish.RequestUri = new Uri("https://company.example.test/api/admin/client-releases/" + releaseId + "/withdraw");
                try { ClientReleaseReceiveBudget.ForRequest(publish, normal); throw new InvalidOperationException("Moved publish budget accepted"); }
                catch (HttpRequestException) { assertions++; }
            }
            good.Properties[ClientReleaseUploadSink.RequestProperty] = sink;
            check(ClientReleaseReceiveBudget.ForRequest(good, normal) == TimeSpan.FromMinutes(5),
                "the existing owned package PUT receives five minutes for server validation");
            wrongId.Properties[ClientReleaseUploadSink.RequestProperty] = sink;
            try { ClientReleaseReceiveBudget.ForRequest(wrongId, normal); throw new InvalidOperationException("Wrong upload owner accepted"); }
            catch (HttpRequestException) { assertions++; }
            var mismatch = new ClientReleaseUploadSink(releaseId, path, 4, new string('0', 64), null, delegate { });
            using (var output = new MemoryStream())
            {
                try { mismatch.WriteTo(output, CancellationToken.None); throw new InvalidOperationException("Changed upload hash accepted"); }
                catch (IOException) { assertions++; }
                check(mismatch.Started && !mismatch.Completed, "hash mismatch after wire writing remains an uncertain upload");
            }
            var retired = new ClientReleaseUploadSink(releaseId, path, 4, sha, null,
                delegate { throw new ApiException("SESSION_CHANGED", "fixture owner retired"); });
            using (var output = new MemoryStream())
            {
                try { retired.WriteTo(output, CancellationToken.None); throw new InvalidOperationException("Retired owner wrote upload bytes"); }
                catch (ApiException) { assertions++; }
                check(!retired.Started && output.Length == 0, "owner retirement prevents the first body write");
            }
            var partial = new ClientReleaseUploadSink(releaseId, path, 4, sha, null, delegate { });
            using (var output = new PartialWriteStream())
            {
                try { partial.WriteTo(output, CancellationToken.None); throw new InvalidOperationException("Partial write did not fail"); }
                catch (IOException) { assertions++; }
                check(partial.Started && !partial.Completed, "a partial stream failure is marked started before Write returns");
            }
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

        private sealed class PartialWriteStream : MemoryStream
        {
            public override void Write(byte[] buffer, int offset, int count)
            { base.Write(buffer, offset, Math.Min(count, 2)); throw new IOException("fixture partial body write"); }
        }
    }
}
