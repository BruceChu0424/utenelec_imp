using System;
using System.IO;
using System.IO.Compression;
using System.Net;
using System.Net.Http;
using System.Text;
using System.Threading;

namespace Uten.Legacy.Core.Tests
{
    /// <summary>Only in-memory HTTP fixtures. No socket, backend, or certificate-store operation.</summary>
    public static class ManagedHttp11Checks
    {
        public static void Run()
        {
            ContentLengthAndRequestEncoding();
            ChunkedAndCloseDelimited();
            GzipIsBoundedAndExact();
            AmbiguousFramingAndTruncationAreRejected();
            HeaderAndBodyLimits();
            RedirectsAndInvalidProtocolAreRejected();
            InvalidRequestsNeverReachTheStream();
            CancellationAndResponseBodyHandoff();
        }

#if MANAGED_HTTP11_STANDALONE
        private static void Main()
        {
            try { Run(); Console.WriteLine("Managed HTTP/1.1 offline checks passed."); }
            catch (Exception error)
            {
                Console.Error.WriteLine(error.GetType().FullName + ": " + error.Message);
                Console.Error.WriteLine(error.StackTrace);
                Environment.ExitCode = 1;
            }
        }
#endif

        private static void ContentLengthAndRequestEncoding()
        {
            using (var request = Request(HttpMethod.Post, "https://api.example.test:8443/api/auth/login?device=desktop"))
            using (var stream = new FixtureStream(Ascii("HTTP/1.1 401 Unauthorized\r\nContent-Length: 2\r\n"
                + "Content-Type: application/json; charset=utf-8\r\nWWW-Authenticate: Bearer error=invalid_token\r\n"
                + "X-Trace-Id: sample\r\nSet-Cookie: session=must-not-be-returned\r\n\r\n{}"), 1))
            {
                request.Content = new StringContent("{\"account\":\"sample\"}", Encoding.UTF8, "application/json");
                request.Headers.Authorization = new System.Net.Http.Headers.AuthenticationHeaderValue("Bearer", "fixture-token");
                using (var response = ManagedHttp11.SendAndReceive(stream, request, 1024, CancellationToken.None))
                {
                    Equal(HttpStatusCode.Unauthorized, response.StatusCode, "Business status is returned");
                    Equal("{}", Read(response), "Content-Length response");
                    Equal(2L, response.Content.Headers.ContentLength.Value, "actual content length");
                    Equal("application/json", response.Content.Headers.ContentType.MediaType, "content type");
                    True(response.Headers.Contains("WWW-Authenticate") && response.Headers.Contains("X-Trace-Id"), "business headers");
                    True(!response.Headers.Contains("Set-Cookie"), "no cookie handling");
                }
                var written = Encoding.ASCII.GetString(stream.Written);
                True(written.StartsWith("POST /api/auth/login?device=desktop HTTP/1.1\r\n", StringComparison.Ordinal), "origin-form request target");
                True(written.Contains("\r\nHost: api.example.test:8443\r\n"), "Host is rebuilt from URI");
                True(written.Contains("\r\nConnection: close\r\n") && written.Contains("\r\nAccept-Encoding: gzip\r\n"), "bounded connection policy");
                True(written.Contains("\r\nAuthorization: Bearer fixture-token\r\n"), "explicit authorization is retained");
                True(written.EndsWith("\r\n\r\n{\"account\":\"sample\"}", StringComparison.Ordinal), "bounded POST body");
            }
            using (var request = Request(HttpMethod.Get, "https://[2001:db8::1]:8443/api/auth/me"))
            using (var stream = new FixtureStream(Ascii("HTTP/1.1 204 No Content\r\n\r\n")))
            using (var response = ManagedHttp11.SendAndReceive(stream, request, 32, CancellationToken.None))
            {
                Equal(String.Empty, Read(response), "204 response");
                True(Encoding.ASCII.GetString(stream.Written).IndexOf("Host: [" + request.RequestUri.IdnHost + "]:8443\r\n", StringComparison.OrdinalIgnoreCase) >= 0,
                    "IPv6 Host syntax");
            }
        }

