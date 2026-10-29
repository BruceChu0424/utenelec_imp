using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Net;
using System.Net.Http;
using System.Net.Http.Headers;
using System.Security.Authentication;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;
using System.Threading.Tasks;

namespace Uten.Legacy.Core
{
    /// <summary>
    /// Native authentication foundation. No business write replay, arbitrary URL, global TLS hook,
    /// cookie authentication, or shared Flutter credential store is used here.
    /// </summary>
    public sealed partial class SessionCoordinator : IDisposable
    {
        private readonly object gate = new object();
        private readonly ClientConfiguration configuration;
        private readonly ISessionStore store;
        private readonly HttpClient client;
        private readonly bool usesManagedTlsTransport;
        private readonly IBusinessStateStore businessStateStore;
        private readonly SemaphoreSlim refreshLock = new SemaphoreSlim(1, 1);
        private readonly SemaphoreSlim revocationLock = new SemaphoreSlim(1, 1);
        private CancellationTokenSource generationCancellation = new CancellationTokenSource();
        private CancellationTokenSource readCancellation = new CancellationTokenSource();
        private readonly ReadScopeRevisionState readScopes = new ReadScopeRevisionState();
        private long readSequence;
        private ServerEndpoint endpoint;
        private Credentials credentials;
        private long generation;
        private bool disposed;

        public SessionCoordinator(ClientConfiguration configuration)
            : this(configuration, new ManagedTlsHttpHandler(configuration), new DpapiSessionStore(), new DpapiBusinessStateStore()) { }

        /// <summary>The injected handler/store are owned by this coordinator; intended for isolated tests.</summary>
        public SessionCoordinator(ClientConfiguration configuration, HttpMessageHandler handler, ISessionStore store)
            : this(configuration, handler, store, null) { }

        public SessionCoordinator(ClientConfiguration configuration, HttpMessageHandler handler, ISessionStore store,
            IBusinessStateStore businessStateStore)
        {
            this.configuration = configuration ?? throw new ArgumentNullException(nameof(configuration));
            this.store = store ?? throw new ArgumentNullException(nameof(store));
            usesManagedTlsTransport = handler is ManagedTlsHttpHandler;
            this.businessStateStore = businessStateStore;
            client = new HttpClient(handler ?? throw new ArgumentNullException(nameof(handler)), true)
            { Timeout = Timeout.InfiniteTimeSpan };
            endpoint = configuration.Endpoints.FirstOrDefault(value => value.Id == configuration.SelectedEndpointId);
        }

        public event EventHandler SessionChanged;
        public event EventHandler ReadScopeChanged;
        public UserProfile CurrentUser { get { lock (gate) return credentials?.User; } }
        public bool IsAuthenticated { get { lock (gate) return credentials?.User != null && credentials.AccessToken != null; } }
        public ServerEndpoint CurrentEndpoint { get { lock (gate) return endpoint; } }
        public long Generation { get { lock (gate) return generation; } }
        public long ReadScopeRevision { get { lock (gate) return readScopes.Revision; } }

        public void SelectEndpoint(string endpointId)
        {
            lock (gate)
            {
                RequireNotDisposed();
                var selected = configuration.Endpoints.FirstOrDefault(value => value.Id == endpointId);
                if (selected == null) throw new ApiException("ENDPOINT_NOT_APPROVED", "请选择配置中已审核的服务器。");
                if (endpoint?.Id == selected.Id) return;
                Persist(() => store.EndSession(credentials?.Stored));
                AdvanceGenerationLocked();
                credentials = null;
                endpoint = selected;
            }
            RaiseSessionChanged();
        }

