using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Net;
using System.Net.Http;
using System.Net.Sockets;
using System.Security.Authentication;
using System.Security.Cryptography;
using System.Security.Cryptography.X509Certificates;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using Org.BouncyCastle.Crypto;
using Org.BouncyCastle.Security;
using Org.BouncyCastle.Tls;
using Org.BouncyCastle.Tls.Crypto.Impl.BC;
using FrameworkCertificateRequest = System.Security.Cryptography.X509Certificates.CertificateRequest;
using BcCertificate = Org.BouncyCastle.Tls.Certificate;

namespace Uten.Legacy.Core.Tests
{
    /// <summary>Real, private loopback TCP/TLS checks. Test keys are generated in memory and never installed.</summary>
    public static class ManagedTlsChecks
    {
        public static void Run()
        {
            using (var certificates = new Certificates())
            {
                RealRsaGcmHandshake(certificates).GetAwaiter().GetResult();
                RejectsWrongNameBeforeHttp(certificates).GetAwaiter().GetResult();
                LateAuthBodyRemainsRevocable(certificates).GetAwaiter().GetResult();
                CancellationClosesSocket(certificates).GetAwaiter().GetResult();
                CertificateBounds(certificates);
            }
        }

        private static ClientConfiguration Configuration()
        { return new ClientConfiguration(new[] { new ServerEndpoint("company", "公司", "https://imp.utenelec/api") }, "company", 5); }

        private static async Task RealRsaGcmHandshake(Certificates certificates)
        {
            using (var server = new Server(certificates, certificates.Leaf, stream =>
                Write(stream, "HTTP/1.1 200 OK\r\nContent-Length: 11\r\nContent-Type: application/json\r\nConnection: close\r\n\r\n{\"ok\":true}")))
            using (var handler = new ManagedTlsHttpHandler(Configuration(), certificates.Policy, server.Connect))
            using (var client = new HttpClient(handler))
            using (var reply = await client.GetAsync("https://imp.utenelec/api/auth/me"))
            {
                True(reply.IsSuccessStatusCode && await reply.Content.ReadAsStringAsync() == "{\"ok\":true}", "real HTTP over TLS");
                Equal(CipherSuite.TLS_ECDHE_RSA_WITH_AES_128_GCM_SHA256, handler.LastNegotiatedCipherSuite, "exact RSA/GCM suite negotiated");
                server.Finish();
                Equal(CipherSuite.TLS_ECDHE_RSA_WITH_AES_128_GCM_SHA256, server.CipherSuite, "server agreed same GCM suite");
                True(server.RequestHeaders.Contains("Host: imp.utenelec\r\n"), "HTTP host bound to TLS origin");
            }
        }

        private static async Task RejectsWrongNameBeforeHttp(Certificates certificates)
        {
            using (var server = new Server(certificates, certificates.WrongName, stream => Write(stream, "HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n")))
            using (var handler = new ManagedTlsHttpHandler(Configuration(), certificates.Policy, server.Connect))
            using (var client = new HttpClient(handler))
            {
                await ThrowsAsync<HttpRequestException>(() => client.PostAsync("https://imp.utenelec/api/auth/login", new StringContent("test-password")));
                server.Finish();
                True(server.RequestHeaders == null, "bad SAN refused before credentials reach HTTP");
            }
        }