        private static void ChunkedAndCloseDelimited()
        {
            Equal("Wikipedia", Response("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\nTrailer: X-Checksum\r\n\r\n"
                + "4;name=token;quoted=\"a\\\"b\"\r\nWiki\r\n5\r\npedia\r\n0\r\nX-Checksum: sample\r\n\r\n", 9), "chunk decoding at limit");
            Equal("closed", Response("HTTP/1.1 200 OK\r\nConnection: close\r\n\r\nclosed", 6), "close framing at limit");
            Equal("{}", Response("HTTP/1.1 103 Early Hints\r\nLink: </api>; rel=preconnect\r\n\r\n"
                + "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\n{}", 2), "bounded informational response");
            using (var request = Request())
            using (var stream = new FixtureStream(Ascii("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n"
                + "Connection: close, X-Hop\r\nX-Hop: omitted\r\n\r\n0\r\nX-End: retained\r\n\r\n")))
            using (var response = ManagedHttp11.SendAndReceive(stream, request, 8, CancellationToken.None))
            {
                True(!response.Headers.Contains("Transfer-Encoding") && !response.Headers.Contains("X-Hop"), "hop headers removed");
                True(response.Headers.Contains("X-End"), "safe chunk trailers retained");
            }
        }

        private static void GzipIsBoundedAndExact()
        {
            var text = new string('x', 512);
            var gzip = Compress(Ascii(text));
            Equal(text, Response(GzipResponse(gzip), 512), "gzip decode");
            Equal(String.Empty, Response(GzipResponse(Compress(new byte[0])), 128), "empty gzip decode");
            Reject(GzipResponse(gzip), 511);
            Reject(GzipResponse(gzip), gzip.Length - 1); // compressed-byte cap independently enforced
            Reject(GzipResponse(Slice(gzip, 0, gzip.Length - 1)), 512);
            Reject(GzipResponse(Slice(gzip, 0, gzip.Length - 8)), 512);
            Reject(GzipResponse(Concat(Slice(gzip, 0, gzip.Length - 9), Slice(gzip, gzip.Length - 8, 8))), 512);
            var badCrc = (byte[])gzip.Clone();
            badCrc[badCrc.Length - 8] ^= 1;
            Reject(GzipResponse(badCrc), 512);
            var badLength = (byte[])gzip.Clone();
            badLength[badLength.Length - 4] ^= 1;
            Reject(GzipResponse(badLength), 512);
            Reject(GzipResponse(Concat(gzip, gzip)), 1024);
            Reject(GzipResponse(Concat(gzip, new byte[] { 0 })), 512);
            Reject(GzipResponse(Concat(Slice(gzip, 0, 10), Slice(gzip, 11, gzip.Length - 11))), 512);
            Reject("HTTP/1.1 200 OK\r\nContent-Encoding: gzip, gzip\r\nContent-Length: 0\r\n\r\n");
            Reject("HTTP/1.1 200 OK\r\nContent-Encoding: gzip\r\nContent-Encoding: gzip\r\nContent-Length: 0\r\n\r\n");
            var chunk = gzip.Length.ToString("x", System.Globalization.CultureInfo.InvariantCulture);
            Equal(text, Response(Concat(Ascii("HTTP/1.1 200 OK\r\nContent-Encoding: gzip\r\nTransfer-Encoding: chunked\r\n\r\n"
                + chunk + "\r\n"), gzip, Ascii("\r\n0\r\n\r\n")), 512), "chunked gzip");
        }

