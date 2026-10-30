using System;
using System.Collections.Generic;
using System.Globalization;
using System.Linq;

namespace Uten.Legacy.Desktop.Features.Columns
{
    public static class ColumnModelContractChecks
    {
        private const string Id = "00000000-0000-0000-0000-000000000061", Other = "00000000-0000-0000-0000-000000000062", Record = "00000000-0000-0000-0000-000000000063";
        public static int Run()
        {
            int count = 0; Action<bool, string> check = (condition, label) => { if (!condition) throw new InvalidOperationException("Column contract: " + label); count++; };
            check(UnitColumnLayout.PreferenceKey == "platform.table.19e439ed14e5af7509dbe9fd5a998194", "preference key matches Flutter SHA256 master.unit identity");
            var definitions = ColumnReadContract.Definitions("[" + Definition(Id, "NUMBER") + "," + Definition(Other, "TEXT") + "]");
            check(definitions[Id].UsageCount == 9007199254740993L, "usage counter is exact Int64");
            check(!ColumnReadContract.Definitions("[" + Definition(Id, "NUMBER").Replace(",\"canDelete\":true", "") + "]")[Id].CanDelete,
                "older metadata without delete capability remains readable but never grants delete");
            var layout = new UnitColumnLayout(new[] { "platform:" + Id, "status", "name", "code", "platform:" + Other },
                new[] { "code", "platform:" + Other }, new[] { "platform:" + Id }, new Dictionary<string, double> { ["name"] = 288.5 }, new[] { Id, Other });
            var projection = layout.Project(definitions);
            check(String.Join(",", projection.Columns.Select(column => column.Key)) == "code,name,status,platform:" + Id, "required leading fields remain visible and fixed despite stale preference order");
            check(projection.Columns[1].Width == 288.5 && projection.PinnedColumnCount == 4, "pixel width and contiguous pin prefix preserved");
            var json = ColumnJson.Object(ColumnJson.Parse(projection.ToJson()));
            check((string)json["tableKey"] == "master.unit" && (string)json["scope"] == "master_unit", "screen print export share the actual table identity");
            check(!projection.ToJson().Contains("definition") && !projection.ToJson().Contains("sourceKey"), "descriptive client formula and source keys are not exported as authority");
            var rows = ColumnReadContract.Rows("[" + Row("0.123456789012345678901234567890", false) + "]", new[] { Record });
            check(rows[Record].Version == 9007199254740995L && rows[Record].Cells["platform:" + Id].Value == "0.123456789012345678901234567890", "field version and decimal text never go through double");
            var masked = ColumnReadContract.Rows("[" + Row(null, true) + "]", new[] { Record });
            check(masked[Record].Cells["platform:" + Id].Value == null && masked[Record].Cells["platform:" + Id].DisplayText == "无查看权限", "masked unknown is not zero");
            Reject<FormatException>(() => ColumnReadContract.Rows("[" + Row("secret", true) + "]", new[] { Record }), check, "masked plaintext response is rejected");
            Reject<FormatException>(() => ColumnReadContract.Rows("[]", new[] { Record }), check, "partial row response cannot be published");
            Reject<FormatException>(() => ColumnReadContract.Rows("[" + Row("1", false).Replace("\"value\":\"1\",", "") + "]", new[] { Record }), check,
                "missing value is not silently changed into an explicit clear on later full-row write");
            Reject<FormatException>(() => ColumnReadContract.Rows("[" + Row("1", false) + "," + Row("2", false) + "]", new[] { Record }), check, "duplicate record response rejected");
            Reject<FormatException>(() => ColumnReadContract.Definitions("[" + Definition(Id, "NUMBER").Replace("master_unit", "master_goods") + "]"), check, "foreign scope definition rejected");
            var same = ColumnReadContract.Definitions("[" + Definition(Id, "NUMBER").Replace("9007199254740993", "9") + "]");
            check(definitions[Id].Fingerprint == same[Id].Fingerprint, "immutable definition evidence excludes dynamic usage counters");
            var preference = layout.ToPreferenceJson(definitions);
            check(!preference.Contains("formula") && !preference.Contains("expectedVersion"), "personal header preference does not invent concurrency version or cache formula authority");
            bool confirmed;
            var loaded = ColumnReadContract.Preference("{\"id\":\"owner\",\"session\":{\"preferences\":{\"" + UnitColumnLayout.PreferenceKey + "\":" + preference + "}}}", "owner", out confirmed);
            check(confirmed && loaded.Project(definitions).ToJson() == projection.ToJson(), "layout is restored only through auth me session preferences");
            ColumnReadContract.Preference("{\"id\":\"owner\",\"session\":null}", "owner", out confirmed);
            check(!confirmed, "missing server snapshot is not treated as known empty preferences");
            var create = new PlatformColumnCreateInput("  原输入列  ", "CALCULATED", formula: new ColumnFormulaInput(ColumnFormulaOperand.Literal("0.123456789012345678901234567890"),
                new[] { new ColumnFormulaStep("MULTIPLY", ColumnFormulaOperand.Column(Id)) }));
            check(create.ToJson().Contains("0.123456789012345678901234567890") && create.ToJson().Contains("  原输入列  "), "formula constants and user text remain original strings");
            var write = ColumnJson.Object(ColumnJson.Parse(PlatformValueWriteContract.ToJson(rows[Record], Id, "  1.0000000000000000001  ")));
            check((long)write["expectedVersion"] == 9007199254740995L && PlatformValueWriteContract.ToJson(rows[Record], Id, null).Contains("\"value\":null"), "field write uses real platform version and explicit clear");
            Reject<InvalidOperationException>(() => PlatformValueWriteContract.ToJson(masked[Record], Id, "1"), check, "masked cells cannot become editable numeric zeros");
            var protectedRow = ColumnJson.Object(ColumnJson.Parse(Row(null, true)));
            var visibleCell = new Dictionary<string, object> { ["columnId"] = Other, ["value"] = "old", ["definition"] = ColumnJson.Parse(Definition(Other, "TEXT")),
                ["masked"] = false, ["persisted"] = true, ["error"] = null };
            protectedRow["cells"] = ColumnJson.Array(protectedRow["cells"]).Concat(new object[] { visibleCell }).ToArray();
            var protectedRows = ColumnReadContract.Rows(ColumnJson.Serialize(new object[] { protectedRow }), new[] { Record });
            Reject<InvalidOperationException>(() => PlatformValueWriteContract.ToJson(protectedRows[Record], Other, "new"), check,
                "editing a visible cell cannot replace an unknown persisted hidden sibling with null");
            var calculatedRow = ColumnJson.Object(ColumnJson.Parse(Row("1", false)));
            var calculated = ColumnJson.Object(ColumnJson.Parse(Definition(Other, "CALCULATED")));
            calculated["formula"] = ColumnJson.Parse("{\"base\":{\"constant\":\"2\"},\"steps\":[]}");
            calculatedRow["cells"] = ColumnJson.Array(calculatedRow["cells"]).Concat(new object[] { new Dictionary<string, object> { ["columnId"] = Other,
                ["value"] = "42", ["definition"] = calculated, ["masked"] = false, ["persisted"] = true, ["error"] = null } }).ToArray();
            var calculatedRows = ColumnReadContract.Rows(ColumnJson.Serialize(new object[] { calculatedRow }), new[] { Record });
            var calculatedWrite = ColumnJson.Object(ColumnJson.Parse(PlatformValueWriteContract.ToJson(calculatedRows[Record], Id, "3")));
            check(ColumnJson.Array(calculatedWrite["cells"]).Select(ColumnJson.Object).Single(cell => (string)cell["columnId"] == Other)["value"] == null,
                "a persisted calculated marker never writes the returned computed amount as a business value");
            var legacy = new Dictionary<string, PlatformColumnDefinition>(StringComparer.OrdinalIgnoreCase);
            var legacyJson = new List<string>();
            for (int index = 0; index < 40; index++) { string id = Extra(index); legacy[id] = ColumnReadContract.Definitions("[" + Definition(id, "TEXT") + "]")[id]; legacyJson.Add(id); }
            var plain = new UnitColumnLayout().ProjectBounded(legacy, legacyJson);
            check(plain.Projection.Columns.Count == 35 && plain.OverflowedDefinitionIds.Count == 8 && plain.OverflowedDefinitionIds[0] == Extra(32),
                "more than 32 persisted legacy columns deliver a bounded 35-column table with explicit stable overflow instead of failing closed");
            var addedLate = new UnitColumnLayout(addedIds: new[] { Extra(39) }).ProjectBounded(legacy, legacyJson);
            check(addedLate.Projection.Columns.Count == 35 && addedLate.Projection.Columns.Any(column => column.PlatformId == Extra(39))
                && addedLate.OverflowedDefinitionIds.Count == 8 && !addedLate.OverflowedDefinitionIds.Contains(Extra(39)),
                "explicit user additions keep their visible budget first and are never reported as overflow");
            var hiddenLate = new UnitColumnLayout(hidden: new[] { "platform:" + Extra(39) }, addedIds: new[] { Extra(39) }).ProjectBounded(legacy, legacyJson);
            check(!hiddenLate.Projection.Columns.Any(column => column.PlatformId == Extra(39)) && hiddenLate.OverflowedDefinitionIds.Count == 7
                && !hiddenLate.OverflowedDefinitionIds.Contains(Extra(39)),
                "an explicitly hidden column frees budget for the next stable persisted columns and is not counted as overflow");
            check(new UnitColumnLayout().ProjectBounded(legacy, legacyJson).Projection.ToJson() == plain.Projection.ToJson(),
                "bounded selection is deterministic across repeated projection");
            var partial = new Dictionary<string, PlatformColumnDefinition>(StringComparer.OrdinalIgnoreCase) { [Extra(0)] = legacy[Extra(0)] };
            Reject<InvalidOperationException>(() => new UnitColumnLayout(addedIds: new[] { Extra(1) }).Project(partial), check,
                "unverified added column still fails the strict projection instead of silently disappearing");
            return count;
        }
        private static void Reject<T>(Action action, Action<bool, string> check, string label) where T : Exception
        { try { action(); } catch (T) { check(true, label); return; } check(false, label); }
        private static string Definition(string id, string type)
        { return "{\"id\":\"" + id + "\",\"scope\":\"master_unit\",\"name\":\"自设列\",\"type\":\"" + type + "\",\"priceProtected\":false,\"formula\":null,\"usageCount\":9007199254740993,\"personalUsageCount\":0,\"relationKey\":null,\"canDelete\":true}"; }
        internal static string Extra(int index)
        { return "00000000-0000-0000-0000-" + (index + 1).ToString("D12", CultureInfo.InvariantCulture); }
        private static string Row(string value, bool masked)
        { return "{\"recordId\":\"" + Record + "\",\"version\":9007199254740995,\"canWrite\":true,\"cells\":[{\"columnId\":\"" + Id + "\",\"value\":" + ColumnJson.Serialize(value) + ",\"definition\":" + Definition(Id, "NUMBER") + ",\"masked\":" + (masked ? "true" : "false") + ",\"persisted\":true,\"error\":null}]}"; }
    }
}
