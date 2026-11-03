using System;
using System.IO;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;
using System.Threading.Tasks;
using System.Net.Http;
using System.Net.Http.Headers;

namespace Uten.Legacy.Core
{
    /// <summary>The owned publish POST and streaming package PUT may wait for server validation.
    /// This never widens prepare/withdraw, send/handshake timeouts or an unrelated request.</summary>
    internal sealed class ClientReleaseReceiveBudget
    {
        internal const string RequestProperty = "Uten.OwnedClientReleaseReceiveBudget";
        internal static readonly TimeSpan Timeout = TimeSpan.FromMinutes(5);
        private static readonly Regex PathPattern = new Regex(
            "^/api/admin/client-releases/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/publish$",
            RegexOptions.Compiled | RegexOptions.CultureInvariant);
        private readonly HttpRequestMessage owner;
        private readonly Uri uri;

        private ClientReleaseReceiveBudget(HttpRequestMessage request)
        { owner = request; uri = request.RequestUri; }

        internal static void Bind(HttpRequestMessage request)
        {
            if (!PublishRequest(request)) throw new HttpRequestException("发布等待预算不属于本次请求。");
            request.Properties[RequestProperty] = new ClientReleaseReceiveBudget(request);
        }

        internal static TimeSpan ForRequest(HttpRequestMessage request, TimeSpan fallback)
        {
            var upload = ClientReleaseUploadSink.FromRequest(request);
            if (upload != null)
            {
                if (!upload.Owns(request) || request.Properties.ContainsKey(RequestProperty))
                    throw new HttpRequestException("上传等待预算离开了冻结请求。");
                return Timeout;
            }
            object value;
            if (request == null || !request.Properties.TryGetValue(RequestProperty, out value)) return fallback;
            var budget = value as ClientReleaseReceiveBudget;
            if (budget == null || !Object.ReferenceEquals(request, budget.owner) || request.RequestUri != budget.uri
                || !PublishRequest(request)) throw new HttpRequestException("发布等待预算离开了冻结请求。");
            return Timeout;
        }

        private static bool PublishRequest(HttpRequestMessage request)
        {
            var target = request?.RequestUri;
            return request != null && request.Method == HttpMethod.Post && request.Content == null
                && target != null && target.IsAbsoluteUri && target.Scheme == Uri.UriSchemeHttps
                && target.Query.Length == 0 && target.Fragment.Length == 0 && PathPattern.IsMatch(target.AbsolutePath);
        }
    }

    /// <summary>Publish-workbench transport over the one approved TLS stack. Only the reviewed
    /// admin client-release routes are callable here; identities are frozen per operation and a
    /// dispatched write that fails without a definite server rejection stays unknown.</summary>
    public sealed partial class SessionCoordinator
    {
        private static readonly Regex PublishCommandPath = new Regex(
            @"^(admin/client-releases|admin/client-releases/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/(publish|withdraw))$",
            RegexOptions.Compiled | RegexOptions.CultureInvariant);
        private static readonly Regex PublishReadPath = new Regex(
            @"^admin/client-releases(/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})?$",
            RegexOptions.Compiled | RegexOptions.CultureInvariant);
        private const int MaximumPublishRequestBytes = 65536;

        public void DemandClientReleasePublishAccess()
        {
            lock (gate)
            {
                RequireAuthenticated();
                if (!credentials.User.HasPermission(ClientReleasePublishLimits.PublishPermission))
                    throw new ApiException("FORBIDDEN", "当前账号没有客户端发布权限。", 403);
            }
        }