        private static void AmbiguousFramingAndTruncationAreRejected()
        {
            foreach (var fixture in new[]
            {
                "HTTP/1.1 200 OK\r\nContent-Length: 0\r\nTransfer-Encoding: chunked\r\n\r\n0\r\n\r\n",
                "HTTP/1.1 200 OK\r\nContent-Length: 2\r\ncontent-length: 2\r\n\r\n{}",
                "HTTP/1.1 200 OK\r\nContent-Length: 2, 2\r\n\r\n{}",
                "HTTP/1.1 200 OK\r\nContent-Length: +2\r\n\r\n{}",
                "HTTP/1.1 200 OK\r\nContent-Length: -2\r\n\r\n{}",
                "HTTP/1.1 200 OK\r\nContent-Length: 999999999999999999999999999\r\n\r\n",
                "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked, chunked\r\n\r\n0\r\n\r\n",
                "HTTP/1.1 200 OK\r\nTransfer-Encoding: gzip, chunked\r\n\r\n0\r\n\r\n",
                "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\nTransfer-Encoding: chunked\r\n\r\n0\r\n\r\n",
                "HTTP/1.1 200 OK\r\nContent-Length: 3\r\n\r\n{}",
                "HTTP/1.1 200 OK\r\nContent-Length: 0\r\n",
                "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n2\r\n{}\r\n",
                "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n3\r\n{}",
                "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n2\r\n{}XX0\r\n\r\n",
                "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n-1\r\n",
                "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n+1\r\n",
                "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n 1\r\n",
                "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\nFFFFFFFFFFFFFFFF\r\n",
                "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n1;broken=\"unterminated\r\na\r\n0\r\n\r\n",
                "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n1;broken=\r\na\r\n0\r\n\r\n",
                "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n0\r\nContent-Length: 0\r\n\r\n",
                "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\nTrailer: Authorization\r\n\r\n0\r\n\r\n",
                "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\nX-Trace: one\r\n\r\n0\r\nX-Trace: two\r\n\r\n",
                "HTTP/1.1 200 OK\r\nConnection: Content-Length\r\nContent-Length: 0\r\n\r\n",
                "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Type: text/html\r\nContent-Length: 0\r\n\r\n",
                "HTTP/1.1 204 No Content\r\nContent-Length: 2\r\n\r\n{}",
                "HTTP/1.1 205 Reset Content\r\nContent-Length: 2\r\n\r\n{}"
            }) Reject(fixture);
        }

        private static void HeaderAndBodyLimits()
        {
            Reject("HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\n12345", 4);
            Reject("HTTP/1.1 200 OK\r\n\r\n12345", 4);
            Reject("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n5\r\n12345\r\n0\r\n\r\n", 4);
            Reject("HTTP/1.1 200 OK\r\nX-Long: " + new string('a', 8192) + "\r\n\r\n");
            var headers = new StringBuilder("HTTP/1.1 200 OK\r\n");
            for (var i = 0; i < 5; i++) headers.Append("X-Large-").Append(i).Append(": ").Append(new string('a', 7000)).Append("\r\n");
            Reject(headers + "\r\n");
            headers = new StringBuilder("HTTP/1.1 200 OK\r\nContent-Length: 0\r\n");
            for (var i = 0; i < 100; i++) headers.Append("X-Count-").Append(i).Append(": a\r\n");
            Reject(headers + "\r\n");
            var chunks = new StringBuilder("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n");
            for (var i = 0; i < 7000; i++) chunks.Append("1\r\nx\r\n");
            Reject(chunks + "0\r\n\r\n", 8192);
            var trailer = new StringBuilder("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n0\r\n");
            for (var i = 0; i < 100; i++) trailer.Append("X-Trailer-").Append(i).Append(": a\r\n");
            Reject(trailer + "\r\n");

            using (var request = Request(HttpMethod.Post))
            {
                request.Content = new ByteArrayContent(new byte[16384]);
                using (var stream = new FixtureStream(Ascii("HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n")))
                using (ManagedHttp11.SendAndReceive(stream, request, 8, CancellationToken.None))
                    True(stream.Written.Length > 16384, "request limit includes full body");
            }
            using (var request = Request(HttpMethod.Post))
            {
                request.Content = new ByteArrayContent(new byte[16385]);
                RejectRequest(request);
            }
            using (var request = Request())
            {
                request.Headers.TryAddWithoutValidation("X-Large", new string('a', 8192));
                RejectRequest(request);
            }
            using (var request = Request())
            {
                for (var i = 0; i < 5; i++) request.Headers.TryAddWithoutValidation("X-Large-" + i, new string('a', 7000));
                RejectRequest(request);
            }
            using (var request = Request())
            {
                for (var i = 0; i < 101; i++) request.Headers.TryAddWithoutValidation("X-Count-" + i, "a");
                RejectRequest(request);
            }
        }

