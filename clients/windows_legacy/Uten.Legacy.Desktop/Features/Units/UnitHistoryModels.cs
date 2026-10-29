using System;
using System.Collections.Generic;
using System.Globalization;
using System.Text;
using System.Text.RegularExpressions;
using System.Web.Script.Serialization;

namespace Uten.Legacy.Desktop.Features.Units
{
    public sealed class UnitOperationEntry
    {
        public string Id { get; internal set; }
        public string OperationType { get; internal set; }
        public string Label { get; internal set; }
        public string Summary { get; internal set; }
        public string CreatedAt { get; internal set; }
        public string CreatedAtDisplay { get { return UnitHistoryContract.ChinaTime(CreatedAt); } }
        public string State { get; internal set; }
        public long Version { get; internal set; }
        public int AffectedCount { get; internal set; }
        public bool CanUndo { get; internal set; }
        public bool CanRedo { get; internal set; }
        public string BlockedReason { get; internal set; }
        public string StateLabel { get { return State == "UNDONE" ? "已撤回" : State == "APPLIED" ? "已应用" : State; } }
    }
    public sealed class UnitOperationEvent
    {
        public string Id { get; internal set; }
        public string OperationId { get; internal set; }
        public string Action { get; internal set; }
        public string Label { get; internal set; }
        public string CreatedAt { get; internal set; }
        public string CreatedAtDisplay { get { return UnitHistoryContract.ChinaTime(CreatedAt); } }
        public string OperationType { get; internal set; }
        public string ActionLabel { get { return Action == "UNDO" ? "撤回" : Action == "REDO" ? "取消撤回" : Action; } }
    }
    public sealed class UnitOperationHistory
    {
        public IReadOnlyList<UnitOperationEntry> Entries { get; internal set; }
        public IReadOnlyList<UnitOperationEvent> Events { get; internal set; }
    }
    public sealed class UnitHistoryChange
    {
        public string Table { get; internal set; }
        public string RowId { get; internal set; }
        public string Field { get; internal set; }
        public string Label { get; internal set; }
        public string BeforeValue { get; internal set; }
        public string AfterValue { get; internal set; }
    }
    public sealed class UnitRecordRevision
    {
        public long Id { get; internal set; }
        public string RecordId { get; internal set; }
        public string RecordLabel { get; internal set; }
        public string RecordCode { get; internal set; }
        public string RecordName { get; internal set; }
        public string Action { get; internal set; }
        public string ActorId { get; internal set; }
        public string ActorName { get; internal set; }
        public string RecordedAt { get; internal set; }
        public string RecordedAtDisplay { get { return UnitHistoryContract.ChinaTime(RecordedAt); } }
        // This is the server's opaque count:max-id token, not a Unit version.
        public string ExpectedHead { get; internal set; }
        public int AffectedCount { get; internal set; }
        public string EntityType { get; internal set; }
        public string SourceType { get; internal set; }
        public string Summary { get; internal set; }
        public bool CanRestoreBefore { get; internal set; }
        public bool CanRestoreAfter { get; internal set; }
        public string BlockedReason { get; internal set; }
        public IReadOnlyList<UnitHistoryChange> Changes { get; internal set; }
        public string ActionLabel { get { return UnitHistoryContract.ActionLabel(Action); } }
        public string SourceLabel { get { return UnitHistoryContract.SourceLabel(SourceType); } }
    }
    public sealed class UnitRecordHistoryPage
    {
        public IReadOnlyList<UnitRecordRevision> Entries { get; internal set; }
        public long? NextCursor { get; internal set; }
    }

