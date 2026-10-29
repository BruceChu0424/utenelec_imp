using System;
using System.Collections.Generic;
using System.Collections.ObjectModel;
using System.Web.Script.Serialization;

namespace Uten.Legacy.Desktop.Features.Units
{
    /// <summary>Real supplemental wire contracts. These are not arbitrary-write transport adapters.</summary>
    public sealed class UnitInlinePatch
    {
        public string Id { get; private set; }
        public IReadOnlyDictionary<string, UnitOptionalText> Expected { get; private set; }
        public IReadOnlyDictionary<string, UnitOptionalText> Changes { get; private set; }
        public string RelativePath { get { return "/master/inline-edit/units/" + Id; } }
        public string Method { get { return "PATCH"; } }
        public bool CoreTypedAdapterAvailable { get { return true; } }
        public bool ServerReceiptAvailable { get { return false; } }

        public UnitInlinePatch(string id, IDictionary<string, UnitOptionalText> expected,
            IDictionary<string, UnitOptionalText> changes, bool controlledMeasurementFields = false)
        {
            UnitReadContract.DetailPath(id); Id = id;
            var allowed = new HashSet<string>(StringComparer.Ordinal) { "name", "status" };
            if (controlledMeasurementFields) { allowed.Add("measurementDimension"); allowed.Add("massUnitCode"); }
            if (changes == null || changes.Count == 0 || expected == null)
                throw new ArgumentException("行内编辑必须有变更及每个字段的原值。");
            var before = new Dictionary<string, UnitOptionalText>();
            var after = new Dictionary<string, UnitOptionalText>();
            foreach (var entry in changes)
            {
                UnitOptionalText original;
                if (!allowed.Contains(entry.Key) || entry.Value == null || !entry.Value.IsPresent
                    || !expected.TryGetValue(entry.Key, out original) || original == null || !original.IsPresent)
                    throw new ArgumentException("行内编辑字段或原值缺失；编号不能通过此接口修改。");
                before.Add(entry.Key, original); after.Add(entry.Key, entry.Value);
            }
            Expected = new ReadOnlyDictionary<string, UnitOptionalText>(before);
            Changes = new ReadOnlyDictionary<string, UnitOptionalText>(after);
        }
        public string ToJson()
        {
            return new JavaScriptSerializer().Serialize(new Dictionary<string, object> {
                ["expected"] = Values(Expected), ["changes"] = Values(Changes) });
        }
        private static Dictionary<string, object> Values(IReadOnlyDictionary<string, UnitOptionalText> source)
        {
            var result = new Dictionary<string, object>();
            foreach (var item in source) result.Add(item.Key, item.Value.Value);
            return result;
        }
    }

    public enum UnitBatchAction { Status, Delete }

    public sealed class UnitBatchCommand
    {
        public const int MaximumItems = 500;
        public UnitBatchAction Action { get; private set; }
        public string Status { get; private set; }
        public IReadOnlyList<string> Ids { get; private set; }
        public string RelativePath { get { return "/master/units/" + (Action == UnitBatchAction.Status ? "batch-status" : "batch-delete"); } }
        public string Method { get { return "POST"; } }
        public string RequiredPermission { get { return Action == UnitBatchAction.Status ? "unit:status" : "unit:delete"; } }
        public bool EnforcesExpectedVersion { get { return false; } }
        public bool ServerReceiptAvailable { get { return false; } }
        public bool CoreTypedAdapterAvailable { get { return true; } }
        public UnitBatchCommand(UnitBatchAction action, IEnumerable<string> ids, string status = null)
        {
            if (action != UnitBatchAction.Status && action != UnitBatchAction.Delete) throw new ArgumentOutOfRangeException(nameof(action));
            if (action == UnitBatchAction.Status && status != "使用" && status != "禁用") throw new ArgumentException("请选择使用或禁用状态。", nameof(status));
            if (action == UnitBatchAction.Delete && status != null) throw new ArgumentException("删除命令不携带状态。", nameof(status));
            if (ids == null) throw new ArgumentNullException(nameof(ids));
            var unique = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            var frozen = new List<string>();
            int rawCount = 0;
            foreach (string id in ids)
            {
                if (++rawCount > MaximumItems) throw new ArgumentException("一次批量最多500条。", nameof(ids));
                UnitReadContract.DetailPath(id);
                if (unique.Add(id)) frozen.Add(id);
            }
            if (frozen.Count == 0) throw new ArgumentException("请先选择单位。", nameof(ids));
            Action = action; Status = status; Ids = new ReadOnlyCollection<string>(frozen);
        }
        public string ToJson()
        {
            var items = new List<Dictionary<string, object>>();
            foreach (string id in Ids) items.Add(new Dictionary<string, object> { ["id"] = id });
            var body = new Dictionary<string, object> { ["items"] = items };
            if (Action == UnitBatchAction.Status) body.Add("status", Status);
            return new JavaScriptSerializer().Serialize(body);
        }
    }
    public sealed class UnitBatchItemResult
    {
        public string Id { get; internal set; }
        public string Label { get; internal set; }
        public bool Ok { get; internal set; }
        public string Reason { get; internal set; }
    }
    public sealed class UnitBatchResult
    {
        public int Succeeded { get; private set; }
        public int Failed { get; private set; }
        public IReadOnlyList<UnitBatchItemResult> Results { get; private set; }
        public static UnitBatchResult Parse(string json, UnitBatchCommand command)
        {
            if (command == null) throw new ArgumentNullException(nameof(command));
            var value = UnitJson.Object(UnitJson.Parse(json));
            int succeeded = (int)UnitJson.Integer(value, "succeeded", 0, UnitBatchCommand.MaximumItems);
            int failed = (int)UnitJson.Integer(value, "failed", 0, UnitBatchCommand.MaximumItems);
            object raw;
            var entries = value.TryGetValue("results", out raw) ? raw as object[] : null;
            if (entries == null || entries.Length != command.Ids.Count || succeeded + failed != entries.Length)
                throw new FormatException("单位批量结果不完整，不能推测未确认条目。");
            var expected = new HashSet<string>(command.Ids, StringComparer.OrdinalIgnoreCase);
            var seen = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            var rows = new List<UnitBatchItemResult>(); int actualSucceeded = 0;
            foreach (object entry in entries)
            {
                var item = UnitJson.Object(entry);
                string id = UnitJson.Text(item, "id"); object ok;
                if (id == null || !expected.Contains(id) || !seen.Add(id) || !item.TryGetValue("ok", out ok) || !(ok is bool))
                    throw new FormatException("单位批量结果包含其他条目或无效状态。");
                if ((bool)ok) actualSucceeded++;
                rows.Add(new UnitBatchItemResult { Id = id, Ok = (bool)ok, Label = UnitJson.Text(item, "label"), Reason = UnitJson.Text(item, "reason") });
            }
            if (actualSucceeded != succeeded) throw new FormatException("单位批量结果计数不一致。");
            return new UnitBatchResult { Succeeded = succeeded, Failed = failed, Results = new ReadOnlyCollection<UnitBatchItemResult>(rows) };
        }
    }
}