        private static void RedirectsAndInvalidProtocolAreRejected()
        {
            foreach (var status in new[] { 300, 301, 302, 303, 304, 307, 308, 399 })
                Reject("HTTP/1.1 " + status + " Redirect\r\nLocation: https://other.example.test/api/auth/login\r\nContent-Length: 0\r\n\r\n");
            foreach (var fixture in new[]
            {
                "HTTP/1.0 200 OK\r\nContent-Length: 0\r\n\r\n",
                "HTTP/2 200 OK\r\nContent-Length: 0\r\n\r\n",
                "HTTP/1.1 200OK\r\nContent-Length: 0\r\n\r\n",
                "HTTP/1.1 600 Invalid\r\nContent-Length: 0\r\n\r\n",
                "HTTP/1.1 101 Switching Protocols\r\n\r\n",
                "HTTP/1.1 200 OK\nContent-Length: 0\n\n",
                "HTTP/1.1 200 OK\r\n Content-Length: 0\r\n\r\n",
                "HTTP/1.1 200 OK\r\nContent-Length : 0\r\n\r\n",
                "HTTP/1.1 200 OK\r\nX-Invalid: a\0b\r\n\r\n",
                "HTTP/1.1 200 OK\r\nX-Invalid: a\r\n\tb\r\n\r\n"
            }) Reject(fixture);
            var informational = new StringBuilder();
            for (var i = 0; i < 6; i++) informational.Append("HTTP/1.1 100 Continue\r\n\r\n");
            Reject(informational + "HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n");
        }

        private static void InvalidRequestsNeverReachTheStream()
        {
            var invalidUriIndex = 0;
            foreach (var uri in new[]
            {
                "http://api.example.test/api/auth/me", "https://api.example.test/", "https://api.example.test/api",
                "https://api.example.test/apix/auth/me", "https://api.example.test/API/auth/me",
                "https://user:secret@api.example.test/api/auth/me", "https://api.example.test/api/auth/me#fragment",
                "https://api.example.test/api/../../auth/me", "https://api.example.test/api/a%2fb",
                "https://api.example.test/api/a%5cb", "https://api.example.test/api/auth%0d%0ame",
                "https://api.example.test/api/au\\th/me", "https://api.example.test/api/auth/me\r\n"
            })
            {
                using (var request = Request(HttpMethod.Get, uri))
                {
                    try { RejectRequest(request); }
                    catch (InvalidOperationException) { throw new InvalidOperationException("Invalid URI fixture failed at index " + invalidUriIndex); }
                }
                invalidUriIndex++;
            }
            using (var request = new HttpRequestMessage(HttpMethod.Get, new Uri("api/auth/me", UriKind.Relative))) RejectRequest(request);
            using (var request = Request(HttpMethod.Delete)) RejectRequest(request);
            using (var request = Request()) { request.Version = new Version(1, 0); RejectRequest(request); }
            foreach (var name in new[] { "Host", "Transfer-Encoding", "Expect", "Connection", "Cookie", "Accept-Encoding", "TE", "Trailer" })
                using (var request = Request())
                {
                    True(request.Headers.TryAddWithoutValidation(name, "untrusted"), "fixture header added");
                    RejectRequest(request);
                }
            using (var request = Request())
            using (var stream = new FixtureStream(Ascii("HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n")))
            {
                True(request.Headers.TryAddWithoutValidation("X-Value", "safe\r\nAuthorization: injected"), "injection fixture accepted by HttpHeaders");
                // Framework 4.x can discard raw CR/LF header values on enumeration.
                // Either that rejection or the codec's own validation must stop injection.
                try { using (ManagedHttp11.SendAndReceive(stream, request, 1024, CancellationToken.None)) { } }
                catch (HttpRequestException) { Equal(0, stream.Written.Length, "injection rejected before send"); }
                var written = Encoding.ASCII.GetString(stream.Written);
                True(!written.Contains("Authorization: injected") && !written.Contains("X-Value:"), "CRLF injection has no wire representation");
            }
            using (var request = Request())
            { request.Headers.TryAddWithoutValidation("X-Value", "safe\u007fvalue"); RejectRequest(request); }
            using (var request = Request(HttpMethod.Post))
            {
                request.Content = new StringContent("{}");
                request.Content.Headers.ContentLength = 1;
                RejectRequest(request);
            }
            using (var request = Request()) { request.Content = new StringContent("{}"); RejectRequest(request); }
        }

