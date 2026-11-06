using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Net;
using System.Net.Http;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using Uten.Legacy.Core;
using Uten.Legacy.Core.Tests;
using Uten.Legacy.Desktop.Features.Goods;
using Uten.Legacy.Desktop.Features.Units;

namespace Uten.Legacy.Desktop.Shared
{
    public static class CompleteSummaryTransportChecks
    {
        private static readonly string Revision = new string('a', 64), Data = new string('d', 64);
        private const string Scope = "complete-scope";
        public static int Run() { return RunAsync().GetAwaiter().GetResult(); }
        private static async Task<int> RunAsync()
        {
            int assertions = 0;
            Action<bool, string> check = (value, message) => { if (!value) throw new InvalidOperationException(message); assertions++; };
            var handler = new Handler();
            using (var state = new BusinessStateTestFixture())
            using (var session = new SessionCoordinator(new ClientConfiguration(new[] { new ServerEndpoint("first", "Fixture", "https://first.company.test/api") }, "first"),
                handler, new Store(), state.Store))
            {
                await session.LoginAsync("fixture", "fixture", CancellationToken.None);
                var owner = session.CaptureMutationOwner();
                var goods = new GoodsReadService(session);
                handler.Wire = Wire(201);
                var complete = await goods.CompleteAsync(null, " 原始 & 数值 ", () => true, CancellationToken.None);
                check(handler.Reads == 1 && complete.Items.Count == 201 && complete.Items[200].Code == "G201", "One HTTP supplies the real final row.");
                check(complete.Items[200].Price == "900719925474099312345.2300", "Original decimal tokens and trailing zeroes survive framing.");
                var request = new System.Web.Script.Serialization.JavaScriptSerializer().Deserialize<Dictionary<string, object>>(handler.LastBody);
                check(Equals(((Dictionary<string, object>)request["filter"])["keyword"], "原始 & 数值") && Equals(request["size"], 100), "Original query and bounded frame size survive.");
                var units = new UnitService(session);
                var unit = await units.CompleteAsync(new UnitQuery(1, 100, "原始", new Dictionary<string, UnitFilter> { ["name"] = UnitFilter.Null, ["status"] = UnitFilter.Exact("使用") }), () => true, CancellationToken.None);
                check(handler.Reads == 2 && unit.Value.Items.Count == 201 && unit.Value.Total == 201 && unit.IsCurrent(session), "Units share the same complete transport and current owner.");
                check(handler.LastBody.Contains("\"nullFields\":[\"name\"]") && handler.LastBody.Contains("\"status\":\"使用\""), "Unit exact/null filters remain distinct.");
                check(state.Store.ListJournal(owner).Count == 0 && state.Store.ListDrafts(owner).Count == 0 && handler.Writes == 0, "Read POSTs create no mutation, journal or draft.");
                foreach (string fault in new[] { "missing", "duplicate", "revision", "terminal-total", "trailing", "error", "malformed", "extra-page" })
                {
                    int before = handler.Reads;
                    handler.Wire = Wire(201, fault);
                    try { await goods.CompleteAsync(null, null, () => true, CancellationToken.None); throw new InvalidOperationException("Accepted malformed stream: " + fault); }
                    catch (ApiException) { assertions++; }
                    check(handler.Reads == before + 1, "Malformed stream never replays a request: " + fault);
                }
                handler.Wire = Wire(0);
                var empty = await goods.CompleteAsync(null, null, () => true, CancellationToken.None);
                check(empty.Total == 0 && empty.Items.Count == 0, "True empty needs a page, matching complete and EOF.");
                handler.Wire = Wire(1); handler.HoldEof = new TaskCompletionSource<bool>(TaskCreationOptions.RunContinuationsAsynchronously);
                handler.AtEof = new TaskCompletionSource<bool>(TaskCreationOptions.RunContinuationsAsynchronously);
                var reading = goods.CompleteAsync(null, null, () => true, CancellationToken.None);
                await handler.AtEof.Task;
                check(!reading.IsCompleted, "Complete frame cannot publish until HTTP EOF arrives.");
                handler.HoldEof.SetResult(true); await reading;
                handler.HoldEof = new TaskCompletionSource<bool>(TaskCreationOptions.RunContinuationsAsynchronously);
                handler.AtEof = new TaskCompletionSource<bool>(TaskCreationOptions.RunContinuationsAsynchronously);
                using (var cancel = new CancellationTokenSource())
                {
                    var pending = goods.CompleteAsync(null, null, () => true, cancel.Token); await handler.AtEof.Task; cancel.Cancel();
                    try { await pending; throw new InvalidOperationException("Cancelled EOF was accepted."); }
                    catch (OperationCanceledException) { assertions++; }
                }
                handler.HoldEof = null; handler.Wire = Wire(1, "scope-error"); long priorScope = session.ReadScopeRevision;
                try { await goods.CompleteAsync(null, null, () => true, CancellationToken.None); throw new InvalidOperationException("Scope error was accepted."); }
                catch (ApiException error) { check(error.Code == "READ_SCOPE_CHANGED" && session.ReadScopeRevision > priorScope, "Scope error retires the shared read owner."); }
            }
            return assertions + await SharedFixture();
        }
        private static async Task<int> SharedFixture()
        {
            var json = new System.Web.Script.Serialization.JavaScriptSerializer();
            Dictionary<string, object> fixture;
            using (var source = typeof(CompleteSummaryTransportChecks).Assembly.GetManifestResourceStream("Uten.CompleteSummaryStreamFixture.json"))
            using (var reader = new StreamReader(source ?? throw new InvalidOperationException("Shared complete stream fixture is missing.")))
                fixture = json.Deserialize<Dictionary<string, object>>(reader.ReadToEnd());
            int assertions = 0;
            foreach (Dictionary<string, object> sample in ((System.Collections.IEnumerable)fixture["cases"]))
            {
                var frames = ((System.Collections.IEnumerable)sample["frames"]).Cast<object>().ToArray();
                var handler = new Handler { Wire = String.Join("\n", frames.Select(json.Serialize)) + (frames.Length == 0 ? "" : "\n") };
                using (var session = new SessionCoordinator(new ClientConfiguration(new[] { new ServerEndpoint("first", "Fixture", "https://first.company.test/api") }, "first"), handler, new Store()))
                {
                    await session.LoginAsync("fixture", "fixture", CancellationToken.None);
                    string expected = (string)sample["expected"];
                    try
                    {
                        var value = await new GoodsReadService(session).CompleteAsync(null, null, () => true, CancellationToken.None);
                        if (expected != "success" || value.Items.Count != 1 || value.Items[0].StockQuantity != "90071992547409.123456789012345678900"
                            || value.Items[0].Price != "12.3400") throw new InvalidOperationException("Shared success fixture lost exact source values.");
                    }
                    catch (ApiException error) { if (error.Code != expected) throw new InvalidOperationException("Shared fixture " + sample["name"] + " expected " + expected + ", got " + error.Code); }
                    if (handler.Reads != 1 || handler.Writes != 0) throw new InvalidOperationException("Shared stream fixture replayed or wrote.");
                    assertions++;
                }
            }
            return assertions;
        }
        private static string Wire(int total, string fault = null)
        {
            var frames = new List<string>(); int batches = Math.Max(1, (total + 99) / 100);
            for (int page = 1; page <= batches; page++)
            {
                var rows = Enumerable.Range((page - 1) * 100 + 1, Math.Max(0, Math.Min(100, total - (page - 1) * 100)))
                    .Select(index => "{\"id\":\"00000000-0000-4000-8000-" + (fault == "duplicate" && index == 101 ? 1 : index).ToString("D12")
                        + "\",\"code\":\"G" + index + "\",\"name\":\"资料\",\"status\":\"使用\",\"price\":900719925474099312345.2300}");
                frames.Add("{\"type\":\"page\",\"value\":{\"items\":[" + String.Join(",", rows) + "],\"page\":" + page + ",\"size\":100,\"total\":" + total
                    + ",\"totalPages\":" + ((total + 99) / 100) + "," + Proof(fault == "revision" && page == 2 ? new string('b', 64) : Revision) + "}}");
            }
            if (fault == "extra-page") frames.Add(frames[frames.Count - 1]);
            if (fault != "missing") frames.Add(fault == "error" || fault == "scope-error"
                ? "{\"type\":\"error\",\"code\":\"" + (fault == "scope-error" ? "READ_SCOPE_CHANGED" : "SNAPSHOT_CHANGED") + "\",\"message\":\"范围变化\"}"
                : "{\"type\":\"complete\",\"total\":" + (fault == "terminal-total" ? total + 1 : total) + "," + Proof(Revision) + "}");
            if (fault == "trailing") frames.Add("{\"type\":\"page\",\"value\":{}}");
            if (fault == "malformed") frames.Insert(1, "{broken");
            return String.Join("\n", frames) + "\n";
        }
        private static string Proof(string revision) => "\"readScopeVersion\":\"" + Scope + "\",\"readDataVersion\":\"" + Data + "\",\"readSnapshotRevision\":\"" + revision + "\"";
        private sealed class Handler : HttpMessageHandler
        {
            internal string Wire, LastBody;
            internal int Reads, Writes;
            internal TaskCompletionSource<bool> HoldEof, AtEof;
            protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken token)
            {
                if (request.RequestUri.AbsolutePath.EndsWith("/auth/login")) return Json("{\"accessToken\":\"fixture-access\",\"refreshToken\":\"fixture-refresh\",\"expiresIn\":900,\"user\":{\"id\":\"owner\",\"loginAccount\":\"fixture\",\"permissions\":[\"goods:view\",\"unit:view\"],\"businessDatasetId\":\"11111111-1111-1111-1111-111111111111\",\"businessResetGeneration\":0}}");
                if (request.RequestUri.AbsolutePath.EndsWith("/summaries") && request.RequestUri.Query == "?complete=true" && request.Method == HttpMethod.Post
                    && request.Headers.Accept.Any(value => value.MediaType == "application/x-ndjson"))
                {
                    Reads++; LastBody = await request.Content.ReadAsStringAsync();
                    var response = new HttpResponseMessage(HttpStatusCode.OK) { Content = new StreamContent(new FragmentedStream(Encoding.UTF8.GetBytes(Wire), HoldEof, AtEof)) };
                    response.Content.Headers.ContentType = new System.Net.Http.Headers.MediaTypeHeaderValue("application/x-ndjson"); return response;
                }
                Writes++; throw new InvalidOperationException("Unexpected write or fallback route.");
            }
        }
        private sealed class FragmentedStream : MemoryStream
        {
            private readonly TaskCompletionSource<bool> hold, atEof;
            internal FragmentedStream(byte[] bytes, TaskCompletionSource<bool> hold, TaskCompletionSource<bool> atEof) : base(bytes) { this.hold = hold; this.atEof = atEof; }
            public override async Task<int> ReadAsync(byte[] buffer, int offset, int count, CancellationToken token)
            {
                if (Position == Length && hold != null)
                { atEof.TrySetResult(true); using (token.Register(() => hold.TrySetCanceled())) await hold.Task; }
                token.ThrowIfCancellationRequested(); return await base.ReadAsync(buffer, offset, Math.Min(count, 37), token);
            }
        }
        private static HttpResponseMessage Json(string text) => new HttpResponseMessage(HttpStatusCode.OK) { Content = new StringContent(text, Encoding.UTF8, "application/json") };
        private sealed class Store : ISessionStore
        {
            private StoredSession value;
            public StoredSession Load() => value;
            public void Save(StoredSession session) { value = session; }
            public void Clear() { value = null; }
            public void EndSession(StoredSession session) { value = null; }
            public void EnqueueRevocation(StoredSession session) { }
            public IList<StoredSession> PendingRevocations() => new List<StoredSession>();
            public void AcknowledgeRevocation(string id) { }
        }
    }
}