        public async Task LoginAsync(string account, string password, string otp, CancellationToken cancellationToken)
        {
            cancellationToken.ThrowIfCancellationRequested();
            if (String.IsNullOrWhiteSpace(account) || account.Trim().Length > 128 || String.IsNullOrEmpty(password)
                || password.Length > 4096 || (otp != null && otp.Length > 16))
                throw new ApiException("LOGIN_INPUT_INVALID", "请填写有效的账号、密码和验证码。");
            Scope scope;
            lock (gate)
            {
                RequireEndpoint();
                Persist(() => store.EndSession(credentials?.Stored));
                AdvanceGenerationLocked();
                credentials = null;
                scope = CaptureLocked();
            }
            RaiseSessionChanged();
            var body = new Dictionary<string, object> { { "loginAccount", account.Trim() }, { "password", password },
                { "deviceName", "Windows 原生兼容客户端" } };
            if (!String.IsNullOrWhiteSpace(otp)) body.Add("otpCode", otp.Trim());
            var response = await SendAsync(scope, HttpMethod.Post, "auth/login", body, null, cancellationToken).ConfigureAwait(false);
            if (response.Status < 200 || response.Status > 299) RequireScope(scope);
            RequireSuccess(response, true);
            var result = ParseIssuedCredentials(response.Text);
            await CommitAsync(scope, null, result, cancellationToken).ConfigureAwait(false);
            await TryDrainPendingAsync(cancellationToken).ConfigureAwait(false);
        }

        public async Task RestoreAsync(CancellationToken cancellationToken, bool waitForPendingRevocations = true)
        {
            cancellationToken.ThrowIfCancellationRequested();
            Scope scope = null;
            lock (gate)
            {
                RequireNotDisposed();
                if (endpoint == null) return;
                var saved = Persist(() => store.Load());
                if (saved != null && saved.IssuerApiBaseUrl == endpoint.ApiBaseUrl && saved.EndpointId == endpoint.Id)
                {
                    AdvanceGenerationLocked();
                    credentials = new Credentials(saved);
                    scope = CaptureLocked();
                }
            }
            if (scope != null) await EnsureAccessAsync(scope, false, null, cancellationToken).ConfigureAwait(false);
            // A logged-out startup still drains the durable queue. This never restores an
            // active record hidden behind the storage failure fence.
            if (waitForPendingRevocations) await TryDrainPendingAsync(cancellationToken).ConfigureAwait(false);
        }

        public async Task ChangePasswordAsync(string oldPassword, string newPassword, CancellationToken cancellationToken)
        {
            cancellationToken.ThrowIfCancellationRequested();
            if (String.IsNullOrEmpty(oldPassword) || String.IsNullOrEmpty(newPassword)
                || oldPassword.Length > 4096 || newPassword.Length > 4096)
                throw new ApiException("PASSWORD_INPUT_INVALID", "请填写原密码和新密码。");
            Scope scope;
            lock (gate)
            {
                RequireAuthenticated();
                AdvanceGenerationLocked();
                scope = CaptureLocked();
            }
            RaiseSessionChanged();
            var owned = await EnsureAccessAsync(scope, false, null, cancellationToken).ConfigureAwait(false);
            var response = await SendAsync(scope, HttpMethod.Post, "auth/change-password",
                new Dictionary<string, object> { { "oldPassword", oldPassword }, { "newPassword", newPassword } },
                owned.AccessToken, cancellationToken).ConfigureAwait(false);
            // A write is never replayed after a 401, transport failure, or uncertain response.
            if (response.Status < 200 || response.Status > 299) RequireScope(scope);
            RequireSuccess(response, true);
            await CommitAsync(scope, owned, ParseIssuedCredentials(response.Text), cancellationToken).ConfigureAwait(false);
        }

