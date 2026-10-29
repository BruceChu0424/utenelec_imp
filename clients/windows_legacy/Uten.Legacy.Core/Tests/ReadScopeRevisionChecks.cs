using System;
using System.Collections.Generic;
using System.Linq;
using System.Net;
using System.Net.Http;
using System.Text;
using System.Threading;
using System.Threading.Tasks;

namespace Uten.Legacy.Core.Tests
{
    /// <summary>Black-box read-scope checks using injected, in-memory HTTPS handlers and stores.</summary>
    public static class ReadScopeRevisionChecks
    {
        public static void Run()
        {
            FirstProofAndChangedProof().GetAwaiter().GetResult();
            OlderSequenceCannotRollBackProof().GetAwaiter().GetResult();
            HeaderBodyMismatchRetiresReaders().GetAwaiter().GetResult();
            NativeDomainsAreIndependent().GetAwaiter().GetResult();
            MasterAndReportDomainsAreIndependent().GetAwaiter().GetResult();
            IdentityChangesForgetProofsAndRejectOldResponses().GetAwaiter().GetResult();
            ReaderRetirementDoesNotCancelSharedRefresh().GetAwaiter().GetResult();
            ConcurrentScopeErrorsRetireOnce().GetAwaiter().GetResult();
            ForbiddenDoesNotRetireScope().GetAwaiter().GetResult();
        }

        private static async Task FirstProofAndChangedProof()
        {
            var proof = "goods-a";
            var sentBearer = new List<string>();
            const string originalBody = " { \"readScopeVersion\" : \"goods-a\", \"items\" : [1,2] } \n";
            using (var fixture = new Fixture((request, token) =>
            {
                sentBearer.Add(request.Headers.Authorization.Parameter);
                return Ready(proof == "goods-a" ? Proof(originalBody, proof) : ProofBody(proof));
            }))
            {
                await fixture.Login();
                var generation = fixture.Session.Generation;
                var revision = fixture.Session.ReadScopeRevision;
                var refresh = fixture.Store.Load().RefreshToken;
                var events = 0;
                fixture.Session.ReadScopeChanged += (sender, args) => events++;
                Equal(originalBody, await fixture.Session.GetAsync("master/goods/page", CancellationToken.None), "JSON is delivered unchanged");
                Equal(revision, fixture.Session.ReadScopeRevision, "first proof is accepted");
                proof = "goods-b";
                await Changed(() => fixture.Session.GetAsync("master/goods/page", CancellationToken.None));
                Equal(revision + 1, fixture.Session.ReadScopeRevision, "changed proof retires readers");
                Equal(1, events, "one read-scope event");
                await fixture.Session.GetAsync("master/goods/page", CancellationToken.None);
                Equal(revision + 1, fixture.Session.ReadScopeRevision, "new proof remains established");
                Equal(generation, fixture.Session.Generation, "read proof does not alter authentication generation");
                Equal(refresh, fixture.Store.Load().RefreshToken, "read proof does not rotate login token");
                True(sentBearer.All(value => value == fixture.LastLoginAccess), "all reads retain the login bearer");
                True(fixture.Session.IsAuthenticated, "authentication survives read retirement");
                NoAutomaticAuthenticationOrWrite(fixture);
            }
        }

