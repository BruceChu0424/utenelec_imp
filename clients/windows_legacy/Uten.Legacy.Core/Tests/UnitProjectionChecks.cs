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
    public static class UnitProjectionChecks
    {
        private const string Job = "99999999-9999-9999-9999-999999999999";
        private const string Custom = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa";
        private static string Projection(string nameWidth = "288.50", bool definitionNull = false)
        {
            Func<string, string, string> column = (key, width) => "{\"key\":\"" + key + "\",\"label\":\"单位列\",\"width\":" + width + ",\"type\":\"text\"" + (definitionNull ? ",\"definition\":null" : "") + "}";
            return "{\"tableKey\":\"master.unit\",\"scope\":\"master_unit\",\"columns\":[" + column("code", "120") + "," + column("name", nameWidth) + "," + column("status", "72") + "," + column("platform:" + Custom, "160.25") + "]}";
        }
        private static string Body(string projection) { return "{\"id\":\"" + Job + "\",\"domain\":\"master\",\"report\":\"unit\",\"format\":\"xlsx\",\"parameters\":{\"filter\":\"{}\"},\"columnProjection\":" + projection + "}"; }
        public static void Run()
        {
            PreciseBodyAndTypedProof().GetAwaiter().GetResult();
            InvalidProjectionNeverSends().GetAwaiter().GetResult();
            VisualNumbersDoNotBroadenBusinessNumbers().GetAwaiter().GetResult();
        }
        private static async Task PreciseBodyAndTypedProof()
        {
            using (var fixture = new Fixture())
            {
                await fixture.Login(); var body = Body(Projection());
                var request = fixture.Session.PrepareMutation(MutationAction.UnitExportSubmit, NewId(), body, fixture.Owner());
                Equal(body, request.BodyJson, "pixel lexemes and full projection remain original");
                var unknown = await fixture.Session.MutateAsync(request, CancellationToken.None);
                Equal(MutationOutcome.Unknown, unknown.Outcome, "fixture creation reply lost");
                fixture.Proof = Body(Projection("288.5", true));
                var known = await fixture.Session.ReconcileUnitExportAsync(request.RequestId, fixture.Owner(), CancellationToken.None);
                True(known.Outcome == MutationOutcome.Confirmed && known.IsDurablyRecorded && known.ConfirmedByReceiptQuery, "typed pixel semantics and definition absent/null defaults prove same creation");
                var journal = await fixture.Session.LoadMutationJournalAsync(request.RequestId, fixture.Owner(), CancellationToken.None);
                Equal(body, journal.BodyJson, "normalization never replaces original projection bytes");
                True(journal.ResultJson.Contains("288.5") && fixture.Posts == 1, "server proof retained, no POST replay");
            }
        }
        private static async Task InvalidProjectionNeverSends()
        {
            using (var fixture = new Fixture())
            {
                await fixture.Login(); var valid = Projection();
                foreach (var projection in new[] { valid.Replace("master.unit", "master.goods"), valid.Replace("master_unit", "master_goods"),
                    valid.Replace("platform:" + Custom, "password"), valid.Replace("\"status\"", "\"code\""),
                    Projection("\"120.\""), Projection("0.5"), Projection("2001"), Projection("1e309"),
                    valid.Replace("\"type\":\"text\"", "\"type\":\"text\",\"sourceKey\":\"name\""),
                    valid.Replace("\"type\":\"text\"", "\"type\":\"text\",\"definition\":{}") })
                    ThrowsApi(() => fixture.Session.PrepareMutation(MutationAction.UnitExportSubmit, NewId(), Body(projection), fixture.Owner()));
                Equal(0, fixture.Posts, "unknown scope/key/claim/pixel input never reaches network");
            }
        }
        private static async Task VisualNumbersDoNotBroadenBusinessNumbers()
        {
            using (var fixture = new Fixture())
            {
                await fixture.Login();
                ThrowsApi(() => fixture.Session.PrepareMutation(MutationAction.UnitStatus, NewId(), "{\"status\":\"使用\",\"version\":1.0}", fixture.Owner(), Custom));
                var request = fixture.Session.PrepareMutation(MutationAction.UnitExportSubmit, NewId(), Body(Projection()), fixture.Owner());
                await fixture.Session.MutateAsync(request, CancellationToken.None);
                fixture.Proof = Body(Projection("288.5001", true));
                var different = await fixture.Session.ReconcileUnitExportAsync(request.RequestId, fixture.Owner(), CancellationToken.None);
                True(different.Outcome == MutationOutcome.Unknown && !different.ConfirmedByReceiptQuery, "changed visual width is a different original request");
            }
        }
        private static string NewId() { return Guid.NewGuid().ToString("D"); }
        private static HttpResponseMessage Json(string value) { return new HttpResponseMessage(HttpStatusCode.OK) { Content = new StringContent(value, Encoding.UTF8, "application/json") }; }
        private static void True(bool value, string label) { if (!value) throw new InvalidOperationException("Unit projection: " + label); }
        private static void Equal<T>(T expected, T actual, string label) { True(EqualityComparer<T>.Default.Equals(expected, actual), label); }
        private static void ThrowsApi(Action action) { try { action(); } catch (ApiException) { return; } throw new InvalidOperationException("Expected projection rejection"); }
        private sealed class Fixture : IDisposable
        {
            private readonly BusinessStateTestFixture state = new BusinessStateTestFixture();
            internal readonly SessionCoordinator Session;
            internal string Proof;
            internal int Posts;
            internal Fixture()
            {
                var config = new ClientConfiguration(new[] { new ServerEndpoint("company", "private fixture", "https://company.example.test/api") }, "company", 5);
                Session = new SessionCoordinator(config, new Handler((message, ct) =>
                {
                    if (message.RequestUri.AbsolutePath == "/api/auth/login") return Task.FromResult(Json("{\"accessToken\":\"fixture-access\",\"refreshToken\":\"fixture-refresh\",\"expiresIn\":900,\"user\":{\"id\":\"projection-owner\",\"loginAccount\":\"fixture\",\"superAdmin\":false,\"mustChangePassword\":false,\"permissions\":[\"unit:view\",\"unit:export\",\"unit:status\"],\"businessDatasetId\":\"11111111-1111-1111-1111-111111111111\",\"businessResetGeneration\":0}}"));
                    if (message.Method == HttpMethod.Post) { Posts++; throw new HttpRequestException("fixture accepted creation reply lost"); }
                    return Task.FromResult(Json("{\"id\":\"" + Job + "\",\"domain\":\"master\",\"report\":\"unit\",\"format\":\"xlsx\",\"status\":\"PENDING\",\"cancelRequested\":false,\"rows\":0,\"bytes\":0,\"createdAt\":\"2026-10-28T12:00:00+08:00\",\"request\":" + Proof + "}"));
                }), new AuthStore(), state.Store);
            }
            internal Task Login() { return Session.LoginAsync("fixture", "fixture-password", CancellationToken.None); }
            internal MutationOwnerSnapshot Owner() { return Session.CaptureMutationOwner(); }
            public void Dispose() { Session.Dispose(); state.Dispose(); }
        }
        private sealed class Handler : HttpMessageHandler
        {
            private readonly Func<HttpRequestMessage, CancellationToken, Task<HttpResponseMessage>> action;
            internal Handler(Func<HttpRequestMessage, CancellationToken, Task<HttpResponseMessage>> action) { this.action = action; }
            protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage message, CancellationToken ct) { return action(message, ct); }
        }
        private sealed class AuthStore : ISessionStore
        {
            private StoredSession active; private readonly List<StoredSession> pending = new List<StoredSession>();
            public StoredSession Load() { return active; } public void Save(StoredSession value) { active = value; } public void Clear() { active = null; }
            public void EndSession(StoredSession value) { EnqueueRevocation(value ?? active); active = null; }
            public void EnqueueRevocation(StoredSession value) { if (value != null) pending.Add(value); } public IList<StoredSession> PendingRevocations() { return pending; }
            public void AcknowledgeRevocation(string id) { pending.RemoveAll(value => value.Id == id); }
        }
    }
}
