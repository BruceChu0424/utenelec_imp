using System;

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
                + "\"price\":123456789012345.678900,\"priceDisplayText\":\"123456789012345.68\","
                + "\"discount\":0.9000,\"stockQty\":9007199254740993.0001,\"legacyId\":9007199254740993,"
                + "\"sourceType\":\"OUTSOURCE\"}],\"page\":1,\"size\":20,\"total\":21,\"totalPages\":2,"
                + "\"readScopeVersion\":\"scope-a\"}";
            GoodsPage page = GoodsReadContract.ParsePage(pageJson);
            GoodsRecord row = page.Items[0];
            check(page.Page == 1 && page.Size == 20 && page.Total == 21 && page.TotalPages == 2, "server pagination retained");
            check(page.ReadScopeVersion == "scope-a", "server read-scope marker retained");
            check(row.Text("price") == "123456789012345.678900", "price has exact raw digits and trailing zeroes");
            check(row.Price == "123456789012345.68", "server display text is authoritative");
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
            return assertions;
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