        private static void CancellationAndResponseBodyHandoff()
        {
            using (var source = new CancellationTokenSource())
            using (var request = Request())
            using (var stream = new FixtureStream(Ascii("HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\n{}")))
            {
                source.Cancel();
                Throws<OperationCanceledException>(() => ManagedHttp11.SendAndReceive(stream, request, 16, source.Token));
                Equal(0, stream.Written.Length, "cancelled request has no bytes");
            }
            using (var source = new CancellationTokenSource())
            using (var request = Request())
            using (var stream = new FixtureStream(Ascii("HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\n{}"), 1))
            {
                var called = 0;
                using (var response = ManagedHttp11.SendAndReceive(stream, request, 16, source.Token, status =>
                {
                    Equal(200, status, "handoff final status");
                    called++;
                    source.Cancel();
                    return CancellationToken.None;
                })) Equal("{}", Read(response), "body uses replacement token after old token cancellation");
                Equal(1, called, "handoff once");
            }
            using (var source = new CancellationTokenSource())
            using (var request = Request())
            using (var stream = new FixtureStream(GzipResponse(Compress(Ascii("{}"))), 1))
            using (var response = ManagedHttp11.SendAndReceive(stream, request, 128, source.Token, status =>
            {
                source.Cancel();
                return CancellationToken.None;
            })) Equal("{}", Read(response), "gzip uses replacement token");
            using (var source = new CancellationTokenSource())
            using (var request = Request())
            using (var stream = new FixtureStream(Ascii("HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\n{}")))
            {
                source.Cancel();
                Throws<OperationCanceledException>(() => ManagedHttp11.SendAndReceive(stream, request, 16, CancellationToken.None,
                    status => source.Token));
            }
            using (var request = Request())
            using (var stream = new FixtureStream(Ascii("HTTP/1.1 200 OK\r\nContent-Length: 1\r\nTransfer-Encoding: chunked\r\n\r\n")))
            {
                var called = false;
                Throws<HttpRequestException>(() => ManagedHttp11.SendAndReceive(stream, request, 16, CancellationToken.None,
                    status => { called = true; return CancellationToken.None; }));
                True(!called, "malformed headers cannot activate body handoff");
            }
        }

