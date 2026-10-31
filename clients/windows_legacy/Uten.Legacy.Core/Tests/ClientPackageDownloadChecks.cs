using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Net;
using System.Net.Http;
using System.Security.Cryptography;
using System.Text;
using System.Threading;
using System.Threading.Tasks;

namespace Uten.Legacy.Core.Tests
{
    public static class ClientPackageDownloadChecks
    {
        private const string ReleaseId = "11111111-1111-1111-1111-111111111111";
        public static void Run()
        {
            LargeFileIsStreamedAndFamiliesAreBound().GetAwaiter().GetResult();
            InvalidMetadataIsRejectedBeforeNetwork().GetAwaiter().GetResult();
            FailedIntegrityPreservesExistingFile().GetAwaiter().GetResult();
            CancellationAndIdentityChangeRemoveOwnTemporary().GetAwaiter().GetResult();
            RefreshBeforeBodyIsSingleRetry().GetAwaiter().GetResult();
            SharedHttpCodecWritesToSinkWithoutBuffering();
        }

        private static async Task LargeFileIsStreamedAndFamiliesAreBound()
        {
            const long size = 6 * 1024 * 1024 + 13;
            foreach (var family in new[] { "flutter", "wpf_legacy" })
            {
                string requested = null;
                GeneratorContent content = null;
                using (var fixture = new Fixture((request, ct) =>
                {
                    requested = request.RequestUri.PathAndQuery;
                    content = new GeneratorContent(size);
                    return Ready(new HttpResponseMessage(HttpStatusCode.OK) { Content = content });
                }))
                {
                    await fixture.Login();
                    var progress = new ProgressCapture();
                    var path = await fixture.Session.DownloadClientPackageAsync(ReleaseId, Hash(size), size, family,
                        fixture.Output, CancellationToken.None, progress);
                    Equal(fixture.Output, path, "final absolute path returned");
                    Equal(size, new FileInfo(path).Length, "large file length");
                    using (var input = File.OpenRead(path)) using (var sha = SHA256.Create())
                        Equal(Hash(size), Hex(sha.ComputeHash(input)), "large file digest");
                    True(content.Source.LargestRead <= 65536 && content.Source.TotalRead == size, "large body consumed through bounded reads");
                    Equal("/api/client-updates/" + ReleaseId + "/download" + (family == "wpf_legacy" ? "?runtimeFamily=wpf_legacy" : ""), requested, "fixed family path");
                    True(progress.Values.Count > 0 && progress.Values[0] == 0 && progress.Values.Last() == size,
                        "progress counts bytes, including initial/final values");
                    True(progress.Values.Count < 1000, "progress reports are throttled");
                    True(!Directory.GetFiles(fixture.Directory, ".uten-download-*.tmp").Any(), "no temporary remains after atomic final");
                    var oldGeneration = fixture.Session.Generation;
                    var response = await ThrowsAsync<ApiException>(() => fixture.Session.GetAsync("too-large-json", CancellationToken.None));
                    Equal("RESPONSE_TOO_LARGE", response.Code, "binary allowance never enlarges JSON allowance");
                    Equal(oldGeneration, fixture.Session.Generation, "download does not alter auth intent");
                }
            }
        }

        private static async Task InvalidMetadataIsRejectedBeforeNetwork()
        {
            using (var fixture = new Fixture((request, ct) => Ready(new HttpResponseMessage(HttpStatusCode.OK))))
            {
                await fixture.Login();
                foreach (var id in new[] { "", "../auth/me", ReleaseId + "?redirect=other" })
                    await ThrowsAsync<ApiException>(() => fixture.Session.DownloadClientPackageAsync(id, Hash(1), 1, "wpf_legacy", fixture.Output, CancellationToken.None));
                foreach (var size in new[] { 0L, -1L, 536870913L })
                    await ThrowsAsync<ApiException>(() => fixture.Session.DownloadClientPackageAsync(ReleaseId, Hash(1), size, "wpf_legacy", fixture.Output, CancellationToken.None));
                await ThrowsAsync<ApiException>(() => fixture.Session.DownloadClientPackageAsync(ReleaseId, "bad-digest", 1, "wpf_legacy", fixture.Output, CancellationToken.None));
                await ThrowsAsync<ApiException>(() => fixture.Session.DownloadClientPackageAsync(ReleaseId, Hash(1), 1, "unknown", fixture.Output, CancellationToken.None));
                Equal(0, fixture.Downloads, "invalid metadata never sends a download request");
                True(!File.Exists(fixture.Output), "invalid metadata creates no output");
            }
        }