        private static async Task OlderSequenceCannotRollBackProof()
        {
            foreach (var primeFirst in new[] { false, true })
            {
                var slowEntered = Signal();
                var slowResponse = new TaskCompletionSource<HttpResponseMessage>(TaskCreationOptions.RunContinuationsAsynchronously);
                var proof = "version-a";
                using (var fixture = new Fixture((request, token) =>
                {
                    if (request.RequestUri.Query == "?slow=1")
                    { slowEntered.TrySetResult(true); return slowResponse.Task; }
                    return Ready(ProofBody(proof));
                }))
                {
                    await fixture.Login();
                    var revision = fixture.Session.ReadScopeRevision;
                    var generation = fixture.Session.Generation;
                    var events = 0;
                    fixture.Session.ReadScopeChanged += (sender, args) => events++;
                    if (primeFirst) await fixture.Session.GetAsync("master/goods", CancellationToken.None);
                    var earlier = fixture.Session.GetAsync("master/goods?slow=1", CancellationToken.None);
                    await WaitFor(slowEntered.Task, "earlier request entered");
                    proof = "version-b";
                    if (primeFirst) await Changed(() => fixture.Session.GetAsync("master/goods?new=1", CancellationToken.None));
                    else await fixture.Session.GetAsync("master/goods?new=1", CancellationToken.None);
                    slowResponse.SetResult(ProofBody("version-a"));
                    await Changed(() => earlier);
                    var expectedRetirements = primeFirst ? 1 : 0;
                    Equal(revision + expectedRetirements, fixture.Session.ReadScopeRevision, "late older sequence cannot retire a newer proof");
                    await fixture.Session.GetAsync("master/goods?confirm=1", CancellationToken.None);
                    Equal(revision + expectedRetirements, fixture.Session.ReadScopeRevision, "late response cannot overwrite or roll back the cached proof");
                    Equal(expectedRetirements, events, "late sequence does not emit an extra event");
                    Equal(generation, fixture.Session.Generation, "out-of-order reads leave authentication generation alone");
                    NoAutomaticAuthenticationOrWrite(fixture);
                }
            }
        }

        private static async Task HeaderBodyMismatchRetiresReaders()
        {
            var mismatch = false;
            using (var fixture = new Fixture((request, token) => Ready(mismatch
                ? Proof("{\"readScopeVersion\":\"body-proof\",\"items\":[]}", "header-proof")
                : ProofBody("original-proof"))))
            {
                await fixture.Login();
                await fixture.Session.GetAsync("master/clients/page", CancellationToken.None);
                var revision = fixture.Session.ReadScopeRevision;
                var generation = fixture.Session.Generation;
                var events = 0;
                fixture.Session.ReadScopeChanged += (sender, args) => events++;
                mismatch = true;
                await Changed(() => fixture.Session.GetAsync("master/clients/page", CancellationToken.None));
                Equal(revision + 1, fixture.Session.ReadScopeRevision, "header/body mismatch retires readers");
                Equal(1, events, "header/body mismatch retires once");
                Equal(generation, fixture.Session.Generation, "mismatched proof does not alter auth generation");
                mismatch = false;
                await fixture.Session.GetAsync("master/clients/page", CancellationToken.None);
                Equal(revision + 1, fixture.Session.ReadScopeRevision, "mismatched proof never overwrites established proof");
                NoAutomaticAuthenticationOrWrite(fixture);
            }
            // A body-only proof is an equally valid first observation.
            var bodyProof = "body-a";
            using (var fixture = new Fixture((request, token) => Ready(Json("{\"readScopeVersion\":\"" + bodyProof + "\",\"items\":[]}"))))
            {
                await fixture.Login();
                var revision = fixture.Session.ReadScopeRevision;
                await fixture.Session.GetAsync("master/suppliers", CancellationToken.None);
                bodyProof = "body-b";
                await Changed(() => fixture.Session.GetAsync("master/suppliers", CancellationToken.None));
                Equal(revision + 1, fixture.Session.ReadScopeRevision, "body-only proof changes are observed");
            }
        }