        public async Task LogoutAsync(CancellationToken cancellationToken)
        {
            // Local logout is committed even if the caller's network wait was cancelled.
            ApiException persistenceFailure = null;
            StoredSession knownSession;
            var fenced = false;
            lock (gate)
            {
                RequireNotDisposed();
                knownSession = credentials?.Stored;
                try { Persist(() => store.EndSession(knownSession)); }
                catch (ApiException error)
                {
                    persistenceFailure = error;
                    if (knownSession == null)
                    {
                        // A read-only disk can still expose the old owned record for an online
                        // revocation attempt. Capture it before installing the restore fence.
                        try { knownSession = Persist(() => store.Load()); }
                        catch (ApiException) { /* No recoverable token; failure remains explicit below. */ }
                    }
                    var safety = store as ISessionStoreSafetyFence;
                    if (safety != null)
                    {
                        try { Persist(() => safety.FenceActiveSession()); fenced = true; }
                        catch (ApiException) { /* Reported below; never claim this logout was durable. */ }
                    }
                }
                AdvanceGenerationLocked();
                credentials = null;
            }
            RaiseSessionChanged();
            if (persistenceFailure != null)
            {
                var revoked = false;
                if (knownSession != null)
                {
                    try
                    {
                        // A broken local queue must not prevent an immediate, issuer-bound server
                        // revocation attempt. No current/new account bearer is attached.
                        await RevokeKnownSessionAsync(knownSession, cancellationToken).ConfigureAwait(false);
                        revoked = true;
                    }
                    catch (Exception error) when (error is ApiException || error is OperationCanceledException) { }
                }
                var message = "已退出本机，但本机会话文件清理失败。"
                    + (fenced ? "已阻止旧会话自动恢复。" : "尚不能确认旧磁盘会话已被阻止恢复。")
                    + (revoked ? "服务器已撤销本次已知会话。" : "服务器注销结果待确认。")
                    + "请联系管理员修复本机存储，不能将本次退出视为完整成功。";
                throw new ApiException("LOGOUT_STORAGE_FAILED", message, isSubmissionUnknown: !revoked);
            }
            try { await DrainPendingRevocationsAsync(cancellationToken).ConfigureAwait(false); }
            catch (Exception error) when (error is ApiException || error is OperationCanceledException)
            { throw new ApiException("LOGOUT_PENDING", "已退出本机；服务器注销已保存在待处理队列，恢复连接后重试。", isSubmissionUnknown: true); }
        }

        public async Task<string> GetAsync(string relativePath, CancellationToken cancellationToken)
        {
            Scope scope;
            ReadRequest reader;
            lock (gate)
            {
                RequireAuthenticated();
                scope = CaptureLocked();
                reader = new ReadRequest(readScopes.Revision, ++readSequence, readCancellation.Token);
            }
            using (var readWait = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken, reader.Cancellation))
            {
                try
                {
                    // A reader's retirement/close must not cancel a shared credential refresh.
                    var owned = await EnsureAccessAsync(scope, false, null, cancellationToken).ConfigureAwait(false);
                    RequireReader(scope, reader);
                    var response = await SendAsync(scope, HttpMethod.Get, relativePath, null, owned.AccessToken, readWait.Token).ConfigureAwait(false);
                    RequireReader(scope, reader);
                    var failure = ErrorFrom(response, false);
                    if (failure != null && failure.StatusCode == 401 && failure.HasResponseCode && failure.Code == "UNAUTHORIZED")
                    {
                        owned = await EnsureAccessAsync(scope, true, owned, cancellationToken).ConfigureAwait(false);
                        RequireReader(scope, reader);
                        response = await SendAsync(scope, HttpMethod.Get, relativePath, null, owned.AccessToken, readWait.Token).ConfigureAwait(false);
                        RequireReader(scope, reader);
                        failure = ErrorFrom(response, false);
                    }
                    if (failure != null)
                    {
                        if (failure.Code == "READ_SCOPE_CHANGED" && failure.StatusCode == 403 && failure.HasResponseCode)
                            RetireReader(scope, reader);
                        if (failure.Code != "VALIDATION_FAILED" && IsDefinitiveRejection(failure)) RejectCurrent(scope, owned);
                        throw failure;
                    }
                    ObserveReadReply(scope, reader, scope.Endpoint.Resolve(relativePath).AbsolutePath, response);
                    RequireReader(scope, reader);
                    return response.Text;
                }
                catch (OperationCanceledException) { RequireReader(scope, reader); throw; }
            }
        }

