using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Net;
using System.Net.Http;
using System.Threading;
using System.Threading.Tasks;

namespace Uten.Legacy.Core.Tests
{
    /// <summary>Offline checks; failures throw. No framework, real server, or certificate store is used.</summary>
    public static class CoreContractChecks
    {
        public static void Run()
        {
            CompanyCertificatePolicy.FromEmbeddedCertificate();
            UserErrorMessageChecks.Run();
            MutationContractChecks.Run();
            UnitCommandContractChecks.Run();
            UnitHistoryMutationChecks.Run();
            UnitExportDownloadChecks.Run();
            UnitExportMutationChecks.Run();
            ReadAndReviewLeaseChecks.Run();
            UnitProjectionChecks.Run();
            UnitPlatformMutationChecks.Run();
            BusinessStateContractChecks.Run();
            ClientPackageDownloadChecks.Run();
            ReadScopeRevisionChecks.Run();
            ManagedHttp11Checks.Run();
            ManagedTlsChecks.Run();
            PublishUploadSinkChecks.Run();
            ConfigurationAndPathBounds();
            RunSessionLifecycle();
            ConcurrentRefreshIsSingleFlight().GetAwaiter().GetResult();
            LogoutFencesPendingRefresh().GetAwaiter().GetResult();
            EndpointSwitchFencesPendingLogin().GetAwaiter().GetResult();
            RefreshOutageKeepsSession().GetAwaiter().GetResult();
            WritesAreNotReplayed().GetAwaiter().GetResult();
            RunClientReleasePublishCommands();
            RedirectAndReadBounds().GetAwaiter().GetResult();
            DurableLogoutRetainsIssuer().GetAwaiter().GetResult();
            DefinitiveRejectionFailsClosedWhenStorageFails().GetAwaiter().GetResult();
            LogoutStorageFailureStillRevokesAtIssuer().GetAwaiter().GetResult();
            FailedCredentialCommitIsFencedAndRevocable().GetAwaiter().GetResult();
            PermissionAndDatasetChangesFenceReads().GetAwaiter().GetResult();
            DpapiEnvelopeContainsOnlyOwnedCredentials();
        }

        public static void RunSessionLifecycle()
        {
            ApplicationStartupRetiresPreviousRun().GetAwaiter().GetResult();
            LateLogoutDoesNotClearNewLogin().GetAwaiter().GetResult();
            SessionWatchRetiresOnlyItsOwner().GetAwaiter().GetResult();
            LateAndCancelledWatchCannotRetireNewLogin().GetAwaiter().GetResult();
            AutomaticWatchRefreshDoesNotRenewActivity().GetAwaiter().GetResult();
            WatchRetainsDispatchedMutationAndDraft().GetAwaiter().GetResult();
        }

        private static async Task WatchRetainsDispatchedMutationAndDraft()
        {
            const string body = " {\"name\":\"  原始单位输入  \"} ";
            var entered = new TaskCompletionSource<bool>(); var reply = new TaskCompletionSource<HttpResponseMessage>();
            int writes = 0; bool nextAccount = false;
            using (var state = new BusinessStateTestFixture())
            using (var session = new SessionCoordinator(Configuration(), new Handler((request, ct) =>
            {
                var path = request.RequestUri.AbsolutePath;
                if (path.EndsWith("/login")) return Task.FromResult(Json(Token("mutation-access", "mutation-refresh")
                    .Replace("goods:view", "unit:view\",\"unit:create").Replace("user-1", nextAccount ? "user-2" : "user-1")));
                if (path.EndsWith("/logout")) return Task.FromResult(Json("", HttpStatusCode.NoContent));
                if (path.EndsWith("/session/watch")) return Task.FromResult(Json("{\"status\":\"replaced\",\"code\":\"SESSION_REPLACED\",\"message\":\"fixture replacement\"}"));
                writes++; entered.TrySetResult(true); return reply.Task;
            }), new MemoryStore(), state.Store))
            {
                await session.LoginAsync("UT0001", "test-password", CancellationToken.None);
                var owner = session.CaptureMutationOwner(); var id = Guid.NewGuid().ToString("D");
                var lease = session.CreateDraftLease(MutationAction.UnitCreate, Guid.NewGuid().ToString("D"), owner);
                var draft = await session.SaveDraftAsync(lease, 0, body, CancellationToken.None);
                var command = await session.PrepareMutationFromDraftAsync(id, draft.DraftId, draft.Revision, owner, CancellationToken.None);
                var sending = session.MutateAsync(command, CancellationToken.None); await entered.Task;
                await session.WatchSessionAsync(CancellationToken.None);
                reply.SetResult(Json("{}")); var result = await sending;
                Equal(MutationOutcome.Unknown, result.Outcome, "watch after dispatch cannot invent a failed or successful write");
                var journal = state.Store.ListJournal(owner).Single();
                True(journal.State == MutationJournalState.Unknown && journal.RequestId == id && journal.BodyJson == body,
                    "watch retirement retains the original durable request ID and raw body");
                Equal(body, state.Store.ListDrafts(owner).Single().BodyJson, "watch retains the last original-owner draft");
                nextAccount = true; await session.LoginAsync("UT0002", "test-password", CancellationToken.None);
                var next = session.CaptureMutationOwner();
                True(state.Store.ListJournal(next).Count == 0 && state.Store.ListDrafts(next).Count == 0 && writes == 1,
                    "a new account neither receives nor replays the original unknown submission");
            }
        }

