using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Net;
using System.Net.Http;
using System.Text;
using System.Threading;
using System.Threading.Tasks;

namespace Uten.Legacy.Core.Tests
{
    /// <summary>Only injected in-memory HTTPS handlers and codec streams. No business server writes.</summary>
    public static class MutationContractChecks
    {
        private const string UnitId = "22222222-2222-2222-2222-222222222222";
        private const string UnitBody = "{\"id\":\"" + UnitId + "\",\"name\":\"kg\",\"status\":\"使用\",\"measurementDimension\":\"MASS\",\"massUnitCode\":\"KG\"}";

        public static void Run()
        {
            AllowlistAndFrozenPresence().GetAwaiter().GetResult();
            PermissionAndOwnerGuards().GetAwaiter().GetResult();
            ExactBodyAndVersionHonesty().GetAwaiter().GetResult();
            NoReplayFor401StepUpAnd5xx().GetAwaiter().GetResult();
            UnknownPreservesOriginalIntent().GetAwaiter().GetResult();
            ConcurrentDuplicateCannotSendTwice().GetAwaiter().GetResult();
            CancelBeforeAndAfterDispatch().GetAwaiter().GetResult();
            LateIssuerAndReadScopeCannotDeliver().GetAwaiter().GetResult();
            OrdinaryRefreshCanPrepareButNotReplay().GetAwaiter().GetResult();
            ChangedRefreshOwnerPreventsWrite().GetAwaiter().GetResult();
            StepUpUsesCurrentSessionAndNeverReplays().GetAwaiter().GetResult();
            WirePermitProtectsExtendedMethods().GetAwaiter().GetResult();
        }

        private static async Task AllowlistAndFrozenPresence()
        {
            using (var fixture = new Fixture())
            {
                await fixture.Login();
                var owner = fixture.Session.CaptureMutationOwner();
                var body = " { \"name\" : \"kg\" } \n";
                var id = NewId();
                var missing = fixture.Session.PrepareMutation(MutationAction.UnitCreate, id, body, owner);
                Equal(body, missing.BodyJson, "raw original body is frozen");
                True(!missing.HasMeasurementDimension && !missing.HasMassUnitCode, "missing keys preserve server inference");
                True(Object.ReferenceEquals(missing, fixture.Session.PrepareMutation(MutationAction.UnitCreate, id, body, owner)), "same intent has one descriptor");
                var explicitNull = fixture.Create("{\"name\":\"kg\",\"measurementDimension\":null,\"massUnitCode\":null}");
                True(explicitNull.HasMeasurementDimension && explicitNull.HasMassUnitCode, "explicit null remains present");
                var oneKey = fixture.Create("{\"name\":\"kg\",\"massUnitCode\":\"KG\"}");
                True(!oneKey.HasMeasurementDimension && oneKey.HasMassUnitCode, "partial measurement presence remains unchanged");
                ExpectCode("MUTATION_INTENT_CHANGED", () => fixture.Session.PrepareMutation(MutationAction.UnitCreate, id, "{\"name\":\"g\"}", owner));
                var distinct = fixture.Create("{\"name\":\"g\"}");
                True(distinct.RequestId != missing.RequestId, "new body requires a new intent id");
                foreach (var bad in new[] { "{\"name\":\"kg\",\"legacyId\":1}", "{\"name\":\"a\",\"name\":\"b\"}",
                    "{\"name\":\"a\",\"\\u006eame\":\"b\"}", "{\"name\":null}", "{\"name\":0}",
                    "{\"name\":\"a\",\"version\":1}", "{\"name\":\"a\",\"code\":{}}", "{\"name\":\"a\",}", "{\"name\":\"a\"}{}" })
                    Throws<ApiException>(() => fixture.Create(bad));
                Throws<ApiException>(() => fixture.Session.PrepareMutation(MutationAction.Unknown, NewId(), "{}", owner));
                Throws<ApiException>(() => fixture.Session.PrepareMutation(MutationAction.UnitUpdate, NewId(), "{\"name\":\"a\"}", owner, UnitId));
                Throws<ApiException>(() => fixture.Session.PrepareMutation(MutationAction.UnitUpdate, NewId(), "{\"name\":\"a\",\"status\":null}", owner, UnitId));
                foreach (var resource in new[] { "../users", "https://evil.test/api", "legacy-42", Guid.Empty.ToString("D") })
                    Throws<ApiException>(() => fixture.Session.PrepareMutation(MutationAction.UnitStatus, NewId(), "{\"status\":\"禁用\"}", owner, resource));
                True(!fixture.Session.DurableMutationJournalAvailable, "in-memory foundation does not claim crash persistence");
                Equal(0, fixture.Writes, "preparation never writes");
            }
        }