        private static async Task LateAuthBodyRemainsRevocable(Certificates certificates)
        {
            var body = "{\"accessToken\":\"late-access\",\"refreshToken\":\"late-refresh\",\"expiresIn\":900,\"mustChangePassword\":false,\"user\":{\"id\":\"late-user\",\"loginAccount\":\"UT0001\",\"permissions\":[],\"superAdmin\":false}}";
            using (var release = new ManualResetEventSlim(false))
            using (var headersSeen = new ManualResetEventSlim(false))
            using (var server = new Server(certificates, certificates.Leaf, stream =>
            {
                Write(stream, "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: "
                    + Encoding.UTF8.GetByteCount(body) + "\r\nConnection: close\r\n\r\n");
                if (!release.Wait(TimeSpan.FromSeconds(5))) throw new InvalidOperationException("TLS fixture body wait expired");
                Write(stream, body);
            }))
            using (var handler = new ManagedTlsHttpHandler(Configuration(), certificates.Policy, server.Connect))
            {
                handler.ResponseHeadersObserved = status => headersSeen.Set();
                var store = new MemoryStore();
                using (var session = new SessionCoordinator(Configuration(), handler, store))
                {
                    var pending = session.LoginAsync("UT0001", "test-password", CancellationToken.None);
                    True(headersSeen.Wait(TimeSpan.FromSeconds(5)), "actual auth response headers observed");
                    await session.LogoutAsync(CancellationToken.None);
                    release.Set();
                    var failure = await ThrowsAsync<ApiException>(() => pending);
                    Equal("SESSION_CHANGED", failure.Code, "late success cannot revive logout");
                    True(!session.IsAuthenticated && store.Load() == null, "logged-out memory and store remain empty");
                    True(store.PendingRevocations().Any(value => value.RefreshToken == "late-refresh"
                        && value.IssuerApiBaseUrl == "https://imp.utenelec/api"), "late actual TLS body token retained at original issuer");
                    server.Finish();
                }
            }
        }

        private static async Task CancellationClosesSocket(Certificates certificates)
        {
            using (var requestSeen = new ManualResetEventSlim(false))
            using (var server = new Server(certificates, certificates.Leaf, stream =>
            {
                requestSeen.Set();
                try { while (stream.ReadByte() >= 0) { } } catch (IOException) { }
            }))
            using (var handler = new ManagedTlsHttpHandler(Configuration(), certificates.Policy, server.Connect))
            using (var client = new HttpClient(handler))
            using (var cancel = new CancellationTokenSource())
            {
                var pending = client.GetAsync("https://imp.utenelec/api/auth/me", cancel.Token);
                True(requestSeen.Wait(TimeSpan.FromSeconds(5)), "cancellable HTTP request reached test server");
                cancel.Cancel();
                await ThrowsAsync<OperationCanceledException>(() => pending);
                server.Finish();
            }
        }

        private static void CertificateBounds(Certificates certificates)
        {
            var validator = new ManagedCertificateValidator(certificates.Policy);
            var chain = new List<byte[]> { certificates.Leaf.RawData, certificates.Root.RawData };
            validator.Validate(new Uri("https://imp.utenelec/api"), chain);
            validator.Validate(new Uri("https://192.168.1.13/api"), chain);
            foreach (var leaf in new[] { certificates.WrongName, certificates.Expired, certificates.WrongUsage, certificates.NoSan })
                Throws<AuthenticationException>(() => validator.Validate(new Uri("https://imp.utenelec/api"),
                    new List<byte[]> { leaf.RawData, certificates.Root.RawData }));
            Throws<AuthenticationException>(() => validator.Validate(new Uri("https://other.example.test/api"), chain));
            Throws<AuthenticationException>(() => validator.Validate(new Uri("https://imp.utenelec:444/api"), chain));
            var broken = certificates.Leaf.RawData;
            broken[broken.Length - 1] ^= 1;
            Throws<AuthenticationException>(() => validator.Validate(new Uri("https://imp.utenelec/api"), new List<byte[]> { broken, certificates.Root.RawData }));
            using (var other = new Certificates())
                Throws<AuthenticationException>(() => validator.Validate(new Uri("https://imp.utenelec/api"),
                    new List<byte[]> { other.Leaf.RawData, other.Root.RawData }));
        }