        private static async Task SessionWatchRetiresOnlyItsOwner()
        {
            var requests = 0;
            var ended = new List<SessionEndedEventArgs>();
            var store = new MemoryStore();
            using (var session = new SessionCoordinator(Configuration(), new Handler((request, ct) =>
            {
                if (request.RequestUri.AbsolutePath.EndsWith("/login")) return Task.FromResult(Json(Token("watch-access", "watch-refresh")));
                Equal("/api/auth/session/watch", request.RequestUri.AbsolutePath, "replacement is observed without a business refresh");
                Equal("1", request.Headers.GetValues("X-Uten-Automatic").Single(), "watch does not count as human activity");
                Equal("watch-access", request.Headers.Authorization.Parameter, "watch uses the staff bearer");
                Equal(TimeSpan.FromSeconds(35), SessionWatchContract.ForRequest(request, TimeSpan.FromSeconds(5)), "watch receives a bounded long-poll budget");
                requests++;
                return Task.FromResult(Json(requests == 1 ? "{\"status\":\"active\",\"code\":null,\"message\":null}"
                    : "{\"status\":\"replaced\",\"code\":\"SESSION_REPLACED\",\"message\":\"账号已在 Android 登录，本设备已自动下线\"}"));
            }), store))
            {
                var changed = 0;
                session.SessionChanged += (sender, value) => { throw new InvalidOperationException("fixture failing changed listener"); };
                session.SessionChanged += (sender, value) => changed++;
                session.SessionEnded += (sender, value) => { throw new InvalidOperationException("fixture failing ended listener"); };
                session.SessionEnded += (sender, value) => ended.Add(value);
                await session.LoginAsync("UT0001", "test-password", CancellationToken.None);
                var generation = session.Generation;
                True(await session.WatchSessionAsync(CancellationToken.None) == null && session.IsAuthenticated, "active watch preserves current login");
                var notice = await session.WatchSessionAsync(CancellationToken.None);
                True(!session.IsAuthenticated && store.Load() == null && generation < session.Generation, "replacement retires the active login immediately");
                Equal("SESSION_REPLACED", notice.Code, "replacement is distinct from expiry");
                Equal(1, ended.Count, "one authoritative termination event");
                True(changed > 1, "a failing subscriber cannot suppress subsequent session notifications");
                Equal(session.Generation, ended[0].RetiredGeneration, "termination notice is fenced to the retired generation");
                True(ended[0].Reason.UserMessage.Contains("Android"), "replacement preserves the server's device explanation");
            }
        }

        private static async Task LateAndCancelledWatchCannotRetireNewLogin()
        {
            foreach (var newLogin in new[] { false, true })
            {
                var reply = new TaskCompletionSource<HttpResponseMessage>();
                var ended = 0;
                using (var cancellation = new CancellationTokenSource())
                using (var session = new SessionCoordinator(Configuration(), new Handler((request, ct) =>
                {
                    if (request.RequestUri.AbsolutePath.EndsWith("/login")) return Task.FromResult(Json(Token("next-access", "next-refresh")));
                    if (request.RequestUri.AbsolutePath.EndsWith("/logout")) return Task.FromResult(Json("", HttpStatusCode.NoContent));
                    return reply.Task; // Deliberately ignore cancellation and return an old result.
                }), new MemoryStore()))
                {
                    session.SessionEnded += (sender, value) => ended++;
                    await session.LoginAsync("UT0001", "test-password", CancellationToken.None);
                    var pending = session.WatchSessionAsync(cancellation.Token);
                    if (newLogin) await session.LoginAsync("UT0001", "test-password", CancellationToken.None);
                    else cancellation.Cancel();
                    reply.SetResult(Json("{\"status\":\"replaced\",\"code\":\"SESSION_REPLACED\",\"message\":\"旧会话已下线\"}"));
                    if (newLogin) Equal("SESSION_CHANGED", (await ThrowsAsync<ApiException>(() => pending)).Code, "late watch cannot target a new same-account login");
                    else await ThrowsAsync<OperationCanceledException>(() => pending);
                    True(session.IsAuthenticated && ended == 0, "retired/cancelled watcher cannot clear or notify another owner");
                }
            }
        }

        private static async Task AutomaticWatchRefreshDoesNotRenewActivity()
        {
            var watches = 0;
            var refreshes = 0;
            using (var session = new SessionCoordinator(Configuration(), new Handler((request, ct) =>
            {
                var path = request.RequestUri.AbsolutePath;
                if (path.EndsWith("/login")) return Task.FromResult(Json(Token("old-access", "old-refresh")));
                Equal("1", request.Headers.GetValues("X-Uten-Automatic").Single(), "automatic watch and its refresh never renew human activity");
                if (path.EndsWith("/refresh")) { refreshes++; return Task.FromResult(Json(Token("fresh-access", "fresh-refresh"))); }
                if (path.EndsWith("/me")) return Task.FromResult(Json("{}"));
                watches++;
                return Task.FromResult(watches == 1 ? Unauthorized() : Json("{\"status\":\"active\"}"));
            }), new MemoryStore()))
            {
                await session.LoginAsync("UT0001", "test-password", CancellationToken.None);
                await session.WatchSessionAsync(CancellationToken.None);
                Equal(1, refreshes, "401 watch uses the existing single-flight refresh");
                await session.ProbeSessionAsync(CancellationToken.None);
                True(session.IsAuthenticated, "compatibility probe does not change the current login");
            }
            using (var ordinary = new HttpRequestMessage(HttpMethod.Get, "https://imp.utenelec/api/auth/me"))
                Equal(TimeSpan.FromSeconds(5), SessionWatchContract.ForRequest(ordinary, TimeSpan.FromSeconds(5)), "ordinary reads keep their timeout");
        }