        private static async Task FailedIntegrityPreservesExistingFile()
        {
            foreach (var wrongLength in new[] { false, true })
            using (var fixture = new Fixture((request, ct) => Ready(new HttpResponseMessage(HttpStatusCode.OK) { Content = new GeneratorContent(10000) })))
            {
                await fixture.Login();
                var original = Encoding.UTF8.GetBytes("existing file must survive");
                File.WriteAllBytes(fixture.Output, original);
                var error = await ThrowsAsync<ApiException>(() => fixture.Session.DownloadClientPackageAsync(ReleaseId,
                    wrongLength ? Hash(10001) : new string('0',64), wrongLength ? 10001 : 10000,
                    "wpf_legacy", fixture.Output, CancellationToken.None));
                Equal(wrongLength ? "INVALID_DOWNLOAD_LENGTH" : "DOWNLOAD_CHECKSUM_MISMATCH", error.Code, "integrity rejection");
                True(File.ReadAllBytes(fixture.Output).SequenceEqual(original), "failed download does not replace original");
                True(!Directory.GetFiles(fixture.Directory, ".uten-download-*.tmp").Any(), "failed download removes own temporary");
            }
        }

        private static async Task CancellationAndIdentityChangeRemoveOwnTemporary()
        {
            foreach (var switchIdentity in new[] { false, true })
            using (var cancel = new CancellationTokenSource())
            {
                Fixture fixture = null;
                fixture = new Fixture((request, ct) => Ready(new HttpResponseMessage(HttpStatusCode.OK)
                {
                    Content = new GeneratorContent(4 * 1024 * 1024, () =>
                    {
                        if (switchIdentity) fixture.Session.SelectEndpoint("cloud");
                        else cancel.Cancel();
                    })
                }));
                using (fixture)
                {
                    await fixture.Login();
                    if (switchIdentity)
                    {
                        var error = await ThrowsAsync<ApiException>(() => fixture.Session.DownloadClientPackageAsync(ReleaseId, Hash(4 * 1024 * 1024),
                            4 * 1024 * 1024, "wpf_legacy", fixture.Output, cancel.Token));
                        Equal("SESSION_CHANGED", error.Code, "old identity cannot finalize package");
                    }
                    else await ThrowsAsync<OperationCanceledException>(() => fixture.Session.DownloadClientPackageAsync(ReleaseId, Hash(4 * 1024 * 1024),
                        4 * 1024 * 1024, "wpf_legacy", fixture.Output, cancel.Token));
                    True(!File.Exists(fixture.Output) && !Directory.GetFiles(fixture.Directory, ".uten-download-*.tmp").Any(), "retired transfer leaves no partial final or own temporary");
                }
            }
        }

        private static async Task RefreshBeforeBodyIsSingleRetry()
        {
            var calls = 0;
            using (var fixture = new Fixture((request, ct) =>
            {
                calls++;
                return Ready(request.Headers.Authorization.Parameter == "access-old"
                    ? Json("{\"code\":\"UNAUTHORIZED\",\"message\":\"会话已过期\"}", HttpStatusCode.Unauthorized)
                    : new HttpResponseMessage(HttpStatusCode.OK) { Content = new GeneratorContent(9000) });
            }))
            {
                await fixture.Login();
                await fixture.Session.DownloadClientPackageAsync(ReleaseId, Hash(9000), 9000, "wpf_legacy", fixture.Output, CancellationToken.None);
                Equal(2, calls, "one body-free GET retry after definitive 401");
                Equal(1, fixture.Refreshes, "shared refresh entry used");
                Equal(9000L, new FileInfo(fixture.Output).Length, "retry did not append the error body");
            }
        }