        private sealed class Certificates : IDisposable
        {
            internal readonly RSA RootKey = RSA.Create(2048);
            internal readonly RSA LeafKey = RSA.Create(2048);
            internal readonly X509Certificate2 Root;
            internal readonly X509Certificate2 Leaf;
            internal readonly X509Certificate2 WrongName;
            internal readonly X509Certificate2 Expired;
            internal readonly X509Certificate2 WrongUsage;
            internal readonly X509Certificate2 NoSan;
            internal CompanyCertificatePolicy Policy { get { return new CompanyCertificatePolicy(Root.RawData); } }
            internal Certificates()
            {
                var root = new FrameworkCertificateRequest("CN=Managed TLS Offline Test Root " + Guid.NewGuid().ToString("N"),
                    RootKey, HashAlgorithmName.SHA256, RSASignaturePadding.Pkcs1);
                root.CertificateExtensions.Add(new X509BasicConstraintsExtension(true, false, 0, true));
                root.CertificateExtensions.Add(new X509KeyUsageExtension(X509KeyUsageFlags.KeyCertSign, true));
                Root = root.CreateSelfSigned(DateTimeOffset.UtcNow.AddDays(-60), DateTimeOffset.UtcNow.AddYears(1));
                Leaf = Issue("imp.utenelec", false, false, false);
                WrongName = Issue("other.example.test", false, false, false);
                Expired = Issue("imp.utenelec", true, false, false);
                WrongUsage = Issue("imp.utenelec", false, true, false);
                NoSan = Issue("imp.utenelec", false, false, true);
            }
            private X509Certificate2 Issue(string dns, bool expired, bool clientOnly, bool noSan)
            {
                var request = new FrameworkCertificateRequest("CN=" + dns, LeafKey, HashAlgorithmName.SHA256, RSASignaturePadding.Pkcs1);
                request.CertificateExtensions.Add(new X509BasicConstraintsExtension(false, false, 0, true));
                request.CertificateExtensions.Add(new X509KeyUsageExtension(X509KeyUsageFlags.DigitalSignature, true));
                request.CertificateExtensions.Add(new X509EnhancedKeyUsageExtension(new OidCollection
                    { new Oid(clientOnly ? "1.3.6.1.5.5.7.3.2" : "1.3.6.1.5.5.7.3.1") }, true));
                if (!noSan)
                {
                    var san = new SubjectAlternativeNameBuilder();
                    san.AddDnsName(dns);
                    san.AddIpAddress(IPAddress.Parse("192.168.1.13"));
                    request.CertificateExtensions.Add(san.Build());
                }
                return request.Create(Root, DateTimeOffset.UtcNow.AddDays(-30),
                    DateTimeOffset.UtcNow.AddDays(expired ? -1 : 30), Guid.NewGuid().ToByteArray());
            }
            public void Dispose()
            { NoSan.Dispose(); WrongUsage.Dispose(); Expired.Dispose(); WrongName.Dispose(); Leaf.Dispose(); Root.Dispose(); LeafKey.Dispose(); RootKey.Dispose(); }
        }

        private sealed class Server : IDisposable
        {
            private readonly TcpListener listener;
            private readonly Task worker;
            private readonly int port;
            internal int CipherSuite;
            internal string RequestHeaders;
            private TcpClient accepted;
            internal Server(Certificates certificates, X509Certificate2 leaf, Action<Stream> respond)
            {
                listener = new TcpListener(IPAddress.Loopback, 0);
                listener.Start();
                port = ((IPEndPoint)listener.LocalEndpoint).Port;
                worker = Task.Run(() =>
                {
                    try
                    {
                        using (accepted = listener.AcceptTcpClient())
                        {
                            accepted.ReceiveTimeout = accepted.SendTimeout = 5000;
                            var protocol = new TlsServerProtocol(accepted.GetStream());
                            {
                                var peer = new RsaGcmServer(certificates, leaf);
                                protocol.Accept(peer);
                                CipherSuite = peer.SelectedSuite;
                                var bytes = new List<byte>();
                                while (bytes.Count < 32768)
                                {
                                    var value = protocol.Stream.ReadByte();
                                    if (value < 0) throw new IOException("TLS fixture request truncated");
                                    bytes.Add((byte)value);
                                    if (bytes.Count >= 4 && bytes[bytes.Count - 4] == 13 && bytes[bytes.Count - 3] == 10
                                        && bytes[bytes.Count - 2] == 13 && bytes[bytes.Count - 1] == 10) break;
                                }
                                RequestHeaders = Encoding.ASCII.GetString(bytes.ToArray());
                                // The fixture consumes the request body before replying, just as the API does.
                                var lengthLine = RequestHeaders.Split(new[] { "\r\n" }, StringSplitOptions.None)
                                    .FirstOrDefault(value => value.StartsWith("Content-Length:", StringComparison.OrdinalIgnoreCase));
                                var length = lengthLine == null ? 0 : Int32.Parse(lengthLine.Substring(lengthLine.IndexOf(':') + 1).Trim());
                                for (var index = 0; index < length; index++) if (protocol.Stream.ReadByte() < 0) throw new IOException("fixture request truncated");
                                respond(protocol.Stream);
                                protocol.Close();
                            }
                        }
                    }
                    catch (IOException) { /* Expected for negative certificate/cancellation cases. */ }
                });
            }
            internal TcpClient Connect(Uri ignoredOrigin, CancellationToken cancellationToken)
            {
                cancellationToken.ThrowIfCancellationRequested();
                var result = new TcpClient();
                result.Connect(IPAddress.Loopback, port);
                return result;
            }
            internal void Finish() { True(worker.Wait(TimeSpan.FromSeconds(6)), "local TLS fixture completed"); worker.GetAwaiter().GetResult(); }
            public void Dispose() { listener.Stop(); if (accepted != null) accepted.Close(); if (!worker.IsCompleted) worker.Wait(TimeSpan.FromSeconds(6)); }
        }