        private static ClientConfiguration Configuration(int maxResponseBytes = 2097152)
        {
            return new ClientConfiguration(new[] { new ServerEndpoint("company", "公司", "https://imp.utenelec/api"),
                new ServerEndpoint("cloud", "可信云端", "https://cloud.example.test/api") }, "company", 5, maxResponseBytes);
        }

        public static void RunClientReleasePublishCommands()
        {
            PublishResponseBudgetRetainsUnknownSubmission().GetAwaiter().GetResult();
            UploadResponseBudgetRetainsUnknownSubmission().GetAwaiter().GetResult();
        }

        private static async Task UploadResponseBudgetRetainsUnknownSubmission()
        {
            var id = Guid.NewGuid().ToString("D");
            var path = Path.Combine(Path.GetTempPath(), "uten-upload-unknown-" + Guid.NewGuid().ToString("N") + ".zip");
            var bytes = new byte[] { 1, 2, 3, 4 };
            File.WriteAllBytes(path, bytes);
            string sha;
            using (var hash = System.Security.Cryptography.SHA256.Create())
                sha = BitConverter.ToString(hash.ComputeHash(bytes)).Replace("-", "").ToLowerInvariant();
            int uploads = 0;
            using (var cancellation = new CancellationTokenSource())
            try
            {
                using (var session = new SessionCoordinator(Configuration(), new Handler((request, token) =>
                {
                    if (request.RequestUri.AbsolutePath.EndsWith("/login", StringComparison.Ordinal))
                        return Task.FromResult(Json(Token("access-test", "refresh-test").Replace("goods:view", "client_release:publish")));
                    uploads++;
                    Equal("/api/admin/client-releases/" + id + "/package", request.RequestUri.AbsolutePath, "upload keeps the original draft ID");
                    Equal(TimeSpan.FromMinutes(5), ClientReleaseReceiveBudget.ForRequest(request, TimeSpan.FromSeconds(5)),
                        "upload response receives five minutes without changing its total send lifetime");
                    var sink = ClientReleaseUploadSink.FromRequest(request);
                    using (var output = new MemoryStream()) sink.WriteTo(output, token);
                    True(sink.Started && sink.Completed, "all original upload bytes and SHA were checked before response waiting");
                    cancellation.Cancel();
                    throw new OperationCanceledException(token);
                }), new MemoryStore()))
                {
                    await session.LoginAsync("UT0001", "test-password", CancellationToken.None);
                    var error = await ThrowsAsync<ApiException>(() => session.UploadClientPackageAsync(id, path, bytes.Length,
                        sha, session.CaptureMutationOwner(), cancellation.Token));
                    True(error.IsSubmissionUnknown, "cancel after body send keeps the upload outcome unknown");
                    Equal(1, uploads, "unknown upload is never automatically retransmitted");
                    True(bytes.SequenceEqual(File.ReadAllBytes(path)), "original upload file survives interruption unchanged");
                }
            }
            finally { File.Delete(path); }
        }

        private static async Task PublishResponseBudgetRetainsUnknownSubmission()
        {
            var id = Guid.NewGuid().ToString("D");
            var publishPath = "/api/admin/client-releases/" + id + "/publish";
            int publishes = 0;
            using (var session = new SessionCoordinator(Configuration(), new Handler((request, cancellation) =>
            {
                if (request.RequestUri.AbsolutePath.EndsWith("/login", StringComparison.Ordinal))
                    return Task.FromResult(Json(Token("access-test", "refresh-test").Replace("goods:view", "client_release:publish")));
                var budget = ClientReleaseReceiveBudget.ForRequest(request, TimeSpan.FromSeconds(5));
                if (request.RequestUri.AbsolutePath == publishPath)
                {
                    publishes++;
                    Equal(TimeSpan.FromMinutes(5), budget, "publish command owns its five-minute receive budget");
                    throw new OperationCanceledException(cancellation);
                }
                Equal(TimeSpan.FromSeconds(5), budget, "prepare/withdraw commands retain their default budget");
                return Task.FromResult(Json("{}"));
            }), new MemoryStore()))
            {
                await session.LoginAsync("UT0001", "test-password", CancellationToken.None);
                var owner = session.CaptureMutationOwner();
                await session.SendClientReleaseCommandAsync("admin/client-releases", "{\"requestId\":\"" + id + "\"}", owner, null, CancellationToken.None);
                await session.SendClientReleaseCommandAsync("admin/client-releases/" + id + "/withdraw", null, owner, null, CancellationToken.None);
                var error = await ThrowsAsync<ApiException>(() => session.SendClientReleaseCommandAsync(
                    "admin/client-releases/" + id + "/publish", null, owner, null, CancellationToken.None));
                True(error.IsSubmissionUnknown, "a dispatched publish timeout retains an unknown outcome");
                Equal(1, publishes, "publish timeout never automatically replays the original command");
            }
        }
        private static void ConfigurationAndPathBounds()
        {
            foreach (var url in new[] { "http://imp.utenelec/api", "https://localhost/api", "https://localhost./api", "https://127.0.0.1/api",
                "https://[::1]/api", "https://name:secret@company.test/api", "https://company.test/", "https://company.test/api?q=x" })
                Throws<InvalidDataException>(() => new ServerEndpoint("x", "x", url));
            var endpoint = Configuration().Endpoints[0];
            foreach (var path in new[] { "https://other.test/api", "//other.test/api", "../auth", "%2e%2e/auth", "x/%2f../auth", "x\\auth", "x#fragment" })
                Throws<ApiException>(() => endpoint.Resolve(path));
            Equal("https://imp.utenelec/api/auth/me", endpoint.Resolve("auth/me").AbsoluteUri, "relative API path");
            var malformed = Token("access-old", "refresh-old").Replace("\"businessResetGeneration\":0", "\"businessResetGeneration\":-1");
            Throws<ApiException>(() => AuthResult.Parse(malformed));
            True(!ClientConfiguration.Load(Path.Combine(Path.GetTempPath(), Guid.NewGuid() + ".json")).IsConfigured, "missing config stays unconfigured");
        }

