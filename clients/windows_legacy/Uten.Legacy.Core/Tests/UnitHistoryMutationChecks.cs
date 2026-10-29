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
    public static class UnitHistoryMutationChecks
    {
        private const string Operation = "55555555-5555-5555-5555-555555555555";
        private const string Other = "66666666-6666-6666-6666-666666666666";
        private const string HistoryId = "9007199254740993";
        private const long Version = 9007199254740995L;
        private const string Head = "9007199254740993:9223372036854775807";
        private static readonly string ReplayBody = " { \"expectedVersion\" : " + Version + " } ";
        private const string RestoreBody = " { \"before\":false,\"expectedHead\":\"" + Head + "\" } ";
        public static void Run()
        {
            PreciseCommandAndPermissionContracts().GetAwaiter().GetResult();
            KnownHistoryAndVoidRestorePersist().GetAwaiter().GetResult();
            InvalidHistoryCannotConfirm().GetAwaiter().GetResult();
            NoReplayForRejectionOrServerError().GetAwaiter().GetResult();
            CancellationAndLateOwnerRemainUnknown().GetAwaiter().GetResult();
            PendingHistoryBlocksNewIdsAcrossTargetsAndStores().GetAwaiter().GetResult();
            ConfirmedHistoryLocalFailureNeverMeansNotSent().GetAwaiter().GetResult();
            CorruptHistoryEvidenceFailsClosed().GetAwaiter().GetResult();
            Int64BoundaryAndVoidResponseShape().GetAwaiter().GetResult();
        }
        private static async Task PreciseCommandAndPermissionContracts()
        {
            using (var f = new Fixture())
            {
                f.Permissions = new[] { "unit:view", "unit:status" }; await f.Login();
                var request = f.Prepare(MutationAction.UnitUndo, ReplayBody, Operation);
                Equal("POST", request.Method, "undo method"); Equal("master/operation-history/" + Operation + "/undo?entityType=units", request.RelativePath, "fixed units-only route");
                Equal(ReplayBody, request.BodyJson, "Int64 version stays verbatim"); Equal(Version.ToString(), request.ExpectedVersionJson, "original version token retained");
                True(request.EnforcesExpectedVersion && request.VersionStrategy == MutationVersionStrategy.OperationVersion
                    && !request.ServerIdempotencyAvailable && !request.RequiresStepUp, "operation concurrency is not a receipt or invented step-up");
                True(request.RequiredPermissions.SequenceEqual(new[] { "unit:view" }), "status-only original actor is not forced to have edit");
                ThrowsCode("FORBIDDEN", () => f.Prepare(MutationAction.UnitRecordRestore, RestoreBody, HistoryId));
                foreach (var bad in new[] { "{}", "{\"expectedVersion\":null}", "{\"expectedVersion\":1.0}", "{\"expectedVersion\":\"1\"}",
                    "{\"expectedVersion\":-1}", "{\"expectedVersion\":9223372036854775808}", "{\"expectedVersion\":1,\"password\":\"secret\"}" })
                    ThrowsApi(() => f.Prepare(MutationAction.UnitUndo, bad, Operation));
                foreach (var id in new[] { "../users", Operation + "?entityType=goods", HistoryId }) ThrowsApi(() => f.Prepare(MutationAction.UnitRedo, ReplayBody, id));
            }
            using (var f = new Fixture())
            {
                await f.Login(); var request = f.Prepare(MutationAction.UnitRecordRestore, RestoreBody, HistoryId);
                Equal("master/record-history/" + HistoryId + "/restore?entityType=units", request.RelativePath, "positive Int64 path without Double conversion");
                Equal(Head, request.ExpectedHead, "head remains opaque text");
                True(request.EnforcesExpectedHead && !request.EnforcesExpectedVersion && request.ResponseKind == MutationResponseKind.Empty, "opaque head and empty response separate from UnitDetail");
                foreach (var id in new[] { "0", "01", "-1", "9223372036854775808", HistoryId + "/../users" }) ThrowsApi(() => f.Prepare(MutationAction.UnitRecordRestore, RestoreBody, id));
                foreach (var body in new[] { "{\"expectedHead\":1,\"before\":true}", "{\"expectedHead\":\"x\",\"before\":null}",
                    "{\"expectedHead\":\"x\",\"before\":\"true\"}", "{\"expectedHead\":\"x\"}", "{\"expectedHead\":\"\",\"before\":false}" })
                    ThrowsApi(() => f.Prepare(MutationAction.UnitRecordRestore, body, HistoryId));
                ThrowsApi(() => f.Session.CreateDraftLease(MutationAction.UnitUndo, Guid.NewGuid().ToString("D"), f.Owner(), Operation));
            }
        }
        private static async Task KnownHistoryAndVoidRestorePersist()
        {
            using (var f = new Fixture())
            {
                await f.Login();
                foreach (var action in new[] { MutationAction.UnitUndo, MutationAction.UnitRedo })
                {
                    var expected = action == MutationAction.UnitUndo ? Version : Version + 1;
                    var body = ReplayBody.Replace(Version.ToString(), expected.ToString());
                    var request = f.Prepare(action, body, Operation);
                    var response = History(action == MutationAction.UnitUndo, expected + 1);
                    f.Business = async (message, ct) => { Equal(body, await message.Content.ReadAsStringAsync(), "wire body immutable"); return Json(response); };
                    var result = await f.Session.MutateAsync(request, CancellationToken.None);
                    True(result.Outcome == MutationOutcome.Confirmed && result.IsDurablyRecorded && result.ResponseKind == MutationResponseKind.OperationHistory, "real history response confirmed");
                    Equal(response, result.ResponseJson, "history response not normalized through numbers");
                    var record = await f.Session.LoadMutationJournalAsync(request.RequestId, f.Owner(), CancellationToken.None);
                    Equal(response, record.ResultJson, "confirmed original history response retained");
                    Equal(expected.ToString(), record.ExpectedVersionJson, "operation version recoverable exactly");
                    True(record.ConfirmedResourceId == null && record.EnforcesExpectedVersion && !record.ServerIdempotencyAvailable, "no fabricated Unit UUID or receipt");
                }
                f.Business = (message, ct) => Ready(Json(""));
                var restore = f.Prepare(MutationAction.UnitRecordRestore, RestoreBody, HistoryId);
                var restored = await f.Session.MutateAsync(restore, CancellationToken.None);
                True(restored.Outcome == MutationOutcome.Confirmed && restored.IsDurablyRecorded && restored.ResponseJson == "", "void 200 is a real success shape");
                var entry = await f.Session.LoadMutationJournalAsync(restore.RequestId, f.Owner(), CancellationToken.None);
                True(entry.State == MutationJournalState.Confirmed && entry.ConfirmedResourceId == null && entry.ResultJson == null && entry.ExpectedHead == Head, "empty restore stored with exact original head");
                Equal(3, f.Writes, "one call per explicit action");
            }
        }
        private static async Task InvalidHistoryCannotConfirm()
        {
            var valid = History(true, Version + 1);
            foreach (var malformed in new[] { "{\"entries\":[],\"events\":[]}", valid.Replace(Operation, Other),
                valid.Replace((Version + 1).ToString(), Version.ToString()), valid.Replace("UNDONE", "APPLIED"),
                valid.Replace("\"canRedo\":true", "\"canRedo\":\"true\""), valid.Replace("\"version\":" + (Version + 1), "\"version\":1.5"),
                valid.Replace("\"events\":[", "\"accessToken\":\"forbidden\",\"events\":[") })
            using (var f = new Fixture())
            {
                await f.Login(); f.Business = (message, ct) => Ready(Json(malformed));
                var result = await f.Session.MutateAsync(f.Prepare(MutationAction.UnitUndo, ReplayBody, Operation), CancellationToken.None);
                True(result.Outcome == MutationOutcome.Unknown && result.ResponseJson == null && result.IsDurablyRecorded, "unrelated or malformed success stays unknown");
                Equal(MutationJournalState.Unknown, (await f.Session.LoadMutationJournalAsync(result.Request.RequestId, f.Owner(), CancellationToken.None)).State, "unknown response never persisted as success");
            }
        }
        private static async Task NoReplayForRejectionOrServerError()
        {
            foreach (var status in new[] { 401, 403, 500 })
            using (var f = new Fixture())
            {
                await f.Login(); var code = status == 401 ? "UNAUTHORIZED" : status == 403 ? "REAUTH_REQUIRED" : "INTERNAL_ERROR";
                f.Business = (message, ct) => Ready(Json("{\"code\":\"" + code + "\",\"message\":\"fixture\"}", status));
                var request = f.Prepare(MutationAction.UnitRecordRestore, RestoreBody, HistoryId);
                var result = await f.Session.MutateAsync(request, CancellationToken.None);
                Equal(status == 500 ? MutationOutcome.Unknown : MutationOutcome.Rejected, result.Outcome, "structured failure classification");
                await ExpectCode("MUTATION_ALREADY_ATTEMPTED", () => f.Session.MutateAsync(request, CancellationToken.None));
                Equal(1, f.Writes, "no history replay"); Equal(0, f.Refreshes, "no automatic 401 refresh-and-resend");
            }
        }
        private static async Task CancellationAndLateOwnerRemainUnknown()
        {
            foreach (var retire in new[] { false, true })
            using (var f = new Fixture())
            using (var cancellation = new CancellationTokenSource())
            {
                await f.Login(); var entered = new TaskCompletionSource<bool>(); var response = new TaskCompletionSource<HttpResponseMessage>();
                f.Business = (message, ct) => { entered.SetResult(true); return response.Task; };
                var request = f.Prepare(MutationAction.UnitUndo, ReplayBody, Operation);
                var pending = f.Session.MutateAsync(request, cancellation.Token); await entered.Task;
                if (retire) f.Session.SelectEndpoint("cloud"); else cancellation.Cancel();
                response.SetResult(Json(History(true, Version + 1)));
                var result = await pending;
                True(result.Outcome == MutationOutcome.Unknown && result.ResponseJson == null && result.IsDurablyRecorded, "late owner or cancellation cannot deliver old data");
                Equal(1, f.Writes, "no second history submission");
            }
        }
        private static async Task PendingHistoryBlocksNewIdsAcrossTargetsAndStores()
        {
            using (var f = new Fixture())
            {
                await f.Login(); f.Business = (message, ct) => { throw new HttpRequestException("fixture lost response"); };
                var original = f.Prepare(MutationAction.UnitUndo, ReplayBody, Operation);
                Equal(MutationOutcome.Unknown, (await f.Session.MutateAsync(original, CancellationToken.None)).Outcome, "unknown original history");
                using (var second = new Fixture(new DpapiBusinessStateStore(f.State.RootDirectory)))
                {
                    await second.Login();
                    foreach (var request in new[] { second.Prepare(MutationAction.UnitRedo, ReplayBody, Operation),
                        second.Prepare(MutationAction.UnitUndo, ReplayBody, Other), second.Prepare(MutationAction.UnitRecordRestore, RestoreBody, HistoryId) })
                    {
                        var blocked = await second.Session.MutateAsync(request, CancellationToken.None);
                        True(blocked.Outcome == MutationOutcome.NotSent && blocked.NeedsManualReconciliation, "new ID/direction/target cannot bypass multi-row history uncertainty");
                    }
                    Equal(0, second.Writes, "same owner durable history gate precedes HTTP");
                    var old = await second.Session.LoadMutationJournalAsync(original.RequestId, second.Owner(), CancellationToken.None);
                    Equal(ReplayBody, old.BodyJson, "all blocked attempts preserve the original frozen intent");
                }
            }
        }
        private static async Task ConfirmedHistoryLocalFailureNeverMeansNotSent()
        {
            var writes = 0;
            using (var state = new BusinessStateTestFixture(point => { if (point == "mutations:before-replace" && ++writes == 2) throw new IOException("fixture local failure"); }))
            using (var f = new Fixture(state.Store))
            {
                await f.Login(); f.Business = (message, ct) => Ready(Json(History(true, Version + 1)));
                var result = await f.Session.MutateAsync(f.Prepare(MutationAction.UnitUndo, ReplayBody, Operation), CancellationToken.None);
                True(result.Outcome == MutationOutcome.Confirmed && result.ResponseJson != null && !result.IsDurablyRecorded && result.PersistenceError != null, "known success survives terminal disk failure");
                Equal(MutationJournalState.Unknown, (await f.Session.LoadMutationJournalAsync(result.Request.RequestId, f.Owner(), CancellationToken.None)).State, "original Sending recovers Unknown");
                var next = await f.Session.MutateAsync(f.Prepare(MutationAction.UnitRecordRestore, RestoreBody, HistoryId), CancellationToken.None);
                True(next.Outcome == MutationOutcome.NotSent && f.Writes == 1, "terminal save failure never causes a new history write");
            }
        }
        private static async Task CorruptHistoryEvidenceFailsClosed()
        {
            using (var f = new Fixture())
            {
                await f.Login(); f.Business = (message, ct) => Ready(Json(History(true, Version + 1)));
                await f.Session.MutateAsync(f.Prepare(MutationAction.UnitUndo, ReplayBody, Operation), CancellationToken.None);
                var file = Directory.GetFiles(f.State.RootDirectory, "mutations.dpapi", SearchOption.AllDirectories).Single();
                var bytes = ProtectedData.Unprotect(File.ReadAllBytes(file), Entropy(file), DataProtectionScope.CurrentUser);
                Dictionary<string, object> document;
                try { document = JsonValue.ParseObject(Encoding.UTF8.GetString(bytes)); } finally { Array.Clear(bytes, 0, bytes.Length); }
                var item = (Dictionary<string, object>)((object[])document["entries"])[0];
                item["resultJson"] = ((string)item["resultJson"]).Replace((Version + 1).ToString(), Version.ToString());
                bytes = Encoding.UTF8.GetBytes(JsonValue.Serialize(document));
                try { File.WriteAllBytes(file, ProtectedData.Protect(bytes, Entropy(file), DataProtectionScope.CurrentUser)); } finally { Array.Clear(bytes, 0, bytes.Length); }
                var before = File.ReadAllBytes(file);
                await ExpectCode("LOCAL_BUSINESS_STORAGE", () => f.Session.ListMutationJournalAsync(f.Owner(), CancellationToken.None));
                True(before.SequenceEqual(File.ReadAllBytes(file)) && f.Writes == 1, "damaged history is neither overwritten nor replayed");
            }
        }
        private static async Task Int64BoundaryAndVoidResponseShape()
        {
            using (var f = new Fixture())
            {
                await f.Login(); f.Business = (message, ct) => Ready(Json(History(true, Int64.MaxValue)));
                var result = await f.Session.MutateAsync(f.Prepare(MutationAction.UnitUndo, "{\"expectedVersion\":9223372036854775807}", Operation), CancellationToken.None);
                Equal(MutationOutcome.Unknown, result.Outcome, "impossible overflowed version is unknown, never rounded or exception-retried");
            }
            using (var f = new Fixture())
            {
                await f.Login(); f.Business = (message, ct) => Ready(Json("{}"));
                Equal(MutationOutcome.Unknown, (await f.Session.MutateAsync(f.Prepare(MutationAction.UnitRecordRestore, RestoreBody, Int64.MaxValue.ToString()), CancellationToken.None)).Outcome,
                    "restore does not accept an invented UnitDetail or arbitrary JSON success");
            }
        }
        private static string History(bool undone, long version)
        { return "{\"entries\":[{\"id\":\"" + Operation + "\",\"operationType\":\"STATUS\",\"label\":\"单位启停\",\"summary\":\"状态变更\",\"createdAt\":\"2026-10-28T12:00:00+08:00\",\"state\":\""
            + (undone ? "UNDONE" : "APPLIED") + "\",\"version\":" + version + ",\"affectedCount\":1,\"canUndo\":" + (undone ? "false" : "true")
            + ",\"canRedo\":" + (undone ? "true" : "false") + ",\"blockedReason\":null}],\"events\":[{\"id\":\"9007199254740997\",\"operationId\":\"" + Operation
            + "\",\"action\":\"" + (undone ? "UNDO" : "REDO") + "\",\"label\":\"单位启停\",\"createdAt\":\"2026-10-28T12:00:00+08:00\",\"operationType\":\"STATUS\"}]}"; }
        private static HttpResponseMessage Json(string body, int status = 200) { return new HttpResponseMessage((HttpStatusCode)status) { Content = new StringContent(body, Encoding.UTF8, "application/json") }; }
        private static Task<HttpResponseMessage> Ready(HttpResponseMessage value) { return Task.FromResult(value); }
        private static byte[] Entropy(string file) { return Encoding.UTF8.GetBytes("Uten/UIMP-Win7-WPF/business-state/v1/mutations/" + Path.GetFileName(Path.GetDirectoryName(file))); }
        private static void True(bool condition, string message) { if (!condition) throw new InvalidOperationException("Unit history mutation: " + message); }
        private static void Equal<T>(T expected, T actual, string message) { True(EqualityComparer<T>.Default.Equals(expected, actual), message); }
        private static void ThrowsApi(Action action) { try { action(); } catch (ApiException) { return; } throw new InvalidOperationException("Expected API failure"); }
        private static void ThrowsCode(string code, Action action) { try { action(); } catch (ApiException e) { Equal(code, e.Code, "expected code"); return; } throw new InvalidOperationException("Expected " + code); }
        private static async Task ExpectCode(string code, Func<Task> action) { try { await action(); } catch (ApiException e) { Equal(code, e.Code, "expected async code"); return; } throw new InvalidOperationException("Expected " + code); }
        private sealed class Fixture : IDisposable
        {
            internal readonly BusinessStateTestFixture State;
            internal readonly SessionCoordinator Session;
            internal string[] Permissions = { "unit:view", "unit:edit", "unit:status" };
            internal int Writes, Refreshes;
            internal Func<HttpRequestMessage, CancellationToken, Task<HttpResponseMessage>> Business;
            internal Fixture() : this(null, true) { }
            internal Fixture(IBusinessStateStore store) : this(store, false) { }
            private Fixture(IBusinessStateStore store, bool owned)
            {
                if (owned) { State = new BusinessStateTestFixture(); store = State.Store; }
                var config = new ClientConfiguration(new[] { new ServerEndpoint("company", "private fixture", "https://company.example.test/api"),
                    new ServerEndpoint("cloud", "private cloud fixture", "https://cloud.example.test/api") }, "company", 5);
                Session = new SessionCoordinator(config, new Handler((request, ct) =>
                {
                    if (request.RequestUri.AbsolutePath == "/api/auth/login") return Ready(Json("{\"accessToken\":\"access-fixture\",\"refreshToken\":\"refresh-fixture\",\"expiresIn\":900,\"user\":{\"id\":\"unit-history-core\",\"employeeId\":\"" + Other
                        + "\",\"loginAccount\":\"UT0001\",\"superAdmin\":false,\"mustChangePassword\":false,\"permissions\":" + JsonValue.Serialize(Permissions)
                        + ",\"businessDatasetId\":\"11111111-1111-1111-1111-111111111111\",\"businessResetGeneration\":0}}"));
                    if (request.RequestUri.AbsolutePath == "/api/auth/logout") return Ready(Json("", 204));
                    if (request.RequestUri.AbsolutePath == "/api/auth/refresh") Interlocked.Increment(ref Refreshes);
                    Interlocked.Increment(ref Writes);
                    True(request.RequestUri.Host == "company.example.test" && request.RequestUri.Query == "?entityType=units"
                        && !request.Headers.Contains(StepUpGrant.HeaderName), "only original fixed units issuer and no invented step-up");
                    return Business == null ? Ready(Json(History(true, Version + 1))) : Business(request, ct);
                }), new AuthStore(), store);
            }
            internal Task Login() { return Session.LoginAsync("fixture", "fixture-password", null, CancellationToken.None); }
            internal MutationOwnerSnapshot Owner() { return Session.CaptureMutationOwner(); }
            internal MutationRequest Prepare(MutationAction action, string body, string target) { return Session.PrepareMutation(action, Guid.NewGuid().ToString("D"), body, Owner(), target); }
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
