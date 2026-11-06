using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Net;
using System.Net.Http;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using System.Web.Script.Serialization;
using Uten.Legacy.Core;
using Uten.Legacy.Core.Tests;
using Uten.Legacy.Desktop.Shared;

namespace Uten.Legacy.Desktop.Features.Goods
{
    // Executed by the offline console test project, never by application startup.
    public static class GoodsReadContractChecks
    {
        public static int Run()
        {
            const string id = "c73a7dd0-b342-4c15-a856-14d4d9d3cc01";
            const string childId = "c73a7dd0-b342-4c15-a856-14d4d9d3cc02";
            int assertions = 0;
            Action<bool, string> check = (condition, message) =>
            {
                if (!condition) throw new InvalidOperationException("Goods read contract: " + message);
                assertions++;
            };
            check(GoodsReadContract.ListPath(null, "  螺丝 & M3  ", 1, 20) ==
                "/master/goods?page=1&size=20&keyword=%E8%9E%BA%E4%B8%9D%20%26%20M3", "real endpoint, one-based page and escaped keyword");
            check(GoodsReadContract.ListPath(id, null, 2, 20) == "/master/goods?page=2&size=20&categoryId=" + id,
                "category relation is the UUID, not legacy ID/code");
            check(GoodsReadContract.DetailPath(id) == "/master/goods/" + id, "real detail endpoint");
            ExpectFailure(() => GoodsReadContract.ListPath("123", null, 1, 20), check, "legacy category ID rejected");
            ExpectFailure(() => GoodsReadContract.DetailPath("35"), check, "legacy goods ID rejected");
            ExpectFailure(() => GoodsReadContract.ListPath(null, null, 0, 20), check, "zero-based page rejected");
            ExpectFailure(() => GoodsReadContract.ListPath(null, null, 1, 101), check, "unbounded page rejected");

            string pageJson = "{\"items\":[{\"id\":\"" + id + "\",\"code\":\"001\",\"name\":\"货品 123\","
                + "\"price\":123456789012345.678900,\"priceDisplayText\":\"123456789012345.6789\","
                + "\"discount\":0.9000,\"stockQty\":9007199254740993.0001,\"legacyId\":9007199254740993,"
                + "\"sourceType\":\"OUTSOURCE\"}],\"page\":1,\"size\":20,\"total\":21,\"totalPages\":2,"
                + "\"readScopeVersion\":\"scope-a\"}";
            GoodsPage page = GoodsReadContract.ParsePage(pageJson);
            GoodsRecord row = page.Items[0];
            check(page.Page == 1 && page.Size == 20 && page.Total == 21 && page.TotalPages == 2, "server pagination retained");
            check(page.ReadScopeVersion == "scope-a", "server read-scope marker retained");
            check(row.Text("price") == "123456789012345.678900", "price has exact raw digits and trailing zeroes");
            check(row.Price == "123456789012345.6789", "server exact display text is authoritative without rounding");
            check(row.Discount == "0.9000", "discount is retained as factor, not multiplied into percent");
            check(row.StockQuantity == "9007199254740993.0001", "quantity never passes through binary floating point");
            check(row.LegacyId == "9007199254740993", "historical identifier precision retained");
            check(row.SourceType == "OUTSOURCE", "server source identity retained");
            check(row.Name == "货品 123", "numbers inside strings are untouched");
            // 单位→货品 FLOW: the unit relationship is the authoritative UUID key, and the
            // legacy snapshot fallback stays a display fact instead of a fake live reference.
            const string unitId = "c73a7dd0-b342-4c15-a856-14d4d9d3cc10";
            GoodsRecord referenced = GoodsReadContract.ParseDetail("{\"id\":\"" + id + "\",\"code\":\"001\",\"name\":\"货品 123\","
                + "\"unitId\":\"" + unitId + "\",\"unitName\":\"个\",\"unitLegacyId\":\"c73a7dd0-b342-4c15-a856-14d4d9d3cc11\"}");
            check(referenced.UnitId == unitId && referenced.UnitRelationship == "UUID 引用" && referenced.UnitLegacyId != null,
                "unit UUID relationship key and legacy id retained for the cross-module chain");
            GoodsRecord legacySnapshot = GoodsReadContract.ParseDetail("{\"id\":\"" + id + "\",\"unitName\":\"箱\"}");
            check(legacySnapshot.UnitId == null && legacySnapshot.UnitName == "箱" && legacySnapshot.UnitRelationship == "历史快照回落",
                "missing unit UUID keeps the read-only legacy fallback fact without inventing a key");
            ExpectFailure(() => { var _ = GoodsReadContract.ParseDetail("{\"id\":\"" + id + "\",\"unitId\":\"个\"}").UnitId; },
                check, "non-UUID unit relationship rejected instead of name-matched");
            GoodsRecord masked = GoodsReadContract.ParseDetail("{\"id\":\"" + id + "\",\"price\":19.9900,"
                + "\"priceDisplayText\":\"19.99\",\"priceMasked\":true,\"discount\":0.90,\"discountMasked\":true,\"costMasked\":true}");
            check(masked.Price == "—" && masked.Discount == "—" && masked.Flag("costMasked"), "financial masks retained");
            GoodsRecord unknown = GoodsReadContract.ParseDetail("{\"id\":\"" + id + "\",\"price\":null,\"stockQty\":null}");
            check(unknown.Price == "—" && unknown.StockQuantity == "—", "unknown is not zero");
            check(unknown.CurrencyId == null && unknown.Currency == "未登记" && unknown.CurrencyColorRole == "Other",
                "historical missing currency is not silently replaced with CNY");
            GoodsRecord currency = GoodsReadContract.ParseDetail("{\"id\":\"" + id + "\",\"currencyId\":\"" + childId
                + "\",\"currencyCode\":\"002\",\"currencyName\":\"美元\"}");
            check(currency.CurrencyId == childId && currency.CurrencyCode == "002" && currency.Currency == "美元"
                && currency.CurrencyColorRole == "Usd", "currency UUID, legacy code, master name and contrasting role retained");
            GoodsRecord hiddenCurrency = GoodsReadContract.ParseDetail("{\"id\":\"" + id + "\",\"priceMasked\":true,"
                + "\"currencyId\":\"" + childId + "\",\"currencyCode\":\"USD\",\"currencyName\":\"美元\"}");
            check(hiddenCurrency.CurrencyId == null && hiddenCurrency.CurrencyCode == null && hiddenCurrency.CurrencyName == null
                && hiddenCurrency.Currency == "—" && hiddenCurrency.CurrencyColorRole == "Other", "price mask covers every currency field");
            GoodsPage empty = GoodsReadContract.ParsePage("{\"items\":[],\"page\":1,\"size\":20,\"total\":0,\"totalPages\":0}");
            check(empty.Items.Count == 0 && empty.TotalPages == 0, "empty server page is valid");

            var tree = GoodsReadContract.ParseCategories("[{\"id\":\"" + id + "\",\"code\":\"A\",\"name\":\"材料\","
                + "\"legacyId\":123,\"children\":[{\"id\":\"" + childId + "\",\"parentId\":\"" + id
                + "\",\"code\":\"A1\",\"name\":\"塑料\",\"children\":null}]}]");
            check(tree.Count == 1 && tree[0].Children.Count == 1 && tree[0].Children[0].ParentId == id,
                "recursive category UUID/parent relation retained");
            check(tree[0].LegacyId == "123", "category legacy value remains display history");
            ExpectFailure(() => GoodsReadContract.ParseCategories("[{\"id\":\"" + id + "\"},{\"id\":\"" + id + "\"}]"),
                check, "duplicate category IDs rejected");
            ExpectFailure(() => GoodsReadContract.ParseDetail("{\"id\":\"" + id + "\",\"stockQty\":--1}"),
                check, "malformed numeric token rejected");
            ExpectFailure(() => GoodsReadContract.ParsePage("{\"items\":[],\"page\":1,\"size\":20,\"total\":9223372036854775808,\"totalPages\":1}"),
                check, "overflowing pagination is rejected rather than truncated");
            using (var input = typeof(GoodsReadContractChecks).Assembly.GetManifestResourceStream("Uten.CurrencyDisplayFixture.json"))
            using (var reader = new StreamReader(input))
            {
                var fixture = (Dictionary<string, object>)new JavaScriptSerializer().DeserializeObject(reader.ReadToEnd());
                foreach (Dictionary<string, object> sample in (object[])fixture["cases"])
                {
                    string name = sample["name"] as string, code = sample["code"] as string;
                    check(CurrencyDisplay.Label(name, code) == sample["label"] as string, "shared currency display fixture label parity");
                    check(CurrencyDisplay.ColorRole(name, code) == sample["role"] as string, "shared currency display fixture role parity");
                }
            }
            assertions += CompletePagedSnapshotChecks.Run();
            assertions += SummaryTransport().GetAwaiter().GetResult();
            return assertions;
        }