        private static async Task ConcurrentRefreshIsSingleFlight()
        {
            var refreshes = 0;
            using (var session = new SessionCoordinator(Configuration(), new Handler(async (request, ct) =>
            {
                if (request.RequestUri.AbsolutePath.EndsWith("/login")) return Json(Token("access-old", "refresh-old"));
                if (request.RequestUri.AbsolutePath.EndsWith("/refresh"))
                {
                    True(request.Headers.Authorization == null, "refresh never carries bearer");
                    Interlocked.Increment(ref refreshes);
                    await Task.Delay(30, ct).ConfigureAwait(false);
                    return Json(Token("access-new", "refresh-new"));
                }
                return request.Headers.Authorization.Parameter == "access-old" ? Unauthorized() : Json("{\"ok\":true}");
            }), new MemoryStore()))
            {
                await session.LoginAsync("UT0001", "test-password", CancellationToken.None);
                var generation = session.Generation;
                await Task.WhenAll(Enumerable.Range(0, 8).Select(_ => session.GetAsync("auth/me", CancellationToken.None)));
                Equal(1, refreshes, "one refresh for concurrent 401s");
                Equal(generation, session.Generation, "ordinary refresh keeps intent generation");
                True(session.CurrentUser.HasPermission("goods:view") && !session.CurrentUser.HasPermission("goods:edit"), "profile permission contract");
            }
        }

        private static async Task LogoutFencesPendingRefresh()
        {
            var entered = new TaskCompletionSource<bool>();
            var release = new TaskCompletionSource<HttpResponseMessage>();
            var store = new MemoryStore();
            using (var session = new SessionCoordinator(Configuration(), new Handler((request, ct) =>
            {
                var path = request.RequestUri.AbsolutePath;
                if (path.EndsWith("/login")) return Task.FromResult(Json(Token("access-old", "refresh-old")));
                if (path.EndsWith("/refresh")) { entered.TrySetResult(true); return release.Task; }
                if (path.EndsWith("/logout")) return Task.FromResult(Json("", HttpStatusCode.NoContent));
                return Task.FromResult(Unauthorized());
            }), store))
            {
                await session.LoginAsync("UT0001", "test-password", CancellationToken.None);
                var pending = session.GetAsync("auth/me", CancellationToken.None);
                True(entered.Task.Wait(TimeSpan.FromSeconds(5)), "refresh entered");
                var generation = session.Generation;
                await session.LogoutAsync(CancellationToken.None);
                release.SetResult(Json(Token("access-new", "refresh-new")));
                await ThrowsAsync<ApiException>(() => pending);
                True(!session.IsAuthenticated && session.CurrentUser == null && store.Load() == null, "logout cannot be revived");
                True(session.Generation > generation, "logout advances generation");
                Equal(1, store.PendingRevocations().Count, "late refresh response queued");
                Equal("refresh-new", store.PendingRevocations()[0].RefreshToken, "newly issued late refresh not lost");
            }
        }

        private static async Task ApplicationStartupRetiresPreviousRun()
        {
            var store = new MemoryStore();
            store.Save(new StoredSession("refresh-previous-run", "https://cloud.example.test/api", "cloud", "old-user"));
            var requests = 0;
            using (var session = new SessionCoordinator(Configuration(), new Handler(async (request, ct) =>
            {
                requests++;
                Equal("https://cloud.example.test/api/auth/logout", request.RequestUri.AbsoluteUri,
                    "startup retires only at the previous record's issuer");
                True(request.Headers.Authorization == null, "startup never attaches another session bearer");
                True((await request.Content.ReadAsStringAsync()).Contains("refresh-previous-run"), "startup revokes the exact old credential");
                return Json("", HttpStatusCode.NoContent);
            }), store))
            {
                await session.StartApplicationAsync(CancellationToken.None, waitForPendingRevocations: false);
                True(!session.IsAuthenticated && store.Load() == null, "previous process cannot automatically log in");
                Equal(0, requests, "startup local retirement does not wait for network");
                Equal(1, store.PendingRevocations().Count, "previous process credential is durably revocable");
                await session.DrainPendingRevocationsAsync(CancellationToken.None);
                Equal(1, requests, "startup cleanup sends no refresh or me request");
                Equal(0, store.PendingRevocations().Count, "issuer acknowledged old process logout");
            }
        }

