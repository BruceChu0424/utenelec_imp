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
    public static class UnitCommandContractChecks
    {
        private const string A = "22222222-2222-2222-2222-222222222222";
        private const string B = "33333333-3333-3333-3333-333333333333";
        private const string C = "44444444-4444-4444-4444-444444444444";
        private const string Detail = "{\"id\":\"" + A + "\",\"name\":\"kg\",\"status\":\"使用\"}";
        private const string Inline = " { \"expected\":{\"name\":null}, \"changes\":{\"name\":\"kg\"} } ";
        public static void Run()
        {
            InlineAllowlistAndPermissions().GetAwaiter().GetResult();
            BatchRawPrecisionAndIgnoredVersions().GetAwaiter().GetResult();
            FullPartialAndAllFailedResults().GetAwaiter().GetResult();
            IncompleteResultsStayUnknown().GetAwaiter().GetResult();
            NewWritesNeverAutomaticallyReplay().GetAwaiter().GetResult();
            CancellationAndLateOwnerFence().GetAwaiter().GetResult();
            CrossStorePendingTargetOverlap().GetAwaiter().GetResult();
            LegacyV1RecordsAndMixedV2RemainReadable().GetAwaiter().GetResult();
            NestedDraftsRetainPresenceAndRetiredOwner().GetAwaiter().GetResult();
            LargeBatchUsesOnlyItsAuditedWireBudget().GetAwaiter().GetResult();
            ConfirmedPartialSurvivesLocalFailure().GetAwaiter().GetResult();
            CorruptPerItemResultCannotBecomeSuccess().GetAwaiter().GetResult();
        }

        private static async Task InlineAllowlistAndPermissions()
        {
            using (var f = new Fixture())
            {
                await f.Login(); var request = f.Prepare(MutationAction.UnitInlineEdit, Inline, A);
                Equal("PATCH", request.Method, "inline method"); Equal("master/inline-edit/units/" + A, request.RelativePath, "fixed units route");
                Equal(Inline, request.BodyJson, "expected null remains explicit in original wire JSON");
                True(request.EnforcesExpectedValues && !request.EnforcesExpectedVersion && !request.ServerIdempotencyAvailable, "field CAS is distinct from version/receipt");
                Equal(2, request.ContractVersion, "new action version");
                f.Business = async (message, ct) => { Equal(Inline, await message.Content.ReadAsStringAsync(), "inline wire remains original"); return Json(Detail); };
                Equal(MutationOutcome.Confirmed, (await f.Session.MutateAsync(request, CancellationToken.None)).Outcome, "inline returns real UnitDetail");
                foreach (var body in new[] { "{\"expected\":{},\"changes\":{\"name\":\"x\"}}", "{\"expected\":{\"code\":\"a\"},\"changes\":{\"code\":\"b\"}}",
                    "{\"expected\":{\"name\":\"a\",\"name\":null},\"changes\":{\"name\":\"b\"}}", "{\"expected\":{\"name\":null},\"changes\":{\"name\":\"\"}}",
                    "{\"expected\":{\"name\":\"a\",\"password\":\"secret\"},\"changes\":{\"name\":\"b\"}}", "{\"expected\":{},\"changes\":{}}" })
                    ThrowsApi(() => f.Prepare(MutationAction.UnitInlineEdit, body, A));
            }
            using (var editOnly = new Fixture())
            {
                editOnly.Permissions = new[] { "unit:view", "unit:edit" }; await editOnly.Login();
                editOnly.Prepare(MutationAction.UnitInlineEdit, "{\"expected\":{\"status\":\"使用\"},\"changes\":{\"status\":\"使用\"}}", A);
                ThrowsCode("FORBIDDEN", () => editOnly.Prepare(MutationAction.UnitInlineEdit, "{\"expected\":{\"status\":\"使用\"},\"changes\":{\"status\":\"禁用\"}}", A));
            }
            using (var statusOnly = new Fixture())
            {
                statusOnly.Permissions = new[] { "unit:view", "unit:status" }; await statusOnly.Login();
                ThrowsCode("FORBIDDEN", () => statusOnly.Prepare(MutationAction.UnitInlineEdit, Inline, A));
                statusOnly.Prepare(MutationAction.UnitBatchStatus, BatchBody(A));
                ThrowsCode("FORBIDDEN", () => statusOnly.Prepare(MutationAction.UnitBatchDelete, BatchBody(A, null)));
            }
        }

        private static async Task BatchRawPrecisionAndIgnoredVersions()
        {
            var raw = " { \"status\":\"禁用\",\"items\":[{\"id\":\"" + A + "\",\"version\":9007199254740993},{\"id\":\"" + B + "\",\"version\":null}]} ";
            using (var f = new Fixture())
            {
                await f.Login(); var request = f.Prepare(MutationAction.UnitBatchStatus, raw);
                Equal(raw, request.BodyJson, "large Int64 and nullable/omitted versions not rewritten");
                True(request.BatchResourceIds.SequenceEqual(new[] { A, B }) && request.VersionStrategy == MutationVersionStrategy.AcceptedButIgnored
                    && !request.EnforcesExpectedVersion, "unit batch versions accepted but server ignores them");
                f.Business = async (message, ct) => { Equal(raw, await message.Content.ReadAsStringAsync(), "exact nested body sent"); return Json(BatchReply(new[] { A, B })); };
                Equal(MutationOutcome.Confirmed, (await f.Session.MutateAsync(request, CancellationToken.None)).Outcome, "verified complete batch result");
                foreach (var bad in new[] { "{\"status\":\"禁用\",\"items\":[]}", "{\"status\":null,\"items\":[{\"id\":\"" + A + "\"}]}",
                    BatchBody(A).Replace("\"id\"", "\"legacyId\""), BatchBody(A).Replace("\"id\":", "\"password\":\"secret\",\"id\":"),
                    "{\"status\":\"使用\",\"items\":[{\"id\":\"" + A + "\"},{\"id\":\"" + A + "\"}]}",
                    raw.Replace("9007199254740993", "9007199254740993.0"), raw.Replace("9007199254740993", "9223372036854775808") })
                    ThrowsApi(() => f.Prepare(MutationAction.UnitBatchStatus, bad));
                ThrowsApi(() => f.Prepare(MutationAction.UnitBatchDelete, BatchBody(A)));
                ThrowsApi(() => f.Prepare(MutationAction.UnitBatchStatus, BatchBody(A), A));
            }
        }

        private static async Task FullPartialAndAllFailedResults()
        {
            foreach (var failures in new[] { 0, 1, 2 })
            using (var f = new Fixture())
            {
                await f.Login(); var reply = BatchReply(new[] { B, A }, failures);
                f.Business = (message, ct) => Ready(Json(reply));
                var request = f.Prepare(MutationAction.UnitBatchDelete, BatchBody(new[] { A, B }, null));
                var result = await f.Session.MutateAsync(request, CancellationToken.None);
                Equal(MutationOutcome.Confirmed, result.Outcome, "HTTP exchange and each outcome known");
                Equal(2 - failures, result.BatchResult.Succeeded, "actual item successes"); Equal(failures, result.BatchResult.Failed, "actual item failures");
                Equal(failures == 0, result.BatchResult.AllSucceeded, "200 does not imply all items succeeded");
                Equal(failures == 1, result.BatchResult.HasPartialFailure, "mixed outcome distinct from all failed");
                True(result.BatchResult.Items.Select(item => item.Id).SequenceEqual(new[] { B, A }), "server item order and UUID identities retained");
                var stored = await f.Session.LoadMutationJournalAsync(request.RequestId, f.Owner(), CancellationToken.None);
                Equal(reply, stored.ResultJson, "raw full result retained in durable v2 record");
                Equal(failures, stored.BatchResult.Failed, "per-item failures survive journal reload");
                True(result.IsDurablyRecorded && !result.NeedsManualReconciliation && stored.ConfirmedResourceId == null, "known batch never fabricates a UnitDetail id");
                if (failures != 0) True(stored.BatchResult.Items.Any(item => !item.Ok && item.Reason == "被业务引用，未删除"), "human failure reason retained");
            }
        }

        private static async Task IncompleteResultsStayUnknown()
        {
            var valid = BatchReply(new[] { A, B }, 1);
            foreach (var bad in new[] { BatchReply(new[] { A }), valid.Replace(B, C), valid.Replace(B, A),
                valid.Replace("\"succeeded\":1", "\"succeeded\":2"), valid.Replace("\"ok\":false", "\"ok\":\"false\""),
                valid.Replace("被业务引用，未删除", ""), "{\"id\":\"" + A + "\",\"name\":\"not a batch receipt\"}" })
            using (var f = new Fixture())
            {
                await f.Login(); f.Business = (message, ct) => Ready(Json(bad));
                var request = f.Prepare(MutationAction.UnitBatchStatus, BatchBody(new[] { A, B }));
                var result = await f.Session.MutateAsync(request, CancellationToken.None);
                Equal(MutationOutcome.Unknown, result.Outcome, "missing/malformed per-item evidence cannot confirm all rows");
                True(result.BatchResult == null && result.ResponseJson == null && result.NeedsManualReconciliation, "invalid body never delivered as known item success");
                var blocked = await f.Session.MutateAsync(f.Prepare(MutationAction.UnitInlineEdit, Inline, B), CancellationToken.None);
                Equal("MUTATION_PENDING_RECONCILIATION", blocked.Error.Code, "new UUID cannot bypass overlapping unknown batch");
                Equal(1, f.Writes, "uncertain batch not automatically replayed or followed with overlapping edit");
            }
        }

        private static async Task NewWritesNeverAutomaticallyReplay()
        {
            foreach (var code in new[] { "UNAUTHORIZED", "REAUTH_REQUIRED", "INTERNAL_ERROR" })
            using (var f = new Fixture())
            {
                await f.Login(); f.Business = (message, ct) => Ready(Json("{\"code\":\"" + code + "\",\"message\":\"fixture\"}", code == "UNAUTHORIZED" ? 401 : code == "REAUTH_REQUIRED" ? 403 : 500));
                var request = f.Prepare(MutationAction.UnitBatchStatus, BatchBody(A));
                var result = await f.Session.MutateAsync(request, CancellationToken.None);
                Equal(code == "INTERNAL_ERROR" ? MutationOutcome.Unknown : MutationOutcome.Rejected, result.Outcome, "write failure classification");
                await ExpectCode("MUTATION_ALREADY_ATTEMPTED", () => f.Session.MutateAsync(request, CancellationToken.None));
                ThrowsCode("MUTATION_INTENT_CHANGED", () => f.Session.PrepareMutation(request.Action, request.RequestId, BatchBody(B), request.Owner));
                Equal(1, f.Writes, "one dispatch only"); Equal(0, f.Refreshes, "401 does not trigger refresh-and-replay");
            }
        }

        private static async Task CancellationAndLateOwnerFence()
        {
            foreach (var retire in new[] { false, true })
            using (var f = new Fixture())
            using (var cancellation = new CancellationTokenSource())
            {
                await f.Login(); var entered = new TaskCompletionSource<bool>(); var response = new TaskCompletionSource<HttpResponseMessage>();
                f.Business = (message, ct) => { entered.SetResult(true); return response.Task; };
                var request = f.Prepare(MutationAction.UnitBatchDelete, BatchBody(A, null));
                var pending = f.Session.MutateAsync(request, cancellation.Token); await entered.Task;
                if (retire) f.Session.SelectEndpoint("cloud"); else cancellation.Cancel();
                response.SetResult(Json(BatchReply(new[] { A })));
                var result = await pending;
                Equal(MutationOutcome.Unknown, result.Outcome, "sent cancellation/retired owner stays uncertain");
                True(result.ResponseJson == null && result.Request.Owner.IssuerApiBaseUrl.Contains("company.example.test"), "late body cannot enter replacement owner");
                Equal(1, f.Writes, "late write does not replay");
            }
        }

        private static async Task CrossStorePendingTargetOverlap()
        {
            using (var f = new Fixture())
            {
                await f.Login(); var pending = f.Prepare(MutationAction.UnitBatchStatus, BatchBody(new[] { A, B }));
                f.Business = (message, ct) => { throw new HttpRequestException("fixture sent reply lost"); };
                Equal(MutationOutcome.Unknown, (await f.Session.MutateAsync(pending, CancellationToken.None)).Outcome, "original batch uncertain");
                using (var other = new Fixture(new DpapiBusinessStateStore(f.State.RootDirectory)))
                {
                    await other.Login();
                    foreach (var request in new[] { other.Prepare(MutationAction.UnitInlineEdit, Inline, A), other.Prepare(MutationAction.UnitStatus, "{\"status\":\"禁用\"}", B),
                        other.Prepare(MutationAction.UnitUpdate, "{\"name\":\"kg\",\"status\":\"使用\"}", A, "使用"),
                        other.Prepare(MutationAction.UnitBatchDelete, BatchBody(new[] { B, C }, null)) })
                    {
                        var result = await other.Session.MutateAsync(request, CancellationToken.None);
                        True(result.Outcome == MutationOutcome.NotSent && result.NeedsManualReconciliation, "overlap gate is below UI and across store instances");
                    }
                    Equal(0, other.Writes, "no cross-process blind resubmission");
                    var different = other.Prepare(MutationAction.UnitBatchStatus, BatchBody(C));
                    other.Business = (message, ct) => Ready(Json(BatchReply(new[] { C })));
                    Equal(MutationOutcome.Confirmed, (await other.Session.MutateAsync(different, CancellationToken.None)).Outcome, "unrelated explicit target is not globally merged");
                    Equal(1, other.Writes, "one unrelated explicit submission");
                }
            }
        }

        private static async Task LegacyV1RecordsAndMixedV2RemainReadable()
        {
            using (var f = new Fixture())
            {
                await f.Login(); var owner = f.Owner(); var lease = f.Session.CreateDraftLease(MutationAction.UnitCreate, Guid.NewGuid().ToString("D"), owner);
                await f.Session.SaveDraftAsync(lease, 0, "{\"name\":\"legacy\"}", CancellationToken.None);
                var directory = Path.GetDirectoryName(Directory.GetFiles(f.State.RootDirectory, "drafts.dpapi", SearchOption.AllDirectories).Single());
                var legacy = new[] { f.Prepare(MutationAction.UnitCreate, " {\"name\":\"kg\"} "), f.Prepare(MutationAction.UnitUpdate, "{\"name\":\"kg\",\"status\":\"使用\"}", A, "使用"),
                    f.Prepare(MutationAction.UnitStatus, "{\"status\":\"使用\",\"version\":9007199254740993}", A) };
                var records = legacy.Select(LegacyRecord).ToArray();
                var document = new Dictionary<string, object> { ["schema"] = 1, ["owner"] = new Dictionary<string, object> { ["issuer"] = owner.IssuerApiBaseUrl,
                    ["userId"] = owner.UserId, ["datasetId"] = owner.BusinessDatasetId, ["resetGeneration"] = owner.BusinessResetGeneration }, ["entries"] = records };
                var path = Path.Combine(directory, "mutations.dpapi"); Protect(path, JsonValue.Serialize(document));
                Equal(3, (await f.Session.ListMutationJournalAsync(owner, CancellationToken.None)).Count, "three exact old v1 field sets readable");
                var batch = f.Prepare(MutationAction.UnitBatchStatus, BatchBody(B)); f.Business = (message, ct) => Ready(Json(BatchReply(new[] { B })));
                True((await f.Session.MutateAsync(batch, CancellationToken.None)).IsDurablyRecorded, "new v2 can share owner envelope with legacy v1");
                var mixed = await f.Session.ListMutationJournalAsync(owner, CancellationToken.None);
                Equal(4, mixed.Count, "no legacy records lost during v2 append");
                foreach (var old in legacy) { var found = mixed.Single(row => row.RequestId == old.RequestId); Equal(1, found.ContractVersion, "old contract not reinterpreted"); Equal(old.BodyJson, found.BodyJson, "old frozen original remains verbatim"); }
            }
        }

        private static async Task NestedDraftsRetainPresenceAndRetiredOwner()
        {
            using (var f = new Fixture())
            {
                await f.Login(); var owner = f.Owner(); var id = Guid.NewGuid().ToString("D");
                var lease = f.Session.CreateDraftLease(MutationAction.UnitInlineEdit, id, owner, A);
                const string incomplete = " {\"expected\":{\"name\":null},\"changes\":{\"name\":\"\"}} ";
                var draft = await f.Session.SaveDraftAsync(lease, 0, incomplete, CancellationToken.None);
                Equal(2, draft.ContractVersion, "nested draft format identified");
                Equal(incomplete, (await f.Session.LoadDraftAsync(id, owner, CancellationToken.None)).BodyJson, "incomplete CAS input preserves null and raw text");
                await ExpectAnyApi(() => f.Session.PrepareMutationFromDraftAsync(Guid.NewGuid().ToString("D"), id, 1, owner, CancellationToken.None));
                f.Session.SelectEndpoint("cloud");
                var retired = await f.Session.SaveDraftAsync(lease, 1, Inline, CancellationToken.None);
                Equal(owner.IssuerApiBaseUrl, retired.IssuerApiBaseUrl, "retired nested draft stays original namespace");
                Equal(0, f.Writes, "nested local preservation never invokes HTTP");
            }
        }

        private static async Task LargeBatchUsesOnlyItsAuditedWireBudget()
        {
            using (var f = new Fixture())
            {
                await f.Login(); var ids = Enumerable.Range(0, 500).Select(i => Guid.NewGuid().ToString("D")).ToArray();
                var body = "{\"status\":\"使用\",\"items\":[" + String.Join(",", ids.Select(id => "{\"id\":\"" + id + "\",\"version\":9007199254740993}")) + "]}";
                True(Encoding.UTF8.GetByteCount(body) > 16384, "fixture exercises more than old auth budget");
                var command = f.Prepare(MutationAction.UnitBatchStatus, body);
                using (var message = new HttpRequestMessage(HttpMethod.Post, command.Owner.IssuerApiBaseUrl + "/" + command.RelativePath))
                using (var stream = new WireStream())
                {
                    message.Content = new StringContent(body, Encoding.UTF8, "application/json");
                    new MutationWirePermit(command, true, () => { }).Attach(message);
                    using (ManagedHttp11.SendAndReceive(stream, message, 1024, CancellationToken.None)) { }
                    True(stream.Written > Encoding.UTF8.GetByteCount(body), "all 500-item bytes use the same bounded HTTP encoder");
                }
                using (var message = new HttpRequestMessage(HttpMethod.Post, command.Owner.IssuerApiBaseUrl + "/auth/login"))
                using (var stream = new WireStream())
                {
                    message.Content = new StringContent(body, Encoding.UTF8, "application/json");
                    Throws<HttpRequestException>(() => ManagedHttp11.SendAndReceive(stream, message, 1024, CancellationToken.None));
                    Equal(0L, stream.Written, "auth has not inherited the batch budget");
                }
                ThrowsApi(() => f.Prepare(MutationAction.UnitBatchStatus, BatchBody(ids.Concat(new[] { C }))));
            }
        }

        private static async Task ConfirmedPartialSurvivesLocalFailure()
        {
            var writes = 0;
            using (var state = new BusinessStateTestFixture(point => { if (point == "mutations:before-replace" && ++writes == 2) throw new IOException("fixture completion failure"); }))
            using (var f = new Fixture(state.Store))
            {
                await f.Login(); f.Business = (message, ct) => Ready(Json(BatchReply(new[] { A, B }, 1)));
                var result = await f.Session.MutateAsync(f.Prepare(MutationAction.UnitBatchDelete, BatchBody(new[] { A, B }, null)), CancellationToken.None);
                True(result.Outcome == MutationOutcome.Confirmed && result.BatchResult.HasPartialFailure, "known per-item outcomes remain known after disk failure");
                True(!result.IsDurablyRecorded && result.PersistenceError != null, "disk error separate from server outcome");
                Equal(MutationJournalState.Unknown, (await f.Session.LoadMutationJournalAsync(result.Request.RequestId, f.Owner(), CancellationToken.None)).State,
                    "unfinalized original still conservatively recoverable");
                var retry = await f.Session.MutateAsync(f.Prepare(MutationAction.UnitBatchDelete, BatchBody(A, null)), CancellationToken.None);
                Equal("MUTATION_PENDING_RECONCILIATION", retry.Error.Code, "local completion failure cannot cause overlapping re-send"); Equal(1, f.Writes, "one server call");
            }
        }

        private static async Task CorruptPerItemResultCannotBecomeSuccess()
        {
            using (var f = new Fixture())
            {
                await f.Login(); f.Business = (message, ct) => Ready(Json(BatchReply(new[] { A, B }, 1)));
                var result = await f.Session.MutateAsync(f.Prepare(MutationAction.UnitBatchStatus, BatchBody(new[] { A, B })), CancellationToken.None);
                var path = Directory.GetFiles(f.State.RootDirectory, "mutations.dpapi", SearchOption.AllDirectories).Single();
                var document = JsonValue.ParseObject(Unprotect(path));
                var entry = (Dictionary<string, object>)((object[])document["entries"])[0];
                entry["resultJson"] = ((string)entry["resultJson"]).Replace(B, C);
                Protect(path, JsonValue.Serialize(document)); var before = File.ReadAllBytes(path);
                await ExpectCode("LOCAL_BUSINESS_STORAGE", () => f.Session.ListMutationJournalAsync(f.Owner(), CancellationToken.None));
                True(before.SequenceEqual(File.ReadAllBytes(path)), "invalid result never silently repaired or claimed");
                Equal(1, f.Writes, "damaged result never causes a network write");
            }
        }

        private static Dictionary<string, object> LegacyRecord(MutationRequest request)
        { var ticks = DateTime.UtcNow.Ticks; return new Dictionary<string, object> { ["id"] = request.RequestId, ["action"] = (int)request.Action,
            ["method"] = request.Method, ["path"] = request.RelativePath, ["resourceId"] = request.ResourceId, ["bodyJson"] = request.BodyJson,
            ["bodySha256"] = request.BodySha256, ["observedStatus"] = request.ObservedStatus, ["state"] = 3, ["draftId"] = null, ["draftRevision"] = null,
            ["createdTicks"] = ticks, ["updatedTicks"] = ticks, ["statusCode"] = 200, ["errorCode"] = null, ["confirmedResourceId"] = A, ["reviewNote"] = null,
            ["contractVersion"] = 1, ["versionStrategy"] = (int)request.VersionStrategy, ["receiptStrategy"] = 0, ["serverIdempotencyAvailable"] = false, ["enforcesExpectedVersion"] = false }; }
        private static string BatchBody(string id, string status = "禁用") { return BatchBody(new[] { id }, status); }
        private static string BatchBody(IEnumerable<string> ids, string status = "禁用")
        { return "{" + (status == null ? "" : "\"status\":\"" + status + "\",") + "\"items\":[" + String.Join(",", ids.Select(id => "{\"id\":\"" + id + "\"}")) + "]}"; }
        private static string BatchReply(string[] ids, int failures = 0)
        { return "{\"succeeded\":" + (ids.Length - failures) + ",\"failed\":" + failures + ",\"results\":[" + String.Join(",", ids.Select((id, i) => "{\"id\":\"" + id + "\",\"label\":\"单位\",\"ok\":"
            + (i < failures ? "false" : "true") + ",\"reason\":" + (i < failures ? "\"被业务引用，未删除\"" : "null") + "}")) + "]}"; }
        private static string Unprotect(string path)
        { var bytes = ProtectedData.Unprotect(File.ReadAllBytes(path), Entropy(path), DataProtectionScope.CurrentUser); try { return Encoding.UTF8.GetString(bytes); } finally { Array.Clear(bytes, 0, bytes.Length); } }
        private static void Protect(string path, string json)
        { var bytes = Encoding.UTF8.GetBytes(json); try { File.WriteAllBytes(path, ProtectedData.Protect(bytes, Entropy(path), DataProtectionScope.CurrentUser)); } finally { Array.Clear(bytes, 0, bytes.Length); } }
        private static byte[] Entropy(string path) { return Encoding.UTF8.GetBytes("Uten/UIMP-Win7-WPF/business-state/v1/mutations/" + Path.GetFileName(Path.GetDirectoryName(path))); }
        private static HttpResponseMessage Json(string body, int status = 200) { return new HttpResponseMessage((HttpStatusCode)status) { Content = new StringContent(body, Encoding.UTF8, "application/json") }; }
        private static Task<HttpResponseMessage> Ready(HttpResponseMessage value) { return Task.FromResult(value); }
        private static void True(bool condition, string message) { if (!condition) throw new InvalidOperationException("Unit command contract: " + message); }
        private static void Equal<T>(T expected, T actual, string message) { True(EqualityComparer<T>.Default.Equals(expected, actual), message); }
        private static void Throws<T>(Action action) where T : Exception { try { action(); } catch (T) { return; } throw new InvalidOperationException("Expected " + typeof(T).Name); }
        private static void ThrowsApi(Action action) { Throws<ApiException>(action); }
        private static void ThrowsCode(string code, Action action) { try { action(); } catch (ApiException e) { Equal(code, e.Code, "expected rejection"); return; } throw new InvalidOperationException("Expected " + code); }
        private static async Task ExpectAnyApi(Func<Task> action) { try { await action(); } catch (ApiException) { return; } throw new InvalidOperationException("Expected API failure"); }
        private static async Task ExpectCode(string code, Func<Task> action) { try { await action(); } catch (ApiException e) { Equal(code, e.Code, "expected async rejection"); return; } throw new InvalidOperationException("Expected " + code); }
        private sealed class Fixture : IDisposable
        {
            internal readonly BusinessStateTestFixture State;
            internal readonly SessionCoordinator Session;
            internal string[] Permissions = { "unit:view", "unit:create", "unit:edit", "unit:status", "unit:delete" };
            internal int Writes, Refreshes;
            internal Func<HttpRequestMessage, CancellationToken, Task<HttpResponseMessage>> Business;
            internal Fixture() : this(null, true) { }
            internal Fixture(IBusinessStateStore store) : this(store, false) { }
            private Fixture(IBusinessStateStore store, bool ownFixture)
            {
                if (ownFixture) { State = new BusinessStateTestFixture(); store = State.Store; }
                var config = new ClientConfiguration(new[] { new ServerEndpoint("company", "private fixture", "https://company.example.test/api"),
                    new ServerEndpoint("cloud", "private cloud fixture", "https://cloud.example.test/api") }, "company", 5);
                Session = new SessionCoordinator(config, new Handler((request, ct) =>
                {
                    if (request.RequestUri.AbsolutePath == "/api/auth/login") return Ready(Json("{\"accessToken\":\"access-fixture\",\"refreshToken\":\"refresh-fixture\",\"expiresIn\":900,\"user\":{\"id\":\"unit-command-user\",\"loginAccount\":\"UT0001\",\"superAdmin\":false,\"mustChangePassword\":false,\"permissions\":"
                        + JsonValue.Serialize(Permissions) + ",\"businessDatasetId\":\"11111111-1111-1111-1111-111111111111\",\"businessResetGeneration\":0}}"));
                    if (request.RequestUri.AbsolutePath == "/api/auth/logout") return Ready(Json("", 204));
                    if (request.RequestUri.AbsolutePath == "/api/auth/refresh") Interlocked.Increment(ref Refreshes);
                    Interlocked.Increment(ref Writes);
                    True(!request.Headers.Contains(StepUpGrant.HeaderName) && request.RequestUri.Host == "company.example.test", "unit write scoped only to original fake issuer, no extra step-up");
                    return Business == null ? Ready(Json(Detail)) : Business(request, ct);
                }), new AuthStore(), store);
            }
            internal Task Login() { return Session.LoginAsync("fixture", "fixture-password", CancellationToken.None); }
            internal MutationOwnerSnapshot Owner() { return Session.CaptureMutationOwner(); }
            internal MutationRequest Prepare(MutationAction action, string body, string resource = null, string observed = null)
            { return Session.PrepareMutation(action, Guid.NewGuid().ToString("D"), body, Owner(), resource, observed); }
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
        private sealed class WireStream : Stream
        {
            private readonly MemoryStream input = new MemoryStream(Encoding.ASCII.GetBytes("HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\n{}"));
            internal long Written;
            public override int Read(byte[] buffer, int offset, int count) { return input.Read(buffer, offset, count); }
            public override void Write(byte[] buffer, int offset, int count) { Written += count; }
            public override void Flush() { } public override bool CanRead { get { return true; } } public override bool CanWrite { get { return true; } } public override bool CanSeek { get { return false; } }
            public override long Length { get { return input.Length; } } public override long Position { get { return input.Position; } set { throw new NotSupportedException(); } }
            public override long Seek(long offset, SeekOrigin origin) { throw new NotSupportedException(); } public override void SetLength(long value) { throw new NotSupportedException(); }
            protected override void Dispose(bool disposing) { if (disposing) input.Dispose(); base.Dispose(disposing); }
        }
    }
}