        private void RequireReader(Scope scope, ReadRequest reader)
        {
            lock (gate)
            {
                RequireScopeLocked(scope);
                if (reader.Revision != readScopes.Revision) throw ReadScopeChangedError();
            }
        }
        private void RetireReader(Scope scope, ReadRequest reader)
        {
            var changed = false;
            lock (gate)
            {
                RequireScopeLocked(scope);
                if (reader.Revision == readScopes.Revision)
                {
                    readScopes.Retire();
                    ResetReadCancellationLocked();
                    changed = true;
                }
            }
            if (changed) RaiseReadScopeChanged();
        }
        private void ObserveReadReply(Scope scope, ReadRequest reader, string path, Reply response)
        {
            var proof = ReadScopeProof.Read(response.Text, response.ReadScope);
            ReadProofDisposition disposition;
            lock (gate)
            {
                RequireScopeLocked(scope);
                disposition = readScopes.Observe(reader, path, proof);
                if (disposition == ReadProofDisposition.Retired) ResetReadCancellationLocked();
            }
            if (disposition == ReadProofDisposition.Retired) RaiseReadScopeChanged();
            if (disposition != ReadProofDisposition.Accepted) throw ReadScopeChangedError();
        }
        private void ResetReadCancellationLocked()
        {
            var prior = readCancellation;
            readCancellation = new CancellationTokenSource();
            prior.Cancel();
            prior.Dispose();
        }
        private void RaiseReadScopeChanged()
        {
            var changed = ReadScopeChanged;
            if (changed != null) changed(this, EventArgs.Empty);
        }
        private static ApiException ReadScopeChangedError()
        { return new ApiException("READ_SCOPE_CHANGED", "数据访问范围已变化，请重新打开页面后核对。", 403); }

        /// <summary>Retries only idempotent logout revocations, always at the record's approved issuer.</summary>
        public async Task DrainPendingRevocationsAsync(CancellationToken cancellationToken)
        {
            await revocationLock.WaitAsync(cancellationToken).ConfigureAwait(false);
            try
            {
                var pending = Persist(() => store.PendingRevocations());
                foreach (var item in pending)
                {
                    cancellationToken.ThrowIfCancellationRequested();
                    // Unrecognized records remain encrypted; never send their token to a replacement host.
                    if (!configuration.Endpoints.Any(value => value.Id == item.EndpointId && value.ApiBaseUrl == item.IssuerApiBaseUrl)) continue;
                    await RevokeKnownSessionAsync(item, cancellationToken).ConfigureAwait(false);
                    Persist(() => store.AcknowledgeRevocation(item.Id));
                }
            }
            finally { revocationLock.Release(); }
        }

        private async Task RevokeKnownSessionAsync(StoredSession item, CancellationToken cancellationToken)
        {
            var issuer = configuration.Endpoints.FirstOrDefault(value => value.Id == item.EndpointId
                && value.ApiBaseUrl == item.IssuerApiBaseUrl);
            if (issuer == null) throw new ApiException("ENDPOINT_NOT_APPROVED", "旧会话的签发服务器已不在受信配置中，未发送其凭据。");
            var scope = new Scope(-1, issuer, CancellationToken.None, true);
            var response = await SendAsync(scope, HttpMethod.Post, "auth/logout",
                new Dictionary<string, object> { { "refreshToken", item.RefreshToken } }, null, cancellationToken).ConfigureAwait(false);
            RequireSuccess(response, true);
        }

        private async Task TryDrainPendingAsync(CancellationToken cancellationToken)
        {
            try { await DrainPendingRevocationsAsync(cancellationToken).ConfigureAwait(false); }
            catch (ApiException) { /* Queue remains durable; a login is not rolled back by an old logout outage. */ }
            catch (OperationCanceledException) { }
        }