        private static async Task<int> SummaryTransport()
        {
            int assertions = 0;
            Action<bool, string> check = (value, text) => { if (!value) throw new InvalidOperationException("Goods summary HTTP: " + text); Interlocked.Increment(ref assertions); };
            const string category = "c73a7dd0-b342-4c15-a856-14d4d9d3cc01";
            string revision = new string('a', 64), data = new string('d', 64), scope = new string('b', 64);
            int reads = 0, writes = 0; bool allowed = true, missing = false;
            using (var state = new BusinessStateTestFixture())
            using (var session = new SessionCoordinator(new ClientConfiguration(new[] {
                new ServerEndpoint("goods", "private fixture", "https://goods.example.test/api") }, "goods"),
                new SummaryHandler(async (request, token) =>
                {
                    string path = request.RequestUri.AbsolutePath;
                    if (path == "/api/auth/login") return SummaryJson("{\"accessToken\":\"fixture-access\",\"refreshToken\":\"fixture-refresh\",\"expiresIn\":900,\"user\":{\"id\":\"goods-summary-owner\",\"loginAccount\":\"fixture\",\"superAdmin\":false,\"mustChangePassword\":false,\"permissions\":"
                        + (allowed ? "[\"goods:view\"]" : "[]") + ",\"businessDatasetId\":\"11111111-1111-1111-1111-111111111111\",\"businessResetGeneration\":0}}");
                    if (path == "/api/auth/logout" && request.Method == HttpMethod.Post) return SummaryJson("", HttpStatusCode.NoContent);
                    if (request.Method != HttpMethod.Post || path != "/api/master/goods/summaries")
                    { Interlocked.Increment(ref writes); throw new InvalidOperationException("Unexpected business route."); }
                    Interlocked.Increment(ref reads);
                    if (missing) return SummaryJson("{\"code\":\"NOT_FOUND\",\"message\":\"fixture unavailable\"}", HttpStatusCode.NotFound);
                    var json = new JavaScriptSerializer();
                    var body = json.Deserialize<Dictionary<string, object>>(await request.Content.ReadAsStringAsync().ConfigureAwait(false));
                    var filter = (Dictionary<string, object>)body["filter"];
                    int page = Convert.ToInt32(body["page"]), size = Convert.ToInt32(body["size"]);
                    check(size == 100 && body.Count == 3 && filter.Count == 2 && (string)filter["categoryId"] == category
                        && (string)filter["keyword"] == "原始 & 货品", "original category/search survive without hidden status/scope/sort filters");
                    check(request.RequestUri.Query == (page == 1 ? "" : "?readSnapshotRevision=" + revision), "each tail pins the real first snapshot revision");
                    var rows = Enumerable.Range((page - 1) * 100 + 1, Math.Min(100, 2414 - (page - 1) * 100))
                        .Select(index => new { id = new Guid(index, 0, 0, new byte[8]).ToString("D"), code = "G" + index, name = "原始货品", price = "9007199254740993.2300", unitId = category, unitName = "个" });
                    var response = SummaryJson(json.Serialize(new { items = rows, page, size, total = 2414, totalPages = 25,
                        readScopeVersion = scope, readDataVersion = data, readSnapshotRevision = revision }));
                    response.Headers.Add("X-Uten-Read-Scope-Version", scope);
                    return response;
                }), new SummaryAuthStore(), state.Store))
            {
                await session.LoginAsync("fixture", "fixture-password", CancellationToken.None).ConfigureAwait(false);
                var owner = session.CaptureMutationOwner(); var service = new GoodsReadService(session); GoodsPage first = null;
                var result = await CompletePagedSnapshot.ReadAsync<GoodsRecord>(async (page, size, token) =>
                {
                    var value = await service.SummariesAsync(category, "  原始 & 货品  ", page, size,
                        first == null ? null : first.ReadSnapshotRevision, token).ConfigureAwait(false);
                    if (first == null) first = value;
                    return new SnapshotPage<GoodsRecord> { Items = value.Items, Page = value.Page, Size = value.Size,
                        Total = value.Total, TotalPages = value.TotalPages, ReadScopeVersion = value.ReadScopeVersion,
                        ReadDataVersion = value.ReadDataVersion, ReadSnapshotRevision = value.ReadSnapshotRevision };
                }, item => Guid.Parse(item.Id).ToString("D"), () => true, CancellationToken.None, maximumConcurrentBatches: 4).ConfigureAwait(false);
                check(result.Count == 2414 && reads == 25 && result[2413].Code == "G2414", "actual typed Core/HTTP/Goods chain collects the true last row");
                check(result[2413].Price == "9007199254740993.2300" && result[2413].UnitId == category,
                    "numeric strings and relationship UUIDs retain exact authority");
                check(writes == 0 && state.Store.ListJournal(owner).Count == 0 && state.Store.ListDrafts(owner).Count == 0,
                    "read-only POST creates no write, draft, unknown command or mutation journal");
                int before = reads;
                foreach (var invalid in new Action[] {
                    () => session.ReadGoodsSummariesAsync(category, null, 1, 101, null, CancellationToken.None),
                    () => session.ReadGoodsSummariesAsync(category, null, 2, 100, null, CancellationToken.None),
                    () => session.ReadGoodsSummariesAsync("legacy-id", null, 1, 100, null, CancellationToken.None),
                    () => session.ReadGoodsSummariesAsync(category, null, 2, 100, revision + "\n", CancellationToken.None) })
                { try { invalid(); throw new InvalidOperationException("Invalid read was accepted."); } catch (ArgumentException) { assertions++; } }
                check(reads == before, "invalid size, UUID or snapshot never reaches HTTP");
                missing = true;
                try { await service.SummariesAsync(category, null, 1, 100, null, CancellationToken.None).ConfigureAwait(false); throw new InvalidOperationException("Missing endpoint became empty."); }
                catch (ApiException error) { check(error.Code == "NOT_FOUND" && error.StatusCode == 404, "404 remains a real failure, never empty success or old GET fallback"); }
                missing = false; allowed = false;
                await session.LoginAsync("fixture", "fixture-password", CancellationToken.None).ConfigureAwait(false); before = reads;
                try { await service.SummariesAsync(category, null, 1, 100, null, CancellationToken.None).ConfigureAwait(false); throw new InvalidOperationException("View permission bypassed."); }
                catch (UnauthorizedAccessException) { assertions++; }
                try { await session.ReadGoodsSummariesAsync(category, null, 1, 100, null, CancellationToken.None).ConfigureAwait(false); throw new InvalidOperationException("Core permission bypassed."); }
                catch (ApiException error) { check(error.Code == "FORBIDDEN", "Core rechecks goods:view before the precise read POST"); }
                check(reads == before && writes == 0, "permission rejection sends no request or business write");
            }
            return assertions;
        }
        private static HttpResponseMessage SummaryJson(string body, HttpStatusCode status = HttpStatusCode.OK)
        { return new HttpResponseMessage(status) { Content = new StringContent(body, Encoding.UTF8, "application/json") }; }
        private sealed class SummaryHandler : HttpMessageHandler
        {
            private readonly Func<HttpRequestMessage, CancellationToken, Task<HttpResponseMessage>> action;
            internal SummaryHandler(Func<HttpRequestMessage, CancellationToken, Task<HttpResponseMessage>> action) { this.action = action; }
            protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage message, CancellationToken token) { return action(message, token); }
        }
        private sealed class SummaryAuthStore : ISessionStore
        {
            private StoredSession active; private readonly List<StoredSession> pending = new List<StoredSession>();
            public StoredSession Load() { return active; } public void Save(StoredSession value) { active = value; }
            public void Clear() { active = null; } public void EndSession(StoredSession value) { EnqueueRevocation(value ?? active); active = null; }
            public void EnqueueRevocation(StoredSession value) { if (value != null) pending.Add(value); }
            public IList<StoredSession> PendingRevocations() { return pending.ToList(); }
            public void AcknowledgeRevocation(string id) { pending.RemoveAll(value => value.Id == id); }
        }

        private static void ExpectFailure(Action action, Action<bool, string> check, string message)
        {
            bool rejected = false;
            try { action(); }
            catch (ArgumentException) { rejected = true; }
            catch (FormatException) { rejected = true; }
            check(rejected, message);
        }
    }
}