        private static async Task NativeDomainsAreIndependent()
        {
            var prefixes = new[] { "sales_owner", "purchase_owner", "subcontract_owner", "production_owner",
                "fqc_records", "workshop_tasks", "warehouse_tasks", "feature" };
            var domains = prefixes.SelectMany(prefix => new[] { "native_" + prefix + ":task", "native_" + prefix + ":browse" }).ToArray();
            var versions = domains.Select((domain, index) => "native-proof-" + index).ToArray();
            var selected = 0;
            var invalidDomain = false;
            using (var fixture = new Fixture((request, token) => Ready(ProofBody(versions[selected],
                invalidDomain ? "native_sales_owner:admin" : domains[selected]))))
            {
                await fixture.Login();
                var revision = fixture.Session.ReadScopeRevision;
                var events = 0;
                fixture.Session.ReadScopeChanged += (sender, args) => events++;
                for (selected = 0; selected < domains.Length; selected++)
                    await fixture.Session.GetAsync("master/goods/page", CancellationToken.None);
                Equal(revision, fixture.Session.ReadScopeRevision, "each known native task/browse domain has its own proof");
                selected = 0;
                versions[0] = "native-task-new";
                await Changed(() => fixture.Session.GetAsync("master/goods/page", CancellationToken.None));
                for (selected = 0; selected < domains.Length; selected++)
                    await fixture.Session.GetAsync("master/goods/page", CancellationToken.None);
                Equal(revision + 1, fixture.Session.ReadScopeRevision, "native task proof cannot overwrite browse or other native domains");
                Equal(1, events, "one native domain change");
                selected = 0;
                invalidDomain = true;
                await Changed(() => fixture.Session.GetAsync("master/goods/page", CancellationToken.None));
                Equal(revision + 1, fixture.Session.ReadScopeRevision, "unrecognized native domain cannot establish or retire another domain");
                Equal(1, events, "invalid native domain does not retire a different proof");
                NoAutomaticAuthenticationOrWrite(fixture);
            }
        }

        private static async Task MasterAndReportDomainsAreIndependent()
        {
            var primary = new[] { "master/clients", "master/suppliers", "master/goods", "master/accounts", "master/currencies",
                "master/colors", "master/units", "master/moulds", "master/warehouses", "sales/reports/summary",
                "purchase/reports/summary", "subcontract/reports/summary", "production/reports/summary", "stock/reports/summary",
                "finance/reports/summary", "master/reference-methods/settlement-admin" };
            var alias = primary.Select(path => path.EndsWith("/summary", StringComparison.Ordinal)
                ? path.Substring(0, path.Length - "summary".Length) + "details" : path + "/page").ToArray();
            var versions = new Dictionary<string, string>(StringComparer.Ordinal);
            for (var index = 0; index < primary.Length; index++)
            { versions["/api/" + primary[index]] = "proof-" + index; versions["/api/" + alias[index]] = "proof-" + index; }
            using (var fixture = new Fixture((request, token) => Ready(ProofBody(versions[request.RequestUri.AbsolutePath]))))
            {
                await fixture.Login();
                var revision = fixture.Session.ReadScopeRevision;
                var events = 0;
                fixture.Session.ReadScopeChanged += (sender, args) => events++;
                for (var index = 0; index < primary.Length; index++)
                {
                    await fixture.Session.GetAsync(primary[index], CancellationToken.None);
                    await fixture.Session.GetAsync(alias[index], CancellationToken.None);
                }
                Equal(revision, fixture.Session.ReadScopeRevision, "master entities, report modules and settlement methods are independent");
                var retired = 0;
                foreach (var changedIndex in new[] { 0, 9, 15 })
                {
                    versions["/api/" + primary[changedIndex]] = "changed-" + changedIndex;
                    versions["/api/" + alias[changedIndex]] = "changed-" + changedIndex;
                    await Changed(() => fixture.Session.GetAsync(alias[changedIndex], CancellationToken.None));
                    retired++;
                    foreach (var path in primary) await fixture.Session.GetAsync(path, CancellationToken.None);
                    Equal(revision + retired, fixture.Session.ReadScopeRevision, "aliases observe the same domain without contaminating independent domains");
                }
                Equal(3, events, "master/report/settlement changes each retire once");
                NoAutomaticAuthenticationOrWrite(fixture);
            }
        }