        private static async Task LateLogoutDoesNotClearNewLogin()
        {
            var store = new MemoryStore();
            var release = new TaskCompletionSource<HttpResponseMessage>();
            var entered = new TaskCompletionSource<bool>();
            var logins = 0;
            using (var session = new SessionCoordinator(Configuration(), new Handler(async (request, ct) =>
            {
                if (request.RequestUri.AbsolutePath.EndsWith("/login"))
                    return Json(++logins == 1 ? Token("access-old", "refresh-old") : Token("access-new", "refresh-new"));
                True(request.Headers.Authorization == null, "old logout carries no new bearer");
                True((await request.Content.ReadAsStringAsync()).Contains("refresh-old"), "old logout retains its exact token");
                entered.TrySetResult(true);
                return await release.Task;
            }), store))
            {
                await session.LoginAsync("UT0001", "test-password", CancellationToken.None);
                var logout = session.LogoutAsync(CancellationToken.None);
                await entered.Task;
                True(!session.IsAuthenticated && store.Load() == null, "close retires local session before remote reply");
                var nextLogin = session.LoginAsync("UT0001", "test-password", CancellationToken.None);
                True(session.IsAuthenticated && store.Load().RefreshToken == "refresh-new", "next login committed while old logout waits");
                release.SetResult(Json("", HttpStatusCode.NoContent));
                await Task.WhenAll(logout, nextLogin);
                True(session.IsAuthenticated && store.Load().RefreshToken == "refresh-new", "late old logout never clears the new login");
            }
        }

        private static async Task EndpointSwitchFencesPendingLogin()
        {
            var reply = new TaskCompletionSource<HttpResponseMessage>();
            var sends = new List<string>();
            var store = new MemoryStore();
            using (var session = new SessionCoordinator(Configuration(), new Handler((request, ct) =>
            { sends.Add(request.RequestUri.Host); return reply.Task; }), store))
            {
                var pending = session.LoginAsync("UT0001", "test-password", CancellationToken.None);
                session.SelectEndpoint("cloud");
                reply.SetResult(Json(Token("access-old", "refresh-old")));
                await ThrowsAsync<ApiException>(() => pending);
                True(!session.IsAuthenticated, "old origin login cannot enter new origin");
                Equal("cloud", session.CurrentEndpoint.Id, "selected origin");
                True(sends.All(value => value == "imp.utenelec"), "credentials never forwarded to cloud");
                Equal(1, store.PendingRevocations().Count, "late login token queued");
                Equal("https://imp.utenelec/api", store.PendingRevocations()[0].IssuerApiBaseUrl, "late login issuer preserved");
            }
        }

        private static async Task PermissionAndDatasetChangesFenceReads()
        {
            foreach (var changed in new[] {
                Token("access-new", "refresh-new").Replace("goods:view", "goods:edit"),
                Token("access-new", "refresh-new").Replace("\"businessResetGeneration\":0", "\"businessResetGeneration\":1") })
            {
                var reads = 0;
                using (var session = new SessionCoordinator(Configuration(), new Handler((request, ct) =>
                {
                    if (request.RequestUri.AbsolutePath.EndsWith("/login")) return Task.FromResult(Json(Token("access-old", "refresh-old")));
                    if (request.RequestUri.AbsolutePath.EndsWith("/refresh")) return Task.FromResult(Json(changed));
                    reads++;
                    return Task.FromResult(Unauthorized());
                }), new MemoryStore()))
                {
                    await session.LoginAsync("UT0001", "test-password", CancellationToken.None);
                    var generation = session.Generation;
                    var error = await ThrowsAsync<ApiException>(() => session.GetAsync("auth/me", CancellationToken.None));
                    Equal("SESSION_CHANGED", error.Code, "changed profile stops old read");
                    True(session.IsAuthenticated && session.Generation > generation, "new profile retained with new generation");
                    Equal(1, reads, "old operation not replayed under new permissions/dataset");
                }
            }
        }

        private static async Task RefreshOutageKeepsSession()
        {
            using (var session = new SessionCoordinator(Configuration(), new Handler((request, ct) => Task.FromResult(
                request.RequestUri.AbsolutePath.EndsWith("/login") ? Json(Token("access-old", "refresh-old")) :
                request.RequestUri.AbsolutePath.EndsWith("/refresh") ? Json("<html>unavailable</html>", HttpStatusCode.ServiceUnavailable) : Unauthorized())), new MemoryStore()))
            {
                await session.LoginAsync("UT0001", "test-password", CancellationToken.None);
                await ThrowsAsync<ApiException>(() => session.GetAsync("auth/me", CancellationToken.None));
                True(session.IsAuthenticated, "proxy refresh outage preserves session");
            }
        }