        private static async Task PermissionAndOwnerGuards()
        {
            using (var missingDataset = new Fixture())
            {
                missingDataset.OmitDataset = true; await missingDataset.Login();
                ExpectCode("MUTATION_DATASET_UNCONFIRMED", () => missingDataset.Session.CaptureMutationOwner());
                Equal(0, missingDataset.Writes, "unconfirmed dataset cannot start a business intent");
            }
            using (var statusOnly = new Fixture())
            using (var other = new Fixture())
            {
                statusOnly.Permissions = new[] { "unit:status" };
                await statusOnly.Login(); await other.Login();
                var owner = statusOnly.Session.CaptureMutationOwner();
                statusOnly.Session.PrepareMutation(MutationAction.UnitStatus, NewId(), "{\"status\":\"禁用\"}", owner, UnitId);
                ExpectCode("FORBIDDEN", () => statusOnly.Session.PrepareMutation(MutationAction.UnitUpdate, NewId(), "{\"name\":\"kg\",\"status\":\"使用\"}", owner, UnitId, "使用"));
                ExpectCode("MUTATION_OWNER_CHANGED", () => other.Session.PrepareMutation(MutationAction.UnitCreate, NewId(), "{\"name\":\"a\"}", owner));
            }
            using (var editOnly = new Fixture())
            {
                editOnly.Permissions = new[] { "unit:edit", "unit:create" }; await editOnly.Login();
                var owner = editOnly.Session.CaptureMutationOwner();
                editOnly.Session.PrepareMutation(MutationAction.UnitUpdate, NewId(), "{\"name\":\"kg\",\"status\":\"使用\"}", owner, UnitId, "使用");
                ExpectCode("FORBIDDEN", () => editOnly.Session.PrepareMutation(MutationAction.UnitUpdate, NewId(), "{\"name\":\"kg\",\"status\":\"禁用\"}", owner, UnitId, "使用"));
                ExpectCode("FORBIDDEN", () => editOnly.Session.PrepareMutation(MutationAction.UnitUpdate, NewId(), "{\"name\":\"kg\",\"status\":\"使用\"}", owner, UnitId));
                ExpectCode("FORBIDDEN", () => editOnly.Create("{\"name\":\"kg\",\"status\":\"禁用\"}"));
                var pending = editOnly.Create();
                editOnly.Session.SelectEndpoint("cloud");
                var result = await editOnly.Session.MutateAsync(pending, CancellationToken.None);
                Equal(MutationOutcome.NotSent, result.Outcome, "changed issuer before submit never writes");
                Equal(0, editOnly.Writes, "no late new-issuer write");
            }
        }