        private static async Task IdentityChangesForgetProofsAndRejectOldResponses()
        {
            foreach (var switchEndpoint in new[] { false, true })
            {
                var slowEntered = Signal();
                var slowResponse = new TaskCompletionSource<HttpResponseMessage>(TaskCreationOptions.RunContinuationsAsynchronously);
                var proof = "identity-a";
                string lastHost = null;
                string lastBearer = null;
                using (var fixture = new Fixture((request, token) =>
                {
                    lastHost = request.RequestUri.Host;
                    lastBearer = request.Headers.Authorization.Parameter;
                    if (request.RequestUri.Query == "?old=1")
                    { slowEntered.TrySetResult(true); return slowResponse.Task; }
                    return Ready(ProofBody(proof));
                }))
                {
                    await fixture.Login();
                    await fixture.Session.GetAsync("master/goods", CancellationToken.None);
                    var oldRead = fixture.Session.GetAsync("master/goods?old=1", CancellationToken.None);
                    await WaitFor(slowEntered.Task, "old identity request entered");
                    if (switchEndpoint) fixture.Session.SelectEndpoint("cloud");
                    else { fixture.UserId = "user-2"; fixture.Account = "UT0002"; }
                    await fixture.Login();
                    proof = "identity-b";
                    var revision = fixture.Session.ReadScopeRevision;
                    var events = 0;
                    fixture.Session.ReadScopeChanged += (sender, args) => events++;
                    await fixture.Session.GetAsync("master/goods", CancellationToken.None);
                    Equal(revision, fixture.Session.ReadScopeRevision, "new account/origin has no inherited proof");
                    slowResponse.SetResult(ProofBody("old-origin-late-proof"));
                    await RejectedOldIdentity(() => oldRead);
                    await fixture.Session.GetAsync("master/goods", CancellationToken.None);
                    Equal(revision, fixture.Session.ReadScopeRevision, "old identity response cannot seed or roll back replacement identity proof");
                    Equal(0, events, "old identity response never retires replacement reader");
                    Equal(switchEndpoint ? "cloud.example.test" : "company.example.test", lastHost, "reads retain current issuer");
                    Equal(fixture.LastLoginAccess, lastBearer, "reads retain replacement account bearer");
                    Equal(fixture.UserId, fixture.Store.Load().UserId, "replacement identity remains persisted");
                    Equal(0, fixture.RefreshCalls, "identity proof changes do not cause refresh");
                    Equal(0, fixture.BusinessWriteCalls, "identity changes do not replay business writes");
                }
            }
        }

        private static async Task ReaderRetirementDoesNotCancelSharedRefresh()
        {
            var refreshEntered = Signal();
            var secondOldReadEntered = Signal();
            var refreshResponse = new TaskCompletionSource<HttpResponseMessage>(TaskCreationOptions.RunContinuationsAsynchronously);
            var refreshToken = CancellationToken.None;
            var refreshCancelled = 0;
            var proof = "refresh-proof-a";
            string bearerAfterRefresh = null;
            using (var view = new CancellationTokenSource())
            using (var fixture = new Fixture((request, token) =>
            {
                if (request.RequestUri.AbsolutePath.EndsWith("/refresh", StringComparison.Ordinal))
                {
                    refreshToken = token;
                    token.Register(() => Interlocked.Increment(ref refreshCancelled));
                    refreshEntered.TrySetResult(true);
                    return refreshResponse.Task;
                }
                var bearer = request.Headers.Authorization.Parameter;
                if (request.RequestUri.Query.StartsWith("?old=", StringComparison.Ordinal) && bearer != "access-refreshed")
                {
                    if (request.RequestUri.Query == "?old=2") secondOldReadEntered.TrySetResult(true);
                    return Ready(Unauthorized());
                }
                if (bearer == "access-refreshed") bearerAfterRefresh = bearer;
                return Ready(ProofBody(proof));
            }))
            {
                await fixture.Login();
                await fixture.Session.GetAsync("master/goods", CancellationToken.None);
                var revision = fixture.Session.ReadScopeRevision;
                var generation = fixture.Session.Generation;
                var events = 0;
                fixture.Session.ReadScopeChanged += (sender, args) => { events++; view.Cancel(); };
                var firstOldRead = fixture.Session.GetAsync("master/goods?old=1", view.Token);
                await WaitFor(refreshEntered.Task, "single-flight refresh entered");
                var secondOldRead = fixture.Session.GetAsync("master/goods?old=2", view.Token);
                await WaitFor(secondOldReadEntered.Task, "second reader joins refresh");
                proof = "refresh-proof-b";
                await Changed(() => fixture.Session.GetAsync("master/goods?change=1", CancellationToken.None));
                True(view.IsCancellationRequested, "retiring UI disposes its caller token");
                True(!refreshToken.IsCancellationRequested && Volatile.Read(ref refreshCancelled) == 0,
                    "read retirement and caller cancellation cannot cancel a shared authentication refresh");
                Equal(1, fixture.RefreshCalls, "readers share one refresh");
                refreshResponse.SetResult(Json(Token("access-refreshed", "refresh-refreshed", "user-1", "UT0001")));
                await RejectedRetiredReader(() => firstOldRead);
                await RejectedRetiredReader(() => secondOldRead);
                await fixture.Session.GetAsync("master/goods?after=1", CancellationToken.None);
                Equal("refresh-refreshed", fixture.Store.Load().RefreshToken, "successful shared refresh is durably retained");
                Equal("access-refreshed", bearerAfterRefresh, "new view uses the committed refreshed bearer");
                True(fixture.Session.IsAuthenticated, "refresh leaves authentication active");
                Equal(generation, fixture.Session.Generation, "read retirement does not alter refresh authentication generation");
                Equal(revision + 1, fixture.Session.ReadScopeRevision, "refresh does not replay or undo read retirement");
                Equal(1, events, "scope transition emitted once while refresh was pending");
                Equal(1, fixture.LoginCalls, "scope retirement never automatically logs in");
                Equal(0, fixture.LogoutCalls, "scope retirement does not revoke a valid refreshed token");
                Equal(0, fixture.BusinessWriteCalls, "scope retirement never replays business writes");
            }
        }