        private sealed class RsaGcmServer : DefaultTlsServer
        {
            private readonly Certificates certificates;
            private readonly X509Certificate2 leaf;
            internal int SelectedSuite;
            internal RsaGcmServer(Certificates certificates, X509Certificate2 leaf) : base(new BcTlsCrypto())
            { this.certificates = certificates; this.leaf = leaf; }
            protected override ProtocolVersion[] GetSupportedVersions() { return new[] { ProtocolVersion.TLSv12 }; }
            protected override int[] GetSupportedCipherSuites() { return new[] { Org.BouncyCastle.Tls.CipherSuite.TLS_ECDHE_RSA_WITH_AES_128_GCM_SHA256 }; }
            protected override TlsCredentialedSigner GetRsaSignerCredentials()
            {
                var crypto = (BcTlsCrypto)Crypto;
                var chain = new BcCertificate(new[] { crypto.CreateCertificate(leaf.RawData), crypto.CreateCertificate(certificates.Root.RawData) });
                var key = DotNetUtilities.GetRsaKeyPair(certificates.LeafKey).Private;
                return new BcDefaultTlsCredentialedSigner(new Org.BouncyCastle.Tls.Crypto.TlsCryptoParameters(m_context), crypto,
                    key, chain, new SignatureAndHashAlgorithm(Org.BouncyCastle.Tls.HashAlgorithm.sha256, SignatureAlgorithm.rsa));
            }
            public override void NotifyHandshakeComplete() { base.NotifyHandshakeComplete(); SelectedSuite = m_context.SecurityParameters.CipherSuite; }
        }

        private static void Write(Stream stream, string value)
        { var bytes = Encoding.UTF8.GetBytes(value); stream.Write(bytes, 0, bytes.Length); stream.Flush(); }
        private static void True(bool condition, string message) { if (!condition) throw new InvalidOperationException("Managed TLS contract: " + message); }
        private static void Equal<T>(T expected, T actual, string message) { True(EqualityComparer<T>.Default.Equals(expected, actual), message); }
        private static T Throws<T>(Action action) where T : Exception
        { try { action(); } catch (T error) { return error; } throw new InvalidOperationException("Managed TLS contract: expected " + typeof(T).Name); }
        private static async Task<T> ThrowsAsync<T>(Func<Task> action) where T : Exception
        { try { await action().ConfigureAwait(false); } catch (T error) { return error; } throw new InvalidOperationException("Managed TLS contract: expected " + typeof(T).Name); }
        private sealed class MemoryStore : ISessionStore
        {
            private StoredSession session;
            private readonly List<StoredSession> pending = new List<StoredSession>();
            public StoredSession Load() { lock (pending) return session; }
            public void Save(StoredSession value) { lock (pending) session = value; }
            public void Clear() { lock (pending) session = null; }
            public void EndSession(StoredSession value) { lock (pending) { EnqueueRevocation(value ?? session); session = null; } }
            public void EnqueueRevocation(StoredSession value) { lock (pending) if (value != null) pending.Add(value); }
            public IList<StoredSession> PendingRevocations() { lock (pending) return pending.ToList(); }
            public void AcknowledgeRevocation(string id) { lock (pending) pending.RemoveAll(value => value.Id == id); }
        }
    }
}
