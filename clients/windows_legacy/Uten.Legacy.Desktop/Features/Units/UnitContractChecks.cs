using System;
using System.Collections.Generic;
using System.Linq;
using System.Net;
using System.Net.Http;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using System.Web.Script.Serialization;
using Uten.Legacy.Core;
using Uten.Legacy.Core.Tests;

namespace Uten.Legacy.Desktop.Features.Units
{
    /// <summary>Debug-only offline contracts. HTTP is an injected handler; state uses a private temporary fixture.</summary>
    public static class UnitContractChecks
    {
        private const string Id = "ffda6731-4bce-4fa1-a5a5-2acf55fd6d01";
        private const string SecondId = "ffda6731-4bce-4fa1-a5a5-2acf55fd6d02";
        public static int Run()
        {
            int assertions = 0;
            Action<bool, string> check = (condition, message) =>
            {
                if (!condition) throw new InvalidOperationException("Unit service contract: " + message);
                assertions++;
            };
            ModelAndQuery(check);
            ReadAndWrite(check).GetAwaiter().GetResult();
            StatusOnlyAndEditOnly(check).GetAwaiter().GetResult();
            LateReadAndUnknown(check).GetAwaiter().GetResult();
            return assertions;
        }
        private static void ModelAndQuery(Action<bool, string> check)
        {
            var input = UnitSaveInput.Daily("  kg  ", "", "使用");
            var body = Parse(input.ToJson());
            check((string)body["name"] == "  kg  " && (string)body["code"] == "", "input text is not trimmed or rewritten");
            check(!body.ContainsKey("measurementDimension") && !body.ContainsKey("massUnitCode"), "daily input omits hidden measurement keys");
            input.MeasurementDimension = UnitOptionalText.Null;
            input.MassUnitCode = UnitOptionalText.Of("KG");
            body = Parse(input.ToJson());
            check(body.ContainsKey("measurementDimension") && body["measurementDimension"] == null && (string)body["massUnitCode"] == "KG", "explicit null/value presence preserved");
            var filter = new Dictionary<string, UnitFilter> { ["name"] = UnitFilter.Null, ["status"] = UnitFilter.Exact("使用") };
            var query = new UnitQuery(1, 20, " M&1 ", filter);
            filter["status"] = UnitFilter.Exact("禁用");
            check(query.ToRelativePath() == "/master/units?page=1&size=20&keyword=M%261&nullFields=name&status=%E4%BD%BF%E7%94%A8", "query escaping, null intent and defensive copy");
            Expect<ArgumentException>(() => new UnitQuery(filters: new Dictionary<string, UnitFilter> { ["sql"] = UnitFilter.Null }), check, "unknown filter rejected");
            Expect<ArgumentOutOfRangeException>(() => new UnitQuery(page: 0), check, "page is one-based");
            Expect<ArgumentOutOfRangeException>(() => new UnitQuery(size: 101), check, "query respects current server Pageables limit of 100");
            var record = UnitRecord.Parse("{\"id\":\"" + Id + "\",\"code\":\"001\",\"name\":null,\"status\":\"使用\",\"legacyId\":9007199254740993,\"measurementDimension\":null}");
            check(record.Code == "001" && record.Name == null && record.LegacyIdText == "9007199254740993", "nullable fields and integer precision are retained");
            check(record.HasMeasurementDimension && record.MeasurementDimension == null && !record.HasMassUnitCode, "read field presence retained");
            check(!record.SupportsExpectedVersion, "no fake whole-record version");
            Expect<FormatException>(() => UnitRecord.Parse("{\"id\":\"" + Id + "\",\"legacyId\":1.5}"), check, "floating historical identifier rejected rather than rounded");
            var facets = UnitReadContract.ParseFacets("{\"status\":[{\"value\":\"使用\",\"count\":0}],\"nullCounts\":{\"status\":0}}");
            check(facets.Fields["status"][0].Count == 0 && facets.NullCounts["status"] == 0 && facets.NullCounts["name"] == null, "unknown facet count is not zero");
            var page = UnitReadContract.ParsePage("{\"items\":[],\"page\":1,\"size\":20,\"total\":0,\"totalPages\":0}");
            check(page.Items.Count == 0 && page.TotalElements == 0 && page.TotalPages == 0, "empty authoritative page");
            var inline = new UnitInlinePatch(Id,
                new Dictionary<string, UnitOptionalText> { ["name"] = UnitOptionalText.Null },
                new Dictionary<string, UnitOptionalText> { ["name"] = UnitOptionalText.Of("新单位") });
            var inlineBody = Parse(inline.ToJson());
            check(((Dictionary<string, object>)inlineBody["expected"])["name"] == null, "inline expected null retained");
            check(!inline.CoreTypedAdapterAvailable && !inline.ServerReceiptAvailable, "typed inline contract does not invent a sender or receipt");
            Expect<ArgumentException>(() => new UnitInlinePatch(Id,
                new Dictionary<string, UnitOptionalText> { ["code"] = UnitOptionalText.Of("A") },
                new Dictionary<string, UnitOptionalText> { ["code"] = UnitOptionalText.Of("B") }), check, "code is not inline writable");
            var batch = new UnitBatchCommand(UnitBatchAction.Status, new[] { Id, SecondId, Id }, "禁用");
            check(batch.Ids.Count == 2 && batch.RelativePath.EndsWith("/batch-status") && !batch.EnforcesExpectedVersion, "batch deduplicates UUIDs without fake unit version");
            Expect<ArgumentException>(() => new UnitBatchCommand(UnitBatchAction.Delete, Enumerable.Repeat(Id, 501)), check, "batch size is bounded before deduplication");
            var result = UnitBatchResult.Parse("{\"succeeded\":1,\"failed\":1,\"results\":[{\"id\":\"" + Id
                + "\",\"ok\":true},{\"id\":\"" + SecondId + "\",\"ok\":false,\"reason\":\"被引用\"}]}", batch);
            check(result.Succeeded == 1 && result.Failed == 1 && result.Results[1].Reason == "被引用", "per-item batch outcome retained");
            Expect<FormatException>(() => UnitBatchResult.Parse("{\"succeeded\":0,\"failed\":0,\"results\":[]}", batch), check, "incomplete batch reply cannot be assumed successful");
        }
        private static async Task ReadAndWrite(Action<bool, string> check)
        {
            using (var fixture = new Fixture("unit:view", "unit:create", "unit:edit", "unit:status"))
            {
                await fixture.Login();
                var service = new UnitService(fixture.Session);
                var page = await service.ListAsync(new UnitQuery(), CancellationToken.None);
                var facets = await service.FacetsAsync(CancellationToken.None);
                var detail = await service.DetailAsync(Id, CancellationToken.None);
                var dict = await service.DictAsync(CancellationToken.None);
                check(page.Value.TotalElements == 1 && page.Value.Items[0].Id == Id, "actual page adapter");
                check(facets.Value.Fields["status"].Count == 1 && dict.Value.Count == 1 && detail.Value.MassUnitCode == "KG", "facets/dict/detail actual adapters");
                check(page.IsCurrent(fixture.Session) && detail.IsCurrent(fixture.Session), "snapshots bind current read owner");
                var owner = service.CaptureWriteOwner();
                string frozen = UnitSaveInput.Daily("  kg  ", null, "使用").ToJson();
                var request = service.PrepareCreateJson(NewId(), frozen, owner);
                check(request.BodyJson == frozen && !request.HasMeasurementDimension && !request.HasMassUnitCode, "raw create body and missing measurement reach Core unchanged");
                var created = await service.SendAsync(request, CancellationToken.None);
                UnitRecord confirmed;
                check(created.Outcome == MutationOutcome.Confirmed && service.TryReadConfirmedUnit(created, out confirmed) && confirmed.Name == "kg", "normalized server detail confirmed");
                check(fixture.Handler.LastBody == frozen && !request.ServerIdempotencyAvailable, "single Core transport, no server idempotency fiction");
                await ExpectAsync<ApiException>(() => service.SendAsync(request, CancellationToken.None), check, "same descriptor is never resent");
                var changed = service.PrepareUpdate(NewId(), detail, UnitSaveInput.Daily("新名称", detail.Value.Code, detail.Value.Status), owner);
                var updated = await service.SendAsync(changed, CancellationToken.None);
                check(updated.Outcome == MutationOutcome.Confirmed && !changed.EnforcesExpectedVersion, "real PUT with explicit unsupported version metadata");
                fixture.Session.SelectEndpoint("second");
                check(!detail.IsCurrent(fixture.Session) && !service.TryReadConfirmedUnit(created, out confirmed)
                    && created.Outcome == MutationOutcome.Confirmed, "old reply not projected; confirmed outcome never becomes retryable");
            }
        }
        private static async Task StatusOnlyAndEditOnly(Action<bool, string> check)
        {
            using (var fixture = new Fixture("unit:view", "unit:status"))
            {
                await fixture.Login(); var service = new UnitService(fixture.Session);
                var detail = await service.DetailAsync(Id, CancellationToken.None);
                var owner = service.CaptureWriteOwner();
                Expect<ApiException>(() => service.PrepareUpdate(NewId(), detail, UnitSaveInput.Daily("名称", null, "使用"), owner), check, "status-only cannot PUT");
                var narrow = service.PrepareStatus(NewId(), Id, "禁用", owner, 9007199254740993L);
                check(narrow.ExpectedVersionJson == "9007199254740993" && narrow.VersionStrategy == MutationVersionStrategy.AcceptedButIgnored && !narrow.EnforcesExpectedVersion,
                    "status version is exact text and explicitly ignored by source contract");
                check((await service.SendAsync(narrow, CancellationToken.None)).Outcome == MutationOutcome.Confirmed, "status-only actual PATCH");
            }
            using (var fixture = new Fixture("unit:view", "unit:edit"))
            {
                await fixture.Login(); var service = new UnitService(fixture.Session);
                var detail = await service.DetailAsync(Id, CancellationToken.None); var owner = service.CaptureWriteOwner();
                var unchangedStatus = service.PrepareUpdate(NewId(), detail, UnitSaveInput.Daily("名称", null, "使用"), owner);
                check(!unchangedStatus.RequiredPermissions.Contains("unit:status"), "same observed status does not widen edit permission");
                Expect<ApiException>(() => service.PrepareUpdate(NewId(), detail, UnitSaveInput.Daily("名称", null, "禁用"), owner), check, "changing status still requires status permission");
                check(fixture.Handler.WriteRequests == 0, "preparation failures never send");
            }
        }
        private static async Task LateReadAndUnknown(Action<bool, string> check)
        {
            using (var fixture = new Fixture("unit:view", "unit:create"))
            {
                await fixture.Login(); var service = new UnitService(fixture.Session);
                fixture.Handler.PendingList = new TaskCompletionSource<HttpResponseMessage>();
                var pending = service.ListAsync(new UnitQuery(), CancellationToken.None);
                fixture.Session.SelectEndpoint("second");
                fixture.Handler.PendingList.SetResult(Reply("{\"items\":[],\"page\":1,\"size\":20,\"total\":0,\"totalPages\":0}"));
                bool retired = false;
                try { await pending; } catch (ApiException) { retired = true; } catch (OperationCanceledException) { retired = true; }
                check(retired, "late prior-owner read is retired");
            }
            using (var fixture = new Fixture("unit:view", "unit:create"))
            {
                await fixture.Login(); var service = new UnitService(fixture.Session); fixture.Handler.LoseWriteReply = true;
                var request = service.PrepareCreate(NewId(), UnitSaveInput.Daily("单位", null, "使用"), service.CaptureWriteOwner());
                var outcome = await service.SendAsync(request, CancellationToken.None);
                check(outcome.Outcome == MutationOutcome.Unknown && outcome.NeedsManualReconciliation && fixture.Handler.WriteRequests == 1, "lost write reply remains Unknown once");
                await ExpectAsync<ApiException>(() => service.SendAsync(request, CancellationToken.None), check, "unknown does not auto-replay");
            }
        }
        private static string NewId() { return Guid.NewGuid().ToString("D"); }
        private static Dictionary<string, object> Parse(string json) { return (Dictionary<string, object>)new JavaScriptSerializer().DeserializeObject(json); }
        private static void Expect<T>(Action action, Action<bool, string> check, string message) where T : Exception
        {
            bool rejected = false; try { action(); } catch (T) { rejected = true; } check(rejected, message);
        }
        private static async Task ExpectAsync<T>(Func<Task> action, Action<bool, string> check, string message) where T : Exception
        {
            bool rejected = false; try { await action(); } catch (T) { rejected = true; } check(rejected, message);
        }
        private static HttpResponseMessage Reply(string json) { return new HttpResponseMessage(HttpStatusCode.OK) { Content = new StringContent(json, Encoding.UTF8, "application/json") }; }
        private sealed class Fixture : IDisposable
        {
            private readonly BusinessStateTestFixture state = new BusinessStateTestFixture();
            internal readonly Handler Handler;
            internal readonly SessionCoordinator Session;
            internal Fixture(params string[] permissions)
            {
                Handler = new Handler(permissions);
                var configuration = new ClientConfiguration(new[] { new ServerEndpoint("first", "First", "https://first.unit.test/api"),
                    new ServerEndpoint("second", "Second", "https://second.unit.test/api") }, "first");
                Session = new SessionCoordinator(configuration, Handler, new AuthStore(), state.Store);
            }
            internal Task Login() { return Session.LoginAsync("fixture", "fixture-secret", null, CancellationToken.None); }
            public void Dispose() { Session.Dispose(); state.Dispose(); }
        }
        private sealed class AuthStore : ISessionStore
        {
            private readonly List<StoredSession> pending = new List<StoredSession>();
            public StoredSession Load() { return null; } public void Save(StoredSession value) { } public void Clear() { }
            public void EndSession(StoredSession value) { if (value != null) pending.Add(value); }
            public void EnqueueRevocation(StoredSession value) { pending.Add(value); }
            public IList<StoredSession> PendingRevocations() { return pending; }
            public void AcknowledgeRevocation(string id) { pending.RemoveAll(value => value.Id == id); }
        }
        private sealed class Handler : HttpMessageHandler
        {
            private readonly string[] permissions;
            internal string LastBody;
            internal int WriteRequests;
            internal bool LoseWriteReply;
            internal TaskCompletionSource<HttpResponseMessage> PendingList;
            internal Handler(string[] permissions) { this.permissions = permissions; }
            protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken)
            {
                string path = request.RequestUri.AbsolutePath;
                if (path == "/api/auth/login" || path == "/api/auth/refresh")
                    return Reply("{\"accessToken\":\"access.fixture\",\"refreshToken\":\"refresh.fixture\",\"expiresIn\":3600,\"user\":" + User() + "}");
                if (path == "/api/auth/me") return Reply(User());
                if (path == "/api/auth/logout") return Reply("{}");
                if (request.Method == HttpMethod.Get)
                {
                    if (path == "/api/master/units" && PendingList != null) return await PendingList.Task;
                    if (path == "/api/master/units") return Reply("{\"items\":[" + Record() + "],\"page\":1,\"size\":20,\"total\":1,\"totalPages\":1}");
                    if (path == "/api/master/units/facets") return Reply("{\"status\":[{\"value\":\"使用\",\"count\":1}],\"nullCounts\":{\"status\":0}}");
                    if (path == "/api/master/units/dict") return Reply("[" + Record() + "]");
                    if (path == "/api/master/units/" + Id) return Reply(Record());
                }
                if (path == "/api/master/units" || path == "/api/master/units/" + Id || path == "/api/master/units/" + Id + "/status")
                {
                    LastBody = await request.Content.ReadAsStringAsync(); WriteRequests++;
                    if (LoseWriteReply) throw new HttpRequestException("fixture lost response");
                    return Reply(Record());
                }
                throw new InvalidOperationException("Unexpected controlled unit fixture request: " + request.Method + " " + path);
            }
            private string User()
            {
                return "{\"id\":\"unit-owner\",\"loginAccount\":\"fixture\",\"superAdmin\":false,\"mustChangePassword\":false,"
                    + "\"permissions\":" + new JavaScriptSerializer().Serialize(permissions)
                    + ",\"businessDatasetId\":\"00000000-0000-0000-0000-000000000001\",\"businessResetGeneration\":0}";
            }
            private static string Record()
            {
                return "{\"id\":\"" + Id + "\",\"code\":\"U001\",\"name\":\"kg\",\"status\":\"使用\",\"legacyId\":null,\"measurementDimension\":\"MASS\",\"massUnitCode\":\"KG\"}";
            }
        }
    }
}