        private static async Task ConcurrentScopeErrorsRetireOnce()
        {
            var firstEntered = Signal();
            var secondEntered = Signal();
            var firstResponse = new TaskCompletionSource<HttpResponseMessage>(TaskCreationOptions.RunContinuationsAsynchronously);
            var secondResponse = new TaskCompletionSource<HttpResponseMessage>(TaskCreationOptions.RunContinuationsAsynchronously);
            using (var fixture = new Fixture((request, token) =>
            {
                if (request.RequestUri.Query == "?error=1") { firstEntered.TrySetResult(true); return firstResponse.Task; }
                if (request.RequestUri.Query == "?error=2") { secondEntered.TrySetResult(true); return secondResponse.Task; }
                return Ready(ProofBody("error-proof-a"));
            }))
            {
                await fixture.Login();
                await fixture.Session.GetAsync("master/goods", CancellationToken.None);
                var revision = fixture.Session.ReadScopeRevision;
                var generation = fixture.Session.Generation;
                var refresh = fixture.Store.Load().RefreshToken;
                var events = 0;
                fixture.Session.ReadScopeChanged += (sender, args) => events++;
                var first = fixture.Session.GetAsync("master/goods?error=1", CancellationToken.None);
                await WaitFor(firstEntered.Task, "first scope error entered");
                var second = fixture.Session.GetAsync("master/goods?error=2", CancellationToken.None);
                await WaitFor(secondEntered.Task, "second scope error entered");
                firstResponse.SetResult(ScopeChanged());
                await Changed(() => first);
                secondResponse.SetResult(ScopeChanged());
                await Changed(() => second);
                Equal(revision + 1, fixture.Session.ReadScopeRevision, "server scope errors retire captured revision once");
                Equal(1, events, "concurrent scope errors emit one event");
                Equal(generation, fixture.Session.Generation, "scope error keeps auth generation");
                Equal(refresh, fixture.Store.Load().RefreshToken, "scope error keeps persisted login");
                await fixture.Session.GetAsync("master/goods", CancellationToken.None);
                Equal(revision + 1, fixture.Session.ReadScopeRevision, "server scope errors do not overwrite proof cache");
                NoAutomaticAuthenticationOrWrite(fixture);
            }
        }

