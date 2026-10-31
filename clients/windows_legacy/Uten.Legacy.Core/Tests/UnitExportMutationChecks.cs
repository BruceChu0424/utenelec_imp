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
    public static class UnitExportMutationChecks
    {
        private const string Job = "77777777-7777-7777-7777-777777777777";
        private const string Other = "88888888-8888-8888-8888-888888888888";
        private const string Filter = " { \"keyword\":\"kg\", \"nullFields\":[\"code\"] } ";
        public static void Run()
        {
            ExactSubmitAndCredentialBoundary().GetAwaiter().GetResult();
            CancelNoBodyAndActualJobState().GetAwaiter().GetResult();
            KnownJobAcceptanceIsNotFileDelivery().GetAwaiter().GetResult();
            ServerKeyCannotChangeFrozenBody().GetAwaiter().GetResult();
            VerifiedGetRequestProofSettlesOnlyOriginalSubmit().GetAwaiter().GetResult();
            MissingOrDifferentProofStaysUnknown().GetAwaiter().GetResult();
            ExplicitSameKeyRetryNeverCreatesNewIdentity().GetAwaiter().GetResult();
            ReceiptPersistenceFailureKeepsKnownOutcome().GetAwaiter().GetResult();
            LateReceiptCannotEnterNewOwner().GetAwaiter().GetResult();
            CorruptReceiptMetadataFailsClosed().GetAwaiter().GetResult();
            PureMetadataParserDoesNotTreatPresenceAsProof();
        }
        private static async Task ExactSubmitAndCredentialBoundary()
        {
            using (var f = new Fixture())
            {
                await f.Login(); var body = SubmitBody(); var request = f.Submit(body);
                Equal("report-export-jobs", request.RelativePath, "fixed creation route"); Equal("POST", request.Method, "fixed creation method");
                True(request.ResourceId == Job && request.ServerIdempotencyKey == Job && request.ServerIdempotencyBodyField == "id"
                    && request.RequestIdBodyField == null && request.RequestId != Job, "server job ID is distinct from local correlation UUID");
                True(request.ServerIdempotencyAvailable && request.ReceiptStrategy == MutationReceiptStrategy.ExportJobCreation && request.ContractVersion == 3, "real server idempotency is action-specific");
                f.Post = async (message, ct) => { Equal(body, await message.Content.ReadAsStringAsync(), "filter JSON string and request original remain exact"); return Json(View(body)); };
                var result = await f.Session.MutateAsync(request, CancellationToken.None);
                True(result.Outcome == MutationOutcome.Confirmed && result.IsDurablyRecorded && result.ExportJob.Id == Job, "known submit result");
                foreach (var bad in new[] { body.Replace("\"master\"", "\"sales\""), body.Replace("\"unit\"", "\"goods\""), body.Replace("\"xlsx\"", "\"pdf\""),
                    body.Replace("\"columnProjection\":null", "\"columnProjection\":{}"), body.Replace("\"sort\":null", "\"sort\":\"name\""),
                    body.Replace("\"parameters\":{", "\"password\":\"secret\",\"parameters\":{") }) ThrowsApi(() => f.Submit(bad));
                ThrowsApi(() => f.Submit(SubmitBody("{\"password\":\"secret\"}")));
                ThrowsApi(() => f.Submit(SubmitBody("{\"token\":\"secret\"}")));
                ThrowsApi(() => f.Submit(SubmitBody("{\"nullFields\":[\"legacyId\"]}")));
                ThrowsApi(() => f.Session.PrepareMutation(MutationAction.UnitExportSubmit, NewId(), body, f.Owner(), Other));
                var path = Directory.GetFiles(f.State.RootDirectory, "mutations.dpapi", SearchOption.AllDirectories).Single();
                var plain = Unprotect(path);
                foreach (var forbidden in new[] { "\"password\"", "fixture-password", "access-fixture", "refresh-fixture" })
                    True(!plain.Contains(forbidden), "no auth material in durable export command");
            }
            using (var f = new Fixture()) { f.Permissions = new[] { "unit:view" }; await f.Login(); ThrowsCode("FORBIDDEN", () => f.Submit(SubmitBody())); }
        }
        private static async Task CancelNoBodyAndActualJobState()
        {
            foreach (var body in new[] { null, "", "{}" })
            using (var f = new Fixture())
            {
                await f.Login(); var request = f.Session.PrepareMutation(MutationAction.UnitExportCancel, NewId(), body, f.Owner(), Job);
                True(!request.ServerIdempotencyAvailable && request.ReceiptStrategy == MutationReceiptStrategy.ExportJobStateQuery, "cancel is a state query, not a creation receipt");
                f.Post = async (message, ct) =>
                {
                    if (body == null) True(message.Content == null, "no-body caller remains a genuinely body-free request");
                    else Equal(body, await message.Content.ReadAsStringAsync(), "explicit empty/object body retains presence");
                    return Json(View(null, "SUCCEEDED"));
                };
                var result = await f.Session.MutateAsync(request, CancellationToken.None);
                True(result.Outcome == MutationOutcome.Confirmed && result.ExportJob.Status == "SUCCEEDED" && !result.ExportJob.CancelRequested,
                    "known cancel response can report already-finished job, never fake cancelled");
                Equal(body, (await f.Session.LoadMutationJournalAsync(request.RequestId, f.Owner(), CancellationToken.None)).BodyJson, "no body is not converted into JSON null/object");
                await ExpectCode("EXPORT_RECEIPT_NOT_APPLICABLE", () => f.Session.ReconcileUnitExportAsync(request.RequestId, f.Owner(), CancellationToken.None));
                Equal(0, f.Gets, "creation-only receipt helper rejects cancel without HTTP");
            }
        }
        private static async Task KnownJobAcceptanceIsNotFileDelivery()
        {
            foreach (var state in new[] { "PENDING", "RUNNING", "SUCCEEDED", "FAILED", "CANCELLED", "EXPIRED" })
            using (var f = new Fixture())
            {
                await f.Login(); f.Post = (message, ct) => Ready(Json(View(null, state)));
                var result = await f.Session.MutateAsync(f.Submit(SubmitBody()), CancellationToken.None);
                True(result.Outcome == MutationOutcome.Confirmed && result.ExportJob.Status == state && !result.ExportJob.HasCreationRequestProof,
                    "accepted command and current worker/file state are separate " + state);
                Equal(1, f.Posts, "one creation request");
            }
            foreach (var bad in new[] { View(null).Replace(Job, Other), View(null).Replace("\"unit\"", "\"goods\""),
                View(null).Replace("\"rows\":0", "\"rows\":0.0"), View(null).Replace("\"cancelRequested\":false", "\"cancelRequested\":\"false\"") })
            using (var f = new Fixture())
            { await f.Login(); f.Post = (message, ct) => Ready(Json(bad)); Equal(MutationOutcome.Unknown, (await f.Session.MutateAsync(f.Submit(SubmitBody()), CancellationToken.None)).Outcome, "bad JobView is not a receipt"); }
        }
        private static async Task ServerKeyCannotChangeFrozenBody()
        {
            using (var f = new Fixture())
            {
                await f.Login(); f.Post = (message, ct) => { throw new HttpRequestException("fixture reply lost"); };
                var original = f.Submit(SubmitBody()); await f.Session.MutateAsync(original, CancellationToken.None);
                var edited = await f.Session.MutateAsync(f.Submit(SubmitBody("{\"keyword\":\"new\"}")), CancellationToken.None);
                True(edited.Outcome == MutationOutcome.NotSent && edited.Error.Code == "MUTATION_SERVER_KEY_CHANGED", "new local UUID cannot change existing server key intent");
                Equal(1, f.Posts, "changed key payload never reaches server");
                Equal(original.BodyJson, (await f.Session.LoadMutationJournalAsync(original.RequestId, f.Owner(), CancellationToken.None)).BodyJson, "original frozen payload survives");
            }
        }
        private static async Task VerifiedGetRequestProofSettlesOnlyOriginalSubmit()
        {
            using (var f = new Fixture())
            {
                await f.Login(); var body = SubmitBody(); f.Post = (message, ct) => { throw new HttpRequestException("fixture accepted but reply lost"); };
                var original = f.Submit(body); var uncertain = await f.Session.MutateAsync(original, CancellationToken.None);
                True(uncertain.Outcome == MutationOutcome.Unknown && uncertain.NeedsReceiptQuery, "lookup supported without automatic write replay");
                // The server normalizes absent/null optional DTO fields. The filter STRING
                // itself stays exact: parsed object equality is intentionally insufficient.
                var proof = body.Replace(",\"format\":\"xlsx\"", "").Replace(",\"sort\":null", "").Replace(",\"order\":null", "").Replace(",\"columnProjection\":null", "");
                f.Get = (message, ct) => Ready(Json(View(proof, "RUNNING", 9007199254740993L)));
                var confirmed = await f.Session.ReconcileUnitExportAsync(original.RequestId, f.Owner(), CancellationToken.None);
                True(confirmed.Outcome == MutationOutcome.Confirmed && confirmed.ConfirmedByReceiptQuery && confirmed.IsDurablyRecorded,
                    "server-owned original request proves the matching logical creation");
                Equal(9007199254740993L, confirmed.ExportJob.Bytes, "Int64 metadata not rounded");
                var saved = await f.Session.LoadMutationJournalAsync(original.RequestId, f.Owner(), CancellationToken.None);
                True(saved.State == MutationJournalState.Confirmed && saved.ConfirmedByReceiptQuery && saved.ReceiptStrategy == MutationReceiptStrategy.ExportJobCreation,
                    "only original matching journal settled by receipt");
                Equal(body, saved.BodyJson, "proof never replaces original raw request"); Equal(1, f.Posts, "receipt lookup emits no POST"); Equal(1, f.Gets, "one fixed GET");
                var again = await f.Session.ReconcileUnitExportAsync(original.RequestId, f.Owner(), CancellationToken.None);
                True(again.Outcome == MutationOutcome.Confirmed && f.Gets == 1, "durable known result does not query/replay again");
            }
        }
        private static async Task MissingOrDifferentProofStaysUnknown()
        {
            foreach (var mode in new[] { "absent", "null", "filter", "id", "404" })
            using (var f = new Fixture())
            {
                await f.Login(); var body = SubmitBody(); f.Post = (message, ct) => { throw new HttpRequestException("fixture lost"); };
                var original = f.Submit(body); await f.Session.MutateAsync(original, CancellationToken.None);
                f.Get = (message, ct) => Ready(mode == "404" ? Json("{\"code\":\"NOT_FOUND\",\"message\":\"fixture\"}", 404)
                    : Json(mode == "absent" ? View(null) : mode == "null" ? View(null).TrimEnd('}') + ",\"request\":null}"
                    : View(mode == "id" ? body.Replace(Job, Other) : SubmitBody("{\"keyword\":\"other\"}"))));
                var result = await f.Session.ReconcileUnitExportAsync(original.RequestId, f.Owner(), CancellationToken.None);
                True(result.Outcome == MutationOutcome.Unknown && result.ResponseJson == null && result.IsDurablyRecorded, "unverified proof stays durably unknown " + mode);
                Equal(MutationJournalState.Unknown, (await f.Session.LoadMutationJournalAsync(original.RequestId, f.Owner(), CancellationToken.None)).State, "GET metadata alone cannot claim accepted original");
                Equal(1, f.Posts, "no hidden re-submit");
            }
        }
        private static async Task ExplicitSameKeyRetryNeverCreatesNewIdentity()
        {
            using (var f = new Fixture())
            {
                await f.Login(); var body = SubmitBody(); var created = false; var actualCreations = 0;
                f.Post = async (message, ct) =>
                {
                    Equal(body, await message.Content.ReadAsStringAsync(), "explicit idempotent retry is the complete same frozen payload");
                    if (!created) { created = true; actualCreations++; throw new HttpRequestException("fixture committed then disconnected"); }
                    return Json(View(null));
                };
                var original = f.Submit(body); await f.Session.MutateAsync(original, CancellationToken.None);
                var retry = f.Submit(original.BodyJson);
                True(retry.RequestId != original.RequestId && retry.ServerIdempotencyKey == original.ServerIdempotencyKey, "new explicit attempt keeps original server command identity");
                Equal(MutationOutcome.Confirmed, (await f.Session.MutateAsync(retry, CancellationToken.None)).Outcome, "explicit old-server retry verifies via submit body equality");
                Equal(1, actualCreations, "true server idempotency creates one job"); Equal(2, f.Posts, "exactly two human-controlled calls, no automatic loop");
            }
        }
        private static async Task ReceiptPersistenceFailureKeepsKnownOutcome()
        {
            var fail = false;
            using (var state = new BusinessStateTestFixture(point => { if (fail && point == "mutations:before-replace") throw new IOException("fixture receipt storage failure"); }))
            using (var f = new Fixture(state.Store))
            {
                await f.Login(); var body = SubmitBody(); f.Post = (message, ct) => { throw new HttpRequestException("fixture lost"); };
                var original = f.Submit(body); await f.Session.MutateAsync(original, CancellationToken.None);
                f.Get = (message, ct) => Ready(Json(View(body))); fail = true;
                var known = await f.Session.ReconcileUnitExportAsync(original.RequestId, f.Owner(), CancellationToken.None);
                True(known.Outcome == MutationOutcome.Confirmed && !known.IsDurablyRecorded && known.PersistenceError != null && known.ExportJob.Id == Job,
                    "valid remote proof stays known when local commit fails");
                fail = false;
                Equal(MutationJournalState.Unknown, (await f.Session.LoadMutationJournalAsync(original.RequestId, f.Owner(), CancellationToken.None)).State, "failed local receipt commit preserves original unknown bytes");
                Equal(1, f.Posts, "local failure never replays creation");
            }
        }
        private static async Task LateReceiptCannotEnterNewOwner()
        {
            using (var f = new Fixture())
            {
                await f.Login(); var body = SubmitBody(); f.Post = (message, ct) => { throw new HttpRequestException("fixture lost"); };
                var original = f.Submit(body); await f.Session.MutateAsync(original, CancellationToken.None); var owner = f.Owner();
                var entered = new TaskCompletionSource<bool>(); var release = new TaskCompletionSource<HttpResponseMessage>();
                f.Get = (message, ct) => { entered.SetResult(true); return release.Task; };
                var pending = f.Session.ReconcileUnitExportAsync(original.RequestId, owner, CancellationToken.None); await entered.Task;
                f.Session.SelectEndpoint("cloud"); release.SetResult(Json(View(body)));
                await ExpectAnyApi(() => pending);
                Equal(MutationJournalState.Unknown, f.Store.LoadJournal(owner, original.RequestId).State, "old proof does not settle into replacement context");
                Equal(1, f.Posts, "no late cross-origin write");
            }
        }
        private static async Task CorruptReceiptMetadataFailsClosed()
        {
            using (var f = new Fixture())
            {
                await f.Login(); var body = SubmitBody(); f.Post = (message, ct) => Ready(Json(View(body)));
                await f.Session.MutateAsync(f.Submit(body), CancellationToken.None);
                var file = Directory.GetFiles(f.State.RootDirectory, "mutations.dpapi", SearchOption.AllDirectories).Single();
                var document = JsonValue.ParseObject(Unprotect(file)); var entry = (Dictionary<string, object>)((object[])document["entries"])[0];
                entry["serverIdempotencyKey"] = Other;
                Protect(file, JsonValue.Serialize(document)); var before = File.ReadAllBytes(file);
                await ExpectCode("LOCAL_BUSINESS_STORAGE", () => f.Session.ListMutationJournalAsync(f.Owner(), CancellationToken.None));
                True(before.SequenceEqual(File.ReadAllBytes(file)), "tampered server key is not silently repaired"); Equal(1, f.Posts, "corruption never triggers POST");
            }
        }
        private static void PureMetadataParserDoesNotTreatPresenceAsProof()
        {
            var unit = View(SubmitBody(), "RUNNING", 9007199254740993L);
            var metadata = SessionCoordinator.ParseUnitExportJob(unit, Job);
            True(metadata.Id == Job && metadata.Bytes == 9007199254740993L && !metadata.HasCreationRequestProof,
                "metadata-only parser preserves Int64 without treating request presence as verified receipt");
            var foreign = View(null).Replace("\"master\"", "\"sales\"").Replace(Job, Other);
            var recent = SessionCoordinator.ParseRecentUnitExportJobs("[" + foreign + "," + unit + "]");
            True(recent.Count == 1 && recent[0].Id == Job && !recent[0].HasCreationRequestProof, "recent filters other reports and never fabricates proof");
            ThrowsFormat(() => SessionCoordinator.ParseUnitExportJob(unit, Other));
            ThrowsFormat(() => SessionCoordinator.ParseRecentUnitExportJobs("[" + unit + "," + unit + "]"));
            ThrowsFormat(() => SessionCoordinator.ParseUnitExportJob(unit.Replace(Job, "not-a-uuid"), Job));
        }
        private static string SubmitBody(string filter = Filter)
        { return "{\"id\":\"" + Job + "\",\"domain\":\"master\",\"report\":\"unit\",\"format\":\"xlsx\",\"parameters\":{\"filter\":" + JsonValue.Serialize(filter) + "},\"sort\":null,\"order\":null,\"columnProjection\":null}"; }
        private static string View(string proof, string status = "PENDING", long bytes = 0)
        { return "{\"id\":\"" + Job + "\",\"domain\":\"master\",\"report\":\"unit\",\"format\":\"xlsx\",\"status\":\"" + status + "\",\"cancelRequested\":false,\"rows\":0,\"bytes\":" + bytes
            + ",\"snapshotAt\":null,\"error\":null,\"createdAt\":\"2026-10-28T12:00:00+08:00\",\"finishedAt\":null" + (proof == null ? "" : ",\"request\":" + proof) + "}"; }
        private static string NewId() { return Guid.NewGuid().ToString("D"); }
        private static HttpResponseMessage Json(string json, int status = 200) { return new HttpResponseMessage((HttpStatusCode)status) { Content = new StringContent(json, Encoding.UTF8, "application/json") }; }
        private static Task<HttpResponseMessage> Ready(HttpResponseMessage value) { return Task.FromResult(value); }
        private static byte[] Entropy(string file) { return Encoding.UTF8.GetBytes("Uten/UIMP-Win7-WPF/business-state/v1/mutations/" + Path.GetFileName(Path.GetDirectoryName(file))); }
        private static string Unprotect(string file) { var plain = ProtectedData.Unprotect(File.ReadAllBytes(file), Entropy(file), DataProtectionScope.CurrentUser); try { return Encoding.UTF8.GetString(plain); } finally { Array.Clear(plain, 0, plain.Length); } }
        private static void Protect(string file, string value) { var plain = Encoding.UTF8.GetBytes(value); try { File.WriteAllBytes(file, ProtectedData.Protect(plain, Entropy(file), DataProtectionScope.CurrentUser)); } finally { Array.Clear(plain, 0, plain.Length); } }
        private static void True(bool condition, string label) { if (!condition) throw new InvalidOperationException("Unit export mutation: " + label); }
        private static void Equal<T>(T expected, T actual, string label) { True(EqualityComparer<T>.Default.Equals(expected, actual), label); }
        private static void ThrowsApi(Action action) { try { action(); } catch (ApiException) { return; } throw new InvalidOperationException("Expected API failure"); }
        private static void ThrowsFormat(Action action) { try { action(); } catch (FormatException) { return; } throw new InvalidOperationException("Expected malformed metadata rejection"); }
        private static void ThrowsCode(string code, Action action) { try { action(); } catch (ApiException e) { Equal(code, e.Code, "expected failure"); return; } throw new InvalidOperationException("Expected " + code); }
        private static async Task ExpectCode(string code, Func<Task> action) { try { await action(); } catch (ApiException e) { Equal(code, e.Code, "expected failure"); return; } throw new InvalidOperationException("Expected " + code); }
        private static async Task ExpectAnyApi(Func<Task> action) { try { await action(); } catch (ApiException) { return; } throw new InvalidOperationException("Expected API failure"); }
        private sealed class Fixture : IDisposable
        {
            internal readonly BusinessStateTestFixture State;
            internal readonly IBusinessStateStore Store;
            internal readonly SessionCoordinator Session;
            internal string[] Permissions = { "unit:view", "unit:export" };
            internal int Posts, Gets;
            internal Func<HttpRequestMessage, CancellationToken, Task<HttpResponseMessage>> Post, Get;
            internal Fixture() : this(null, true) { }
            internal Fixture(IBusinessStateStore store) : this(store, false) { }
            private Fixture(IBusinessStateStore store, bool owned)
            {
                if (owned) { State = new BusinessStateTestFixture(); store = State.Store; } Store = store;
                var config = new ClientConfiguration(new[] { new ServerEndpoint("company", "private fixture", "https://company.example.test/api"),
                    new ServerEndpoint("cloud", "private cloud fixture", "https://cloud.example.test/api") }, "company", 5);
                Session = new SessionCoordinator(config, new Handler((message, ct) =>
                {
                    if (message.RequestUri.AbsolutePath == "/api/auth/login" || message.RequestUri.AbsolutePath == "/api/auth/refresh")
                        return Ready(Json("{\"accessToken\":\"access-fixture\",\"refreshToken\":\"refresh-fixture\",\"expiresIn\":900,\"user\":{\"id\":\"unit-export-core-owner\",\"loginAccount\":\"UT0001\",\"superAdmin\":false,\"mustChangePassword\":false,\"permissions\":"
                            + JsonValue.Serialize(Permissions) + ",\"businessDatasetId\":\"11111111-1111-1111-1111-111111111111\",\"businessResetGeneration\":0}}"));
                    if (message.RequestUri.AbsolutePath == "/api/auth/logout") return Ready(Json("", 204));
                    True(message.RequestUri.Host == "company.example.test" && !message.Headers.Contains(StepUpGrant.HeaderName), "only original fixed issuer, no password/token headers");
                    if (message.Method == HttpMethod.Get)
                    { Interlocked.Increment(ref Gets); Equal("/api/report-export-jobs/" + Job, message.RequestUri.AbsolutePath, "fixed receipt GET"); return Get == null ? Ready(Json(View(null))) : Get(message, ct); }
                    Interlocked.Increment(ref Posts);
                    True(message.Method == HttpMethod.Post && (message.RequestUri.AbsolutePath == "/api/report-export-jobs" || message.RequestUri.AbsolutePath == "/api/report-export-jobs/" + Job + "/cancel"), "fixed creation/cancel routes only");
                    return Post == null ? Ready(Json(View(null))) : Post(message, ct);
                }), new AuthStore(), store);
            }
            internal Task Login() { return Session.LoginAsync("fixture", "fixture-password", CancellationToken.None); }
            internal MutationOwnerSnapshot Owner() { return Session.CaptureMutationOwner(); }
            internal MutationRequest Submit(string body) { return Session.PrepareMutation(MutationAction.UnitExportSubmit, NewId(), body, Owner()); }
            public void Dispose() { Session.Dispose(); State?.Dispose(); }
        }
        private sealed class Handler : HttpMessageHandler
        {
            private readonly Func<HttpRequestMessage, CancellationToken, Task<HttpResponseMessage>> action;
            internal Handler(Func<HttpRequestMessage, CancellationToken, Task<HttpResponseMessage>> action) { this.action = action; }
            protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken ct) { return action(request, ct); }
        }
        private sealed class AuthStore : ISessionStore
        {
            private StoredSession active; private readonly List<StoredSession> pending = new List<StoredSession>();
            public StoredSession Load() { return active; } public void Save(StoredSession value) { active = value; } public void Clear() { active = null; }
            public void EndSession(StoredSession value) { EnqueueRevocation(value ?? active); active = null; }
            public void EnqueueRevocation(StoredSession value) { if (value != null && !pending.Any(item => item.Id == value.Id)) pending.Add(value); }
            public IList<StoredSession> PendingRevocations() { return pending.ToList(); } public void AcknowledgeRevocation(string id) { pending.RemoveAll(value => value.Id == id); }
        }
    }
}