        private static async Task ExactBodyAndVersionHonesty()
        {
            const string exact = " { \"status\":\"禁用\", \"version\":9007199254740993 } ";
            using (var fixture = new Fixture(async (request, ct) =>
            {
                Equal("PATCH", request.Method.Method, "status uses fixed PATCH");
                Equal("/api/master/units/" + UnitId + "/status", request.RequestUri.AbsolutePath, "fixed status path");
                Equal(exact, await request.Content.ReadAsStringAsync(), "integer beyond Double exactness remains byte-identical");
                True(!request.Headers.Contains("Idempotency-Key") && !request.Headers.Contains("X-Request-ID")
                    && !request.Headers.Contains("If-Match") && !request.Headers.Contains(StepUpGrant.HeaderName), "no invented server guarantees");
                return Json(UnitBody);
            }))
            {
                await fixture.Login();
                var command = fixture.Session.PrepareMutation(MutationAction.UnitStatus, NewId(), exact, fixture.Session.CaptureMutationOwner(), UnitId);
                Equal("9007199254740993", command.ExpectedVersionJson, "original numeric token retained");
                Equal(MutationVersionStrategy.AcceptedButIgnored, command.VersionStrategy, "unit version is honestly ignored");
                True(!command.EnforcesExpectedVersion && !command.ServerIdempotencyAvailable && command.RequestIdBodyField == null, "no fake concurrency/receipt");
                var result = await fixture.Session.MutateAsync(command, CancellationToken.None);
                Equal(MutationOutcome.Confirmed, result.Outcome, "current owner receives verified unit detail");
                Equal(UnitBody, result.ResponseJson, "response stays raw");
                True(!result.IsDurablyRecorded, "no false durable journal");
                Equal(1, fixture.Writes, "exactly one write");
                foreach (var version in new[] { "1.0", "1e0", "-1", "9223372036854775808", "true" })
                    Throws<ApiException>(() => fixture.Session.PrepareMutation(MutationAction.UnitStatus, NewId(), "{\"status\":\"禁用\",\"version\":" + version + "}", fixture.Session.CaptureMutationOwner(), UnitId));
            }
        }

        private static async Task NoReplayFor401StepUpAnd5xx()
        {
            foreach (var response in new[] { new { Status = 401, Code = "UNAUTHORIZED", Outcome = MutationOutcome.Rejected },
                new { Status = 403, Code = "REAUTH_REQUIRED", Outcome = MutationOutcome.Rejected },
                new { Status = 503, Code = "AUTH_BUSY", Outcome = MutationOutcome.Unknown },
                new { Status = 500, Code = "INTERNAL_ERROR", Outcome = MutationOutcome.Unknown } })
            using (var fixture = new Fixture((request, ct) => Ready(Error(response.Status, response.Code))))
            {
                await fixture.Login();
                var command = fixture.Create();
                var result = await fixture.Session.MutateAsync(command, CancellationToken.None);
                Equal(response.Outcome, result.Outcome, "structured status classification " + response.Code);
                Equal(1, fixture.Writes, "no business replay " + response.Code);
                Equal(0, fixture.Refreshes, "no automatic 401 refresh/replay");
                Equal(0, fixture.StepUps, "no automatic reauth password action");
                await ExpectCodeAsync("MUTATION_ALREADY_ATTEMPTED", () => fixture.Session.MutateAsync(command, CancellationToken.None));
                Equal(1, fixture.Writes, "same command cannot be sent twice");
                True(result.NeedsManualReconciliation == (response.Outcome == MutationOutcome.Unknown), "manual review only for uncertain outcome");
                True(result.Error.IsSubmissionUnknown == (response.Outcome == MutationOutcome.Unknown), "error/result uncertainty agrees");
            }
            foreach (var body in new[] { "not json", "{\"ok\":true}", "{\"id\":\"bad\",\"name\":\"a\"}" })
            using (var fixture = new Fixture((request, ct) => Ready(Json(body))))
            {
                await fixture.Login();
                Equal(MutationOutcome.Unknown, (await fixture.Session.MutateAsync(fixture.Create(), CancellationToken.None)).Outcome, "invalid success is not a receipt");
            }
        }