        private static async Task ForbiddenDoesNotRetireScope()
        {
            using (var fixture = new Fixture((request, token) => Ready(Json("{\"code\":\"FORBIDDEN\",\"message\":\"fixture forbidden\"}", HttpStatusCode.Forbidden))))
            {
                await fixture.Login();
                var revision = fixture.Session.ReadScopeRevision;
                var generation = fixture.Session.Generation;
                var events = 0;
                fixture.Session.ReadScopeChanged += (sender, args) => events++;
                var error = await ThrowsApi(() => fixture.Session.GetAsync("master/goods", CancellationToken.None));
                Equal("FORBIDDEN", error.Code, "ordinary forbidden response is preserved");
                Equal(revision, fixture.Session.ReadScopeRevision, "ordinary forbidden is local to its view");
                Equal(0, events, "ordinary forbidden does not retire global read scope");
                Equal(generation, fixture.Session.Generation, "ordinary forbidden does not retire authentication");
                True(fixture.Session.IsAuthenticated, "ordinary forbidden leaves login active");
                NoAutomaticAuthenticationOrWrite(fixture);
            }
        }

        private static TaskCompletionSource<bool> Signal()
        { return new TaskCompletionSource<bool>(TaskCreationOptions.RunContinuationsAsynchronously); }
        private static Task<HttpResponseMessage> Ready(HttpResponseMessage response) { return Task.FromResult(response); }
        private static async Task WaitFor(Task task, string message)
        {
            if (await Task.WhenAny(task, Task.Delay(TimeSpan.FromSeconds(5))).ConfigureAwait(false) != task)
                throw new InvalidOperationException("Read-scope check timed out: " + message);
            await task.ConfigureAwait(false);
        }
        private static async Task<ApiException> ThrowsApi(Func<Task> action)
        {
            try { await WaitFor(action(), "expected API rejection").ConfigureAwait(false); }
            catch (ApiException error) { return error; }
            throw new InvalidOperationException("Read-scope check expected an API rejection.");
        }
        private static async Task Changed(Func<Task> action)
        {
            var error = await ThrowsApi(action).ConfigureAwait(false);
            Equal("READ_SCOPE_CHANGED", error.Code, "retired reader error code");
            Equal((int?)403, error.StatusCode, "retired reader status");
        }
        private static async Task RejectedOldIdentity(Func<Task> action)
        {
            var error = await ThrowsApi(action).ConfigureAwait(false);
            True(error.Code == "SESSION_CHANGED" || error.Code == "READ_SCOPE_CHANGED", "old identity cannot deliver data");
        }
        private static async Task RejectedRetiredReader(Func<Task> action)
        {
            try { await WaitFor(action(), "retired reader completion").ConfigureAwait(false); }
            catch (OperationCanceledException) { return; }
            catch (ApiException error)
            {
                Equal("READ_SCOPE_CHANGED", error.Code, "cancelled old reader is scope fenced");
                return;
            }
            throw new InvalidOperationException("Read-scope check delivered an obsolete reader.");
        }
        private static HttpResponseMessage ProofBody(string version, string domain = null)
        { return Proof("{\"readScopeVersion\":\"" + version + "\",\"items\":[]}", version, domain); }
        private static HttpResponseMessage Proof(string body, string version, string domain = null)
        {
            var response = Json(body);
            response.Headers.Add("X-Uten-Read-Scope-Version", version);
            if (domain != null) response.Headers.Add("X-Uten-Read-Scope-Domain", domain);
            return response;
        }
        private static HttpResponseMessage Json(string body, HttpStatusCode status = HttpStatusCode.OK)
        { return new HttpResponseMessage(status) { Content = new StringContent(body, Encoding.UTF8, "application/json") }; }
        private static HttpResponseMessage Unauthorized()
        { return Json("{\"code\":\"UNAUTHORIZED\",\"message\":\"fixture expired\"}", HttpStatusCode.Unauthorized); }
        private static HttpResponseMessage ScopeChanged()
        { return Json("{\"code\":\"READ_SCOPE_CHANGED\",\"message\":\"fixture scope changed\"}", HttpStatusCode.Forbidden); }
        private static string Token(string access, string refresh, string userId, string account)
        {
            return "{\"accessToken\":\"" + access + "\",\"refreshToken\":\"" + refresh + "\",\"expiresIn\":900,\"mustChangePassword\":false,"
                + "\"user\":{\"id\":\"" + userId + "\",\"loginAccount\":\"" + account + "\",\"name\":\"fixture user\",\"superAdmin\":false,"
                + "\"mustChangePassword\":false,\"permissions\":[\"goods:view\"],\"businessResetGeneration\":0,"
                + "\"businessDatasetId\":\"11111111-1111-1111-1111-111111111111\"}}";
        }
        private static void NoAutomaticAuthenticationOrWrite(Fixture fixture)
        {
            Equal(1, fixture.LoginCalls, "read-scope changes never automatically log in");
            Equal(0, fixture.RefreshCalls, "read-scope changes never request a token refresh");
            Equal(0, fixture.LogoutCalls, "read-scope changes never log out");
            Equal(0, fixture.BusinessWriteCalls, "read-scope changes never send business writes");
        }
        private static void True(bool value, string message)
        { if (!value) throw new InvalidOperationException("Read-scope contract: " + message); }
        private static void Equal<T>(T expected, T actual, string message)
        { True(EqualityComparer<T>.Default.Equals(expected, actual), message); }