        private async Task<Credentials> EnsureAccessAsync(Scope scope, bool force, Credentials used, CancellationToken cancellationToken)
        {
            lock (gate)
            {
                RequireScopeLocked(scope);
                if (credentials == null) throw SessionChangedError();
                if (!force && !credentials.NearExpiry) return credentials;
            }
            using (var wait = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken, scope.Cancellation))
            {
                try { await refreshLock.WaitAsync(wait.Token).ConfigureAwait(false); }
                catch (OperationCanceledException) { RequireScope(scope); throw; }
            }
            Credentials submitted = null;
            try
            {
                lock (gate)
                {
                    RequireScopeLocked(scope);
                    submitted = credentials;
                    if (submitted == null) throw SessionChangedError();
                    if ((!force && !submitted.NearExpiry)
                        || (force && used != null && submitted.AccessToken != used.AccessToken)) return submitted;
                }
                var response = await SendAsync(scope, HttpMethod.Post, "auth/refresh",
                    new Dictionary<string, object> { { "refreshToken", submitted.Stored.RefreshToken } },
                    null, CancellationToken.None).ConfigureAwait(false);
                if (response.Status < 200 || response.Status > 299) RequireScope(scope);
                RequireSuccess(response, true);
                var result = ParseIssuedCredentials(response.Text);
                await CommitAsync(scope, submitted, result, CancellationToken.None).ConfigureAwait(false);
                cancellationToken.ThrowIfCancellationRequested();
                lock (gate) { RequireScopeLocked(scope); return credentials; }
            }
            catch (ApiException error)
            {
                if (IsDefinitiveRejection(error)) RejectCurrent(scope, submitted);
                throw;
            }
            finally { refreshLock.Release(); }
        }

        private async Task CommitAsync(Scope scope, Credentials expected, AuthResult result, CancellationToken cancellationToken)
        {
            var saved = new StoredSession(result.RefreshToken, scope.Endpoint.ApiBaseUrl, scope.Endpoint.Id, result.User.Id);
            try
            {
                lock (gate)
                {
                    RequireScopeLocked(scope);
                    if (!Object.ReferenceEquals(credentials, expected)) throw SessionChangedError();
                    if (expected != null && expected.Stored.UserId != result.User.Id)
                        throw new ApiException("INVALID_AUTH_RESPONSE", "会话账号不一致，请重新登录。");
                    Persist(() => store.Save(saved));
                    if (expected?.User != null && ProfileFenceChanged(expected.User, result.User)) AdvanceGenerationLocked();
                    credentials = new Credentials(result, saved);
                }
            }
            catch (ApiException error) when (error.Code == "SESSION_CHANGED" || error.Code == "INVALID_AUTH_RESPONSE"
                || error.Code == "LOCAL_SESSION_STORAGE")
            {
                var changed = false;
                if (error.Code == "LOCAL_SESSION_STORAGE")
                {
                    lock (gate)
                    {
                        if (IsCurrentLocked(scope) && Object.ReferenceEquals(credentials, expected))
                        {
                            AdvanceGenerationLocked();
                            credentials = null;
                            changed = true;
                            var safety = store as ISessionStoreSafetyFence;
                            if (safety != null)
                            {
                                try { Persist(() => safety.FenceActiveSession()); }
                                catch (ApiException) { /* The durable failure is reported below. */ }
                            }
                        }
                    }
                    if (changed) RaiseSessionChanged();
                }
                var queued = false;
                var revoked = false;
                try { Persist(() => store.EnqueueRevocation(saved)); queued = true; }
                catch (ApiException) { }
                if (!queued)
                {
                    // Even a failed durable commit must account for the newly issued token.
                    // A stale result may only revoke itself, never the replacement identity.
                    try { await RevokeKnownSessionAsync(saved, cancellationToken).ConfigureAwait(false); revoked = true; }
                    catch (Exception cleanupError) when (cleanupError is ApiException || cleanupError is OperationCanceledException) { }
                }
                if (queued && error.Code != "LOCAL_SESSION_STORAGE") throw;
                throw new ApiException(error.Code,
                    error.Code == "LOCAL_SESSION_STORAGE"
                        ? "服务器返回了新凭据，但本机未能完成会话保存；已清除本次内存会话。"
                            + (queued ? "新凭据已进入待注销队列。" : revoked ? "新凭据已在原服务器撤销。" : "新凭据撤销尚未确认。")
                            + "请联系管理员修复存储后重新登录。"
                        : "账号或服务器已变化，本次旧凭据没有进入新会话；其持久清理失败，请联系管理员核对。",
                    isSubmissionUnknown: !queued && !revoked);
            }
            RaiseSessionChanged();
        }

        private static bool ProfileFenceChanged(UserProfile before, UserProfile after)
        {
            return before.BusinessDatasetId != after.BusinessDatasetId
                || before.BusinessResetGeneration != after.BusinessResetGeneration
                || before.SuperAdmin != after.SuperAdmin || before.MustChangePassword != after.MustChangePassword
                || !before.Permissions.OrderBy(value => value, StringComparer.Ordinal)
                    .SequenceEqual(after.Permissions.OrderBy(value => value, StringComparer.Ordinal));
        }

        private void RejectCurrent(Scope scope, Credentials expected)
        {
            var changed = false;
            ApiException persistenceFailure = null;
            lock (gate)
            {
                if (!IsCurrentLocked(scope) || expected == null || !Object.ReferenceEquals(credentials, expected)) return;
                // A definitive disabled/replaced/rejected account must disappear from memory
                // and fence all in-flight readers even when the disk is unavailable.
                AdvanceGenerationLocked();
                credentials = null;
                changed = true;
                try { Persist(() => store.Clear()); }
                catch (ApiException error)
                {
                    persistenceFailure = error;
                    var safety = store as ISessionStoreSafetyFence;
                    if (safety != null)
                    {
                        try { Persist(() => safety.FenceActiveSession()); }
                        catch (ApiException) { }
                    }
                }
            }
            if (changed) RaiseSessionChanged();
            if (persistenceFailure != null) throw persistenceFailure;
        }

        private static bool IsDefinitiveRejection(ApiException error)
        {
            if (!error.HasResponseCode) return false;
            return (error.StatusCode == 401 && (error.Code == "UNAUTHORIZED" || error.Code == "ACCOUNT_LOCKED"
                || error.Code == "ACCOUNT_DISABLED" || error.Code == "SESSION_REPLACED"))
                || (error.StatusCode == 422 && error.Code == "VALIDATION_FAILED")
                || (error.StatusCode == 403 && (error.Code == "VISITOR_BLOCKED" || error.Code == "REMOTE_ACCESS_DENIED"));
        }

        private async Task<Reply> SendAsync(Scope scope, HttpMethod method, string path, object body, string bearer,
            CancellationToken cancellationToken, string rawBodyJson = null, MutationWirePermit mutationPermit = null)
        {
            RequireScope(scope);
            cancellationToken.ThrowIfCancellationRequested();
            var uri = scope.Endpoint.Resolve(path);
            var write = method != HttpMethod.Get;
            var submitted = false;
            using (var timeout = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken, scope.Cancellation))
            using (var request = new HttpRequestMessage(method, uri))
            {
                timeout.CancelAfter(configuration.RequestTimeout);
                request.Headers.Accept.Add(new MediaTypeWithQualityHeaderValue("application/json"));
                if (bearer != null) request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", bearer);
                if (rawBodyJson != null && mutationPermit == null)
                    throw new ApiException("MUTATION_ACTION_NOT_APPROVED", "原始业务提交必须经过审核的公共入口。");
                if (body != null || rawBodyJson != null)
                {
                    var json = rawBodyJson ?? JsonValue.Serialize(body);
                    if (Encoding.UTF8.GetByteCount(json) > 16384) throw new ApiException("REQUEST_TOO_LARGE", "提交内容超出限制。");
                    request.Content = new StringContent(json, Encoding.UTF8, "application/json");
                }
                if (mutationPermit != null) mutationPermit.Attach(request);
                try
                {
                    RequireScope(scope);
                    if (mutationPermit != null) mutationPermit.MarkDispatch();
                    submitted = true;
                    using (var response = await client.SendAsync(request, HttpCompletionOption.ResponseHeadersRead, timeout.Token).ConfigureAwait(false))
                    {
                        var status = (int)response.StatusCode;
                        if (status >= 300 && status <= 399)
                            throw new ApiException("REDIRECT_BLOCKED", "服务器返回了重定向，请管理员核对正式接口地址。", status, write);
                        if (response.RequestMessage?.RequestUri != null && response.RequestMessage.RequestUri != uri)
                            throw new ApiException("REDIRECT_BLOCKED", "接口响应离开了当前请求地址。", status, write);
                        var readScopeHeaders = ReadScopeHeaders.Capture(response);
                        if (response.Content == null) return new Reply(status, "", readScopeHeaders);
                        if (response.Content.Headers.ContentLength > configuration.MaxResponseBytes)
                            throw new ApiException("RESPONSE_TOO_LARGE", "服务器返回的内容超出读取上限。", status, write);
                        // A completed credential exchange can arrive after logout even when the handler
                        // ignores cancellation. Read its bounded body independently, then CAS/queue it;
                        // never discard a known newly-issued refresh token before parsing it.
                        var issuedCredentials = status >= 200 && status <= 299 && write
                            && (path == "auth/login" || path == "auth/refresh" || path == "auth/change-password");
                        using (var credentialBodyDeadline = new CancellationTokenSource())
                        using (var stream = await response.Content.ReadAsStreamAsync().ConfigureAwait(false))
                        using (var output = new MemoryStream())
                        {
                            credentialBodyDeadline.CancelAfter(TimeSpan.FromSeconds(Math.Min(5, configuration.RequestTimeout.TotalSeconds)));
                            var readCancellation = issuedCredentials ? credentialBodyDeadline.Token : timeout.Token;
                            var buffer = new byte[8192];
                            int read;
                            while ((read = await stream.ReadAsync(buffer, 0, buffer.Length, readCancellation).ConfigureAwait(false)) != 0)
                            {
                                if (output.Length + read > configuration.MaxResponseBytes)
                                    throw new ApiException("RESPONSE_TOO_LARGE", "服务器返回的内容超出读取上限。", status, write);
                                output.Write(buffer, 0, read);
                            }
                            return new Reply(status, new UTF8Encoding(false, true).GetString(output.ToArray()), readScopeHeaders);
                        }
                    }
                }
                catch (OperationCanceledException)
                {
                    RequireScope(scope);
                    if (write && submitted) throw SubmissionUnknown();
                    if (cancellationToken.IsCancellationRequested) throw;
                    throw new ApiException("NETWORK_TIMEOUT", "等待服务器响应超时，请检查网络后重试。");
                }
                catch (HttpRequestException error)
                {
                    RequireScope(scope);
                    if (IsTlsFailure(error))
                        throw new ApiException("TLS_VALIDATION_FAILED", "服务器证书验证失败，请核对公司连接配置和系统时间。");
                    if (write && submitted) throw SubmissionUnknown();
                    throw new ApiException("NETWORK", "无法连接服务器，请检查网络后重试。");
                }
                catch (IOException)
                {
                    RequireScope(scope);
                    if (write && submitted) throw SubmissionUnknown();
                    throw new ApiException("NETWORK", "读取服务器响应失败，请检查网络后重试。");
                }
                catch (DecoderFallbackException)
                { throw new ApiException("INVALID_RESPONSE", "服务器响应格式不正确。", isSubmissionUnknown: write); }
            }
        }

        private static bool IsTlsFailure(Exception error)
        {
            for (var current = error; current != null; current = current.InnerException)
            {
                var web = current as WebException;
                if (current is AuthenticationException || web?.Status == WebExceptionStatus.TrustFailure
                    || web?.Status == WebExceptionStatus.SecureChannelFailure) return true;
            }
            return false;
        }
        private static ApiException SubmissionUnknown()
        {
            return new ApiException("SUBMISSION_UNKNOWN", "操作已发送，但结果尚未确认。请先核对结果，不要重复提交。", isSubmissionUnknown: true);
        }
        private static AuthResult ParseIssuedCredentials(string text)
        {
            try { return AuthResult.Parse(text); }
            catch (ApiException) { throw new ApiException("INVALID_AUTH_RESPONSE", "认证结果无法确认，请重新核对账号状态后登录。", isSubmissionUnknown: true); }
        }
        private static void RequireSuccess(Reply response, bool write)
        {
            var error = ErrorFrom(response, write);
            if (error != null) throw error;
        }
        private static ApiException ErrorFrom(Reply response, bool write)
        {
            if (response.Status >= 200 && response.Status <= 299) return null;
            try
            {
                var root = JsonValue.ParseObject(response.Text);
                var code = JsonValue.RequiredString(root, "code", 80);
                var message = JsonValue.RequiredString(root, "message", 1000);
                if (!Regex.IsMatch(code, "^[A-Z][A-Z0-9_]*$")) throw new FormatException();
                var unknown = write && response.Status >= 500 && code != "AUTH_BUSY";
                return new ApiException(code, message, response.Status, unknown, true);
            }
            catch (Exception error) when (error is FormatException || error is ArgumentException || error is InvalidOperationException)
            {
                return new ApiException("HTTP_ERROR", "服务器暂时无法完成请求，请稍后核对。", response.Status,
                    write);
            }
        }

        private Scope CaptureLocked() { return new Scope(generation, endpoint, generationCancellation.Token, false); }
        private bool IsCurrentLocked(Scope scope)
        { return !disposed && (scope.Revocation || (generation == scope.Generation && endpoint?.ApiBaseUrl == scope.Endpoint.ApiBaseUrl)); }
        private void RequireScope(Scope scope) { lock (gate) RequireScopeLocked(scope); }
        private void RequireScopeLocked(Scope scope) { if (!IsCurrentLocked(scope)) throw SessionChangedError(); }
        private void AdvanceGenerationLocked()
        {
            generation++;
            stepUpGrant = null;
            readScopes.ResetIdentity();
            ResetReadCancellationLocked();
            var previous = generationCancellation;
            generationCancellation = new CancellationTokenSource();
            previous.Cancel();
            previous.Dispose();
        }
        private void RequireEndpoint()
        {
            RequireNotDisposed();
            if (endpoint == null) throw new ApiException("SERVER_NOT_CONFIGURED", "尚未配置公司服务器，请联系管理员提供正式连接配置。");
        }
        private void RequireAuthenticated()
        {
            RequireEndpoint();
            if (credentials?.User == null) throw new ApiException("UNAUTHORIZED", "请先登录。");
        }
        private void RequireNotDisposed() { if (disposed) throw new ObjectDisposedException(nameof(SessionCoordinator)); }
        private static ApiException SessionChangedError() { return new ApiException("SESSION_CHANGED", "登录账号或服务器已经变化，请重新打开当前页面。"); }
        private static T Persist<T>(Func<T> action)
        {
            try { return action(); }
            catch (Exception error) when (error is IOException || error is UnauthorizedAccessException
                || error is System.Security.Cryptography.CryptographicException || error is FormatException || error is ArgumentException)
            { throw new ApiException("LOCAL_SESSION_STORAGE", "本机会话保存或读取失败，请联系管理员核对当前用户的私有目录。"); }
        }
        private static void Persist(Action action) { Persist(() => { action(); return true; }); }
        private void RaiseSessionChanged()
        {
            var changed = SessionChanged;
            if (changed != null) changed(this, EventArgs.Empty);
        }
        public void Dispose()
        {
            lock (gate)
            {
                if (disposed) return;
                disposed = true;
                credentials = null;
                stepUpGrant = null;
                generationCancellation.Cancel();
                generationCancellation.Dispose();
                readCancellation.Cancel();
                readCancellation.Dispose();
            }
            client.Dispose();
            businessStateStore?.Dispose();
        }

        private sealed class Scope
        {
            internal readonly long Generation;
            internal readonly ServerEndpoint Endpoint;
            internal readonly CancellationToken Cancellation;
            internal readonly bool Revocation;
            internal Scope(long generation, ServerEndpoint endpoint, CancellationToken cancellation, bool revocation)
            { Generation = generation; Endpoint = endpoint; Cancellation = cancellation; Revocation = revocation; }
        }
        private sealed class Credentials
        {
            internal readonly string AccessToken;
            internal readonly StoredSession Stored;
            internal readonly UserProfile User;
            private readonly long issuedAt;
            private readonly int expiresIn;
            internal Credentials(AuthResult result, StoredSession stored)
            { AccessToken = result.AccessToken; Stored = stored; User = result.User; expiresIn = result.ExpiresIn; issuedAt = Stopwatch.GetTimestamp(); }
            internal Credentials(StoredSession stored) { Stored = stored; }
            internal bool NearExpiry { get { return AccessToken == null || (Stopwatch.GetTimestamp() - issuedAt) / (double)Stopwatch.Frequency >= Math.Max(0, expiresIn - 30); } }
        }
        private sealed class Reply
        {
            internal readonly int Status;
            internal readonly string Text;
            internal readonly ReadScopeHeaders ReadScope;
            internal Reply(int status, string text, ReadScopeHeaders readScope)
            { Status = status; Text = text; ReadScope = readScope; }
        }
    }
}
