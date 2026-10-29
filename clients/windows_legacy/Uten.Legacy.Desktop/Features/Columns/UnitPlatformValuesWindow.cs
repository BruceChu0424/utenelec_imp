using System;
using System.Collections.Generic;
using System.Collections.ObjectModel;
using System.ComponentModel;
using System.Globalization;
using System.Linq;
using System.Text.RegularExpressions;
using System.Threading;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Data;
using Uten.Legacy.Core;
using Uten.Legacy.Desktop.Controls;
using Uten.Legacy.Desktop.Features.Units;

namespace Uten.Legacy.Desktop.Features.Columns
{
    public sealed class PlatformValueTarget : INotifyPropertyChanged
    {
        private string text; private bool clear, selected;
        public string Id { get; internal set; }
        public string Label { get; internal set; }
        public string Type { get; internal set; }
        public string CurrentText { get; internal set; }
        public bool Editable { get; internal set; }
        public bool Recovery { get; internal set; }
        public bool UseDraft { get { return !Recovery || selected; } set { if (selected == value) return; selected = value; Change("UseDraft"); Change("CanEdit"); Change("CanType"); } }
        public bool CanEdit { get { return Editable && UseDraft; } }
        public bool CanType { get { return CanEdit; } }
        public string TargetText { get { return text; } set { if (text == value) return; text = value; if (clear && !String.IsNullOrEmpty(value)) { clear = false; Change("Clear"); } Change("TargetText"); } }
        public bool Clear { get { return clear; } set { if (clear == value) return; clear = value; if (clear && !String.IsNullOrEmpty(text)) { text = ""; Change("TargetText"); } Change("Clear"); } }
        public string RawValue { get { return Clear ? null : TargetText; } }
        public event PropertyChangedEventHandler PropertyChanged;
        private void Change(string name) { PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(name)); }
    }
    public sealed class UnitPlatformValuesWindow : DurableDraftDialog
    {
        private readonly UnitColumnsService service;
        private readonly UnitColumnsSnapshot source;
        private PlatformColumnRow baseline, saved;
        private UnitReadOwner rowOwner;
        private readonly string recordId, focusColumnId;
        private readonly ObservableCollection<PlatformValueTarget> targets = new ObservableCollection<PlatformValueTarget>();
        private readonly DataGrid table = new DataGrid { Height = 330, CanUserSortColumns = false, SelectionMode = DataGridSelectionMode.Single };
        private readonly TextBlock hint = new TextBlock { TextWrapping = TextWrapping.Wrap };
        private readonly Button review;
        private readonly Dictionary<string, string> recoveredTargets = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        private long recoveredVersion;
        private bool changing, useRestoredRaw, reviewed;
        public PlatformColumnRow SavedRow { get { return IsDraftOwnerCurrent ? saved : null; } }
        public UnitPlatformValuesWindow(Window parent, SessionCoordinator session, UnitColumnsSnapshot source, string recordId,
            string focusColumnId, BusinessDraft restoredDraft = null)
            : base(parent, session, "编辑单位扩展字段", MutationAction.UnitPlatformValuesWrite, ColumnJson.Uuid(recordId), restoredDraft: restoredDraft, width: 1020)
        {
            this.source = source ?? throw new ArgumentNullException(nameof(source)); this.recordId = ColumnJson.Uuid(recordId);
            if (!source.IsCurrent(session) || !source.Owner.Matches(DraftOwner) || !source.Rows.TryGetValue(this.recordId, out baseline))
                throw new ApiException("READ_SCOPE_CHANGED", "字段来源已变化，请重新读取该单位。");
            if (restoredDraft == null && focusColumnId == null) throw new ArgumentException("正常编辑必须明确用户点击的单元格。", nameof(focusColumnId));
            this.focusColumnId = restoredDraft == null ? ColumnJson.Uuid(focusColumnId) : null;
            rowOwner = source.Owner; service = new UnitColumnsService(session); reviewed = restoredDraft == null;
            if (restoredDraft == null)
            {
                PlatformColumnCell focused;
                if (!baseline.Cells.TryGetValue("platform:" + this.focusColumnId, out focused)) throw new ApiException("COLUMN_VALUES_UNAVAILABLE", "所选字段未完整读取，请刷新后重新选择。", 409);
                PlatformValueWriteContract.ToJson(baseline, this.focusColumnId, focused.Value);
            }
            Populate(null); string initial = restoredDraft == null ? TypedBody(baseline.Version) : "";
            if (restoredDraft != null)
            {
                var raw = ColumnJson.Object(ColumnJson.Parse(restoredDraft.BodyJson)); recoveredVersion = ColumnJson.Integer(raw, "expectedVersion");
                object cells; if (!raw.TryGetValue("cells", out cells)) throw new FormatException("原草稿缺少整行字段目标。");
                foreach (object entry in ColumnJson.Array(cells))
                {
                    var cell = ColumnJson.Object(entry);
                    if (!cell.ContainsKey("value")) throw new FormatException("原草稿未明确记录字段值或空值，不能把缺失值猜成清空目标。");
                    recoveredTargets.Add(ColumnJson.Uuid(ColumnJson.Text(cell, "columnId")), ColumnJson.Text(cell, "value"));
                }
                if (recoveredTargets.Count > 32) throw new FormatException("原草稿超过32个字段目标。");
                useRestoredRaw = true; Populate(null);
            }
            hint.Margin = new Thickness(0, 0, 0, Space("S12")); Body.Children.Add(hint);
            table.Columns.Add(new DataGridTextColumn { Header = "字段", Binding = new Binding("Label"), Width = 170 });
            table.Columns.Add(new DataGridTextColumn { Header = "当前值", Binding = new Binding("CurrentText"), Width = new DataGridLength(1, DataGridLengthUnitType.Star) });
            var choose = new FrameworkElementFactory(typeof(CheckBox)); choose.SetBinding(CheckBox.IsCheckedProperty, new Binding("UseDraft") { Mode = BindingMode.TwoWay }); choose.SetBinding(IsEnabledProperty, new Binding("Editable"));
            table.Columns.Add(new DataGridTemplateColumn { Header = "采用草稿目标", Width = 110, Visibility = restoredDraft == null ? Visibility.Collapsed : Visibility.Visible, CellTemplate = new DataTemplate { VisualTree = choose } });
            var input = new FrameworkElementFactory(typeof(TextBox)); input.SetBinding(TextBox.TextProperty, new Binding("TargetText") { Mode = BindingMode.TwoWay, UpdateSourceTrigger = UpdateSourceTrigger.PropertyChanged });
            input.SetBinding(IsEnabledProperty, new Binding("CanType")); input.SetValue(TextBox.MaxLengthProperty, 2000); input.SetValue(StyleProperty, FindResource("Uten.CompactInput")); input.SetValue(MinHeightProperty, FindResource("Uten.Height.Cell"));
            table.Columns.Add(new DataGridTemplateColumn { Header = "目标值", Width = new DataGridLength(1, DataGridLengthUnitType.Star), CellTemplate = new DataTemplate { VisualTree = input } });
            var empty = new FrameworkElementFactory(typeof(CheckBox)); empty.SetBinding(CheckBox.IsCheckedProperty, new Binding("Clear") { Mode = BindingMode.TwoWay }); empty.SetBinding(IsEnabledProperty, new Binding("CanEdit"));
            table.Columns.Add(new DataGridTemplateColumn { Header = "清空", Width = 60, CellTemplate = new DataTemplate { VisualTree = empty } });
            table.ItemsSource = targets; Body.Children.Add(UtenSurfaces.Wrap(table, UtenSurfaceRole.Table));
            review = ActionButton("核对并采用当前字段版本", () => { _ = ReviewAsync(); }); review.Visibility = restoredDraft == null ? Visibility.Collapsed : Visibility.Visible;
            if (restoredDraft != null) Loaded += async (sender, args) => await LoadRecoveredRowAsync();
            InitializeDraftUi("保存字段", initial); UpdateHint();
        }
        private void Populate(IDictionary<string, PlatformValueTarget> previous)
        {
            changing = true;
            try
            {
                foreach (var target in targets) target.PropertyChanged -= TargetChanged; targets.Clear();
                foreach (var cell in baseline.Cells.Values)
                {
                    bool hasRecovered = recoveredTargets.ContainsKey(cell.ColumnId);
                    bool editable = baseline.CanWrite && source.Capabilities.CanWrite && cell.Definition.Editable && !cell.Masked && cell.Error == null
                        && (RestoredDraft == null ? cell.ColumnId == focusColumnId : hasRecovered);
                    PlatformValueTarget prior = null; previous?.TryGetValue(cell.ColumnId, out prior);
                    string value = cell.Masked ? null : prior != null ? prior.RawValue : hasRecovered ? recoveredTargets[cell.ColumnId] : cell.Value;
                    var row = new PlatformValueTarget { Id = cell.ColumnId, Label = cell.Definition.Name, Type = cell.Definition.Type,
                        CurrentText = cell.DisplayText, Editable = editable, Recovery = RestoredDraft != null, TargetText = value ?? "", Clear = value == null,
                        UseDraft = prior?.UseDraft == true };
                    row.PropertyChanged += TargetChanged; targets.Add(row);
                }
            }
            finally { changing = false; }
        }
        private void TargetChanged(object sender, PropertyChangedEventArgs args)
        { if (!changing && (args.PropertyName == "TargetText" || args.PropertyName == "Clear" || args.PropertyName == "UseDraft")) { useRestoredRaw = false; MarkDraftChanged(); } }
        private IReadOnlyDictionary<string, string> Edits()
        { return targets.Where(row => row.Editable && row.UseDraft).ToDictionary(row => row.Id, row => row.RawValue, StringComparer.OrdinalIgnoreCase); }
        private string TypedBody(long version)
        {
            var row = new PlatformColumnRow { RecordId = baseline.RecordId, Version = version, CanWrite = baseline.CanWrite, Cells = baseline.Cells };
            return PlatformValueWriteContract.ToJson(row, Edits());
        }
        protected override string BuildCurrentBody()
        {
            if (useRestoredRaw || RestoredDraft != null && Edits().Count == 0) return RestoredDraft.BodyJson;
            return TypedBody(RestoredDraft != null && !reviewed ? recoveredVersion : baseline.Version);
        }
        protected override bool CanSubmitBody
        {
            get
            {
                if (!reviewed || !rowOwner.IsCurrent(Session) || !source.IsCurrent(Session) || Edits().Count == 0) return false;
                foreach (var target in targets.Where(row => row.Editable && row.UseDraft && row.Type == "NUMBER" && row.RawValue != null && !String.IsNullOrWhiteSpace(row.RawValue)))
                    if (target.RawValue.Trim().Length > 120 || !Regex.IsMatch(target.RawValue.Trim(), @"^[+-]?(?:[0-9]+(?:\.[0-9]*)?|\.[0-9]+)$", RegexOptions.CultureInvariant)) return false;
                TypedBody(baseline.Version); return true;
            }
        }
        protected override void SetEditorEnabled(bool enabled) { base.SetEditorEnabled(enabled); if (review != null) review.IsEnabled = enabled && !reviewed; }
        protected override Task BeforeSubmitAsync(CancellationToken ct)
        {
            if (!rowOwner.IsCurrent(Session) || !rowOwner.Matches(DraftOwner)) throw new ApiException("READ_SCOPE_CHANGED", "字段对照与提交身份不一致，请重新读取。", 403);
            TypedBody(baseline.Version); return Task.CompletedTask;
        }
        protected override Task OnConfirmedAsync(MutationResult response)
        { saved = ColumnReadContract.Rows("[" + response.ResponseJson + "]", new[] { recordId })[recordId]; return Task.CompletedTask; }
        private async Task LoadRecoveredRowAsync()
        {
            try { using (BeginEditorOperation()) { var fresh = await service.ReadRowAsync(recordId, recoveredTargets.Keys.ToArray(), LifetimeToken);
                if (!IsDraftOwnerCurrent) return; baseline = fresh.Value; rowOwner = fresh.Owner; Populate(null); UpdateHint(); } }
            catch (OperationCanceledException) { }
            catch (ApiException error) { if (IsDraftOwnerCurrent) ShowStatus(error.UserMessage, true); }
            catch (Exception) { if (IsDraftOwnerCurrent) ShowStatus("读取恢复对照失败，原草稿保持原样。请重新打开并核对字段。", true); }
        }
        private async Task ReviewAsync()
        {
            try { using (BeginEditorOperation()) {
                var edits = targets.ToDictionary(row => row.Id, StringComparer.OrdinalIgnoreCase);
                var fresh = await service.ReadRowAsync(recordId, recoveredTargets.Keys.ToArray(), LifetimeToken); if (!IsDraftOwnerCurrent) return;
                bool changed = fresh.Value.Version != baseline.Version; baseline = fresh.Value; rowOwner = fresh.Owner; Populate(edits);
                if (changed) { reviewed = false; ShowStatus("当前字段又有更新，已刷新对照。请重新检查每个目标，再采用当前版本。", true); }
                else { reviewed = true; useRestoredRaw = false; MarkDraftChanged(); ShowStatus("已采用当前字段版本。仅勾选的草稿目标会被应用，未勾选字段保留当前值。"); }
                UpdateHint();
            } }
            catch (OperationCanceledException) { }
            catch (ApiException error) { if (IsDraftOwnerCurrent) ShowStatus(error.UserMessage, true); }
            catch (Exception) { if (IsDraftOwnerCurrent) ShowStatus("字段版本暂未核对完成，原输入仍保留。请稍后重试。", true); }
        }
        private void UpdateHint()
        {
            hint.Text = RestoredDraft == null ? "只修改本次点击的字段，其余已存字段保持原值。空值不会当作0；计算展示不能手工回写。"
                : "原草稿没有可证的单格焦点。请逐项勾选要采用的草稿目标，再核对当前字段版本；未勾选项保留当前值，不会自动换版本重发。";
            if (baseline.Cells.Values.Any(cell => cell.Persisted && cell.Masked)) hint.Text += "\n此行存在未完整读取的受保护字段，不能安全保存整行。请先核对查看权限。";
        }
    }
}
