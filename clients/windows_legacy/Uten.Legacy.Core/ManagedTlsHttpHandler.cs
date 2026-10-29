using System;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Net;
using System.Net.Http;
using System.Net.Sockets;
using System.Security.Authentication;
using System.Security.Cryptography;
using System.Threading;
using System.Threading.Tasks;
using Org.BouncyCastle.Tls;
using Org.BouncyCastle.Tls.Crypto.Impl.BC;

namespace Uten.Legacy.Core
{
    /// <summary>
    /// TLS 1.2 is implemented by the pinned official BC library, avoiding Win7 Schannel's
    /// missing ECDHE_RSA AES-GCM suites. HTTP remains a bounded, one-request-per-connection protocol.
    /// </summary>
    internal sealed class ManagedTlsHttpHandler : HttpMessageHandler
    {
        internal const string ExpectedBouncyCastleSha256 = "4f96977e9c67334742c683410b3a361258219f0d3084a5e0bc10fba96cf23a0d";
        private static readonly Lazy<bool> DependencyVerified = new Lazy<bool>(VerifyDependency, true);
        private readonly ClientConfiguration configuration;
        private readonly ManagedCertificateValidator validator;
        private readonly Func<Uri, CancellationToken, TcpClient> connector;
        private readonly SemaphoreSlim connectionSlots = new SemaphoreSlim(8, 8);
        private readonly ConcurrentDictionary<TcpClient, byte> active = new ConcurrentDictionary<TcpClient, byte>();
        private volatile bool disposed;
        internal int LastNegotiatedCipherSuite { get; private set; }
        internal Action<int> ResponseHeadersObserved { get; set; }

        internal ManagedTlsHttpHandler(ClientConfiguration configuration)
            : this(configuration, CompanyCertificatePolicy.FromEmbeddedCertificate(), null) { }

        // Test-owned root/loopback connector never alter production origins, pinned root, DNS or system trust.
        internal ManagedTlsHttpHandler(ClientConfiguration configuration, CompanyCertificatePolicy companyPolicy,
            Func<Uri, CancellationToken, TcpClient> connector)
        {
            if (!DependencyVerified.Value) throw new InvalidDataException("安全通信组件校验失败。");
            this.configuration = configuration ?? throw new ArgumentNullException(nameof(configuration));
            validator = new ManagedCertificateValidator(companyPolicy ?? throw new ArgumentNullException(nameof(companyPolicy)));
            this.connector = connector ?? Connect;
        }

        protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken)
        {
            if (disposed) throw new ObjectDisposedException(nameof(ManagedTlsHttpHandler));
            ValidateRequestOrigin(request);
            await connectionSlots.WaitAsync(cancellationToken).ConfigureAwait(false);
            try
            {
                // BC's blocking stream API runs off the UI thread. Cancellation closes the owned socket.
                return await Task.Run(() => SendBlocking(request, cancellationToken)).ConfigureAwait(false);
            }
            finally { connectionSlots.Release(); }
        }