        private static HttpRequestMessage Request(HttpMethod method = null, string uri = "https://api.example.test/api/auth/me")
        { return new HttpRequestMessage(method ?? HttpMethod.Get, new Uri(uri, UriKind.Absolute)); }
        private static string Read(HttpResponseMessage response) { return response.Content.ReadAsStringAsync().GetAwaiter().GetResult(); }
        private static string Response(string fixture, int limit = 1024) { return Response(Ascii(fixture), limit); }
        private static string Response(byte[] fixture, int limit = 1024)
        {
            using (var request = Request())
            using (var stream = new FixtureStream(fixture, 2))
            using (var response = ManagedHttp11.SendAndReceive(stream, request, limit, CancellationToken.None)) return Read(response);
        }
        private static void Reject(string fixture, int limit = 1024) { Reject(Ascii(fixture), limit); }
        private static void Reject(byte[] fixture, int limit = 1024) { Throws<HttpRequestException>(() => Response(fixture, limit)); }
        private static void RejectRequest(HttpRequestMessage request)
        {
            using (var stream = new FixtureStream(Ascii("HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n")))
            {
                Throws<HttpRequestException>(() => ManagedHttp11.SendAndReceive(stream, request, 1024, CancellationToken.None));
                Equal(0, stream.Written.Length, "invalid request never reaches transport");
            }
        }
        private static byte[] Ascii(string value) { return Encoding.ASCII.GetBytes(value); }
        private static byte[] Slice(byte[] value, int offset, int count)
        { var result = new byte[count]; Buffer.BlockCopy(value, offset, result, 0, count); return result; }
        private static byte[] Concat(params byte[][] values)
        {
            using (var output = new MemoryStream())
            { foreach (var value in values) output.Write(value, 0, value.Length); return output.ToArray(); }
        }
        private static byte[] Compress(byte[] bytes)
        {
            // Framework 4.x emits no gzip member if no non-empty Write was made.
            if (bytes.Length == 0) return new byte[] { 31, 139, 8, 0, 0, 0, 0, 0, 0, 3, 3, 0, 0, 0, 0, 0, 0, 0, 0, 0 };
            using (var output = new MemoryStream())
            {
                using (var gzip = new GZipStream(output, CompressionMode.Compress, true)) gzip.Write(bytes, 0, bytes.Length);
                return output.ToArray();
            }
        }
        private static byte[] GzipResponse(byte[] bytes)
        {
            return Concat(Ascii("HTTP/1.1 200 OK\r\nContent-Encoding: gzip\r\nContent-Length: "
                + bytes.Length.ToString(System.Globalization.CultureInfo.InvariantCulture) + "\r\n\r\n"), bytes);
        }
        private static void True(bool value, string message) { if (!value) throw new InvalidOperationException("HTTP codec check failed: " + message); }
        private static void Equal<T>(T expected, T actual, string message)
        { True(Object.Equals(expected, actual), message); }
        private static void Throws<T>(Action action) where T : Exception
        {
            try { action(); }
            catch (T) { return; }
            throw new InvalidOperationException("HTTP codec check failed: expected " + typeof(T).Name);
        }

        private sealed class FixtureStream : Stream
        {
            private readonly MemoryStream response;
            private readonly MemoryStream sent = new MemoryStream();
            private readonly int fragment;
            internal FixtureStream(byte[] response, int fragment = 4096)
            { this.response = new MemoryStream(response, false); this.fragment = fragment; }
            internal byte[] Written { get { return sent.ToArray(); } }
            public override int Read(byte[] buffer, int offset, int count) { return response.Read(buffer, offset, Math.Min(count, fragment)); }
            public override int ReadByte() { return response.ReadByte(); }
            public override void Write(byte[] buffer, int offset, int count) { sent.Write(buffer, offset, count); }
            public override void Flush() { }
            public override bool CanRead { get { return true; } }
            public override bool CanSeek { get { return false; } }
            public override bool CanWrite { get { return true; } }
            public override long Length { get { throw new NotSupportedException(); } }
            public override long Position { get { throw new NotSupportedException(); } set { throw new NotSupportedException(); } }
            public override long Seek(long offset, SeekOrigin origin) { throw new NotSupportedException(); }
            public override void SetLength(long value) { throw new NotSupportedException(); }
            protected override void Dispose(bool disposing)
            { if (disposing) { response.Dispose(); sent.Dispose(); } base.Dispose(disposing); }
        }
    }
}