        private static async Task WritesAreNotReplayed()
        {
            var changes = 0;
            var refreshes = 0;
            using (var session = new SessionCoordinator(Configuration(), new Handler((request, ct) =>
            {
                if (request.RequestUri.AbsolutePath.EndsWith("/login")) return Task.FromResult(Json(Token("access-old", "refresh-old")));
                if (request.RequestUri.AbsolutePath.EndsWith("/refresh")) Interlocked.Increment(ref refreshes);
                Interlocked.Increment(ref changes);
                return Task.FromResult(Unauthorized());
            }), new MemoryStore()))
            {
                await session.LoginAsync("UT0001", "test-password", CancellationToken.None);
                await ThrowsAsync<ApiException>(() => session.ChangePasswordAsync("old-password", "new-password", CancellationToken.None));
                Equal(1, changes, "password submission count");
                Equal(0, refreshes, "password 401 does not replay via refresh");
            }
            var attempts = 0;
            using (var session = new SessionCoordinator(Configuration(), new Handler((request, ct) =>
            { attempts++; throw new HttpRequestException("fixture network failure"); }), new MemoryStore()))
            {
                var error = await ThrowsAsync<ApiException>(() => session.LoginAsync("UT0001", "test-password", CancellationToken.None));
                True(error.IsSubmissionUnknown, "sent write has unknown outcome");
                Equal(1, attempts, "no automatic network retry");
            }
        }

        private static async Task RedirectAndReadBounds()
        {
            var attempts = 0;
            using (var session = new SessionCoordinator(Configuration(), new Handler((request, ct) =>
            {
                attempts++;
                var response = Json("", HttpStatusCode.Redirect);
                response.Headers.Location = new Uri("https://other.example.test/api/auth/login");
                return Task.FromResult(response);
            }), new MemoryStore()))
            {
                var error = await ThrowsAsync<ApiException>(() => session.LoginAsync("UT0001", "test-password", CancellationToken.None));
                Equal("REDIRECT_BLOCKED", error.Code, "redirect rejected");
                Equal(1, attempts, "redirect not followed");
            }
            using (var session = new SessionCoordinator(Configuration(1024), new Handler((request, ct) => Task.FromResult(
                request.RequestUri.AbsolutePath.EndsWith("/login") ? Json(Token("access-old", "refresh-old")) : Json(new string('x', 2048)))), new MemoryStore()))
            {
                await session.LoginAsync("UT0001", "test-password", CancellationToken.None);
                var error = await ThrowsAsync<ApiException>(() => session.GetAsync("large", CancellationToken.None));
                Equal("RESPONSE_TOO_LARGE", error.Code, "read bound");
            }
        }

        private static async Task DurableLogoutRetainsIssuer()
        {
            var store = new MemoryStore();
            using (var session = new SessionCoordinator(Configuration(), new Handler((request, ct) =>
            {
                if (request.RequestUri.AbsolutePath.EndsWith("/login")) return Task.FromResult(Json(Token("access-old", "refresh-old")));
                throw new HttpRequestException("fixture offline");
            }), store))
            {
                await session.LoginAsync("UT0001", "test-password", CancellationToken.None);
                await ThrowsAsync<ApiException>(() => session.LogoutAsync(CancellationToken.None));
                True(!session.IsAuthenticated && store.Load() == null, "offline local logout");
                Equal(1, store.PendingRevocations().Count, "offline logout retained");
                Equal("https://imp.utenelec/api", store.PendingRevocations()[0].IssuerApiBaseUrl, "issuer retained");
            }
            using (var session = new SessionCoordinator(Configuration(), new Handler((request, ct) =>
            {
                Equal("imp.utenelec", request.RequestUri.Host, "revocation uses original issuer");
                True(request.Headers.Authorization == null, "logout never carries new bearer");
                return Task.FromResult(Json("", HttpStatusCode.NoContent));
            }), store))
            {
                session.SelectEndpoint("cloud");
                await session.DrainPendingRevocationsAsync(CancellationToken.None);
                Equal(0, store.PendingRevocations().Count, "logout acknowledged only after response");
            }
        }

        private static async Task DefinitiveRejectionFailsClosedWhenStorageFails()
        {
            var store = new FailingStore { FailClear = true };
            var notifications = 0;
            using (var session = new SessionCoordinator(Configuration(), new Handler((request, ct) => Task.FromResult(
                request.RequestUri.AbsolutePath.EndsWith("/login") ? Json(Token("access-old", "refresh-old")) :
                request.RequestUri.AbsolutePath.EndsWith("/refresh")
                    ? Json("{\"code\":\"ACCOUNT_DISABLED\",\"message\":\"账号已停用\"}", HttpStatusCode.Unauthorized)
                    : Unauthorized())), store))
            {
                await session.LoginAsync("UT0001", "test-password", CancellationToken.None);
                session.SessionChanged += (sender, args) => notifications++;
                var generation = session.Generation;
                var error = await ThrowsAsync<ApiException>(() => session.GetAsync("auth/me", CancellationToken.None));
                Equal("LOCAL_SESSION_STORAGE", error.Code, "clear failure remains visible");
                True(!session.IsAuthenticated && session.CurrentUser == null, "disabled account fails closed before disk cleanup");
                True(session.Generation > generation && notifications > 0, "disabled account fences stale UI even on disk failure");
                True(store.Load() == null, "failed clear activates restoration fence");
            }
        }

