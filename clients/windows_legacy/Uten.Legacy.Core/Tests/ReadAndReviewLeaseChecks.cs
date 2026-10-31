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
    public static class ReadAndReviewLeaseChecks
    {
        private const string Record = "22222222-2222-2222-2222-222222222222";
        private const string Column = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa";
        private const string Rows = "[{\"recordId\":\"" + Record + "\",\"version\":9007199254740993,\"canWrite\":true,\"cells\":[{\"columnId\":\"" + Column + "\",\"value\":null,\"masked\":true,\"persisted\":true}]}]";
        public static void Run()
        {
            RetiredNoteLeaseCannotReadOrChangeOutcome().GetAwaiter().GetResult();
            NoteFaultForeignCapabilityAndMissingRecord().GetAwaiter().GetResult();
            PostReadPreservesRawValuesAndDoesNotJournal().GetAwaiter().GetResult();
            OneRead401RefreshIsNotBusinessReplay().GetAwaiter().GetResult();
            PlatformProofUsesUnitDomain().GetAwaiter().GetResult();
            LateReadCannotEnterReplacementOwner().GetAwaiter().GetResult();
            ReadBoundsAndFixedColonRoute().GetAwaiter().GetResult();
            ReadNetworkAndCancellationAreNotUnknownWrites().GetAwaiter().GetResult();
        }
        private static async Task RetiredNoteLeaseCannotReadOrChangeOutcome()
        {
            using (var f = new Fixture())
            {
                await f.Login(); var owner = f.Owner(); var command = f.Command();
                await f.Session.MutateAsync(command, CancellationToken.None);
                var lease = await f.Session.CreateMutationReviewLeaseAsync(command.RequestId, owner, CancellationToken.None);
                True(lease.GetType().GetProperties().All(property => property.Name == "RequestId"), "lease exposes no old owner/body read capability");
                f.Session.SelectEndpoint("cloud");
                var receipt = await f.Session.AppendMutationReviewNoteAsync(lease, "人工核对中，原结果仍待确认。", CancellationToken.None);
                True(receipt.RequestId == command.RequestId && receipt.RecordedAtUtc.Kind == DateTimeKind.Utc, "local save result is a small append receipt");
                True(receipt.GetType().GetProperties().All(property => property.Name == "RequestId" || property.Name == "RecordedAtUtc"), "save receipt cannot return old business fields");
                var original = f.State.Store.LoadJournal(owner, command.RequestId);
                True(original.State == MutationJournalState.Unknown && original.ReviewNote.Contains("人工核对中") && original.BodyJson == command.BodyJson,
                    "retired note is original namespace append only");
                await f.Login();
                Equal(0, (await f.Session.ListMutationJournalAsync(f.Owner(), CancellationToken.None)).Count, "note cannot enter replacement endpoint namespace");
                Equal(1, f.BusinessWrites, "note creation/save never sends business HTTP");
            }
        }
        private static async Task NoteFaultForeignCapabilityAndMissingRecord()
        {
            var fail = false;
            using (var state = new BusinessStateTestFixture(point => { if (fail && point == "mutations:before-replace") throw new IOException("fixture note storage failure"); }))
            using (var f = new Fixture(state.Store))
            using (var other = new Fixture())
            {
                await f.Login(); await other.Login(); var command = f.Command(); await f.Session.MutateAsync(command, CancellationToken.None);
                var owner = f.Owner(); var lease = await f.Session.CreateMutationReviewLeaseAsync(command.RequestId, owner, CancellationToken.None);
                await ExpectCode("MUTATION_RECORD_NOT_FOUND", () => f.Session.CreateMutationReviewLeaseAsync(Guid.NewGuid().ToString("D"), owner, CancellationToken.None));
                await ExpectAnyApi(() => other.Session.AppendMutationReviewNoteAsync(lease, "not another coordinator", CancellationToken.None));
                var file = Directory.GetFiles(state.RootDirectory, "mutations.dpapi", SearchOption.AllDirectories).Single(); var before = File.ReadAllBytes(file);
                fail = true; await ExpectCode("LOCAL_BUSINESS_STORAGE", () => f.Session.AppendMutationReviewNoteAsync(lease, "必须保留的尚未保存说明", CancellationToken.None));
                True(before.SequenceEqual(File.ReadAllBytes(file)), "failed append preserves original encrypted journal");
                Equal(1, f.BusinessWrites, "local append failure never retries original command");
            }
        }
        private static async Task PostReadPreservesRawValuesAndDoesNotJournal()
        {
            using (var f = new Fixture())
            {
                await f.Login(); f.Read = async (message, ct) =>
                {
                    Equal("/api/platform-columns/master_unit/values:batch", message.RequestUri.AbsolutePath, "only fixed unit scope");
                    Equal("POST", message.Method.Method, "owning read uses POST");
                    var body = JsonValue.ParseObject(await message.Content.ReadAsStringAsync());
                    True(((object[])body["recordIds"]).Cast<string>().SequenceEqual(new[] { Record }) && ((object[])body["columnIds"]).Cast<string>().SequenceEqual(new[] { Column }), "only bounded UUID arrays");
                    return Json(Rows);
                };
                Equal(Rows, await f.Session.ReadUnitPlatformValuesAsync(new[] { Record }, new[] { Column }, CancellationToken.None), "masked null and Int64 remain unchanged");
                Equal(0, f.State.Store.ListJournal(f.Owner()).Count, "read-only SQL endpoint does not create a mutation journal");
                Equal(0, f.BusinessWrites, "read is not classified as business write");
            }
        }
        private static async Task OneRead401RefreshIsNotBusinessReplay()
        {
            using (var f = new Fixture())
            {
                await f.Login(); f.Read = (message, ct) => Ready(message.Headers.Authorization.Parameter == "access-original"
                    ? Json("{\"code\":\"UNAUTHORIZED\",\"message\":\"fixture\"}", 401) : Json(Rows));
                Equal(Rows, await f.Session.ReadUnitPlatformValuesAsync(new[] { Record }, null, CancellationToken.None), "idempotent read retries once after real refresh");
                True(f.ReadPosts == 2 && f.Refreshes == 1 && f.BusinessWrites == 0, "one shared read refresh only");
                Equal(0, f.State.Store.ListJournal(f.Owner()).Count, "read retry has no write journal");
            }
        }
        private static async Task PlatformProofUsesUnitDomain()
        {
            using (var f = new Fixture())
            {
                await f.Login(); f.Read = (message, ct) => Ready(Proof(Rows, "unit-a"));
                await f.Session.GetAsync("master/units", CancellationToken.None); // Same authoritative unit domain.
                var generation = f.Session.Generation; var revision = f.Session.ReadScopeRevision;
                f.Read = (message, ct) => Ready(Proof(Rows, "unit-b"));
                await ExpectCode("READ_SCOPE_CHANGED", () => f.Session.ReadUnitPlatformValuesAsync(new[] { Record }, new[] { Column }, CancellationToken.None));
                True(f.Session.ReadScopeRevision == revision + 1 && f.Session.Generation == generation, "column proof retires reads without changing auth generation");
                Equal(Rows, await f.Session.ReadUnitPlatformValuesAsync(new[] { Record }, new[] { Column }, CancellationToken.None), "next reader uses established new proof");
            }
        }
        private static async Task LateReadCannotEnterReplacementOwner()
        {
            using (var f = new Fixture())
            {
                await f.Login(); var entered = new TaskCompletionSource<bool>(); var release = new TaskCompletionSource<HttpResponseMessage>();
                f.Read = (message, ct) => { entered.SetResult(true); return release.Task; };
                var pending = f.Session.ReadUnitPlatformValuesAsync(new[] { Record }, new[] { Column }, CancellationToken.None); await entered.Task;
                f.Session.SelectEndpoint("cloud"); release.SetResult(Json(Rows));
                await ExpectAnyApi(() => pending);
                Equal(0, f.BusinessWrites, "retired read never resubmits a business command");
            }
        }
        private static async Task ReadBoundsAndFixedColonRoute()
        {
            using (var f = new Fixture())
            {
                await f.Login();
                foreach (var ids in new IReadOnlyList<string>[] { null, new[] { Record, Record }, new[] { "../users" }, new[] { Column.ToUpperInvariant() }, Enumerable.Range(0, 201).Select(i => Guid.NewGuid().ToString("D")).ToArray() })
                    await ExpectAnyApi(() => f.Session.ReadUnitPlatformValuesAsync(ids, null, CancellationToken.None));
                await ExpectAnyApi(() => f.Session.ReadUnitPlatformValuesAsync(new[] { Record }, Enumerable.Range(0, 33).Select(i => Guid.NewGuid().ToString("D")).ToArray(), CancellationToken.None));
                foreach (var path in new[] { "other:batch", "platform-columns/master_goods/values:batch", "platform-columns/master_unit/values:batch/extra" })
                    await ExpectCode("INVALID_API_PATH", () => f.Session.GetAsync(path, CancellationToken.None));
                Equal(0, f.ReadPosts, "invalid route/UUID input never enters handler");
            }
            using (var f = new Fixture()) { f.Permissions = new[] { "unit:status" }; await f.Login(); await ExpectCode("FORBIDDEN", () => f.Session.ReadUnitPlatformValuesAsync(new[] { Record }, null, CancellationToken.None)); Equal(0, f.ReadPosts, "view permission checked before POST read"); }
        }
        private static async Task ReadNetworkAndCancellationAreNotUnknownWrites()
        {
            using (var f = new Fixture())
            {
                await f.Login(); f.Read = (message, ct) => { throw new HttpRequestException("fixture read unavailable"); };
                var error = await AnyApi(() => f.Session.ReadUnitPlatformValuesAsync(new[] { Record }, null, CancellationToken.None));
                True(!error.IsSubmissionUnknown && error.Code == "NETWORK", "POST SQL read transport error is not unknown business submission");
                Equal(1, f.ReadPosts, "no automatic network read loop");
                using (var cancellation = new CancellationTokenSource())
                {
                    cancellation.Cancel();
                    try { await f.Session.ReadUnitPlatformValuesAsync(new[] { Record }, null, cancellation.Token); }
                    catch (OperationCanceledException) { return; }
                    throw new InvalidOperationException("Expected cancelled read.");
                }
            }
        }
        private static HttpResponseMessage Json(string body, int status = 200) { return new HttpResponseMessage((HttpStatusCode)status) { Content = new StringContent(body, Encoding.UTF8, "application/json") }; }
        private static HttpResponseMessage Proof(string body, string version) { var response = Json(body); response.Headers.Add("X-Uten-Read-Scope-Version", version); response.Headers.Add("X-Uten-Read-Scope-Domain", "master_unit"); return response; }
        private static Task<HttpResponseMessage> Ready(HttpResponseMessage value) { return Task.FromResult(value); }
        private static void True(bool condition, string message) { if (!condition) throw new InvalidOperationException("Read/review lease: " + message); }
        private static void Equal<T>(T expected, T actual, string message) { True(EqualityComparer<T>.Default.Equals(expected, actual), message); }
        private static async Task<ApiException> AnyApi(Func<Task> action) { try { await action(); } catch (ApiException e) { return e; } throw new InvalidOperationException("Expected API failure"); }
        private static async Task ExpectAnyApi(Func<Task> action) { await AnyApi(action); }
        private static async Task ExpectCode(string code, Func<Task> action) { Equal(code, (await AnyApi(action)).Code, "expected error code"); }
        private sealed class Fixture : IDisposable
        {
            internal readonly BusinessStateTestFixture State;
            internal readonly SessionCoordinator Session;
            internal string[] Permissions = { "unit:view", "unit:status" };
            internal int BusinessWrites, ReadPosts, Refreshes;
            internal Func<HttpRequestMessage, CancellationToken, Task<HttpResponseMessage>> Read;
            internal Fixture() : this(null, true) { }
            internal Fixture(IBusinessStateStore store) : this(store, false) { }
            private Fixture(IBusinessStateStore store, bool own)
            {
                if (own) { State = new BusinessStateTestFixture(); store = State.Store; }
                var config = new ClientConfiguration(new[] { new ServerEndpoint("company", "private fixture", "https://company.example.test/api"),
                    new ServerEndpoint("cloud", "private cloud fixture", "https://cloud.example.test/api") }, "company", 5);
                Session = new SessionCoordinator(config, new Handler((message, ct) =>
                {
                    if (message.RequestUri.AbsolutePath == "/api/auth/login") return Ready(Json(Token("access-original")));
                    if (message.RequestUri.AbsolutePath == "/api/auth/refresh") { Interlocked.Increment(ref Refreshes); return Ready(Json(Token("access-refreshed"))); }
                    if (message.RequestUri.AbsolutePath == "/api/auth/logout") return Ready(Json("", 204));
                    if (message.RequestUri.AbsolutePath == "/api/master/units") return Ready(Proof("{\"readScopeVersion\":\"unit-a\",\"items\":[]}", "unit-a"));
                    if (message.RequestUri.AbsolutePath == "/api/platform-columns/master_unit/values:batch")
                    { Interlocked.Increment(ref ReadPosts); return Read == null ? Ready(Json(Rows)) : Read(message, ct); }
                    Interlocked.Increment(ref BusinessWrites); throw new HttpRequestException("fixture sent write lost");
                }), new AuthStore(), store);
            }
            internal Task Login() { return Session.LoginAsync("fixture", "fixture-password", CancellationToken.None); }
            internal MutationOwnerSnapshot Owner() { return Session.CaptureMutationOwner(); }
            internal MutationRequest Command() { return Session.PrepareMutation(MutationAction.UnitStatus, Guid.NewGuid().ToString("D"), "{\"status\":\"禁用\"}", Owner(), Record); }
            private string Token(string access) { return "{\"accessToken\":\"" + access + "\",\"refreshToken\":\"refresh-fixture\",\"expiresIn\":900,\"user\":{\"id\":\"read-review-owner\",\"loginAccount\":\"UT0001\",\"superAdmin\":false,\"mustChangePassword\":false,\"permissions\":"
                + JsonValue.Serialize(Permissions) + ",\"businessDatasetId\":\"11111111-1111-1111-1111-111111111111\",\"businessResetGeneration\":0}}"; }
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