    /// <summary>Only the actual unit history filters. Units have no category filter.</summary>
    public sealed class UnitHistoryQuery
    {
        public string RecordId { get; private set; }
        public long? Cursor { get; private set; }
        public string Action { get; private set; }
        public string ActorId { get; private set; }
        public string ActorKeyword { get; private set; }
        public string Keyword { get; private set; }
        public string DateFrom { get; private set; }
        public string DateTo { get; private set; }
        public string SourceType { get; private set; }
        public string SummaryKeyword { get; private set; }
        public int Size { get; private set; }
        public UnitHistoryQuery(string recordId = null, long? cursor = null, string action = null,
            string actorId = null, string actorKeyword = null, string keyword = null, string dateFrom = null,
            string dateTo = null, int size = 50, string sourceType = null, string summaryKeyword = null)
        {
            if (recordId != null) UnitHistoryContract.RequireUuid(recordId);
            if (actorId != null) UnitHistoryContract.RequireUuid(actorId);
            if (cursor.HasValue && cursor.Value <= 0) throw new ArgumentOutOfRangeException(nameof(cursor));
            if (size < 1 || size > 100) throw new ArgumentOutOfRangeException(nameof(size));
            if (action != null && action != "CREATE" && action != "EDIT" && action != "DELETE" && action != "STATUS" && action != "RESTORE")
                throw new ArgumentException("不支持的历史动作。", nameof(action));
            if (sourceType != null && sourceType != "RECORD" && sourceType != "EXTENSION" && sourceType != "CATEGORY" && sourceType != "BOM")
                throw new ArgumentException("不支持的历史修改范围。", nameof(sourceType));
            ValidateDate(dateFrom); ValidateDate(dateTo);
            RecordId = recordId; Cursor = cursor; Action = action; ActorId = actorId; ActorKeyword = actorKeyword;
            Keyword = keyword; DateFrom = dateFrom; DateTo = dateTo; Size = size; SourceType = sourceType; SummaryKeyword = summaryKeyword;
        }
        private static void ValidateDate(string value)
        {
            if (String.IsNullOrEmpty(value)) return;
            DateTime day; DateTimeOffset instant;
            if (!DateTime.TryParseExact(value, "yyyy-MM-dd", CultureInfo.InvariantCulture, DateTimeStyles.None, out day)
                && !(value.IndexOf('T') > 0 && Regex.IsMatch(value, @"(?:Z|[+-][0-9]{2}:[0-9]{2})$", RegexOptions.CultureInvariant)
                    && DateTimeOffset.TryParse(value, CultureInfo.InvariantCulture, DateTimeStyles.None, out instant)))
                throw new ArgumentException("日期请使用 yyyy-MM-dd 或含时区的 ISO 时间。");
        }
        public string ToRelativePath()
        {
            var path = new StringBuilder("/master/record-history?entityType=units&size=").Append(Size.ToString(CultureInfo.InvariantCulture));
            Add(path, "recordId", RecordId); Add(path, "cursor", Cursor?.ToString(CultureInfo.InvariantCulture));
            Add(path, "action", Action); Add(path, "actorId", ActorId); Add(path, "actorKeyword", ActorKeyword);
            Add(path, "keyword", Keyword); Add(path, "dateFrom", DateFrom); Add(path, "dateTo", DateTo);
            Add(path, "sourceType", SourceType); Add(path, "summaryKeyword", SummaryKeyword);
            return path.ToString();
        }
        private static void Add(StringBuilder path, string key, string value)
        { if (!String.IsNullOrEmpty(value)) path.Append('&').Append(key).Append('=').Append(Uri.EscapeDataString(value)); }
    }