        private static async Task LogoutStorageFailureStillRevokesAtIssuer()
        {
            foreach (var serverRejects in new[] { false, true })
            {
                var store = new FailingStore();
                var logouts = 0;
                using (var session = new SessionCoordinator(Configuration(), new Handler((request, ct) =>
                {
                    if (request.RequestUri.AbsolutePath.EndsWith("/login")) return Task.FromResult(Json(Token("access-old", "refresh-old")));
                    Equal("https://imp.utenelec/api/auth/logout", request.RequestUri.AbsoluteUri, "fallback logout pinned to original issuer");
                    True(request.Headers.Authorization == null, "fallback logout has no bearer");
                    logouts++;
                    return Task.FromResult(serverRejects
                        ? Json("{\"code\":\"INTERNAL\",\"message\":\"暂时失败\"}", HttpStatusCode.InternalServerError)
                        : Json("", HttpStatusCode.NoContent));
                }), store))
                {
                    await session.LoginAsync("UT0001", "test-password", CancellationToken.None);
                    store.FailEnd = true;
                    var error = await ThrowsAsync<ApiException>(() => session.LogoutAsync(CancellationToken.None));
                    Equal("LOGOUT_STORAGE_FAILED", error.Code, "durability failure not reported as successful logout");
                    Equal(serverRejects, error.IsSubmissionUnknown, "server revocation outcome reported accurately");
                    Equal(1, logouts, "storage failure still tries one issuer logout without replay");
                    True(!session.IsAuthenticated && session.CurrentUser == null && store.Load() == null, "local state and restore are fenced");
                    True(store.PendingRevocations().Count == 1, "old envelope retained as issuer-bound recovery candidate");
                }
                var restoreRequests = 0;
                using (var reopened = new SessionCoordinator(Configuration(), new Handler((request, ct) =>
                {
                    if (request.RequestUri.AbsolutePath.EndsWith("/refresh")) restoreRequests++;
                    else True(request.RequestUri.AbsolutePath.EndsWith("/logout") && request.Headers.Authorization == null,
                        "fenced startup may only retry issuer-bound logout");
                    return Task.FromResult(Json("", HttpStatusCode.NoContent));
                }), store))
                {
                    var startupError = await ThrowsAsync<ApiException>(() => reopened.StartApplicationAsync(CancellationToken.None));
                    Equal("LOGOUT_STORAGE_FAILED", startupError.Code, "startup reports the unresolved disk cleanup failure");
                    True(!reopened.IsAuthenticated && restoreRequests == 0, "failed logout cannot automatically restore old disk credentials");
                }
            }
        }

        private static async Task FailedCredentialCommitIsFencedAndRevocable()
        {
            var store = new FailingStore();
            using (var session = new SessionCoordinator(Configuration(), new Handler((request, ct) =>
            {
                if (request.RequestUri.AbsolutePath.EndsWith("/login")) return Task.FromResult(Json(Token("access-old", "refresh-old")));
                if (request.RequestUri.AbsolutePath.EndsWith("/refresh"))
                {
                    store.FailSave = true;
                    return Task.FromResult(Json(Token("access-new", "refresh-new")));
                }
                return Task.FromResult(Unauthorized());
            }), store))
            {
                await session.LoginAsync("UT0001", "test-password", CancellationToken.None);
                var generation = session.Generation;
                var error = await ThrowsAsync<ApiException>(() => session.GetAsync("auth/me", CancellationToken.None));
                Equal("LOCAL_SESSION_STORAGE", error.Code, "commit storage failure visible");
                True(!session.IsAuthenticated && session.CurrentUser == null && session.Generation > generation,
                    "failed new credential commit clears stale memory session");
                True(store.Load() == null, "failed credential commit blocks old disk restore");
                True(store.PendingRevocations().Any(value => value.RefreshToken == "refresh-new"
                    && value.IssuerApiBaseUrl == "https://imp.utenelec/api"), "newly issued uncommitted token remains revocable at issuer");
            }
        }