        /// <summary>Reads the admin release ledger or one record. Uses the shared read channel
        /// (bearer refresh, bounded body, read-scope observation) and re-verifies the frozen
        /// publish identity before returning.</summary>
        public async Task<string> ReadClientReleaseAsync(string relativePath, MutationOwnerSnapshot owner, CancellationToken cancellationToken)
        {
            if (owner == null) throw new ArgumentNullException("owner");
            if (relativePath == null || !PublishReadPath.IsMatch(relativePath))
                throw new ApiException("PUBLISH_PATH_NOT_APPROVED", "发布读取路径不符合已审核合同。");
            DemandClientReleasePublishAccess();
            cancellationToken.ThrowIfCancellationRequested();
            var json = await GetAsync("/" + relativePath, cancellationToken).ConfigureAwait(true);
            lock (gate) RequireMutationOwnerLocked(owner);
            return json;
        }

        /// <summary>Sends prepare/publish/withdraw. stepUpToken attaches the one-shot
        /// re-authentication header; the caller decides how to obtain it and may retry the same
        /// frozen request exactly once after obtaining a fresh grant.</summary>
        public async Task<string> SendClientReleaseCommandAsync(string relativePath, string bodyJson,
            MutationOwnerSnapshot owner, string stepUpToken, CancellationToken cancellationToken)
        {
            if (owner == null) throw new ArgumentNullException("owner");
            if (relativePath == null || !PublishCommandPath.IsMatch(relativePath) || relativePath.Contains("/publish") && bodyJson != null
                || relativePath.Contains("/withdraw") && bodyJson != null)
                throw new ApiException("PUBLISH_PATH_NOT_APPROVED", "发布操作路径或请求体不符合已审核合同。");
            if (bodyJson != null && Encoding.UTF8.GetByteCount(bodyJson) > MaximumPublishRequestBytes)
                throw new ApiException("REQUEST_TOO_LARGE", "提交内容超出限制。");
            Scope scope;
            lock (gate)
            {
                RequireMutationOwnerLocked(owner);
                RequireMutationPermissionsLocked(new[] { ClientReleasePublishLimits.PublishPermission });
                scope = CaptureLocked();
            }
            var submitted = false;
            using (var wait = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken, scope.Cancellation))
            using (var request = new HttpRequestMessage(HttpMethod.Post, scope.Endpoint.Resolve(relativePath)))
            {
                if (relativePath.EndsWith("/publish", StringComparison.Ordinal))
                    ClientReleaseReceiveBudget.Bind(request);
                wait.CancelAfter(ClientReleaseReceiveBudget.ForRequest(request, configuration.RequestTimeout));
                request.Headers.Accept.Add(new MediaTypeWithQualityHeaderValue("application/json"));
                if (bodyJson != null) request.Content = new StringContent(bodyJson, Encoding.UTF8, "application/json");
                if (!String.IsNullOrEmpty(stepUpToken))
                    request.Headers.Add(StepUpGrant.HeaderName, stepUpToken);
                try
                {
                    RequireScope(scope);
                    submitted = true;
                    using (var response = await client.SendAsync(request, HttpCompletionOption.ResponseHeadersRead, wait.Token).ConfigureAwait(true))
                    {
                        var status = (int)response.StatusCode;
                        if (status >= 300 && status <= 399)
                            throw new ApiException("REDIRECT_BLOCKED", "服务器返回了重定向，请管理员核对正式接口地址。", status, true);
                        if (response.RequestMessage?.RequestUri != null && response.RequestMessage.RequestUri != request.RequestUri)
                            throw new ApiException("REDIRECT_BLOCKED", "接口响应离开了当前请求地址。", status, true);
                        var text = await ReadBoundedReplyAsync(response, wait.Token).ConfigureAwait(true);
                        lock (gate) RequireMutationOwnerLocked(owner);
                        var failure = ErrorFrom(new Reply(status, text, ReadScopeHeaders.Capture(response)), true);
                        if (failure != null) throw failure;
                        return text;
                    }
                }
                catch (OperationCanceledException)
                {
                    RequireScope(scope);
                    if (submitted) throw SubmissionUnknown();
                    if (cancellationToken.IsCancellationRequested) throw;
                    throw new ApiException("NETWORK_TIMEOUT", "等待服务器响应超时，请检查网络后重试。");
                }
                catch (HttpRequestException error)
                {
                    RequireScope(scope);
                    if (IsTlsFailure(error)) throw new ApiException("TLS_VALIDATION_FAILED", "服务器证书验证失败，请核对公司连接配置和系统时间。");
                    if (submitted) throw SubmissionUnknown();
                    throw new ApiException("NETWORK", "无法连接服务器，请检查网络后重试。");
                }
                catch (IOException)
                {
                    RequireScope(scope);
                    if (submitted) throw SubmissionUnknown();
                    throw new ApiException("NETWORK", "读取服务器响应失败，请检查网络后重试。");
                }
                catch (DecoderFallbackException)
                { throw new ApiException("INVALID_RESPONSE", "服务器响应格式不正确。", isSubmissionUnknown: true); }
            }
        }

