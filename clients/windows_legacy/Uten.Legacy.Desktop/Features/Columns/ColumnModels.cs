using System;
using System.Collections;
using System.Collections.Generic;
using System.Collections.ObjectModel;
using System.Globalization;
using System.Linq;
using System.Security.Cryptography;
using System.Text;
using System.Web.Script.Serialization;
using Uten.Legacy.Core;
using Uten.Legacy.Desktop.Features.Units;

namespace Uten.Legacy.Desktop.Features.Columns
{
    public sealed class PlatformColumnDefinition
    {
        public string Id { get; internal set; }
        public string Scope { get; internal set; }
        public string Name { get; internal set; }
        public string Type { get; internal set; }
        public bool PriceProtected { get; internal set; }
        public long UsageCount { get; internal set; }
        public long PersonalUsageCount { get; internal set; }
        public bool CanDelete { get; internal set; }
        public string FormulaJson { get; internal set; }
        public string RelationKey { get; internal set; }
        public string Key { get { return "platform:" + Id; } }
        public bool Numeric { get { return Type == "NUMBER" || Type == "CALCULATED"; } }
        public bool Editable { get { return Type == "TEXT" || Type == "NUMBER"; } }
        public string TypeLabel { get { switch (Type) { case "TEXT": return "文字说明"; case "NUMBER": return "记数字"; case "CALCULATED": return "计算展示"; case "RELATED": return "关联资料"; default: return Type; } } }
        // The owning API has immutable definition IDs, not an invented definition version.
        public string Fingerprint { get { return ColumnJson.Hash(ColumnJson.Canonical(ToDictionary(true))); } }
        internal Dictionary<string, object> ToDictionary(bool includeFormula)
        {
            var result = new Dictionary<string, object> { ["id"] = Id, ["scope"] = Scope, ["name"] = Name,
                ["type"] = Type, ["priceProtected"] = PriceProtected };
            if (includeFormula && FormulaJson != null) result["formula"] = ColumnJson.Parse(FormulaJson);
            if (RelationKey != null) result["relationKey"] = RelationKey;
            return result;
        }
    }
    public sealed class PlatformColumnCapabilities
    {
        public string Scope { get; internal set; }
        public string Label { get; internal set; }
        public bool CanWrite { get; internal set; }
        public bool CanDefine { get; internal set; }
        public bool CanCreate { get; internal set; }
        public bool PriceVisible { get; internal set; }
        public bool SupportsValues { get; internal set; }
        public bool PersonalDefinitions { get; internal set; }
        public bool CanDefineRelated { get; internal set; }
    }
    public sealed class PlatformColumnCell
    {
        public string ColumnId { get; internal set; }
        public string Value { get; internal set; }
        public PlatformColumnDefinition Definition { get; internal set; }
        public bool Masked { get; internal set; }
        public bool Persisted { get; internal set; }
        public string Error { get; internal set; }
        public string DisplayText { get { return Masked ? "无查看权限" : Error != null ? "读取失败：" + Error : Value ?? "—"; } }
    }
    public sealed class PlatformColumnRow
    {
        public string RecordId { get; internal set; }
        public long Version { get; internal set; }
        public bool CanWrite { get; internal set; }
        // Keys are canonical platform:UUID, also used by the common projection.
        public IReadOnlyDictionary<string, PlatformColumnCell> Cells { get; internal set; }
    }
    public sealed class ProjectedColumn
    {
        public string Key { get; private set; }
        public string Label { get; private set; }
        public double Width { get; private set; } // Presentation pixels only. Never business arithmetic.
        public string Type { get; private set; }
        public bool Pinned { get; private set; }
        public bool RequiredLeading { get { return Key == "code" || Key == "name" || Key == "status"; } }
        public string PlatformId { get { return Key.StartsWith("platform:", StringComparison.Ordinal) ? Key.Substring(9) : null; } }
        public ProjectedColumn(string key, string label, double width, string type, bool pinned = false)
        {
            key = ColumnJson.ColumnKey(key);
            if (String.IsNullOrEmpty(label) || label.Length > 200) throw new ArgumentException("列名无效。", nameof(label));
            if (Double.IsNaN(width) || Double.IsInfinity(width) || width < 48 || width > 2000) throw new ArgumentOutOfRangeException(nameof(width));
            if (type != "text" && type != "number") throw new ArgumentException("显示列类型无效。", nameof(type));
            Key = key; Label = label; Width = width; Type = type; Pinned = pinned || RequiredLeading;
        }
        internal Dictionary<string, object> ToDictionary()
        { return new Dictionary<string, object> { ["key"] = Key, ["label"] = Label, ["width"] = Width, ["type"] = Type }; }
    }
    public sealed class UnitColumnProjection
    {
        public const string UnitTableKey = "master.unit";
        public const string UnitScope = "master_unit";
        public string TableKey { get { return UnitTableKey; } }
        public string Scope { get { return UnitScope; } }
        public IReadOnlyList<ProjectedColumn> Columns { get; private set; }
        public string Fingerprint { get { return ColumnJson.Hash(ToJson()); } }
        public int PinnedColumnCount { get { return Columns.TakeWhile(column => column.Pinned).Count(); } }
        public UnitColumnProjection(IEnumerable<ProjectedColumn> columns)
        {
            var frozen = (columns ?? throw new ArgumentNullException(nameof(columns))).ToList();
            if (frozen.Count < 3 || frozen.Count > 35 || frozen.Select(column => column.Key).Distinct(StringComparer.Ordinal).Count() != frozen.Count
                || frozen[0].Key != "code" || frozen[1].Key != "name" || frozen[2].Key != "status")
                throw new ArgumentException("单位投影必须保留编号、名称、状态的固定前缀，最多32个自设列。", nameof(columns));
            bool unpinned = false;
            foreach (var column in frozen) { if (!column.Pinned) unpinned = true; else if (unpinned) throw new ArgumentException("固定列必须连续位于表头前部。"); }
            Columns = frozen.AsReadOnly();
        }
        public string ToJson()
        {
            return ColumnJson.Serialize(new Dictionary<string, object> { ["tableKey"] = TableKey, ["scope"] = Scope,
                ["columns"] = Columns.Select(column => column.ToDictionary()).ToArray() });
        }
        public static UnitColumnProjection Default
        {
            get { return new UnitColumnProjection(new[] { new ProjectedColumn("code", "编号", 120, "text", true),
                new ProjectedColumn("name", "单位名称", 220, "text", true), new ProjectedColumn("status", "状态", 72, "text", true) }); }
        }
    }
    public sealed class UnitColumnLayout
    {
        public IReadOnlyList<string> Order { get; private set; }
        public IReadOnlyCollection<string> Hidden { get; private set; }
        public IReadOnlyCollection<string> Pinned { get; private set; }
        public IReadOnlyDictionary<string, double> Widths { get; private set; }
        public IReadOnlyList<string> AddedIds { get; private set; }
        public static string PreferenceKey { get { return "platform.table." + ColumnJson.Hash(UnitColumnProjection.UnitTableKey).Substring(0, 32); } }
        public UnitColumnLayout(IEnumerable<string> order = null, IEnumerable<string> hidden = null, IEnumerable<string> pinned = null,
            IDictionary<string, double> widths = null, IEnumerable<string> addedIds = null)
        {
            Order = FreezeKeys(order); Hidden = FreezeKeys(hidden); Pinned = FreezeKeys(pinned);
            var pixelWidths = new Dictionary<string, double>(StringComparer.Ordinal);
            foreach (var pair in widths ?? new Dictionary<string, double>())
            {
                ColumnJson.ColumnKey(pair.Key);
                if (Double.IsNaN(pair.Value) || Double.IsInfinity(pair.Value) || pair.Value < 48 || pair.Value > 2000) throw new ArgumentOutOfRangeException(nameof(widths));
                pixelWidths.Add(pair.Key, pair.Value);
            }
            Widths = new ReadOnlyDictionary<string, double>(pixelWidths);
            var ids = (addedIds ?? Enumerable.Empty<string>()).Select(ColumnJson.Uuid).Distinct(StringComparer.OrdinalIgnoreCase).ToList();
            if (ids.Count > 32) throw new ArgumentException("最多32个自设列。", nameof(addedIds));
            AddedIds = ids.AsReadOnly();
        }
        private static IReadOnlyList<string> FreezeKeys(IEnumerable<string> raw)
        { var values = (raw ?? Enumerable.Empty<string>()).Select(ColumnJson.ColumnKey).Distinct(StringComparer.Ordinal).ToList(); if (values.Count > 160) throw new ArgumentException("表头列数超出范围。"); return values.AsReadOnly(); }
        public UnitColumnProjection Project(IReadOnlyDictionary<string, PlatformColumnDefinition> definitions, IEnumerable<string> persistedIds = null)
        {
            var roots = AddedIds.Concat(persistedIds ?? Enumerable.Empty<string>()).Distinct(StringComparer.OrdinalIgnoreCase).ToList();
            var available = UnitColumnProjection.Default.Columns.ToDictionary(column => column.Key, StringComparer.Ordinal);
            foreach (string id in roots)
            {
                PlatformColumnDefinition definition;
                if (!definitions.TryGetValue(id, out definition)) throw new InvalidOperationException("自设列尚未通过当前权限验读。");
                available[definition.Key] = new ProjectedColumn(definition.Key, definition.Name, 160, definition.Numeric ? "number" : "text");
            }
            var ordered = new[] { "code", "name", "status" }.Concat(Order.Where(key => !UnitColumnProjection.Default.Columns.Any(column => column.Key == key)))
                .Concat(available.Keys).Distinct(StringComparer.Ordinal).Where(available.ContainsKey).ToList();
            var required = new HashSet<string>(new[] { "code", "name", "status" }, StringComparer.Ordinal);
            ordered = ordered.Where(key => required.Contains(key) || !Hidden.Contains(key)).ToList();
            ordered = ordered.Where(required.Contains).Concat(ordered.Where(key => !required.Contains(key) && Pinned.Contains(key)))
                .Concat(ordered.Where(key => !required.Contains(key) && !Pinned.Contains(key))).ToList();
            return new UnitColumnProjection(ordered.Select(key => { var column = available[key]; double width;
                return new ProjectedColumn(key, column.Label, Widths.TryGetValue(key, out width) ? width : column.Width, column.Type, required.Contains(key) || Pinned.Contains(key)); }));
        }
        public string ToPreferenceJson(IReadOnlyDictionary<string, PlatformColumnDefinition> definitions)
        {
            var body = new Dictionary<string, object> { ["order"] = Order, ["hidden"] = Hidden.Where(key => key != "code" && key != "name" && key != "status").ToArray(),
                ["pinned"] = new[] { "code", "name", "status" }.Concat(Pinned).Distinct(StringComparer.Ordinal).ToArray(), ["widths"] = Widths,
                ["added"] = AddedIds.Select(id => definitions[id].ToDictionary(false)).ToArray(), ["sortColumn"] = null, ["sortAscending"] = true, ["hasQueryPreferences"] = false };
            string json = ColumnJson.Serialize(body);
            if (Encoding.UTF8.GetByteCount(json) > 16384) throw new InvalidOperationException("表头设置超过16KiB，请减少自设列后重试。");
            return json;
        }
    }
    public sealed class UnitColumnsSnapshot
    {
        public UnitReadOwner Owner { get; internal set; }
        public UnitColumnLayout Layout { get; internal set; }
        public UnitColumnProjection Projection { get; internal set; }
        public PlatformColumnCapabilities Capabilities { get; internal set; }
        public IReadOnlyDictionary<string, PlatformColumnDefinition> Definitions { get; internal set; }
        public IReadOnlyDictionary<string, PlatformColumnRow> Rows { get; internal set; }
        public string DefinitionFingerprint { get; internal set; }
        public IReadOnlyList<string> UnavailableDefinitionIds { get; internal set; }
        public IReadOnlyList<string> ObservedDefinitionIds { get; internal set; }
        public bool PreferencesConfirmed { get; internal set; }
        public bool IsCurrent(SessionCoordinator session) { return Owner != null && Owner.IsCurrent(session); }
        public string DisplayText(string recordId, string columnKey)
        {
            PlatformColumnRow row; PlatformColumnCell cell;
            return Rows.TryGetValue(recordId, out row) && row.Cells.TryGetValue(columnKey, out cell) ? cell.DisplayText : "—";
        }
    }
    internal static class ColumnJson
    {
        internal static object Parse(string json) { return new JavaScriptSerializer { MaxJsonLength = 8388608, RecursionLimit = 64 }.DeserializeObject(json); }
        internal static string Serialize(object value) { return new JavaScriptSerializer { MaxJsonLength = 8388608, RecursionLimit = 64 }.Serialize(value); }
        internal static string Hash(string value) { using (var hash = SHA256.Create()) return String.Concat(hash.ComputeHash(Encoding.UTF8.GetBytes(value)).Select(part => part.ToString("x2", CultureInfo.InvariantCulture))); }
        internal static Dictionary<string, object> Object(object value) { var map = value as Dictionary<string, object>; if (map == null) throw new FormatException("列响应不是对象。"); return map; }
        internal static string Uuid(string value) { Guid id; if (!Guid.TryParseExact(value, "D", out id)) throw new FormatException("列或记录标识不是UUID。"); return id.ToString("D"); }
        internal static string ColumnKey(string value)
        { if (value == "code" || value == "name" || value == "status") return value; if (value != null && value.StartsWith("platform:", StringComparison.Ordinal)) return "platform:" + Uuid(value.Substring(9)); throw new FormatException("单位列键不在已审核范围内。"); }
        internal static string Text(Dictionary<string, object> map, string key)
        { object value; if (!map.TryGetValue(key, out value) || value == null) return null; if (!(value is string)) throw new FormatException("列文字字段无效：" + key); return (string)value; }
        internal static bool Flag(Dictionary<string, object> map, string key)
        { object value; if (!map.TryGetValue(key, out value) || !(value is bool)) throw new FormatException("列能力字段无效：" + key); return (bool)value; }
        internal static long Integer(Dictionary<string, object> map, string key)
        { object value; if (!map.TryGetValue(key, out value) || !(value is int || value is long) || Convert.ToInt64(value, CultureInfo.InvariantCulture) < 0) throw new FormatException("列版本或计数无效：" + key); return Convert.ToInt64(value, CultureInfo.InvariantCulture); }
        internal static object[] Array(object raw) { var values = raw as object[]; if (values == null) throw new FormatException("列响应不是数组。"); return values; }
        internal static string Canonical(object raw)
        {
            var map = raw as IDictionary<string, object>;
            if (map != null) return "{" + String.Join(",", map.OrderBy(pair => pair.Key, StringComparer.Ordinal).Select(pair => Serialize(pair.Key) + ":" + Canonical(pair.Value))) + "}";
            var array = raw as IEnumerable;
            if (array != null && !(raw is string)) return "[" + String.Join(",", array.Cast<object>().Select(Canonical)) + "]";
            return Serialize(raw);
        }
    }
}