        private static void DpapiEnvelopeContainsOnlyOwnedCredentials()
        {
            var directory = Path.Combine(Path.GetTempPath(), "uten-wpf-core-check-" + Guid.NewGuid().ToString("N"));
            var path = Path.Combine(directory, "session.dpapi");
            try
            {
                var store = new DpapiSessionStore(directory);
                var session = new StoredSession("test-refresh-token", "https://imp.utenelec/api", "company", "user-1");
                store.Save(session);
                Equal(session.RefreshToken, store.Load().RefreshToken, "DPAPI round trip");
                True(!System.Text.Encoding.UTF8.GetString(File.ReadAllBytes(path)).Contains(session.RefreshToken), "encrypted token at rest");
                var originalEnvelope = File.ReadAllBytes(path);
                ((ISessionStoreSafetyFence)store).FenceActiveSession();
                True(store.Load() == null, "fence blocks automatic restoration");
                True(originalEnvelope.SequenceEqual(File.ReadAllBytes(path)), "fence preserves original encrypted queue bytes");
                Equal(1, new DpapiSessionStore(directory).PendingRevocations().Count, "fenced active record remains recoverable for revocation");
                var fresh = new StoredSession("new-test-refresh-token", "https://imp.utenelec/api", "company", "user-1");
                store.Save(fresh);
                Equal(fresh.Id, store.Load().Id, "new durable login releases restore fence");
                Equal(1, store.PendingRevocations().Count, "new login preserves fenced old refresh in pending queue");
                store.AcknowledgeRevocation(session.Id);
                session = fresh;
                store.EndSession(session);
                True(store.Load() == null && store.PendingRevocations().Count == 1, "atomic logout envelope");
                var reopened = new DpapiSessionStore(directory);
                Equal(session.Id, reopened.PendingRevocations()[0].Id, "queue survives reopening");
                reopened.AcknowledgeRevocation(session.Id);
                Equal(0, reopened.PendingRevocations().Count, "queue acknowledgement");
            }
            finally
            {
                // Test owns this exact randomly named directory, never a caller-supplied path.
                if (File.Exists(path)) File.Delete(path);
                var fence = Path.Combine(directory, "restore-blocked.fence");
                if (File.Exists(fence)) File.Delete(fence);
                if (Directory.Exists(directory)) Directory.Delete(directory, false);
            }
        }

        private static string Token(string access, string refresh)
        {
            return "{\"accessToken\":\"" + access + "\",\"refreshToken\":\"" + refresh + "\",\"expiresIn\":900,\"mustChangePassword\":false,\"user\":{\"id\":\"user-1\",\"loginAccount\":\"UT0001\",\"name\":\"测试员工\",\"superAdmin\":false,\"mustChangePassword\":false,\"permissions\":[\"goods:view\"],\"businessResetGeneration\":0,\"businessDatasetId\":\"11111111-1111-1111-1111-111111111111\"}}";
        }
        private static HttpResponseMessage Json(string text, HttpStatusCode status = HttpStatusCode.OK)
        { return new HttpResponseMessage(status) { Content = new StringContent(text, System.Text.Encoding.UTF8, "application/json") }; }
        private static HttpResponseMessage Unauthorized()
        { return Json("{\"code\":\"UNAUTHORIZED\",\"message\":\"会话已过期\"}", HttpStatusCode.Unauthorized); }
        private static void True(bool condition, string message) { if (!condition) throw new InvalidOperationException("Core contract: " + message); }
        private static void Equal<T>(T expected, T actual, string message) { True(EqualityComparer<T>.Default.Equals(expected, actual), message); }
        private static T Throws<T>(Action action) where T : Exception
        { try { action(); } catch (T error) { return error; } throw new InvalidOperationException("Core contract: expected " + typeof(T).Name); }
        private static async Task<T> ThrowsAsync<T>(Func<Task> action) where T : Exception
        { try { await action().ConfigureAwait(false); } catch (T error) { return error; } throw new InvalidOperationException("Core contract: expected " + typeof(T).Name); }
        private sealed class Handler : HttpMessageHandler
        {
            private readonly Func<HttpRequestMessage, CancellationToken, Task<HttpResponseMessage>> action;
            internal Handler(Func<HttpRequestMessage, CancellationToken, Task<HttpResponseMessage>> action) { this.action = action; }
            protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken) { return action(request, cancellationToken); }
        }
        private sealed class MemoryStore : ISessionStore
        {
            private readonly object gate = new object();
            private StoredSession session;
            private readonly List<StoredSession> pending = new List<StoredSession>();
            public StoredSession Load() { lock (gate) return session; }
            public void Save(StoredSession value) { lock (gate) session = value; }
            public void Clear() { lock (gate) session = null; }
            public void EndSession(StoredSession value) { lock (gate) { EnqueueRevocation(value ?? session); session = null; } }
            public void EnqueueRevocation(StoredSession value) { lock (gate) if (value != null && !pending.Any(item => item.Id == value.Id)) pending.Add(value); }
            public IList<StoredSession> PendingRevocations() { lock (gate) return pending.ToList(); }
            public void AcknowledgeRevocation(string id) { lock (gate) pending.RemoveAll(item => item.Id == id); }
        }
        private sealed class FailingStore : ISessionStore, ISessionStoreSafetyFence
        {
            private readonly MemoryStore inner = new MemoryStore();
            internal bool FailClear;
            internal bool FailEnd;
            internal bool FailSave;
            private bool fenced;
            public StoredSession Load() { return fenced ? null : inner.Load(); }
            public void Save(StoredSession value) { if (FailSave) throw new IOException("fixture save failure"); inner.Save(value); fenced = false; }
            public void Clear() { if (FailClear) throw new IOException("fixture clear failure"); inner.Clear(); }
            public void EndSession(StoredSession value) { if (FailEnd) throw new IOException("fixture end failure"); inner.EndSession(value); }
            public void EnqueueRevocation(StoredSession value) { inner.EnqueueRevocation(value); }
            public IList<StoredSession> PendingRevocations()
            {
                var values = inner.PendingRevocations();
                var active = inner.Load();
                if (fenced && active != null && !values.Any(value => value.Id == active.Id)) values.Add(active);
                return values;
            }
            public void AcknowledgeRevocation(string id) { inner.AcknowledgeRevocation(id); }
            public void FenceActiveSession() { fenced = true; }
        }
    }
}