        private static async Task UnknownPreservesOriginalIntent()
        {
            const string original = "{\"name\":\"kg\",\"measurementDimension\":null}";
            using (var fixture = new Fixture((request, ct) => { throw new HttpRequestException("fixture disconnected after dispatch"); }))
            {
                await fixture.Login(); var command = fixture.Create(original);
                var result = await fixture.Session.MutateAsync(command, CancellationToken.None);
                Equal(MutationOutcome.Unknown, result.Outcome, "fake dispatched transport failure is conservatively unknown");
                True(Object.ReferenceEquals(command, result.Request), "original intent is preserved for reconciliation");
                Equal(original, result.Request.BodyJson, "original body is never replaced with edited values");
                True(result.Request.Owner.IssuerApiBaseUrl.EndsWith("company.example.test/api", StringComparison.Ordinal), "original issuer stays with unknown");
                True(result.NeedsManualReconciliation && result.ResponseJson == null && !String.IsNullOrEmpty(result.ReconciliationHint), "unknown provides no success data or fake receipt");
                ExpectCode("MUTATION_INTENT_CHANGED", () => fixture.Session.PrepareMutation(command.Action, command.RequestId, "{\"name\":\"g\"}", command.Owner));
                await ExpectCodeAsync("MUTATION_ALREADY_ATTEMPTED", () => fixture.Session.MutateAsync(command, CancellationToken.None));
                Equal(1, fixture.Writes, "unknown never replays");
            }
        }

        private static async Task ConcurrentDuplicateCannotSendTwice()
        {
            var entered = Signal(); var release = ResponseSignal();
            using (var fixture = new Fixture((request, ct) => { entered.TrySetResult(true); return release.Task; }))
            {
                await fixture.Login(); var command = fixture.Create();
                var first = fixture.Session.MutateAsync(command, CancellationToken.None);
                await Wait(entered.Task);
                await ExpectCodeAsync("MUTATION_ALREADY_ATTEMPTED", () => fixture.Session.MutateAsync(command, CancellationToken.None));
                release.SetResult(Json(UnitBody));
                Equal(MutationOutcome.Confirmed, (await first).Outcome, "duplicate cannot overwrite original completion");
                Equal(1, fixture.Writes, "concurrent same intent sends once");
            }
        }

        private static async Task CancelBeforeAndAfterDispatch()
        {
            using (var fixture = new Fixture())
            {
                await fixture.Login(); var command = fixture.Create(); fixture.Session.Dispose();
                Equal(MutationOutcome.NotSent, (await fixture.Session.MutateAsync(command, CancellationToken.None)).Outcome, "closed context before dispatch is not sent");
                Equal(0, fixture.Writes, "closed context never calls transport");
            }
            using (var fixture = new Fixture())
            using (var cancellation = new CancellationTokenSource())
            {
                await fixture.Login(); var command = fixture.Create(); cancellation.Cancel();
                Equal(MutationOutcome.NotSent, (await fixture.Session.MutateAsync(command, cancellation.Token)).Outcome, "pre-cancel is not sent");
                Equal(0, fixture.Writes, "pre-cancel no handler call");
            }
            var entered = Signal();
            using (var fixture = new Fixture(async (request, ct) => { entered.TrySetResult(true); await Task.Delay(5000, ct); return Json(UnitBody); }))
            using (var cancellation = new CancellationTokenSource())
            {
                await fixture.Login(); var command = fixture.Create();
                var pending = fixture.Session.MutateAsync(command, cancellation.Token); await Wait(entered.Task); cancellation.Cancel();
                var result = await pending;
                Equal(MutationOutcome.Unknown, result.Outcome, "cancel after dispatch cannot claim failure");
                Equal(1, fixture.Writes, "cancelled write is never replayed");
            }
        }