        private static void SharedHttpCodecWritesToSinkWithoutBuffering()
        {
            const int size = 4 * 1024 * 1024 + 1;
            using (var wire = new Wire(size))
            using (var output = new CountStream())
            using (var request = new HttpRequestMessage(HttpMethod.Get, "https://company.example.test/api/client-updates/" + ReleaseId + "/download?runtimeFamily=wpf_legacy"))
            {
                var sink = new HttpResponseSink(output, size, 1024, request.RequestUri.AbsolutePath, request.RequestUri.Query);
                using (var response = ManagedHttp11.SendAndReceive(wire, request, HttpResponseSink.MaximumPackageBytes, CancellationToken.None, null, sink))
                {
                    True(sink.Completed && output.Length == size, "shared framing wrote complete stream to sink");
                    Equal(0, response.Content.ReadAsByteArrayAsync().GetAwaiter().GetResult().Length, "streamed payload not retained in HttpContent");
                    True(wire.RequestText.Contains("Accept-Encoding: identity\r\n"), "package wire coding fixed to identity");
                    True(output.LargestWrite <= 65536, "shared codec uses bounded writes");
                }
            }
        }

        private sealed class Fixture : IDisposable
        {
            internal readonly string Directory = Path.Combine(Path.GetTempPath(), "uten-package-check-" + Guid.NewGuid().ToString("N"));
            internal string Output { get { return Path.Combine(Directory, "package.bin"); } }
            internal readonly SessionCoordinator Session;
            internal int Downloads;
            internal int Refreshes;
            internal Fixture(Func<HttpRequestMessage,CancellationToken,Task<HttpResponseMessage>> body)
            {
                System.IO.Directory.CreateDirectory(Directory);
                var configuration = new ClientConfiguration(new[] { new ServerEndpoint("company","公司","https://company.example.test/api"),
                    new ServerEndpoint("cloud","云端","https://cloud.example.test/api") },"company",5,1024);
                Session = new SessionCoordinator(configuration, new Handler((request, ct) =>
                {
                    if (request.RequestUri.AbsolutePath.EndsWith("/login")) return Ready(Json(Token("access-old","refresh-old")));
                    if (request.RequestUri.AbsolutePath.EndsWith("/refresh")) { Refreshes++; return Ready(Json(Token("access-new","refresh-new"))); }
                    if (request.RequestUri.AbsolutePath.EndsWith("too-large-json")) return Ready(new HttpResponseMessage(HttpStatusCode.OK) {Content=new StringContent(new string('x',2048))});
                    Downloads++; return body(request,ct);
                }),new MemoryStore());
            }
            internal Task Login() { return Session.LoginAsync("UT0001","test-password",CancellationToken.None); }
            public void Dispose()
            {
                Session.Dispose();
                foreach (var file in System.IO.Directory.GetFiles(Directory)) File.Delete(file);
                System.IO.Directory.Delete(Directory,false);
            }
        }
        private sealed class GeneratorContent : HttpContent
        {
            internal readonly Generator Source;
            internal GeneratorContent(long length,Action duringRead=null) { Source=new Generator(length,duringRead); Headers.ContentLength=length; }
            protected override Task<Stream> CreateContentReadStreamAsync() { return Task.FromResult<Stream>(Source); }
            protected override Task SerializeToStreamAsync(Stream stream,TransportContext context) { throw new InvalidOperationException("Fixture must be consumed as a stream"); }
            protected override bool TryComputeLength(out long length) { length=Source.Length; return true; }
        }
        private sealed class Generator : Stream
        {
            private readonly long length; private readonly Action duringRead; private bool signaled;
            internal long TotalRead; internal int LargestRead;
            internal Generator(long length,Action duringRead=null) { this.length=length; this.duringRead=duringRead; }
            public override int Read(byte[] buffer,int offset,int count)
            {
                if (!signaled && TotalRead>=65536 && duringRead!=null) { signaled=true; duringRead(); }
                LargestRead=Math.Max(LargestRead,count); var actual=(int)Math.Min(count,length-TotalRead);
                for(var index=0;index<actual;index++) buffer[offset+index]=42;
                TotalRead+=actual; return actual;
            }
            public override Task<int> ReadAsync(byte[] buffer,int offset,int count,CancellationToken ct) { ct.ThrowIfCancellationRequested(); return Task.FromResult(Read(buffer,offset,count)); }
            public override bool CanRead {get{return true;}} public override bool CanWrite{get{return false;}} public override bool CanSeek{get{return false;}}
            public override long Length{get{return length;}} public override long Position{get{return TotalRead;}set{throw new NotSupportedException();}}
            public override void Flush(){} public override void Write(byte[] b,int o,int c){throw new NotSupportedException();}
            public override long Seek(long o,SeekOrigin origin){throw new NotSupportedException();} public override void SetLength(long value){throw new NotSupportedException();}
        }
        private sealed class CountStream : Stream
        {
            private long length; internal int LargestWrite;
            public override void Write(byte[] buffer,int offset,int count){length+=count;LargestWrite=Math.Max(LargestWrite,count);}
            public override long Length{get{return length;}} public override long Position{get{return length;}set{throw new NotSupportedException();}}
            public override bool CanRead{get{return false;}} public override bool CanWrite{get{return true;}} public override bool CanSeek{get{return false;}}
            public override void Flush(){} public override int Read(byte[] b,int o,int c){throw new NotSupportedException();}
            public override long Seek(long o,SeekOrigin origin){throw new NotSupportedException();} public override void SetLength(long v){throw new NotSupportedException();}
        }
        private sealed class Wire : Stream
        {
            private readonly MemoryStream headers; private readonly Generator body; private readonly MemoryStream sent=new MemoryStream();
            internal string RequestText{get{return Encoding.ASCII.GetString(sent.ToArray());}}
            internal Wire(int length){headers=new MemoryStream(Encoding.ASCII.GetBytes("HTTP/1.1 200 OK\r\nContent-Length: "+length+"\r\nConnection: close\r\n\r\n"));body=new Generator(length);}
            public override int Read(byte[] b,int o,int c){return headers.Position<headers.Length?headers.Read(b,o,c):body.Read(b,o,c);}
            public override void Write(byte[] b,int o,int c){sent.Write(b,o,c);} public override void Flush(){}
            public override bool CanRead{get{return true;}} public override bool CanWrite{get{return true;}} public override bool CanSeek{get{return false;}}
            public override long Length{get{throw new NotSupportedException();}} public override long Position{get{throw new NotSupportedException();}set{throw new NotSupportedException();}}
            public override long Seek(long o,SeekOrigin origin){throw new NotSupportedException();} public override void SetLength(long v){throw new NotSupportedException();}
        }
        private sealed class ProgressCapture : IProgress<long> {internal readonly List<long> Values=new List<long>();public void Report(long value){Values.Add(value);}}
        private sealed class Handler : HttpMessageHandler {private readonly Func<HttpRequestMessage,CancellationToken,Task<HttpResponseMessage>> body;internal Handler(Func<HttpRequestMessage,CancellationToken,Task<HttpResponseMessage>> body){this.body=body;}protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage r,CancellationToken ct){return body(r,ct);}}
        private sealed class MemoryStore : ISessionStore
        {
            private StoredSession active; private readonly List<StoredSession> pending=new List<StoredSession>();
            public StoredSession Load(){return active;} public void Save(StoredSession value){active=value;} public void Clear(){active=null;}
            public void EndSession(StoredSession value){EnqueueRevocation(value??active);active=null;} public void EnqueueRevocation(StoredSession value){if(value!=null)pending.Add(value);}
            public IList<StoredSession> PendingRevocations(){return pending.ToList();} public void AcknowledgeRevocation(string id){pending.RemoveAll(value=>value.Id==id);}
        }
        private static string Token(string access,string refresh){return "{\"accessToken\":\""+access+"\",\"refreshToken\":\""+refresh+"\",\"expiresIn\":900,\"user\":{\"id\":\"user-1\",\"loginAccount\":\"UT0001\",\"permissions\":[],\"superAdmin\":false}}";}
        private static HttpResponseMessage Json(string text,HttpStatusCode status=HttpStatusCode.OK){return new HttpResponseMessage(status){Content=new StringContent(text,Encoding.UTF8,"application/json")};}
        private static Task<HttpResponseMessage> Ready(HttpResponseMessage value){return Task.FromResult(value);}
        private static string Hash(long length){using(var source=new Generator(length))using(var sha=SHA256.Create())return Hex(sha.ComputeHash(source));}
        private static string Hex(byte[] bytes){return BitConverter.ToString(bytes).Replace("-","").ToLowerInvariant();}
        private static void True(bool value,string message){if(!value)throw new InvalidOperationException("Package download contract: "+message);}
        private static void Equal<T>(T expected,T actual,string message){True(EqualityComparer<T>.Default.Equals(expected,actual),message);}
        private static async Task<T> ThrowsAsync<T>(Func<Task> action)where T:Exception{try{await action().ConfigureAwait(false);}catch(T error){return error;}throw new InvalidOperationException("Package download contract: expected "+typeof(T).Name);}
    }
}
