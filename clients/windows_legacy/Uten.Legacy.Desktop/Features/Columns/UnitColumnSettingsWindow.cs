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

namespace Uten.Legacy.Desktop.Features.Columns
{
    public sealed class ColumnSettingRow : INotifyPropertyChanged
    {
        private bool visible, pinned;
        private string widthText;
        public string Key { get; internal set; }
        public string Label { get; internal set; }
        public string TypeLabel { get; internal set; }
        public bool Required { get { return Key == "code" || Key == "name" || Key == "status"; } }
        public bool CanToggle { get { return !Required; } }
        public bool Visible { get { return Required || visible; } set { bool next = Required || value; if (visible == next) return; visible = next; Changed("Visible"); if (!next) Pinned = false; } }
        public bool Pinned { get { return Required || pinned; } set { bool next = Required || value; if (pinned == next) return; pinned = next; Changed("Pinned"); } }
        public string WidthText { get { return widthText; } set { if (widthText == value) return; widthText = value; Changed("WidthText"); } }
        public event PropertyChangedEventHandler PropertyChanged;
        private void Changed(string name) { PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(name)); }
    }

    public sealed class UnitColumnSettingsWindow : DurableDraftDialog
    {
        private readonly UnitColumnsService service;
        private UnitColumnsSnapshot current, applied;
        private readonly ObservableCollection<ColumnSettingRow> rows = new ObservableCollection<ColumnSettingRow>();
        private readonly DataGrid table = new DataGrid { Height = 250, SelectionMode = DataGridSelectionMode.Single, CanUserSortColumns = false };
        private readonly ListBox catalog = new ListBox { Height = 160, DisplayMemberPath = "Name", BorderThickness = new Thickness(0) };
        private readonly TextBox search = new TextBox { MinWidth = 230, MaxLength = 80 };
        private readonly Button add, create, delete, review;
        private readonly List<string> addedIds;
        private readonly Dictionary<string, int> pinOrigins = new Dictionary<string, int>(StringComparer.Ordinal);
        private readonly HashSet<string> attemptedDeletes = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        private bool changing, useRestoredRaw, reviewed, catalogUnresolved;
        public bool HasCatalogChanges { get; private set; }
        public UnitColumnsSnapshot AppliedSnapshot { get { return applied?.IsCurrent(Session) == true ? applied : null; } }

        public UnitColumnSettingsWindow(Window parent, SessionCoordinator session, UnitColumnsSnapshot source, BusinessDraft restoredDraft = null)
            : base(parent, session, "单位表头设置", MutationAction.UnitColumnLayoutSave, restoredDraft: restoredDraft, width: 900)
        {
            current = source ?? throw new ArgumentNullException(nameof(source));
            if (!source.IsCurrent(session) || !source.Owner.Matches(DraftOwner)) throw new ApiException("READ_SCOPE_CHANGED", "表头来源已经变化，请重新打开设置。");
            service = new UnitColumnsService(session); addedIds = source.Layout.AddedIds.ToList(); reviewed = restoredDraft == null;
            PopulateRows(source.Layout); string initial = BuildPreferenceBody();
            if (restoredDraft != null)
            {
                var raw = ColumnJson.Object(ColumnJson.Parse(restoredDraft.BodyJson)); var restoredLayout = ColumnReadContract.Layout(raw);
                addedIds.Clear(); addedIds.AddRange(restoredLayout.AddedIds); PopulateRows(restoredLayout);
                object widths;
                if (raw.TryGetValue("widths", out widths) && widths != null)
                    foreach (var pair in ColumnJson.Object(widths))
                    { var row = rows.FirstOrDefault(item => item.Key == pair.Key); if (row != null && pair.Value is string) row.WidthText = (string)pair.Value; }
                useRestoredRaw = true;
            }
            table.Columns.Add(new DataGridTextColumn { Header = "列名", Binding = new Binding("Label"), Width = new DataGridLength(1, DataGridLengthUnitType.Star) });
            table.Columns.Add(new DataGridTextColumn { Header = "类型", Binding = new Binding("TypeLabel"), Width = 110 });
            table.Columns.Add(ToggleColumn("显示", "Visible")); table.Columns.Add(ToggleColumn("固定", "Pinned"));
            var widthFactory = new FrameworkElementFactory(typeof(TextBox)); widthFactory.SetBinding(TextBox.TextProperty, new Binding("WidthText") { Mode = BindingMode.TwoWay, UpdateSourceTrigger = UpdateSourceTrigger.PropertyChanged });
            widthFactory.SetValue(StyleProperty, FindResource("Uten.CompactInput")); widthFactory.SetValue(MinHeightProperty, FindResource("Uten.Height.Cell"));
            table.Columns.Add(new DataGridTemplateColumn { Header = "列宽（像素）", CellTemplate = new DataTemplate { VisualTree = widthFactory }, Width = 150 });
            table.ItemsSource = rows;
            Body.Children.Add(new TextBlock { Text = "编号、单位名称、状态始终显示并固定在前。自设列可调整顺序、显隐和固定位置；屏幕、预览打印与下载共用此表头。", TextWrapping = TextWrapping.Wrap,
                Margin = new Thickness(0, 0, 0, Space("S12")) });
            Body.Children.Add(UtenSurfaces.Wrap(table, UtenSurfaceRole.Table));
            var moves = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(0, Space("S8"), 0, Space("S16")) };
            var up = new Button { Content = "上移", Margin = new Thickness(0, 0, Space("S8"), 0) }; up.Click += (sender, args) => MoveSelected(-1);
            var down = new Button { Content = "下移" }; down.Click += (sender, args) => MoveSelected(1); moves.Children.Add(up); moves.Children.Add(down); Body.Children.Add(moves);
            var catalogHeader = new WrapPanel { Margin = new Thickness(0, 0, 0, Space("S8")) };
            catalog.SetResourceReference(BackgroundProperty, "Uten.Surface"); catalog.SetResourceReference(ForegroundProperty, "Uten.Text");
            search.ToolTip = "按自设列名称查找"; System.Windows.Automation.AutomationProperties.SetName(search, "按自设列名称查找");
            search.SetResourceReference(StyleProperty, "Uten.CompactInput"); catalogHeader.Children.Add(search);
            var find = new Button { Content = "查找自设列", Margin = new Thickness(Space("S8"), 0, Space("S8"), 0) };
            find.Click += async (sender, args) => await SearchAsync(); catalogHeader.Children.Add(find);
            add = new Button { Content = "添加所选列", Margin = new Thickness(0, 0, Space("S8"), 0) }; add.Click += async (sender, args) => await AddSelectedAsync(); catalogHeader.Children.Add(add);
            create = new Button { Content = "新建自设列", Margin = new Thickness(0, 0, Space("S8"), 0) }; create.Click += async (sender, args) => await CreateAsync(); catalogHeader.Children.Add(create);
            delete = new Button { Content = "删除所选目录列" }; delete.Click += async (sender, args) => await DeleteSelectedAsync(); catalogHeader.Children.Add(delete);
            Body.Children.Add(catalogHeader); Body.Children.Add(UtenSurfaces.Wrap(catalog, UtenSurfaceRole.Table));
            catalog.SelectionChanged += (sender, args) => UpdateCatalogActions();
            review = ActionButton("核对后采用当前字段定义", () => { _ = ReviewRestoredAsync(); }); review.Visibility = restoredDraft == null ? Visibility.Collapsed : Visibility.Visible;
            InitializeDraftUi("保存表头", initial); UpdateCatalogActions();
            if (!source.PreferencesConfirmed) ShowStatus("当前尚未确认账号的完整偏好快照。可以核对表头，暂不能覆盖远端设置，请刷新后重新打开。", true);
            if (source.UnavailableDefinitionIds.Count > 0) ShowStatus("有已失效或不属于当前范围的列未被加载，请核对后保存新的表头。", true);
            if (source.OverflowedDefinitionIds.Count > 0)
                ShowStatus("当前资料有 " + source.OverflowedDefinitionIds.Count.ToString(CultureInfo.InvariantCulture)
                    + " 个自设列超出单表32列上限：这些列的原值和定义仍保留；隐藏暂不查看的列或移除已添加列后，其余列会按稳定顺序补入显示。", true);
        }
        private DataGridTemplateColumn ToggleColumn(string label, string property)
        {
            var factory = new FrameworkElementFactory(typeof(CheckBox)); factory.SetBinding(CheckBox.IsCheckedProperty, new Binding(property) { Mode = BindingMode.TwoWay });
            factory.SetBinding(IsEnabledProperty, new Binding("CanToggle")); factory.SetValue(HorizontalAlignmentProperty, HorizontalAlignment.Center);
            return new DataGridTemplateColumn { Header = label, Width = 75, CellTemplate = new DataTemplate { VisualTree = factory } };
        }
        private void PopulateRows(UnitColumnLayout layout)
        {
            changing = true;
            try
            {
                foreach (var row in rows) row.PropertyChanged -= OnRowChanged; rows.Clear();
                var baseColumns = UnitColumnProjection.Default.Columns.ToDictionary(column => column.Key, StringComparer.Ordinal);
                var customIds = addedIds.Concat(current.ObservedDefinitionIds).Distinct(StringComparer.OrdinalIgnoreCase).Where(current.Definitions.ContainsKey).ToList();
                foreach (string id in customIds) { var definition = current.Definitions[id]; baseColumns[definition.Key] = new ProjectedColumn(definition.Key, definition.Name, 160, definition.Numeric ? "number" : "text"); }
                var keys = new[] { "code", "name", "status" }.Concat(layout.Order).Concat(baseColumns.Keys).Distinct(StringComparer.Ordinal).Where(baseColumns.ContainsKey);
                foreach (string key in keys)
                {
                    var column = baseColumns[key]; double width;
                    var row = new ColumnSettingRow { Key = key, Label = column.Label, TypeLabel = column.PlatformId == null ? "系统列" : current.Definitions[column.PlatformId].TypeLabel,
                        WidthText = (layout.Widths.TryGetValue(key, out width) ? width : column.Width).ToString(CultureInfo.InvariantCulture), Visible = !layout.Hidden.Contains(key), Pinned = layout.Pinned.Contains(key) };
                    row.PropertyChanged += OnRowChanged; rows.Add(row);
                }
            }
            finally { changing = false; }
        }
        private void OnRowChanged(object sender, PropertyChangedEventArgs args)
        {
            if (changing) return;
            var row = (ColumnSettingRow)sender;
            if (args.PropertyName == "Pinned" && !row.Required)
            {
                changing = true;
                try
                {
                    int index = rows.IndexOf(row), target;
                    if (row.Pinned) { pinOrigins[row.Key] = index; target = 3 + rows.Count(item => !item.Required && item != row && item.Pinned); }
                    else { target = pinOrigins.ContainsKey(row.Key) ? pinOrigins[row.Key] : rows.Count - 1; pinOrigins.Remove(row.Key); }
                    rows.Move(index, Math.Max(3, Math.Min(rows.Count - 1, target)));
                }
                finally { changing = false; }
            }
            useRestoredRaw = false; MarkDraftChanged();
        }
        private void MoveSelected(int direction)
        {
            var row = table.SelectedItem as ColumnSettingRow; if (row == null || row.Required) return;
            int index = rows.IndexOf(row), target = index + direction;
            if (target < 3 || target >= rows.Count || rows[target].Pinned != row.Pinned) return;
            rows.Move(index, target); useRestoredRaw = false; MarkDraftChanged();
        }
        private UnitColumnLayout ValidLayout()
        {
            var widths = new Dictionary<string, double>(StringComparer.Ordinal);
            foreach (var row in rows)
            { double width; if (!TryCompleteWidth(row.WidthText, out width)) throw new FormatException("列宽需为48至2000的完整像素数。"); widths.Add(row.Key, width); }
            return new UnitColumnLayout(rows.Select(row => row.Key), rows.Where(row => !row.Visible).Select(row => row.Key), rows.Where(row => row.Pinned).Select(row => row.Key), widths, addedIds);
        }
        private string BuildPreferenceBody()
        {
            var widths = new Dictionary<string, object>(StringComparer.Ordinal);
            foreach (var row in rows) { double value; widths[row.Key] = TryCompleteWidth(row.WidthText, out value) ? (object)value : row.WidthText; }
            return ColumnJson.Serialize(new Dictionary<string, object> { ["order"] = rows.Select(row => row.Key).ToArray(), ["hidden"] = rows.Where(row => !row.Visible).Select(row => row.Key).ToArray(),
                ["pinned"] = rows.Where(row => row.Pinned).Select(row => row.Key).ToArray(), ["widths"] = widths, ["added"] = addedIds.Where(current.Definitions.ContainsKey).Select(id => current.Definitions[id].ToDictionary(false)).ToArray(),
                ["sortColumn"] = null, ["sortAscending"] = true, ["hasQueryPreferences"] = false });
        }
        private static bool TryCompleteWidth(string text, out double value)
        {
            value = 0;
            return text != null && text.Length <= 120 && Regex.IsMatch(text, @"^[0-9]+(?:\.[0-9]+)?(?:[eE][+-]?[0-9]+)?$", RegexOptions.CultureInvariant)
                && Double.TryParse(text, NumberStyles.Float, CultureInfo.InvariantCulture, out value) && !Double.IsNaN(value) && !Double.IsInfinity(value) && value >= 48 && value <= 2000;
        }
        protected override string BuildCurrentBody() { return useRestoredRaw ? RestoredDraft.BodyJson : BuildPreferenceBody(); }
        protected override bool CanSubmitBody { get { ValidLayout(); return reviewed && current.PreferencesConfirmed && current.IsCurrent(Session); } }
        protected override void SetEditorEnabled(bool enabled) { base.SetEditorEnabled(enabled); if (review != null) review.IsEnabled = enabled && !reviewed; UpdateCatalogActions(); }
        protected override async Task BeforeSubmitAsync(CancellationToken ct)
        {
            var checkedSnapshot = await service.PreviewLayoutAsync(ValidLayout(), current, ct);
            if (!checkedSnapshot.PreferencesConfirmed || checkedSnapshot.UnavailableDefinitionIds.Count > 0) throw new ApiException("COLUMN_DEFINITION_CHANGED", "有未确认或失效的表头来源，请重新核对后保存。", 409);
            current = checkedSnapshot;
        }
        protected override Task OnConfirmedAsync(MutationResult response) { applied = current; return Task.CompletedTask; }
        private async Task ReviewRestoredAsync()
        {
            try { using (BeginEditorOperation()) { current = await service.PreviewLayoutAsync(ValidLayout(), current, LifetimeToken); if (!IsDraftOwnerCurrent) return; PopulateRows(current.Layout); reviewed = true; useRestoredRaw = false; MarkDraftChanged(); ShowStatus("已核对当前字段与权限；保存前请检查表头目标。失效列不会被带入新设置。"); } }
            catch (ApiException error) { if (IsDraftOwnerCurrent) ShowStatus(error.UserMessage, true); }
            catch (Exception error) when (error is FormatException || error is ArgumentException || error is InvalidOperationException) { if (IsDraftOwnerCurrent) ShowStatus("请先修正列宽和列清单，再核对恢复的表头。", true); }
            catch (OperationCanceledException) { }
            catch (Exception) { if (IsDraftOwnerCurrent) ShowStatus("读取当前字段定义失败，原表头输入仍保留。请稍后重试核对。", true); }
        }
        private async Task SearchAsync()
        {
            try { using (BeginEditorOperation()) { var result = await service.SearchAsync(search.Text, LifetimeToken); if (!IsDraftOwnerCurrent) return; current = service.WithCatalog(current, result); catalog.ItemsSource = result.Value.Values.ToList(); } }
            catch (OperationCanceledException) { }
            catch (ApiException error) { if (IsDraftOwnerCurrent) ShowStatus(error.UserMessage, true); }
            catch (Exception) { if (IsDraftOwnerCurrent) ShowStatus("读取列目录失败，请重新查找；原表头草稿仍保留。", true); }
            finally { UpdateCatalogActions(); }
        }
        private async Task AddSelectedAsync()
        {
            var selected = catalog.SelectedItem as PlatformColumnDefinition; if (selected == null || !add.IsEnabled) return;
            try { using (BeginEditorOperation()) { var fresh = await service.DefinitionAsync(selected.Id, LifetimeToken); if (!IsDraftOwnerCurrent) return;
                var nextIds = addedIds.Concat(new[] { selected.Id }).Distinct(StringComparer.OrdinalIgnoreCase).ToArray(); if (nextIds.Length > 32) throw new InvalidOperationException("最多添加32个自设列。");
                var layout = ValidLayout(); var next = new UnitColumnLayout(layout.Order, layout.Hidden.Where(key => key != selected.Key), layout.Pinned,
                    layout.Widths.ToDictionary(pair => pair.Key, pair => pair.Value), nextIds);
                current = await service.PreviewLayoutAsync(next, current, LifetimeToken); if (!IsDraftOwnerCurrent) return;
                addedIds.Clear(); addedIds.AddRange(current.Layout.AddedIds); PopulateRows(current.Layout); useRestoredRaw = false; MarkDraftChanged();
                var response = await service.SendAsync(service.PrepareDefinitionUse(Guid.NewGuid().ToString("D"), fresh), LifetimeToken);
                if (IsDraftOwnerCurrent && (response.Outcome == MutationOutcome.Unknown || response.NeedsManualReconciliation
                    || response.Outcome == MutationOutcome.Confirmed && !response.IsDurablyRecorded))
                { catalogUnresolved = true; ShowStatus("列已加入当前表头草稿，使用次数提交需核对：" + response.Request.RequestId + "。不会自动重试。", true); }
                else if (IsDraftOwnerCurrent && response.Outcome != MutationOutcome.Confirmed) ShowStatus("列已加入表头草稿，使用次数未确认保存；不会自动重试。", true);
            } }
            catch (OperationCanceledException) { }
            catch (ApiException error) { if (IsDraftOwnerCurrent) ShowStatus(error.UserMessage, true); }
            catch (InvalidOperationException error) { if (IsDraftOwnerCurrent) ShowStatus(error.Message, true); }
            catch (Exception) { if (IsDraftOwnerCurrent) { catalogUnresolved = true; ShowStatus("列选择暂未完成，请先核对本机记录；原表头草稿仍保留。", true); } }
            finally { UpdateCatalogActions(); }
        }
        private async Task CreateAsync()
        {
            if (!create.IsEnabled) return;
            try { using (BeginEditorOperation())
            {
                var window = new UnitPlatformDefinitionWindow(this, Session, current); window.ShowDialog();
                if (!IsDraftOwnerCurrent) return;
                HasCatalogChanges = HasCatalogChanges || window.BusinessChanged;
                if (window.Result?.NeedsManualReconciliation == true || window.Result?.Outcome == MutationOutcome.Confirmed && !window.Result.IsDurablyRecorded) catalogUnresolved = true;
                if (window.CreatedDefinition != null) await SearchCoreAsync(window.CreatedDefinition.Name);
            } }
            catch (OperationCanceledException) { }
            catch (ApiException error) { if (IsDraftOwnerCurrent) ShowStatus(error.UserMessage, true); }
            catch (Exception) { if (IsDraftOwnerCurrent) ShowStatus("暂时无法打开或读取自设列编辑，请核对原记录后刷新。", true); }
            finally { UpdateCatalogActions(); }
        }
        private async Task SearchCoreAsync(string query)
        { var result = await service.SearchAsync(query, LifetimeToken); if (!IsDraftOwnerCurrent) return; current = service.WithCatalog(current, result); catalog.ItemsSource = result.Value.Values.ToList(); UpdateCatalogActions(); }
        private async Task DeleteSelectedAsync()
        {
            var selected = catalog.SelectedItem as PlatformColumnDefinition; if (selected == null || !delete.IsEnabled) return;
            bool serverConfirmed = false;
            try { using (BeginEditorOperation()) {
                var fresh = await service.DefinitionAsync(selected.Id, LifetimeToken); if (!IsDraftOwnerCurrent || !fresh.Value.CanDelete) return;
                var confirm = new ColumnConfirmation(this, "删除自设列目录", "确认删除“" + fresh.Value.Name + "”的目录入口？已保存值、计算依赖和历史保持原样。本表将隐藏此列，表头变更仍需保存。");
                if (confirm.ShowDialog() != true || !IsDraftOwnerCurrent) return;
                attemptedDeletes.Add(selected.Id);
                var response = await service.SendAsync(service.PrepareDefinitionDelete(Guid.NewGuid().ToString("D"), fresh), LifetimeToken);
                if (!IsDraftOwnerCurrent) return;
                if (response.Outcome == MutationOutcome.Confirmed)
                {
                    serverConfirmed = true; if (!response.IsDurablyRecorded) catalogUnresolved = true;
                    HasCatalogChanges = true; var row = rows.FirstOrDefault(item => item.Key == selected.Key); if (row != null) row.Visible = false; addedIds.Remove(selected.Id);
                    useRestoredRaw = false; MarkDraftChanged(); await SearchCoreAsync(search.Text);
                    ShowStatus("已删除目录入口，原值与历史未删除。请保存需要保留的表头变更。");
                }
                else { catalogUnresolved = response.Outcome == MutationOutcome.Unknown || response.NeedsManualReconciliation; ShowStatus(response.Error?.UserMessage ?? "本次目录操作没有确认成功，请核对提交记录。", true); }
            } }
            catch (OperationCanceledException) { }
            catch (ApiException error) { if (IsDraftOwnerCurrent) ShowStatus(serverConfirmed ? "目录入口已删除，但目录刷新未完成。请稍后刷新，不要重复删除。" : error.UserMessage, true); }
            catch (Exception) { if (IsDraftOwnerCurrent) { catalogUnresolved = true; ShowStatus(serverConfirmed ? "目录入口已删除，但目录刷新未完成。不要重复提交原操作。" : "目录操作结果暂未完整读取，请先核对本机记录，不要连续提交。", true); } }
            finally { UpdateCatalogActions(); }
        }
        private void UpdateCatalogActions()
        {
            if (add == null) return; var selected = catalog.SelectedItem as PlatformColumnDefinition;
            bool canAuthor = current.IsCurrent(Session) && Session.CurrentUser?.HasPermission("unit:edit") == true && !IsSubmitting && !IsRetired && !HasUnresolvedOutcome && !catalogUnresolved;
            add.IsEnabled = canAuthor && selected != null && (!selected.PriceProtected || current.Capabilities.PriceVisible)
                && !rows.Any(row => row.Key == selected.Key && row.Visible);
            create.IsEnabled = canAuthor && current.Capabilities.CanDefine;
            delete.IsEnabled = canAuthor && selected?.CanDelete == true && !attemptedDeletes.Contains(selected.Id);
        }
        protected override void RetireSensitiveContent()
        {
            catalog.ItemsSource = null; search.Clear();
            foreach (var confirm in OwnedWindows.OfType<ColumnConfirmation>().ToArray()) confirm.Close();
            base.RetireSensitiveContent();
        }
    }
    internal sealed class ColumnConfirmation : UtenDialogWindow
    {
        internal ColumnConfirmation(Window parent, string title, string message) : base(parent, title, 600)
        { Body.Children.Add(new TextBlock { Text = message, TextWrapping = TextWrapping.Wrap }); ActionButton("取消", () => Close()); ActionButton("确认", () => { DialogResult = true; }, primary: true); }
    }
}