        private HttpResponseMessage SendBlocking(HttpRequestMessage request, CancellationToken originalCancellation)
        {
            originalCancellation.ThrowIfCancellationRequested();
            var origin = request.RequestUri;
            var responseSink = HttpResponseSink.FromRequest(request);
            var handshakeComplete = false;
            TcpClient socket = null;
            CancellationTokenSource credentialBodyDeadline = null;
            CancellationTokenRegistration originalAbort = default(CancellationTokenRegistration);
            CancellationTokenRegistration bodyAbort = default(CancellationTokenRegistration);
            try
            {
                socket = connector(origin, originalCancellation);
                if (disposed) throw new ObjectDisposedException(nameof(ManagedTlsHttpHandler));
                active.TryAdd(socket, 0);
                socket.NoDelay = true;
                socket.ReceiveTimeout = socket.SendTimeout = (int)configuration.RequestTimeout.TotalMilliseconds;
                var ownedSocket = socket;
                originalAbort = originalCancellation.Register(() => CloseSocket(ownedSocket));
                using (var stream = socket.GetStream())
                {
                    var protocol = new TlsClientProtocol(stream);
                    try
                    {
                    var peer = new StrictTlsClient(origin, validator, (int)configuration.RequestTimeout.TotalMilliseconds);
                    protocol.Connect(peer);
                    handshakeComplete = true;
                    LastNegotiatedCipherSuite = peer.NegotiatedCipherSuite;
                    ValidateRequestOrigin(request);
                    if (request.RequestUri != origin) throw new HttpRequestException("接口请求地址已经变化。");
                    return ManagedHttp11.SendAndReceive(protocol.Stream, request,
                        responseSink == null ? configuration.MaxResponseBytes : responseSink.MaximumBytes,
                        originalCancellation, status =>
                        {
                            var auth = request.Method == HttpMethod.Post && status >= 200 && status <= 299
                                && (origin.AbsolutePath == "/api/auth/login" || origin.AbsolutePath == "/api/auth/refresh"
                                    || origin.AbsolutePath == "/api/auth/change-password");
                            if (auth)
                            {
                                // A completed auth exchange may issue a new refresh token. After its
                                // headers, preserve its bounded body even if logout changes generation.
                                originalAbort.Dispose();
                                credentialBodyDeadline = new CancellationTokenSource(TimeSpan.FromSeconds(5));
                                bodyAbort = credentialBodyDeadline.Token.Register(() => CloseSocket(ownedSocket));
                            }
                            var observed = ResponseHeadersObserved;
                            if (observed != null) observed(status);
                            return auth ? credentialBodyDeadline.Token : originalCancellation;
                        }, responseSink);
                    }
                    finally
                    {
                        // A complete framed response is already authenticated. Closing this
                        // one-use connection must not turn it into an uncertain write result.
                        try { protocol.Close(); } catch (IOException) { }
                    }
                }
            }
            catch (Exception error) when (error is IOException || error is SocketException || error is AuthenticationException
                || error is ObjectDisposedException)
            {
                if (credentialBodyDeadline?.IsCancellationRequested == true)
                    throw new OperationCanceledException(credentialBodyDeadline.Token);
                if (originalCancellation.IsCancellationRequested && credentialBodyDeadline == null)
                    throw new OperationCanceledException(originalCancellation);
                if (!handshakeComplete)
                    throw new HttpRequestException("安全连接未能建立。", new AuthenticationException("服务器 TLS 或证书验证失败。"));
                throw new HttpRequestException("安全连接读取中断。", new IOException("安全通信未完整结束。"));
            }
            finally
            {
                originalAbort.Dispose();
                bodyAbort.Dispose();
                if (credentialBodyDeadline != null) credentialBodyDeadline.Dispose();
                if (socket != null) { byte ignored; active.TryRemove(socket, out ignored); CloseSocket(socket); }
            }
        }

        private void ValidateRequestOrigin(HttpRequestMessage request)
        {
            var uri = request?.RequestUri;
            if (uri == null || !uri.IsAbsoluteUri || uri.Scheme != Uri.UriSchemeHttps || uri.UserInfo.Length != 0
                || uri.Fragment.Length != 0 || (request.Method != HttpMethod.Get && request.Method != HttpMethod.Post
                    && !MutationWirePermit.AllowsExtendedMethod(request)))
                throw new HttpRequestException("接口请求不符合固定 HTTPS 契约。");
            var owner = configuration.Endpoints.FirstOrDefault(value =>
                value.ApiBaseUri.GetLeftPart(UriPartial.Authority) == uri.GetLeftPart(UriPartial.Authority));
            if (owner == null || !uri.AbsolutePath.StartsWith("/api/", StringComparison.Ordinal)
                || owner.Resolve(uri.PathAndQuery.Substring(5)) != uri)
                throw new HttpRequestException("接口请求不属于已审核服务器。");
            var sink = HttpResponseSink.FromRequest(request);
            if (sink != null && !sink.Owns(request))
                throw new HttpRequestException("下载请求不属于预先绑定的下载合同。");
            var mutation = MutationWirePermit.From(request);
            if (mutation != null && !mutation.Owns(request)) throw new HttpRequestException("提交请求离开了冻结的接口合同。");
        }

        private static TcpClient Connect(Uri uri, CancellationToken cancellationToken)
        {
            var socket = new TcpClient();
            try
            {
                using (cancellationToken.Register(() => CloseSocket(socket)))
                {
                    var pending = socket.ConnectAsync(uri.DnsSafeHost, uri.Port);
                    try { pending.Wait(cancellationToken); }
                    catch (AggregateException) { pending.GetAwaiter().GetResult(); throw; }
                    cancellationToken.ThrowIfCancellationRequested();
                    pending.GetAwaiter().GetResult();
                }
                return socket;
            }
            catch { CloseSocket(socket); throw; }
        }