        /// <summary>Streams one package file to its frozen draft record. The upload runs on a
        /// dedicated 30-minute budget and hashes while writing; nothing is buffered in memory.</summary>
        public Task<string> UploadClientPackageAsync(string releaseId, string sourcePath, long expectedBytes,
            string expectedSha256, MutationOwnerSnapshot owner, CancellationToken cancellationToken,
            IProgress<long> progress = null)
        {
            if (owner == null) throw new ArgumentNullException("owner");
            cancellationToken.ThrowIfCancellationRequested();
            Scope scope;
            lock (gate)
            {
                RequireMutationOwnerLocked(owner);
                RequireMutationPermissionsLocked(new[] { ClientReleasePublishLimits.PublishPermission });
                scope = CaptureLocked();
            }
            return Task.Run(delegate
            {
                return UploadOwnedClientPackageAsync(scope, releaseId, sourcePath, expectedBytes, expectedSha256, owner, cancellationToken, progress);
            }, cancellationToken);
        }

        private async Task<string> UploadOwnedClientPackageAsync(Scope scope, string releaseId, string sourcePath,
            long expectedBytes, string expectedSha256, MutationOwnerSnapshot owner, CancellationToken callerCancellation,
            IProgress<long> progress)
        {
            Guid id;
            if (!Guid.TryParseExact(releaseId, "D", out id) || expectedSha256 == null
                || !Regex.IsMatch(expectedSha256, "^[0-9a-fA-F]{64}$") || expectedBytes < 1
                || expectedBytes > ClientReleaseUploadSink.MaximumPackageBytes)
                throw new ApiException("INVALID_UPLOAD_METADATA", "上传信息无效，请核对原发布记录。");
            var submitted = false;
            ClientReleaseUploadSink sink = null;
            using (var lifetime = CancellationTokenSource.CreateLinkedTokenSource(callerCancellation, scope.Cancellation))
            {
                lifetime.CancelAfter(TimeSpan.FromMinutes(30));
                try
                {
                    var token = lifetime.Token;
                    var owned = await EnsureAccessAsync(scope, false, null, token).ConfigureAwait(false);
                    token.ThrowIfCancellationRequested();
                    RequireScope(scope);
                    var relative = "admin/client-releases/" + releaseId + "/package";
                    var uri = scope.Endpoint.Resolve(relative);
                    for (var attempt = 0; ; attempt++)
                    {
                        token.ThrowIfCancellationRequested();
                        RequireScope(scope);
                        using (var request = new HttpRequestMessage(new HttpMethod("PUT"), uri))
                        {
                            sink = new ClientReleaseUploadSink(releaseId, sourcePath, expectedBytes, expectedSha256, progress, delegate { RequireScope(scope); });
                            request.Headers.Accept.Add(new MediaTypeWithQualityHeaderValue("application/json"));
                            request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", owned.AccessToken);
                            request.Properties[ClientReleaseUploadSink.RequestProperty] = sink;
                            using (var response = await client.SendAsync(request, HttpCompletionOption.ResponseHeadersRead, token).ConfigureAwait(false))
                            {
                                RequireScope(scope);
                                token.ThrowIfCancellationRequested();
                                submitted = true;
                                var status = (int)response.StatusCode;
                                if (status >= 300 && status <= 399 || response.RequestMessage?.RequestUri != null && response.RequestMessage.RequestUri != uri)
                                    throw new ApiException("REDIRECT_BLOCKED", "服务器返回了重定向，请管理员核对正式接口地址。", status, true);
                                if (status == 401 && attempt == 0)
                                {
                                    var preliminary = ErrorFrom(new Reply(status, await ReadBoundedReplyAsync(response, token).ConfigureAwait(false), null), false);
                                    if (preliminary != null && preliminary.HasResponseCode && preliminary.Code == "UNAUTHORIZED")
                                    {
                                        owned = await EnsureAccessAsync(scope, true, owned, token).ConfigureAwait(false);
                                        submitted = false;
                                        // An explicit UNAUTHORIZED reply is a definite rejection.
                                        // Any retry keeps the original ID/file/hash and a fresh stream sink.
                                        continue;
                                    }
                                    throw preliminary;
                                }
                                var text = await ReadBoundedReplyAsync(response, token).ConfigureAwait(false);
                                lock (gate) RequireMutationOwnerLocked(owner);
                                var failure = ErrorFrom(new Reply(status, text, ReadScopeHeaders.Capture(response)), true);
                                if (failure != null) throw failure;
                                return text;
                            }
                        }
                    }
                }
                catch (OperationCanceledException)
                {
                    RequireScope(scope);
                    if (submitted || sink?.Started == true) throw SubmissionUnknown();
                    if (callerCancellation.IsCancellationRequested) throw;
                    throw new ApiException("UPLOAD_TIMEOUT", "软件包上传超时，请核对原记录后重试。");
                }
                catch (HttpRequestException error)
                {
                    RequireScope(scope);
                    if (IsTlsFailure(error)) throw new ApiException("TLS_VALIDATION_FAILED", "上传服务器证书验证失败。", isSubmissionUnknown: submitted || sink?.Started == true);
                    if (submitted || sink?.Started == true) throw SubmissionUnknown();
                    throw new ApiException("NETWORK", "无法连接服务器，请检查网络后重试。");
                }
                catch (IOException)
                {
                    RequireScope(scope);
                    // A partial package write may already be staged server-side: unknown, not failed.
                    if (submitted || sink?.Started == true) throw SubmissionUnknown();
                    throw new ApiException("UPLOAD_IO", "软件包读取或上传失败，请核对原文件。");
                }
                catch (DecoderFallbackException)
                { throw new ApiException("INVALID_RESPONSE", "服务器响应格式不正确。", isSubmissionUnknown: true); }
            }
        }

        private async Task<string> ReadBoundedReplyAsync(HttpResponseMessage response, CancellationToken token)
        {
            if (response.Content == null) return "";
            if (response.Content.Headers.ContentLength > configuration.MaxResponseBytes)
                throw new ApiException("RESPONSE_TOO_LARGE", "服务器返回的内容超出读取上限。", (int)response.StatusCode, true);
            using (var stream = await response.Content.ReadAsStreamAsync().ConfigureAwait(false))
            using (var output = new MemoryStream())
            {
                var buffer = new byte[8192];
                int read;
                while ((read = await stream.ReadAsync(buffer, 0, buffer.Length, token).ConfigureAwait(false)) != 0)
                {
                    if (output.Length + read > configuration.MaxResponseBytes)
                        throw new ApiException("RESPONSE_TOO_LARGE", "服务器返回的内容超出读取上限。", (int)response.StatusCode, true);
                    output.Write(buffer, 0, read);
                }
                return new UTF8Encoding(false, true).GetString(output.ToArray());
            }
        }
    }
}
