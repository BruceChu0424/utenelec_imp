using System;
using System.Collections.Generic;
using System.Linq;

namespace Uten.Legacy.Desktop.Features.Columns
{
    public sealed class ColumnFormulaOperand
    {
        public string ColumnId { get; private set; }
        public string Constant { get; private set; }
        private ColumnFormulaOperand() { }
        public static ColumnFormulaOperand Column(string id) { return new ColumnFormulaOperand { ColumnId = ColumnJson.Uuid(id) }; }
        public static ColumnFormulaOperand Literal(string value)
        {
            if (String.IsNullOrWhiteSpace(value) || value.Length > 120) throw new ArgumentException("请填写有界的原始数字常量。", nameof(value));
            return new ColumnFormulaOperand { Constant = value };
        }
        internal Dictionary<string, object> ToDictionary()
        { return ColumnId != null ? new Dictionary<string, object> { ["columnId"] = ColumnId } : new Dictionary<string, object> { ["constant"] = Constant }; }
    }
    public sealed class ColumnFormulaStep
    {
        public string Operation { get; private set; }
        public ColumnFormulaOperand Operand { get; private set; }
        public ColumnFormulaStep(string operation, ColumnFormulaOperand operand)
        {
            if (operation != "ADD" && operation != "SUBTRACT" && operation != "MULTIPLY" && operation != "DIVIDE") throw new ArgumentException("请选择加、减、乘、除。", nameof(operation));
            Operation = operation; Operand = operand ?? throw new ArgumentNullException(nameof(operand));
        }
        internal Dictionary<string, object> ToDictionary() { return new Dictionary<string, object> { ["operation"] = Operation, ["operand"] = Operand.ToDictionary() }; }
    }
    public sealed class ColumnFormulaInput
    {
        public ColumnFormulaOperand Base { get; private set; }
        public IReadOnlyList<ColumnFormulaStep> Steps { get; private set; }
        public ColumnFormulaInput(ColumnFormulaOperand initial, IEnumerable<ColumnFormulaStep> steps = null)
        {
            Base = initial ?? throw new ArgumentNullException(nameof(initial)); var frozen = (steps ?? Enumerable.Empty<ColumnFormulaStep>()).ToList();
            if (frozen.Count > 16 || frozen.Any(step => step == null)) throw new ArgumentException("计算公式最多16步。", nameof(steps));
            Steps = frozen.AsReadOnly();
        }
        internal Dictionary<string, object> ToDictionary() { return new Dictionary<string, object> { ["base"] = Base.ToDictionary(), ["steps"] = Steps.Select(step => step.ToDictionary()).ToArray() }; }
    }
    public sealed class PlatformColumnCreateInput
    {
        public string Name { get; private set; }
        public string Type { get; private set; }
        public bool PriceProtected { get; private set; }
        public ColumnFormulaInput Formula { get; private set; }
        public PlatformColumnCreateInput(string name, string type, bool priceProtected = false, ColumnFormulaInput formula = null)
        {
            if (String.IsNullOrWhiteSpace(name) || name.Length > 80 || name.Any(Char.IsControl)) throw new ArgumentException("列名需为1至80个可见字符。", nameof(name));
            if (type != "TEXT" && type != "NUMBER" && type != "CALCULATED") throw new ArgumentException("单位仅支持文字、记数字和计算展示列。", nameof(type));
            if ((type == "CALCULATED") != (formula != null)) throw new ArgumentException("计算展示列需要公式，普通列不能带公式。", nameof(formula));
            Name = name; Type = type; PriceProtected = priceProtected; Formula = formula;
        }
        public string ToJson()
        {
            return ColumnJson.Serialize(new Dictionary<string, object> { ["name"] = Name, ["type"] = Type,
                ["priceProtected"] = PriceProtected, ["formula"] = Formula?.ToDictionary() });
        }
    }
    public static class PlatformValueWriteContract
    {
        public static string ToJson(PlatformColumnRow baseline, string columnId, string value)
        {
            return ToJson(baseline, new Dictionary<string, string> { [ColumnJson.Uuid(columnId)] = value });
        }
        public static string ToJson(PlatformColumnRow baseline, IReadOnlyDictionary<string, string> edits)
        {
            if (baseline == null) throw new ArgumentNullException(nameof(baseline));
            if (edits == null || edits.Count == 0 || edits.Count > 32) throw new ArgumentException("请选择最多32个字段目标。", nameof(edits));
            var targets = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
            foreach (var edit in edits)
            {
                string id = ColumnJson.Uuid(edit.Key); PlatformColumnCell target;
                if (!baseline.CanWrite || !baseline.Cells.TryGetValue("platform:" + id, out target) || !target.Definition.Editable || target.Masked || target.Error != null)
                    throw new InvalidOperationException("此字段当前只能查看，请重新读取权限与字段资料。");
                targets.Add(id, edit.Value);
            }
            // The owning PUT replaces the row. Its masked-null preservation depends on current price access,
            // which can change independently of the field-row CAS. A missing hidden value is not a safe clear.
            if (baseline.Cells.Values.Any(cell => cell.Persisted && cell.Masked))
                throw new InvalidOperationException("此行有未完整读取的受保护字段，不能安全保全整行；请先核对字段查看权限。");
            var cells = new List<Dictionary<string, object>>();
            foreach (var cell in baseline.Cells.Values.Where(cell => cell.Persisted && !targets.ContainsKey(cell.ColumnId)))
            {
                if (cell.Definition.Type == "RELATED") throw new InvalidOperationException("关联展示列不能作为业务字段回写。");
                cells.Add(new Dictionary<string, object> { ["columnId"] = cell.ColumnId,
                    ["value"] = cell.Masked || cell.Definition.Type == "CALCULATED" ? null : cell.Value });
            }
            foreach (var target in targets) cells.Add(new Dictionary<string, object> { ["columnId"] = target.Key, ["value"] = target.Value });
            if (cells.Count > 32) throw new InvalidOperationException("最多保存32个扩展字段，未丢弃原有字段。");
            return ColumnJson.Serialize(new Dictionary<string, object> { ["expectedVersion"] = baseline.Version, ["cells"] = cells });
        }
    }
}