        private sealed class Fixture : IDisposable
        {
            internal readonly MemoryStore Store = new MemoryStore();
            internal readonly SessionCoordinator Session;
            internal string UserId = "user-1";
            internal string Account = "UT0001";
            internal string LastLoginAccess;
            internal int LoginCalls;
            internal int LogoutCalls;
            internal int RefreshCalls;
            internal int BusinessWriteCalls;
            internal Fixture(Func<HttpRequestMessage, CancellationToken, Task<HttpResponseMessage>> action)
            {
                var configuration = new ClientConfiguration(new[] {
                    new ServerEndpoint("company", "fixture company", "https://company.example.test/api"),
                    new ServerEndpoint("cloud", "fixture cloud", "https://cloud.example.test/api") }, "company", 5, 2097152);
                Session = new SessionCoordinator(configuration, new Handler((request, token) =>
                {
                    True(request.RequestUri.Scheme == Uri.UriSchemeHttps && request.RequestUri.Host.EndsWith(".example.test", StringComparison.Ordinal),
                        "only fake HTTPS issuers are used");
                    var path = request.RequestUri.AbsolutePath;
                    if (path == "/api/auth/login")
                    {
                        var index = Interlocked.Increment(ref LoginCalls);
                        LastLoginAccess = "access-" + UserId + "-" + index;
                        return Ready(Json(Token(LastLoginAccess, "refresh-" + UserId + "-" + index, UserId, Account)));
                    }
                    if (path == "/api/auth/logout")
                    { Interlocked.Increment(ref LogoutCalls); return Ready(Json(String.Empty, HttpStatusCode.NoContent)); }
                    if (path == "/api/auth/refresh") Interlocked.Increment(ref RefreshCalls);
                    else if (request.Method != HttpMethod.Get) Interlocked.Increment(ref BusinessWriteCalls);
                    return action(request, token);
                }), Store);
            }
            internal Task Login() { return Session.LoginAsync(Account, "fixture-password", null, CancellationToken.None); }
            public void Dispose() { Session.Dispose(); }
        }
        private sealed class Handler : HttpMessageHandler
        {
            private readonly Func<HttpRequestMessage, CancellationToken, Task<HttpResponseMessage>> action;
            internal Handler(Func<HttpRequestMessage, CancellationToken, Task<HttpResponseMessage>> action) { this.action = action; }
            protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken)
            { return action(request, cancellationToken); }
        }
        private sealed class MemoryStore : ISessionStore
        {
            private readonly object gate = new object();
            private StoredSession active;
            private readonly List<StoredSession> pending = new List<StoredSession>();
            public StoredSession Load() { lock (gate) return active; }
            public void Save(StoredSession session) { lock (gate) active = session; }
            public void Clear() { lock (gate) active = null; }
            public void EndSession(StoredSession session)
            { lock (gate) { EnqueueRevocation(session ?? active); active = null; } }
            public void EnqueueRevocation(StoredSession session)
            { lock (gate) if (session != null && !pending.Any(value => value.Id == session.Id)) pending.Add(session); }
            public IList<StoredSession> PendingRevocations() { lock (gate) return pending.ToList(); }
            public void AcknowledgeRevocation(string id) { lock (gate) pending.RemoveAll(value => value.Id == id); }
        }
    }
}
