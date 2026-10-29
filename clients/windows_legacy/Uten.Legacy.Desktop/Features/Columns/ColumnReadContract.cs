using System;
using System.Collections.Generic;
using System.Collections.ObjectModel;
using System.Globalization;
using System.Linq;

namespace Uten.Legacy.Desktop.Features.Columns
{
    public static class ColumnReadContract
    {
        public static PlatformColumnCapabilities UnitCapabilities(string json)
        {
            PlatformColumnCapabilities result = null;
            foreach (object raw in ColumnJson.Array(ColumnJson.Parse(json)))
            {
                var row = ColumnJson.Object(raw);
                if (ColumnJson.Text(row, "scope") != UnitColumnProjection.UnitScope) continue;
                if (result != null) throw new FormatException("单位扩展字段范围重复。");
                result = new PlatformColumnCapabilities { Scope = UnitColumnProjection.UnitScope, Label = ColumnJson.Text(row, "label"),
                    CanWrite = ColumnJson.Flag(row, "canWrite"), CanDefine = ColumnJson.Flag(row, "canDefine"), CanCreate = ColumnJson.Flag(row, "canCreate"),
                    PriceVisible = ColumnJson.Flag(row, "priceVisible"), SupportsValues = ColumnJson.Flag(row, "supportsValues"),
                    PersonalDefinitions = ColumnJson.Flag(row, "personalDefinitions"), CanDefineRelated = OptionalFlag(row, "canDefineRelated") };
            }
            if (result == null) throw new FormatException("当前没有单位扩展字段范围的访问能力。");
            return result;
        }
        public static IReadOnlyDictionary<string, PlatformColumnDefinition> Definitions(string json)
        {
            var result = new Dictionary<string, PlatformColumnDefinition>(StringComparer.OrdinalIgnoreCase);
            foreach (object raw in ColumnJson.Array(ColumnJson.Parse(json)))
            {
                var definition = Definition(ColumnJson.Object(raw));
                if (result.ContainsKey(definition.Id)) throw new FormatException("自设列响应包含重复UUID。");
                result.Add(definition.Id, definition);
            }
            if (result.Count > 8192) throw new FormatException("自设列依赖超过范围。");
            return new ReadOnlyDictionary<string, PlatformColumnDefinition>(result);
        }
        internal static PlatformColumnDefinition Definition(Dictionary<string, object> row)
        {
            string scope = ColumnJson.Text(row, "scope"), type = ColumnJson.Text(row, "type"), name = ColumnJson.Text(row, "name");
            if (scope != UnitColumnProjection.UnitScope || String.IsNullOrEmpty(name) || name.Length > 200
                || type != "TEXT" && type != "NUMBER" && type != "CALCULATED" && type != "RELATED") throw new FormatException("自设列不属于当前范围或类型无效。");
            object formula; row.TryGetValue("formula", out formula);
            if (formula != null) ValidateFormula(ColumnJson.Object(formula));
            return new PlatformColumnDefinition { Id = ColumnJson.Uuid(ColumnJson.Text(row, "id")), Scope = scope, Name = name, Type = type,
                PriceProtected = ColumnJson.Flag(row, "priceProtected"), UsageCount = ColumnJson.Integer(row, "usageCount"),
                PersonalUsageCount = ColumnJson.Integer(row, "personalUsageCount"), CanDelete = OptionalFlag(row, "canDelete"),
                FormulaJson = formula == null ? null : ColumnJson.Canonical(formula), RelationKey = ColumnJson.Text(row, "relationKey") };
        }
        private static void ValidateFormula(Dictionary<string, object> formula)
        {
            object root, steps;
            if (!formula.TryGetValue("base", out root) || !formula.TryGetValue("steps", out steps)) throw new FormatException("计算列公式缺少操作数。");
            ValidateOperand(ColumnJson.Object(root));
            var entries = ColumnJson.Array(steps); if (entries.Length > 16) throw new FormatException("计算步骤超出范围。");
            foreach (object raw in entries)
            {
                var step = ColumnJson.Object(raw); string operation = ColumnJson.Text(step, "operation");
                if (operation != "ADD" && operation != "SUBTRACT" && operation != "MULTIPLY" && operation != "DIVIDE") throw new FormatException("计算步骤类型无效。");
                object operand; if (!step.TryGetValue("operand", out operand)) throw new FormatException("计算步骤缺少操作数。");
                ValidateOperand(ColumnJson.Object(operand));
            }
        }
        private static bool OptionalFlag(Dictionary<string, object> row, string key)
        { object raw; return !row.TryGetValue(key, out raw) || raw == null ? false : ColumnJson.Flag(row, key); }
        private static void ValidateOperand(Dictionary<string, object> operand)
        {
            string id = ColumnJson.Text(operand, "columnId"), fact = ColumnJson.Text(operand, "fact"), constant = ColumnJson.Text(operand, "constant");
            if ((id == null ? 0 : 1) + (fact == null ? 0 : 1) + (constant == null ? 0 : 1) != 1) throw new FormatException("计算操作数必须保留唯一来源。");
            if (id != null) ColumnJson.Uuid(id);
            if (constant != null && (constant.Length == 0 || constant.Length > 120)) throw new FormatException("计算常量格式无效。");
            // Constants and fact names remain strings; business arithmetic is server-owned.
        }
        public static IReadOnlyDictionary<string, PlatformColumnRow> Rows(string json, IReadOnlyList<string> expectedRecordIds)
        {
            var expected = new HashSet<string>(expectedRecordIds.Select(ColumnJson.Uuid), StringComparer.OrdinalIgnoreCase);
            if (expected.Count != expectedRecordIds.Count || expected.Count > 200) throw new ArgumentException("记录清单必须为不重复的UUID，最多200条。");
            var result = new Dictionary<string, PlatformColumnRow>(StringComparer.OrdinalIgnoreCase);
            foreach (object raw in ColumnJson.Array(ColumnJson.Parse(json)))
            {
                var row = ColumnJson.Object(raw); string id = ColumnJson.Uuid(ColumnJson.Text(row, "recordId"));
                if (!expected.Contains(id) || result.ContainsKey(id)) throw new FormatException("扩展字段包含重复或其他范围记录。");
                object rawCells; if (!row.TryGetValue("cells", out rawCells)) throw new FormatException("扩展字段缺少单元格。");
                var cells = new Dictionary<string, PlatformColumnCell>(StringComparer.Ordinal);
                foreach (object rawCell in ColumnJson.Array(rawCells))
                {
                    var cell = ColumnJson.Object(rawCell); string columnId = ColumnJson.Uuid(ColumnJson.Text(cell, "columnId"));
                    object rawDefinition; if (!cell.TryGetValue("definition", out rawDefinition)) throw new FormatException("扩展字段缺少权威定义。");
                    var definition = Definition(ColumnJson.Object(rawDefinition));
                    if (definition.Id != columnId || cells.ContainsKey(definition.Key)) throw new FormatException("扩展字段定义和单元格不匹配。");
                    if (!cell.ContainsKey("value")) throw new FormatException("扩展字段未明确返回值或空值，不能把缺失值当成清空字段。");
                    bool masked = ColumnJson.Flag(cell, "masked"); string value = ColumnJson.Text(cell, "value");
                    if (masked && value != null) throw new FormatException("受保护字段意外包含明文，已拒绝展示。");
                    cells.Add(definition.Key, new PlatformColumnCell { ColumnId = columnId, Value = value, Definition = definition,
                        Masked = masked, Persisted = ColumnJson.Flag(cell, "persisted"), Error = ColumnJson.Text(cell, "error") });
                }
                if (cells.Count > 64) throw new FormatException("单条扩展字段清单超出范围。");
                result.Add(id, new PlatformColumnRow { RecordId = id, Version = ColumnJson.Integer(row, "version"), CanWrite = ColumnJson.Flag(row, "canWrite"),
                    Cells = new ReadOnlyDictionary<string, PlatformColumnCell>(cells) });
            }
            if (result.Count != expected.Count) throw new FormatException("扩展字段读取不完整，未替换原资料。");
            return new ReadOnlyDictionary<string, PlatformColumnRow>(result);
        }
        public static UnitColumnLayout Preference(string authMeJson, string expectedUserId, out bool confirmed)
        {
            var root = ColumnJson.Object(ColumnJson.Parse(authMeJson));
            if (ColumnJson.Text(root, "id") != expectedUserId) throw new FormatException("表头偏好不属于当前账号。");
            object session, preferences, preference;
            confirmed = root.TryGetValue("session", out session) && session != null;
            if (!confirmed) return new UnitColumnLayout();
            var snapshot = ColumnJson.Object(session);
            if (!snapshot.TryGetValue("preferences", out preferences) || preferences == null) { confirmed = false; return new UnitColumnLayout(); }
            var table = ColumnJson.Object(preferences);
            if (!table.TryGetValue(UnitColumnLayout.PreferenceKey, out preference) || preference == null) return new UnitColumnLayout();
            if (preference is string) preference = ColumnJson.Parse((string)preference);
            return Layout(ColumnJson.Object(preference));
        }
        public static UnitColumnLayout Layout(Dictionary<string, object> value)
        {
            var widths = new Dictionary<string, double>(StringComparer.Ordinal); object raw;
            if (value.TryGetValue("widths", out raw) && raw != null)
                foreach (var pair in ColumnJson.Object(raw))
                {
                    // Only pixel widths may be numeric/double. Values and formulas never pass here.
                    if (!(pair.Value is int || pair.Value is long || pair.Value is double || pair.Value is decimal)) continue;
                    double pixels = Convert.ToDouble(pair.Value, CultureInfo.InvariantCulture);
                    if (Double.IsNaN(pixels) || Double.IsInfinity(pixels) || pixels < 48 || pixels > 2000) continue;
                    string key; if (TryKey(pair.Key, out key)) widths.Add(key, pixels);
                }
            var added = new List<string>();
            if (value.TryGetValue("added", out raw) && raw != null)
                foreach (object entry in ColumnJson.Array(raw))
                {
                    var column = ColumnJson.Object(entry);
                    if (ColumnJson.Text(column, "scope") == UnitColumnProjection.UnitScope)
                    { string key; if (TryKey("platform:" + ColumnJson.Text(column, "id"), out key)) added.Add(key.Substring(9)); }
                }
            return new UnitColumnLayout(Keys(value, "order"), Keys(value, "hidden"), Keys(value, "pinned"), widths, added);
        }
        private static IEnumerable<string> Keys(Dictionary<string, object> value, string key)
        {
            object raw; if (!value.TryGetValue(key, out raw) || raw == null) return new string[0];
            var keys = new List<string>();
            foreach (object entry in ColumnJson.Array(raw)) { string parsedKey; if (entry is string && TryKey((string)entry, out parsedKey)) keys.Add(parsedKey); }
            return keys;
        }
        private static bool TryKey(string input, out string value)
        { try { value = ColumnJson.ColumnKey(input); return true; } catch (FormatException) { value = null; return false; } }
    }
}
