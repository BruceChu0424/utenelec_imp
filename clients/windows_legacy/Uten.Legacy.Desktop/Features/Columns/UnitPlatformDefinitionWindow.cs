using System;
using System.Collections.Generic;
using System.Linq;
using System.Text.RegularExpressions;
using System.Threading;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Controls;
using Uten.Legacy.Core;
using Uten.Legacy.Desktop.Controls;

namespace Uten.Legacy.Desktop.Features.Columns
{
    internal sealed class ColumnOperandEditor : WrapPanel
    {
        private readonly ComboBox kind = new ComboBox { MinWidth = 100 };
        private readonly TextBox constant = new TextBox { MinWidth = 140, MaxLength = 120 };
        private readonly ComboBox column = new ComboBox { MinWidth = 210, DisplayMemberPath = "Name", SelectedValuePath = "Id" };
        internal ColumnOperandEditor(IEnumerable<PlatformColumnDefinition> definitions, Action changed, double gap)
        {
            Orientation = Orientation.Horizontal; kind.ItemsSource = new[] { "常量", "数字列" }; kind.SelectedIndex = 0;
            kind.Margin = new Thickness(0, 0, gap, 0); column.ItemsSource = definitions.Where(value => value.Numeric).ToList();
            constant.Text = "0"; constant.Margin = new Thickness(0, 0, gap, 0);
            Children.Add(kind); Children.Add(constant); Children.Add(column); UpdateVisibility();
            kind.SelectionChanged += (sender, args) => { UpdateVisibility(); changed(); };
            constant.TextChanged += (sender, args) => changed(); column.SelectionChanged += (sender, args) => changed();
        }
        private void UpdateVisibility() { constant.Visibility = kind.SelectedIndex == 0 ? Visibility.Visible : Visibility.Collapsed; column.Visibility = kind.SelectedIndex == 1 ? Visibility.Visible : Visibility.Collapsed; }
        internal Dictionary<string, object> Raw()
        { return kind.SelectedIndex == 1 ? new Dictionary<string, object> { ["columnId"] = column.SelectedValue as string } : new Dictionary<string, object> { ["constant"] = constant.Text }; }
        internal bool Valid
        { get { return kind.SelectedIndex == 1 ? column.SelectedItem != null : constant.Text.Length <= 120 && Regex.IsMatch(constant.Text, @"^[+-]?(?:[0-9]+(?:\.[0-9]*)?|\.[0-9]+)$", RegexOptions.CultureInvariant); } }
        internal string SelectedColumnId { get { return kind.SelectedIndex == 1 ? column.SelectedValue as string : null; } }
        internal void Restore(Dictionary<string, object> value)
        { string id = ColumnJson.Text(value, "columnId"); if (id != null) { kind.SelectedIndex = 1; column.SelectedValue = id; } else { kind.SelectedIndex = 0; constant.Text = ColumnJson.Text(value, "constant") ?? ""; } }
    }
    public sealed class UnitPlatformDefinitionWindow : DurableDraftDialog
    {
        private sealed class StepEditor
        { internal ComboBox Operation; internal ColumnOperandEditor Operand; internal WrapPanel Panel; }
        private readonly UnitColumnsService service;
        private UnitColumnsSnapshot source;
        private readonly TextBox name = new TextBox { MaxLength = 80 };
        private readonly ComboBox type = new ComboBox { DisplayMemberPath = "Value", SelectedValuePath = "Key" };
        private readonly CheckBox protectedPrice = new CheckBox { Content = "按敏感列保护" };
        private readonly StackPanel formula = new StackPanel(), stepsPanel = new StackPanel();
        private readonly ColumnOperandEditor initial;
        private readonly List<StepEditor> steps = new List<StepEditor>();
        private readonly Button review;
        private bool restoring, useRestoredRaw, reviewed;
        private PlatformColumnDefinition created;
        public PlatformColumnDefinition CreatedDefinition { get { return IsDraftOwnerCurrent ? created : null; } }
        public UnitPlatformDefinitionWindow(Window parent, SessionCoordinator session, UnitColumnsSnapshot source, BusinessDraft restoredDraft = null)
            : base(parent, session, "新建单位自设列", MutationAction.UnitPlatformDefinitionCreate, restoredDraft: restoredDraft, width: 820)
        {
            this.source = source ?? throw new ArgumentNullException(nameof(source)); service = new UnitColumnsService(session);
            if (!source.IsCurrent(session) || !source.Owner.Matches(DraftOwner) || !source.Capabilities.CanDefine || session.CurrentUser?.HasPermission("unit:edit") != true)
                throw new ApiException("FORBIDDEN", "当前没有定义单位自设列的权限。", 403);
            reviewed = restoredDraft == null;
            type.ItemsSource = new[] { new KeyValuePair<string, string>("TEXT", "文字说明"), new KeyValuePair<string, string>("NUMBER", "记数字"), new KeyValuePair<string, string>("CALCULATED", "计算展示") };
            type.SelectedValue = "TEXT"; protectedPrice.IsEnabled = source.Capabilities.PriceVisible;
            protectedPrice.Margin = new Thickness(0, Space("S12"), 0, 0);
            Field("列名", name); Field("用途", type); Body.Children.Add(protectedPrice);
            formula.Margin = new Thickness(0, Space("S16"), 0, 0);
            formula.Children.Add(new TextBlock { Text = "计算基数", Margin = new Thickness(0, 0, 0, Space("S8")) });
            initial = new ColumnOperandEditor(source.Definitions.Values, Changed, Space("S8")); formula.Children.Add(initial); formula.Children.Add(stepsPanel);
            var add = new Button { Content = "增加计算步骤", HorizontalAlignment = HorizontalAlignment.Left, Margin = new Thickness(0, Space("S12"), 0, 0) };
            add.Click += (sender, args) => { if (steps.Count < 16) { AddStep(); Changed(); } }; formula.Children.Add(add);
            formula.Children.Add(new TextBlock { Text = "缺失或不可查看的数字不会当作0。计算结果由已有字段和公式生成，不能手工填写。", TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, Space("S12"), 0, 0) });
            Body.Children.Add(formula); UpdateType(); string originalInitial = RawBody();
            if (restoredDraft != null) Restore(restoredDraft.BodyJson);
            name.TextChanged += (sender, args) => Changed(); type.SelectionChanged += (sender, args) => { UpdateType(); Changed(); };
            protectedPrice.Checked += (sender, args) => Changed(); protectedPrice.Unchecked += (sender, args) => Changed();
            review = ActionButton("已核对，继续编辑原目标", () => { reviewed = true; Changed(); ShowStatus("请检查列名、用途、依赖字段和常量后保存。"); });
            review.Visibility = restoredDraft == null ? Visibility.Collapsed : Visibility.Visible;
            Loaded += (sender, args) => name.Focus();
            InitializeDraftUi("创建自设列", originalInitial);
        }
        private void Field(string label, Control input)
        { Body.Children.Add(new TextBlock { Text = label, Margin = new Thickness(0, Space("S12"), 0, Space("S6")) }); System.Windows.Automation.AutomationProperties.SetName(input, label); Body.Children.Add(input); }
        private void AddStep(Dictionary<string, object> restored = null)
        {
            var row = new StepEditor(); row.Panel = new WrapPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(0, Space("S8"), 0, 0) };
            row.Operation = new ComboBox { DisplayMemberPath = "Value", SelectedValuePath = "Key", MinWidth = 90, Margin = new Thickness(0, 0, Space("S8"), 0) };
            row.Operation.ItemsSource = new[] { new KeyValuePair<string, string>("ADD", "加"), new KeyValuePair<string, string>("SUBTRACT", "减"), new KeyValuePair<string, string>("MULTIPLY", "乘"), new KeyValuePair<string, string>("DIVIDE", "除") };
            row.Operation.SelectedValue = "ADD"; row.Operation.SelectionChanged += (sender, args) => Changed();
            row.Operand = new ColumnOperandEditor(source.Definitions.Values, Changed, Space("S8"));
            var remove = new Button { Content = "删除步骤", Margin = new Thickness(Space("S8"), 0, 0, 0) };
            remove.Click += (sender, args) => { steps.Remove(row); stepsPanel.Children.Remove(row.Panel); Changed(); };
            row.Panel.Children.Add(row.Operation); row.Panel.Children.Add(row.Operand); row.Panel.Children.Add(remove); steps.Add(row); stepsPanel.Children.Add(row.Panel);
            if (restored != null) { row.Operation.SelectedValue = ColumnJson.Text(restored, "operation"); object operand; if (restored.TryGetValue("operand", out operand)) row.Operand.Restore(ColumnJson.Object(operand)); }
        }
        private void UpdateType() { formula.Visibility = (type.SelectedValue as string) == "CALCULATED" ? Visibility.Visible : Visibility.Collapsed; }
        private void Changed() { if (restoring) return; useRestoredRaw = false; MarkDraftChanged(); }
        private string RawBody()
        {
            object expression = null;
            if ((type.SelectedValue as string) == "CALCULATED") expression = new Dictionary<string, object> { ["base"] = initial.Raw(),
                ["steps"] = steps.Select(step => new Dictionary<string, object> { ["operation"] = step.Operation.SelectedValue as string, ["operand"] = step.Operand.Raw() }).ToArray() };
            return ColumnJson.Serialize(new Dictionary<string, object> { ["name"] = name.Text, ["type"] = type.SelectedValue as string,
                ["priceProtected"] = protectedPrice.IsChecked == true, ["formula"] = expression });
        }
        private void Restore(string body)
        {
            restoring = true;
            try
            {
                var raw = ColumnJson.Object(ColumnJson.Parse(body)); name.Text = ColumnJson.Text(raw, "name") ?? ""; type.SelectedValue = ColumnJson.Text(raw, "type");
                protectedPrice.IsChecked = ColumnJson.Flag(raw, "priceProtected"); object expression;
                if (raw.TryGetValue("formula", out expression) && expression != null)
                {
                    var value = ColumnJson.Object(expression); object first, operations;
                    if (value.TryGetValue("base", out first)) initial.Restore(ColumnJson.Object(first));
                    if (value.TryGetValue("steps", out operations)) foreach (object step in ColumnJson.Array(operations)) { if (steps.Count >= 16) throw new FormatException("原草稿计算步骤超出范围。"); AddStep(ColumnJson.Object(step)); }
                }
                UpdateType(); useRestoredRaw = true;
            }
            finally { restoring = false; }
        }
        protected override string BuildCurrentBody() { return useRestoredRaw ? RestoredDraft.BodyJson : RawBody(); }
        protected override bool CanSubmitBody
        {
            get { return reviewed && !String.IsNullOrWhiteSpace(name.Text) && name.Text.Length <= 80 && !name.Text.Any(Char.IsControl)
                && type.SelectedValue != null && (type.SelectedValue as string != "CALCULATED" || initial.Valid && steps.All(step => step.Operation.SelectedValue != null && step.Operand.Valid))
                && source.Capabilities.CanDefine && source.IsCurrent(Session); }
        }
        protected override void SetEditorEnabled(bool enabled) { base.SetEditorEnabled(enabled); protectedPrice.IsEnabled = enabled && source.Capabilities.PriceVisible; if (review != null) review.IsEnabled = enabled && !reviewed; }
        protected override async Task BeforeSubmitAsync(CancellationToken ct)
        {
            if (!source.IsCurrent(Session) || !source.Owner.Matches(DraftOwner)) throw new ApiException("READ_SCOPE_CHANGED", "列定义来源已经变化，请重新打开。", 403);
            var references = new[] { initial.SelectedColumnId }.Concat(steps.Select(step => step.Operand.SelectedColumnId)).Where(id => id != null).Distinct(StringComparer.OrdinalIgnoreCase);
            if ((type.SelectedValue as string) == "CALCULATED")
                foreach (string id in references)
                { var fresh = await service.DefinitionAsync(id, ct); if (!fresh.Value.Numeric) throw new ApiException("COLUMN_DEPENDENCY_CHANGED", "所选依赖已不再是可用数字列，请重新核对。", 409); }
        }
        protected override Task OnConfirmedAsync(MutationResult response)
        { created = ColumnReadContract.Definition(ColumnJson.Object(ColumnJson.Parse(response.ResponseJson))); return Task.CompletedTask; }
    }
}