    public static class UnitHistoryContract
    {
        public const string OperationsPath = "/master/operation-history?entityType=units";
        internal static string RequireUuid(string value)
        { Guid parsed; if (!Guid.TryParseExact(value, "D", out parsed)) throw new FormatException("历史资料标识不是 UUID。"); return value; }
        public static string RecordDetailPath(long id)
        { if (id <= 0) throw new ArgumentOutOfRangeException(nameof(id)); return "/master/record-history/" + id.ToString(CultureInfo.InvariantCulture) + "?entityType=units"; }
        public static string ReplayBody(long version)
        { if (version < 0) throw new ArgumentOutOfRangeException(nameof(version)); return "{\"expectedVersion\":" + version.ToString(CultureInfo.InvariantCulture) + "}"; }
        public static string RestoreBody(string expectedHead, bool before)
        {
            if (String.IsNullOrWhiteSpace(expectedHead) || expectedHead.Length > 128) throw new ArgumentException("请重新读取历史详情中的当前校验标记。", nameof(expectedHead));
            return new JavaScriptSerializer().Serialize(new Dictionary<string, object> { ["expectedHead"] = expectedHead, ["before"] = before });
        }
        public static UnitOperationHistory ParseOperations(string json)
        {
            var root = UnitJson.Object(UnitJson.Parse(json));
            var entries = new List<UnitOperationEntry>(); var seen = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            foreach (object raw in Rows(root, "entries"))
            {
                var row = UnitJson.Object(raw); string id = RequireUuid(Text(row, "id"));
                if (!seen.Add(id)) throw new FormatException("历史响应包含重复操作。");
                entries.Add(new UnitOperationEntry { Id = id, OperationType = Text(row, "operationType"), Label = Text(row, "label"),
                    Summary = Text(row, "summary"), CreatedAt = Text(row, "createdAt"), State = Text(row, "state"),
                    Version = UnitJson.Integer(row, "version", 0, Int64.MaxValue), AffectedCount = (int)UnitJson.Integer(row, "affectedCount", 0, Int32.MaxValue),
                    CanUndo = Flag(row, "canUndo"), CanRedo = Flag(row, "canRedo"), BlockedReason = UnitJson.Text(row, "blockedReason") });
            }
            var events = new List<UnitOperationEvent>();
            foreach (object raw in Rows(root, "events"))
            {
                var row = UnitJson.Object(raw); events.Add(new UnitOperationEvent { Id = Text(row, "id"), OperationId = RequireUuid(Text(row, "operationId")),
                    Action = Text(row, "action"), Label = Text(row, "label"), CreatedAt = Text(row, "createdAt"), OperationType = Text(row, "operationType") });
            }
            return new UnitOperationHistory { Entries = entries.AsReadOnly(), Events = events.AsReadOnly() };
        }
        public static UnitRecordHistoryPage ParseRecordPage(string json)
        {
            var root = UnitJson.Object(UnitJson.Parse(json)); var entries = new List<UnitRecordRevision>(); var seen = new HashSet<long>();
            foreach (object raw in Rows(root, "entries"))
            {
                var row = ReadRevision(UnitJson.Object(raw));
                if (!seen.Add(row.Id)) throw new FormatException("历史响应包含重复版本。");
                entries.Add(row);
            }
            string cursor = UnitJson.Text(root, "nextCursor");
            return new UnitRecordHistoryPage { Entries = entries.AsReadOnly(), NextCursor = cursor == null ? (long?)null : PositiveId(cursor) };
        }
        public static UnitRecordRevision ParseRecordDetail(string json) { return ReadRevision(UnitJson.Object(UnitJson.Parse(json))); }
        private static UnitRecordRevision ReadRevision(Dictionary<string, object> row)
        {
            string entity = Text(row, "entityType");
            if (entity != "units") throw new FormatException("返回的历史不属于单位资料。");
            var changes = new List<UnitHistoryChange>();
            foreach (object raw in Rows(row, "changes"))
            {
                var cell = UnitJson.Object(raw); string rowId = UnitJson.Text(cell, "rowId");
                if (rowId != null) RequireUuid(rowId);
                changes.Add(new UnitHistoryChange { Table = Text(cell, "table"), RowId = rowId, Field = Text(cell, "field"), Label = Text(cell, "label"),
                    BeforeValue = Text(cell, "beforeValue"), AfterValue = Text(cell, "afterValue") });
            }
            string actorId = UnitJson.Text(row, "actorId"); if (actorId != null) RequireUuid(actorId);
            return new UnitRecordRevision { Id = PositiveId(Text(row, "id")), RecordId = RequireUuid(Text(row, "recordId")),
                RecordLabel = Text(row, "recordLabel"), RecordCode = Text(row, "recordCode"), RecordName = Text(row, "recordName"),
                Action = Text(row, "action"), ActorId = actorId, ActorName = Text(row, "actorName"), RecordedAt = Text(row, "recordedAt"),
                ExpectedHead = Text(row, "expectedHead"), AffectedCount = (int)UnitJson.Integer(row, "affectedCount", 0, Int32.MaxValue),
                EntityType = entity, SourceType = Text(row, "sourceType"), Summary = Text(row, "summary"), CanRestoreBefore = Flag(row, "canRestoreBefore"),
                CanRestoreAfter = Flag(row, "canRestoreAfter"), BlockedReason = UnitJson.Text(row, "blockedReason"), Changes = changes.AsReadOnly() };
        }
        internal static long PositiveId(string text)
        {
            long value;
            if (String.IsNullOrEmpty(text) || !Int64.TryParse(text, NumberStyles.None, CultureInfo.InvariantCulture, out value) || value <= 0
                || text != value.ToString(CultureInfo.InvariantCulture)) throw new FormatException("历史版本标识不是有效的正整数。");
            return value;
        }
        private static string Text(Dictionary<string, object> row, string key) { return UnitJson.Text(row, key) ?? ""; }
        private static bool Flag(Dictionary<string, object> row, string key)
        { object value; if (!row.TryGetValue(key, out value) || !(value is bool)) throw new FormatException("历史能力字段不是布尔值：" + key); return (bool)value; }
        private static object[] Rows(Dictionary<string, object> row, string key)
        { object value; if (!row.TryGetValue(key, out value) || !(value is object[])) throw new FormatException("历史响应缺少数组：" + key); return (object[])value; }
        public static string ActionLabel(string value)
        { switch (value) { case "CREATE": return "新增"; case "EDIT": return "编辑"; case "DELETE": return "删除"; case "STATUS": return "状态"; case "RESTORE": return "恢复版本"; default: return value; } }
        public static string SourceLabel(string value)
        { switch (value) { case "RECORD": return "资料字段"; case "EXTENSION": return "扩展字段"; case "CATEGORY": return "分类"; case "BOM": return "BOM"; default: return value; } }
        public static string ChinaTime(string value)
        {
            DateTimeOffset instant;
            return DateTimeOffset.TryParse(value, CultureInfo.InvariantCulture, DateTimeStyles.None, out instant)
                ? instant.ToOffset(TimeSpan.FromHours(8)).ToString("yyyy-MM-dd HH:mm:ss", CultureInfo.InvariantCulture) : value;
        }
    }
}