        private static async Task LateIssuerAndReadScopeCannotDeliver()
        {
            foreach (var scopeChange in new[] { false, true })
            {
                var entered = Signal(); var release = ResponseSignal(); var proof = "proof-a";
                using (var fixture = new Fixture((request, ct) =>
                {
                    if (request.Method == HttpMethod.Get)
                    { var response = Json("{\"readScopeVersion\":\"" + proof + "\",\"items\":[]}"); response.Headers.Add("X-Uten-Read-Scope-Version", proof); return Ready(response); }
                    entered.TrySetResult(true); return release.Task; // Deliberately ignore old cancellation.
                }))
                {
                    await fixture.Login();
                    if (scopeChange) await fixture.Session.GetAsync("master/units", CancellationToken.None);
                    var command = fixture.Create(); var auth = fixture.Session.Generation;
                    var pending = fixture.Session.MutateAsync(command, CancellationToken.None); await Wait(entered.Task);
                    if (scopeChange)
                    {
                        proof = "proof-b";
                        await ExpectCodeAsync("READ_SCOPE_CHANGED", () => fixture.Session.GetAsync("master/units", CancellationToken.None));
                        Equal(auth, fixture.Session.Generation, "scope change stays separate from auth CAS");
                    }
                    else fixture.Session.SelectEndpoint("cloud");
                    release.SetResult(Json(UnitBody));
                    var result = await pending;
                    Equal(MutationOutcome.Unknown, result.Outcome, "late retired owner write stays uncertain");
                    True(result.ResponseJson == null && Object.ReferenceEquals(command.Owner, result.Request.Owner), "late body never enters new view/issuer");
                    Equal(1, fixture.Writes, "late result never replays to new context");
                }
            }
        }

        private static async Task OrdinaryRefreshCanPrepareButNotReplay()
        {
            using (var fixture = new Fixture())
            {
                fixture.LoginExpires = 1; await fixture.Login();
                var command = fixture.Create(); var auth = fixture.Session.Generation;
                var result = await fixture.Session.MutateAsync(command, CancellationToken.None);
                Equal(MutationOutcome.Confirmed, result.Outcome, "ordinary same-owner refresh can prepare one submission");
                Equal(auth, fixture.Session.Generation, "normal refresh retains logical owner");
                Equal(1, fixture.Refreshes, "one preflight refresh"); Equal(1, fixture.Writes, "one business dispatch");
                Equal("access-refreshed", fixture.LastBusinessBearer, "uses newly prepared access credential");
            }
        }

        private static async Task ChangedRefreshOwnerPreventsWrite()
        {
            using (var fixture = new Fixture())
            {
                fixture.LoginExpires = 1; fixture.ChangeDatasetOnRefresh = true; await fixture.Login(); var command = fixture.Create();
                var result = await fixture.Session.MutateAsync(command, CancellationToken.None);
                Equal(MutationOutcome.NotSent, result.Outcome, "refresh changed dataset invalidates frozen intent before write");
                Equal(1, fixture.Refreshes, "refresh processed once"); Equal(0, fixture.Writes, "dataset change never sends old body");
            }
        }