        private static void CloseSocket(TcpClient socket)
        { try { socket.Close(); } catch (ObjectDisposedException) { } }

        private static bool VerifyDependency()
        {
            var location = typeof(TlsClientProtocol).Assembly.Location;
            if (String.IsNullOrEmpty(location)) throw new InvalidDataException("安全通信组件位置无效。");
            using (var stream = File.OpenRead(location))
            using (var sha = SHA256.Create())
            {
                var actual = BitConverter.ToString(sha.ComputeHash(stream)).Replace("-", "").ToLowerInvariant();
                if (actual != ExpectedBouncyCastleSha256) throw new InvalidDataException("安全通信组件不是本次审核的固定版本。");
            }
            return true;
        }

        protected override void Dispose(bool disposing)
        {
            disposed = true;
            if (disposing) foreach (var socket in active.Keys) CloseSocket(socket);
            base.Dispose(disposing);
        }

        private sealed class StrictTlsClient : DefaultTlsClient
        {
            private readonly Uri origin;
            private readonly ManagedCertificateValidator validator;
            private readonly int timeoutMilliseconds;
            internal int NegotiatedCipherSuite { get; private set; }
            internal StrictTlsClient(Uri origin, ManagedCertificateValidator validator, int timeoutMilliseconds) : base(new BcTlsCrypto())
            { this.origin = origin; this.validator = validator; this.timeoutMilliseconds = timeoutMilliseconds; }
            protected override ProtocolVersion[] GetSupportedVersions() { return new[] { ProtocolVersion.TLSv12 }; }
            protected override int[] GetSupportedCipherSuites()
            {
                return new[] { CipherSuite.TLS_ECDHE_RSA_WITH_AES_128_GCM_SHA256, CipherSuite.TLS_ECDHE_RSA_WITH_AES_256_GCM_SHA384,
                    CipherSuite.TLS_ECDHE_ECDSA_WITH_AES_128_GCM_SHA256, CipherSuite.TLS_ECDHE_ECDSA_WITH_AES_256_GCM_SHA384 };
            }
            protected override IList<ServerName> GetSniServerNames()
            {
                IPAddress address;
                return IPAddress.TryParse(origin.DnsSafeHost, out address) ? null
                    : new List<ServerName> { new ServerName(NameType.host_name, System.Text.Encoding.ASCII.GetBytes(origin.IdnHost)) };
            }
            protected override IList<ProtocolName> GetProtocolNames() { return new List<ProtocolName> { ProtocolName.Http_1_1 }; }
            protected override CertificateStatusRequest GetCertificateStatusRequest() { return null; }
            public override int GetHandshakeTimeoutMillis() { return timeoutMilliseconds; }
            public override int GetMaxCertificateChainLength() { return 8; }
            public override int GetMaxHandshakeMessageSize() { return 65536; }
            public override bool RequiresExtendedMasterSecret() { return true; }
            public override TlsAuthentication GetAuthentication() { return new ServerAuthentication(origin, validator); }
            public override void NotifyHandshakeComplete()
            {
                base.NotifyHandshakeComplete();
                var security = m_context.SecurityParameters;
                if (!ProtocolVersion.TLSv12.Equals(security.NegotiatedVersion)
                    || (security.ApplicationProtocol != null && !ProtocolName.Http_1_1.Equals(security.ApplicationProtocol)))
                    throw new TlsFatalAlert(AlertDescription.handshake_failure);
                NegotiatedCipherSuite = security.CipherSuite;
            }
        }

        private sealed class ServerAuthentication : TlsAuthentication
        {
            private readonly Uri origin;
            private readonly ManagedCertificateValidator validator;
            internal ServerAuthentication(Uri origin, ManagedCertificateValidator validator) { this.origin = origin; this.validator = validator; }
            public void NotifyServerCertificate(TlsServerCertificate certificate)
            {
                try { validator.Validate(origin, certificate.Certificate.GetCertificateList().Select(value => value.GetEncoded()).ToList()); }
                catch (AuthenticationException error) { throw new TlsFatalAlert(AlertDescription.bad_certificate, error); }
            }
            public TlsCredentials GetClientCredentials(Org.BouncyCastle.Tls.CertificateRequest certificateRequest) { return null; }
        }
    }
}
