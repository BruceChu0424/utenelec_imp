using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Net;
using System.Net.Http;
using System.Net.Http.Headers;
using System.Security.Cryptography;
using System.Text;
using System.Threading;
using System.Threading.Tasks;

namespace Uten.Legacy.Core.Tests
{
    public static class UnitExportDownloadChecks
    {
        private const string Job = "44444444-4444-4444-4444-444444444444";
        private const string Password = "fixture-private-export-password";
        public static void Run()
        {
            CompleteArtifactAndPrivatePassword().GetAwaiter().GetResult();
            LegacyExplicitPathAndQuery().GetAwaiter().GetResult();
            InvalidMetadataBeforeDownload().GetAwaiter().GetResult();
            InvalidArtifactsPreserveOldFile().GetAwaiter().GetResult();
            NoPostReplay().GetAwaiter().GetResult();
            CancellationAndOwnerRetirement().GetAwaiter().GetResult();
            SharedCodecBoundedFraming();
            SinkMethodAndPathAreBound().GetAwaiter().GetResult();
        }
        private static async Task CompleteArtifactAndPrivatePassword()
        {
            foreach (bool encrypted in new[] { false, true })
            using (var fixture = new Fixture())
            {
                fixture.Bytes = Workbook(encrypted); await fixture.Login();
                var owner = fixture.Session.CaptureMutationOwner();
                File.WriteAllText(fixture.Output, "old-file");
                var saved = await fixture.Session.DownloadUnitExportJobAsync(Job, Password, fixture.Output, owner, CancellationToken.None);
                Equal(fixture.Output, saved.Path); Equal((long)fixture.Bytes.Length, saved.SizeBytes);
                using (var sha = SHA256.Create()) Equal(Hex(sha.ComputeHash(fixture.Bytes)), saved.Sha256);
                True(File.ReadAllBytes(saved.Path).SequenceEqual(fixture.Bytes), "whole received artifact saved");
                Equal("/api/report-export-jobs/" + Job + "/download", fixture.RequestPath);
                var body = JsonValue.ParseObject(fixture.RequestBody);
                Equal(Password, body["password"]); True(!fixture.RequestPath.Contains(Password), "password never in URI");
                Equal(1, fixture.Downloads);
                True(!fixture.State.Store.ListJournal(owner).Any(), "download password never enters mutation journal");
                foreach (var file in Directory.GetFiles(fixture.State.RootDirectory, "*", SearchOption.AllDirectories))
                    True(!Encoding.UTF8.GetString(File.ReadAllBytes(file)).Contains(Password), "password never persisted");
                True(!Directory.GetFiles(fixture.Directory, ".uten-export-*.tmp").Any(), "temporary removed after publish");
            }
        }
        private static async Task LegacyExplicitPathAndQuery()
        {
            using (var fixture = new Fixture())
            {
                await fixture.Login();
                await fixture.Session.DownloadLegacyUnitExportAsync(new Dictionary<string, string> {
                    ["keyword"] = "M&1", ["nullFields"] = "name,dimension", ["status"] = "使用" }, Password, null,
                    fixture.Output, fixture.Session.CaptureMutationOwner(), CancellationToken.None);
                True(fixture.RequestPath.StartsWith("/api/master/units/export?"), "only fixed legacy read");
                True(fixture.RequestPath.Contains("keyword=M%261") && fixture.RequestPath.Contains("nullFields=name%2Cdimension"), "query encoded");
                True(!fixture.RequestPath.Contains("page=") && !fixture.RequestPath.Contains("size="), "no current-page-only export");
                Equal(1, fixture.Downloads);
            }
        }
        private static async Task InvalidMetadataBeforeDownload()
        {
            using (var fixture = new Fixture())
            {
                await fixture.Login(); var owner = fixture.Session.CaptureMutationOwner();
                await Throws<ApiException>(() => fixture.Session.DownloadUnitExportJobAsync("../auth/me", Password, fixture.Output, owner, CancellationToken.None));
                await Throws<ApiException>(() => fixture.Session.DownloadUnitExportJobAsync(Job, new string('x', 129), fixture.Output, owner, CancellationToken.None));
                await Throws<ApiException>(() => fixture.Session.DownloadLegacyUnitExportAsync(new Dictionary<string, string> { ["password"] = Password },
                    null, null, fixture.Output, owner, CancellationToken.None));
                await Throws<ApiException>(() => fixture.Session.DownloadLegacyUnitExportAsync(new Dictionary<string, string> { ["nullFields"] = "sql" },
                    null, null, fixture.Output, owner, CancellationToken.None));
                Equal(0, fixture.Downloads); True(!File.Exists(fixture.Output), "invalid input creates no target");
            }
            using (var fixture = new Fixture(false))
            {
                await fixture.Login();
                await Throws<ApiException>(() => fixture.Session.DownloadUnitExportJobAsync(Job, null, fixture.Output,
                    fixture.Session.CaptureMutationOwner(), CancellationToken.None));
                Equal(0, fixture.Downloads);
            }
        }
        private static async Task InvalidArtifactsPreserveOldFile()
        {
            foreach (string invalid in new[] { "mime", "length", "encoding", "range", "signature", "too-large" })
            using (var fixture = new Fixture())
            {
                fixture.Invalid = invalid; await fixture.Login(); File.WriteAllText(fixture.Output, "preserve-old");
                await Throws<ApiException>(() => fixture.Session.DownloadUnitExportJobAsync(Job, Password, fixture.Output,
                    fixture.Session.CaptureMutationOwner(), CancellationToken.None));
                Equal("preserve-old", File.ReadAllText(fixture.Output));
                True(!Directory.GetFiles(fixture.Directory, ".uten-export-*.tmp").Any(), "failed download leaves no own temporary");
            }
        }
        private static async Task NoPostReplay()
        {
            foreach (HttpStatusCode status in new[] { HttpStatusCode.Unauthorized, HttpStatusCode.ServiceUnavailable, HttpStatusCode.Found })
            using (var fixture = new Fixture())
            {
                fixture.Status = status; await fixture.Login();
                await Throws<ApiException>(() => fixture.Session.DownloadUnitExportJobAsync(Job, Password, fixture.Output,
                    fixture.Session.CaptureMutationOwner(), CancellationToken.None));
                Equal(1, fixture.Downloads); Equal(0, fixture.Refreshes);
                True(!File.Exists(fixture.Output), "failure never publishes partial file");
            }
        }
        private static async Task CancellationAndOwnerRetirement()
        {
            foreach (bool switchOwner in new[] { false, true })
            using (var fixture = new Fixture())
            using (var cancel = new CancellationTokenSource())
            {
                await fixture.Login(); File.WriteAllText(fixture.Output, "preserve-old");
                fixture.BeforeRead = () => { if (switchOwner) fixture.Session.SelectEndpoint("second"); else cancel.Cancel(); };
                try
                {
                    await fixture.Session.DownloadUnitExportJobAsync(Job, Password, fixture.Output,
                        fixture.Session.CaptureMutationOwner(), cancel.Token);
                    throw new InvalidOperationException("Expected download cancellation.");
                }
                catch (OperationCanceledException) { }
                catch (ApiException) { }
                Equal("preserve-old", File.ReadAllText(fixture.Output));
                True(!Directory.GetFiles(fixture.Directory, ".uten-export-*.tmp").Any(), "cancelled download cleans only own temporary");
            }
        }
        private static void SharedCodecBoundedFraming()
        {
            foreach (string framing in new[] { "length", "chunked", "unframed", "oversize" })
            using (var output = new MemoryStream())
            using (var request = new HttpRequestMessage(HttpMethod.Post, "https://export.company.test/api/report-export-jobs/" + Job + "/download"))
            {
                request.Content = new StringContent("{\"password\":\"fixture\"}", Encoding.UTF8, "application/json");
                var sink = HttpResponseSink.BoundedExport(output, 64, 1024, request.RequestUri.AbsolutePath, "");
                string headers = framing == "length" ? "Content-Length: 8\r\n" : framing == "chunked" ? "Transfer-Encoding: chunked\r\n"
                    : framing == "oversize" ? "Content-Length: 65\r\n" : "";
                string payload = framing == "chunked" ? "8\r\n12345678\r\n0\r\n\r\n" : "12345678";
                using (var wire = new Duplex(Encoding.ASCII.GetBytes("HTTP/1.1 200 OK\r\n" + headers + "\r\n" + payload)))
                {
                    if (framing == "unframed" || framing == "oversize")
                    {
                        try { ManagedHttp11.SendAndReceive(wire, request, 64, CancellationToken.None, responseSink: sink); throw new InvalidOperationException("Expected bounded framing rejection."); }
                        catch (HttpRequestException) { True(!sink.Completed, "invalid framing never completes"); }
                    }
                    else using (var response = ManagedHttp11.SendAndReceive(wire, request, 64, CancellationToken.None, responseSink: sink))
                    { True(sink.Completed && output.Length == 8 && response.Content.Headers.ContentLength == 0, "one codec streamed to owned sink"); }
                }
            }
        }
        private static async Task SinkMethodAndPathAreBound()
        {
            using (var output = new MemoryStream())
            {
                try { HttpResponseSink.BoundedExport(output, 64, 1024, "/api/auth/login", ""); throw new InvalidOperationException("Expected export path rejection."); }
                catch (ArgumentException) { }
                try { new HttpResponseSink(output, -1, 1024, "/api/client-updates/" + Job + "/download", ""); throw new InvalidOperationException("Expected package length rejection."); }
                catch (ArgumentException) { }
                int connections = 0;
                var configuration = Configuration();
                using (var handler = new ManagedTlsHttpHandler(configuration, CompanyCertificatePolicy.FromEmbeddedCertificate(),
                    (uri, token) => { connections++; throw new InvalidOperationException("Fixture must not open a connection."); }))
                using (var client = new HttpClient(handler))
                using (var request = new HttpRequestMessage(HttpMethod.Get, "https://export.company.test/api/report-export-jobs/" + Job + "/download"))
                {
                    request.Properties[HttpResponseSink.RequestProperty] = HttpResponseSink.BoundedExport(output, 64, 1024, request.RequestUri.AbsolutePath, "");
                    await Throws<HttpRequestException>(() => client.SendAsync(request));
                    Equal(0, connections);
                }
            }
        }
        private static ClientConfiguration Configuration()
        { return new ClientConfiguration(new[] { new ServerEndpoint("first", "First", "https://export.company.test/api"),
            new ServerEndpoint("second", "Second", "https://second.company.test/api") }, "first"); }
        private sealed class Fixture : IDisposable
        {
            internal readonly BusinessStateTestFixture State = new BusinessStateTestFixture();
            internal readonly SessionCoordinator Session;
            internal readonly string Directory, Output;
            internal byte[] Bytes = Workbook(false);
            internal string Invalid, RequestPath, RequestBody;
            internal int Downloads, Refreshes;
            internal Action BeforeRead;
            internal HttpStatusCode Status = HttpStatusCode.OK;
            internal Fixture(bool export = true)
            {
                Directory = System.IO.Path.Combine(State.RootDirectory, "downloads"); System.IO.Directory.CreateDirectory(Directory);
                Output = System.IO.Path.Combine(Directory, "units.xlsx");
                Session = new SessionCoordinator(Configuration(), new Handler(async (request, ct) =>
                {
                    string path = request.RequestUri.AbsolutePath;
                    if (path.EndsWith("/auth/login") || path.EndsWith("/auth/refresh"))
                    {
                        if (path.EndsWith("/auth/refresh")) Refreshes++;
                        string permissions = export ? "[\"unit:view\",\"unit:export\"]" : "[\"unit:view\"]";
                        return Json(HttpStatusCode.OK, "{\"accessToken\":\"access.fixture\",\"refreshToken\":\"refresh.fixture\",\"expiresIn\":900,\"user\":"
                            + "{\"id\":\"fixture-export-user\",\"loginAccount\":\"fixture\",\"superAdmin\":false,\"mustChangePassword\":false,\"permissions\":"
                            + permissions + ",\"businessDatasetId\":\"00000000-0000-0000-0000-000000000001\",\"businessResetGeneration\":0}}");
                    }
                    Downloads++; RequestPath = request.RequestUri.PathAndQuery; RequestBody = await request.Content.ReadAsStringAsync();
                    if (Status != HttpStatusCode.OK) return Json(Status, "{\"code\":\"UNAUTHORIZED\",\"message\":\"fixture rejection\"}");
                    byte[] bytes = Invalid == "signature" ? Encoding.UTF8.GetBytes("not a workbook") : Bytes;
                    var content = new StreamContent(new ReadHookStream(bytes, BeforeRead)); content.Headers.ContentLength = Invalid == "length" ? bytes.Length + 1
                        : Invalid == "too-large" ? 512L * 1024 * 1024 + 1 : bytes.Length;
                    content.Headers.ContentType = new MediaTypeHeaderValue(Invalid == "mime" ? "application/json" : "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet");
                    if (Invalid == "encoding") content.Headers.ContentEncoding.Add("gzip");
                    if (Invalid == "range") content.Headers.ContentRange = new ContentRangeHeaderValue(0, 7, 100);
                    return new HttpResponseMessage(Status) { Content = content };
                }), new MemoryStore(), State.Store);
            }
            internal Task Login() { return Session.LoginAsync("fixture", "fixture-password", null, CancellationToken.None); }
            public void Dispose() { Session.Dispose(); State.Dispose(); }
        }
        private sealed class Handler : HttpMessageHandler
        {
            private readonly Func<HttpRequestMessage, CancellationToken, Task<HttpResponseMessage>> send;
            internal Handler(Func<HttpRequestMessage, CancellationToken, Task<HttpResponseMessage>> send) { this.send = send; }
            protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken token) { return send(request, token); }
        }
        private sealed class ReadHookStream : MemoryStream
        {
            private Action before;
            internal ReadHookStream(byte[] bytes, Action before) : base(bytes, false) { this.before = before; }
            public override Task<int> ReadAsync(byte[] buffer, int offset, int count, CancellationToken ct)
            { var action = before; before = null; action?.Invoke(); ct.ThrowIfCancellationRequested(); return base.ReadAsync(buffer, offset, count, ct); }
        }
        private sealed class Duplex : Stream
        {
            private readonly MemoryStream input;
            internal Duplex(byte[] bytes) { input = new MemoryStream(bytes, false); }
            public override int Read(byte[] b, int o, int c) { return input.Read(b, o, c); }
            public override void Write(byte[] b, int o, int c) { }
            public override void Flush() { }
            public override bool CanRead => true; public override bool CanWrite => true; public override bool CanSeek => false;
            public override long Length => input.Length; public override long Position { get => input.Position; set => throw new NotSupportedException(); }
            public override long Seek(long o, SeekOrigin s) { throw new NotSupportedException(); } public override void SetLength(long v) { throw new NotSupportedException(); }
            protected override void Dispose(bool disposing) { if (disposing) input.Dispose(); base.Dispose(disposing); }
        }
        private sealed class MemoryStore : ISessionStore
        {
            private StoredSession active;
            public StoredSession Load() => active; public void Save(StoredSession value) { active = value; }
            public void Clear() { active = null; } public void EndSession(StoredSession value) { active = null; }
            public void EnqueueRevocation(StoredSession value) { } public IList<StoredSession> PendingRevocations() => new List<StoredSession>();
            public void AcknowledgeRevocation(string id) { }
        }
        private static byte[] Workbook(bool ole)
        {
            var bytes = new byte[1024];
            byte[] prefix = ole ? new byte[] { 0xd0, 0xcf, 0x11, 0xe0, 0xa1, 0xb1, 0x1a, 0xe1 } : new byte[] { 0x50, 0x4b, 3, 4 };
            Buffer.BlockCopy(prefix, 0, bytes, 0, prefix.Length); return bytes;
        }
        private static HttpResponseMessage Json(HttpStatusCode status, string body)
        { return new HttpResponseMessage(status) { Content = new StringContent(body, Encoding.UTF8, "application/json") }; }
        private static async Task<T> Throws<T>(Func<Task> run) where T : Exception
        { try { await run(); } catch (T error) { return error; } throw new InvalidOperationException("Expected fixture " + typeof(T).Name); }
        private static string Hex(byte[] bytes) => BitConverter.ToString(bytes).Replace("-", "").ToLowerInvariant();
        private static void Equal<T>(T expected, T actual) { if (!Object.Equals(expected, actual)) throw new InvalidOperationException("Unit export fixture mismatch."); }
        private static void True(bool value, string label) { if (!value) throw new InvalidOperationException("Unit export fixture: " + label); }
    }
}