        private static async Task StepUpUsesCurrentSessionAndNeverReplays()
        {
            using (var fixture = new Fixture())
            {
                await fixture.Login(); var generation = fixture.Session.Generation;
                var grant = await fixture.Session.StepUpAsync("fixture-password", CancellationToken.None);
                Equal(1, fixture.StepUps, "explicit step-up once");
                Equal(300L, grant.ExpiresInSeconds, "real idle TTL");
                True(!grant.IsExpired && grant.StepUpToken.Length == 43 && Object.ReferenceEquals(grant, fixture.Session.CurrentStepUpGrant), "usable current memory-only grant");
                Equal("X-Uten-Step-Up", StepUpGrant.HeaderName, "real server header name");
                Equal(generation, fixture.Session.Generation, "step-up does not replace auth identity");
                var result = await fixture.Session.MutateAsync(fixture.Create(), CancellationToken.None);
                Equal(MutationOutcome.Confirmed, result.Outcome, "unit write works without requiring step-up");
                fixture.Session.SelectEndpoint("cloud");
                True(fixture.Session.CurrentStepUpGrant == null, "grant never crosses issuer/session");
            }
            foreach (var code in new[] { "REAUTH_FAILED", "REAUTH_LOCKED", "REAUTH_REQUIRED" })
            using (var fixture = new Fixture())
            {
                fixture.StepUpError = code; await fixture.Login();
                await ExpectCodeAsync(code, () => fixture.Session.StepUpAsync("fixture-password", CancellationToken.None));
                Equal(1, fixture.StepUps, "bad password/reauth never replays"); Equal(0, fixture.Refreshes, "no hidden reauth refresh");
                True(fixture.Session.CurrentStepUpGrant == null, "failed grant not published");
                if (code == "REAUTH_LOCKED") True(!fixture.Session.IsAuthenticated, "server-revoked locked session fails closed");
            }
            var entered = Signal(); var release = ResponseSignal();
            using (var fixture = new Fixture())
            {
                fixture.StepUpAction = (request, ct) => { entered.TrySetResult(true); return release.Task; };
                await fixture.Login(); var pending = fixture.Session.StepUpAsync("fixture-password", CancellationToken.None); await Wait(entered.Task);
                fixture.Session.SelectEndpoint("cloud"); release.SetResult(Json("{\"stepUpToken\":\"" + new string('a', 43) + "\",\"expiresInSeconds\":300}"));
                await ThrowsAsync<ApiException>(() => pending);
                True(fixture.Session.CurrentStepUpGrant == null, "late old-issuer grant cannot enter current context");
            }
        }

        private static async Task WirePermitProtectsExtendedMethods()
        {
            using (var fixture = new Fixture())
            {
                await fixture.Login();
                var command = fixture.Session.PrepareMutation(MutationAction.UnitUpdate, NewId(), "{\"name\":\"kg\",\"status\":\"使用\"}", fixture.Session.CaptureMutationOwner(), UnitId, "使用");
                foreach (var invalid in new[] { "missing", "body", "path", "owner", "header", "partial", "valid" })
                using (var request = new HttpRequestMessage(HttpMethod.Put, command.Owner.IssuerApiBaseUrl + "/" + command.RelativePath))
                using (var stream = new WireStream(invalid == "partial"))
                {
                    request.Content = new StringContent(invalid == "body" ? "{\"name\":\"g\",\"status\":\"使用\"}" : command.BodyJson, Encoding.UTF8, "application/json");
                    var permit = new MutationWirePermit(command, true, () => { if (invalid == "owner") throw new ApiException("MUTATION_OWNER_CHANGED", "fixture owner changed"); });
                    if (invalid != "missing") permit.Attach(request);
                    if (invalid == "path") request.RequestUri = new Uri(command.Owner.IssuerApiBaseUrl + "/master/units/" + NewId());
                    if (invalid == "header") request.Headers.Add(StepUpGrant.HeaderName, "fixture-forbidden");
                    if (invalid == "valid")
                    {
                        using (var response = ManagedHttp11.SendAndReceive(stream, request, 1024, CancellationToken.None)) { }
                        True(permit.MayHaveBeenSubmitted && stream.Written > 0, "exact approved body reaches single HTTP encoder");
                    }
                    else
                    {
                        Throws<Exception>(() => ManagedHttp11.SendAndReceive(stream, request, 1024, CancellationToken.None));
                        Equal(invalid == "partial", permit.MayHaveBeenSubmitted, "only first attempted physical write marks submitted " + invalid);
                        if (invalid != "partial") Equal(0L, stream.Written, "invalid mutation never writes one byte " + invalid);
                    }
                }
            }
        }

        private static string NewId() { return Guid.NewGuid().ToString("D"); }
        private static HttpResponseMessage Json(string body, int status = 200)
        { return new HttpResponseMessage((HttpStatusCode)status) { Content = new StringContent(body, Encoding.UTF8, "application/json") }; }
        private static HttpResponseMessage Error(int status, string code) { return Json("{\"code\":\"" + code + "\",\"message\":\"fixture rejection\"}", status); }
        private static Task<HttpResponseMessage> Ready(HttpResponseMessage value) { return Task.FromResult(value); }
        private static TaskCompletionSource<bool> Signal() { return new TaskCompletionSource<bool>(TaskCreationOptions.RunContinuationsAsynchronously); }
        private static TaskCompletionSource<HttpResponseMessage> ResponseSignal() { return new TaskCompletionSource<HttpResponseMessage>(TaskCreationOptions.RunContinuationsAsynchronously); }
        private static async Task Wait(Task task)
        { if (await Task.WhenAny(task, Task.Delay(5000)) != task) throw new InvalidOperationException("Mutation fixture timed out."); await task; }
        private static void True(bool value, string message) { if (!value) throw new InvalidOperationException("Mutation contract: " + message); }
        private static void Equal<T>(T expected, T actual, string message) { True(EqualityComparer<T>.Default.Equals(expected, actual), message); }
        private static void Throws<T>(Action action) where T : Exception { try { action(); } catch (T) { return; } throw new InvalidOperationException("Expected " + typeof(T).Name); }
        private static async Task ThrowsAsync<T>(Func<Task> action) where T : Exception { try { await Wait(action()); } catch (T) { return; } throw new InvalidOperationException("Expected " + typeof(T).Name); }
        private static void ExpectCode(string code, Action action)
        { try { action(); } catch (ApiException error) { Equal(code, error.Code, "expected API rejection"); return; } throw new InvalidOperationException("Expected " + code); }
        private static async Task ExpectCodeAsync(string code, Func<Task> action)
        { try { await Wait(action()); } catch (ApiException error) { Equal(code, error.Code, "expected async rejection"); return; } throw new InvalidOperationException("Expected " + code); }

        private sealed class Fixture : IDisposable
        {
            internal readonly SessionCoordinator Session;
            internal string[] Permissions = { "unit:view", "unit:create", "unit:edit", "unit:status" };
            internal int LoginExpires = 900;
            internal bool ChangeDatasetOnRefresh;
            internal bool OmitDataset;
            internal string StepUpError;
            internal Func<HttpRequestMessage, CancellationToken, Task<HttpResponseMessage>> StepUpAction;
            internal int Writes, Refreshes, StepUps;
            internal string LastBusinessBearer;
            internal Fixture(Func<HttpRequestMessage, CancellationToken, Task<HttpResponseMessage>> action = null)
            {
                var config = new ClientConfiguration(new[] { new ServerEndpoint("company", "fixture company", "https://company.example.test/api"),
                    new ServerEndpoint("cloud", "fixture cloud", "https://cloud.example.test/api") }, "company", 5, 2097152);
                Session = new SessionCoordinator(config, new Handler(async (request, ct) =>
                {
                    True(request.RequestUri.Host.EndsWith(".example.test", StringComparison.Ordinal), "only fake issuer");
                    if (request.RequestUri.AbsolutePath == "/api/auth/login")
                    {
                        var body = Token("access-original", LoginExpires, false);
                        if (OmitDataset) body = body.Replace("\"businessDatasetId\":\"11111111-1111-1111-1111-111111111111\",", "");
                        return Json(body);
                    }
                    if (request.RequestUri.AbsolutePath == "/api/auth/logout") return Json("", 204);
                    if (request.RequestUri.AbsolutePath == "/api/auth/refresh")
                    { Interlocked.Increment(ref Refreshes); return Json(Token("access-refreshed", 900, ChangeDatasetOnRefresh)); }
                    if (request.RequestUri.AbsolutePath == "/api/auth/step-up")
                    {
                        Interlocked.Increment(ref StepUps);
                        Equal("{\"password\":\"fixture-password\"}", await request.Content.ReadAsStringAsync(), "step-up real request field");
                        True(request.Headers.Authorization != null && !request.Headers.Contains(StepUpGrant.HeaderName), "step-up authenticated, never previous grant/password in URL");
                        if (StepUpAction != null) return await StepUpAction(request, ct);
                        if (StepUpError != null) return Error(StepUpError == "REAUTH_LOCKED" ? 429 : StepUpError == "REAUTH_FAILED" ? 422 : 403, StepUpError);
                        return Json("{\"stepUpToken\":\"" + new string('a', 43) + "\",\"expiresInSeconds\":300}");
                    }
                    if (request.Method != HttpMethod.Get)
                    {
                        Interlocked.Increment(ref Writes); LastBusinessBearer = request.Headers.Authorization?.Parameter;
                        True(!request.Headers.Contains(StepUpGrant.HeaderName), "unit action does not transmit unnecessary grant");
                    }
                    return action == null ? Json(UnitBody) : await action(request, ct);
                }), new MemoryStore());
            }
            internal Task Login() { return Session.LoginAsync("UT0001", "fixture-password", null, CancellationToken.None); }
            internal MutationRequest Create(string body = "{\"name\":\"kg\"}")
            { return Session.PrepareMutation(MutationAction.UnitCreate, NewId(), body, Session.CaptureMutationOwner()); }
            private string Token(string access, int expires, bool changed)
            { return "{\"accessToken\":\"" + access + "\",\"refreshToken\":\"refresh-fixture\",\"expiresIn\":" + expires + ",\"user\":{\"id\":\"user-fixture\",\"loginAccount\":\"UT0001\",\"name\":\"fixture\",\"superAdmin\":false,\"mustChangePassword\":false,\"permissions\":"
                + JsonValue.Serialize(Permissions) + ",\"businessDatasetId\":\"" + (changed ? "33333333-3333-3333-3333-333333333333" : "11111111-1111-1111-1111-111111111111") + "\",\"businessResetGeneration\":0}}"; }
            public void Dispose() { Session.Dispose(); }
        }
        private sealed class Handler : HttpMessageHandler
        {
            private readonly Func<HttpRequestMessage, CancellationToken, Task<HttpResponseMessage>> action;
            internal Handler(Func<HttpRequestMessage, CancellationToken, Task<HttpResponseMessage>> action) { this.action = action; }
            protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken) { return action(request, cancellationToken); }
        }
        private sealed class MemoryStore : ISessionStore
        {
            private StoredSession active;
            private readonly List<StoredSession> pending = new List<StoredSession>();
            public StoredSession Load() { return active; }
            public void Save(StoredSession value) { active = value; }
            public void Clear() { active = null; }
            public void EndSession(StoredSession value) { EnqueueRevocation(value ?? active); active = null; }
            public void EnqueueRevocation(StoredSession value) { if (value != null && !pending.Any(item => item.Id == value.Id)) pending.Add(value); }
            public IList<StoredSession> PendingRevocations() { return pending.ToList(); }
            public void AcknowledgeRevocation(string id) { pending.RemoveAll(value => value.Id == id); }
        }
        private sealed class WireStream : Stream
        {
            private readonly MemoryStream input = new MemoryStream(Encoding.ASCII.GetBytes("HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\n{}"));
            private readonly bool failWrite;
            internal long Written;
            internal WireStream(bool failWrite) { this.failWrite = failWrite; }
            public override void Write(byte[] buffer, int offset, int count) { Written += count; if (failWrite) throw new IOException("fixture partial write"); }
            public override int Read(byte[] buffer, int offset, int count) { return input.Read(buffer, offset, count); }
            public override bool CanRead { get { return true; } } public override bool CanSeek { get { return false; } } public override bool CanWrite { get { return true; } }
            public override long Length { get { return input.Length; } } public override long Position { get { return input.Position; } set { throw new NotSupportedException(); } }
            public override void Flush() { } public override long Seek(long offset, SeekOrigin origin) { throw new NotSupportedException(); }
            public override void SetLength(long value) { throw new NotSupportedException(); }
            protected override void Dispose(bool disposing) { if (disposing) input.Dispose(); base.Dispose(disposing); }
        }
    }
}
