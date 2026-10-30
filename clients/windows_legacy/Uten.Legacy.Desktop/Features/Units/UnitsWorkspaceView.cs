using System;
using System.Collections.Generic;
using System.Globalization;
using System.Linq;
using System.Threading;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Data;
using System.Windows.Threading;
using Uten.Legacy.Core;
using Uten.Legacy.Desktop.Controls;
using Uten.Legacy.Desktop.Updates;
using Uten.Legacy.Desktop.Shared;
using Uten.Legacy.Desktop.Features.Columns;

namespace Uten.Legacy.Desktop.Features.Units
{
    public sealed class UnitsWorkspaceView : UserControl, IDisposable, IUpdateExitGuard
    {
        private sealed class FilterChoice
        {
            public string Label { get; set; }
            public UnitFilter Filter { get; set; }
        }
        private readonly SessionCoordinator session;
        private readonly UnitService service;
        private readonly UnitColumnsService columnsService;
        private readonly TextBox search = new TextBox { MinWidth = 220, ToolTip = "按单位编号或名称搜索" };
        private readonly DataGrid rows = new DataGrid { SelectionMode = DataGridSelectionMode.Extended, SelectionUnit = DataGridSelectionUnit.FullRow };
        private readonly TextBlock status = new TextBlock { TextWrapping = TextWrapping.Wrap, VerticalAlignment = VerticalAlignment.Center };
        private readonly TextBlock pager = new TextBlock { VerticalAlignment = VerticalAlignment.Center };
        private readonly Button create = new Button { Content = "新增单位" };
        private readonly Button edit = new Button { Content = "编辑" };
        private readonly Button changeStatus = new Button { Content = "更改状态" };
        private readonly Button delete = new Button { Content = "删除" };
        private readonly Button operations = new Button { Content = "本人操作" };
        private readonly Button history = new Button { Content = "版本历史" };
        private readonly Button printPreview = new Button { Content = "打印预览" };
        private readonly Button export = new Button { Content = "下载Excel" };
        private readonly Button headerSettings = new Button { Content = "表头设置" };
        private readonly Button inlineEdit = new Button { Content = "行内编辑" };
        private readonly Button refresh = new Button { Content = "刷新" };
        private readonly Button recovery = new Button { Content = "本机草稿与记录" };
        private readonly Button previous = new Button { Content = "上一页" };
        private readonly Button next = new Button { Content = "下一页" };
        private readonly TextBlock selectionText = new TextBlock { VerticalAlignment = VerticalAlignment.Center };
        private readonly Button clearSelection = new Button { Content = "清空选择" };
        private readonly PersistentRowSelection<UnitRecord> selection = new PersistentRowSelection<UnitRecord>(row => row.Id);
        private readonly Dictionary<string, ComboBox> filterBoxes = new Dictionary<string, ComboBox>();
        private readonly Dictionary<string, UnitFilter> filters = new Dictionary<string, UnitFilter>(StringComparer.Ordinal);
        private readonly DispatcherTimer searchDelay = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(300) };
        private readonly CancellationTokenSource lifetime = new CancellationTokenSource();
        private CancellationTokenSource pageRead;
        private UnitEditorWindow editor;
        private UnitReadOwner loadedOwner;
        private UnitReadOwner scopeFence;
        private UnitColumnsSnapshot columnSnapshot;
        private Border tableSurface;
        private UnitInlineWorkspace inlineWorkspace;
        private IReadOnlyList<UnitRecord> currentRows = new UnitRecord[0];
        private bool disposed, subscribed, loading, openingEditor, changingFilters, changingSelection;
        private long sequence;
        private int page = 1, totalPages;
        public bool CanCloseForUpdate { get { return !openingEditor && editor == null && inlineWorkspace == null; } }

        public UnitsWorkspaceView(SessionCoordinator session)
        {
            this.session = session ?? throw new ArgumentNullException(nameof(session));
            SetResourceReference(StyleProperty, "Uten.Workspace");
            scopeFence = new UnitReadOwner(session);
            service = new UnitService(session);
            columnsService = new UnitColumnsService(session);
            BuildLayout();
            Loaded += OnLoaded;
            Unloaded += (sender, args) => Dispose();
            refresh.Click += async (sender, args) => { await LoadPageAsync(page); await LoadFacetsAsync(); };
            previous.Click += async (sender, args) => await LoadPageAsync(Math.Max(1, page - 1));
            next.Click += async (sender, args) => await LoadPageAsync(page + 1);
            create.Click += async (sender, args) => await OpenEditorAsync(MutationAction.UnitCreate);
            edit.Click += async (sender, args) => await OpenEditorAsync(MutationAction.UnitUpdate);
            changeStatus.Click += (sender, args) => OpenStatusMenu();
            delete.Click += async (sender, args) => await OpenBatchAsync(UnitBatchAction.Delete);
            operations.Click += async (sender, args) => await OpenHistoryAsync(false);
            history.Click += async (sender, args) => await OpenHistoryAsync(true);
            printPreview.Click += (sender, args) => OpenPrint();
            export.Click += (sender, args) => OpenExport();
            headerSettings.Click += async (sender, args) => await OpenHeaderSettingsAsync();
            inlineEdit.Click += (sender, args) => OpenInline();
            recovery.Click += async (sender, args) => await OpenRecoveryAsync();
            rows.SelectionChanged += (sender, args) =>
            {
                if (!changingSelection)
                {
                    foreach (UnitRecord row in args.RemovedItems) selection.Forget(row);
                    foreach (UnitRecord row in args.AddedItems) selection.Remember(row);
                }
                UpdateActions();
            };
            clearSelection.Click += (sender, args) => { ClearSelection(true); UpdateActions(); };
            rows.PreviewMouseRightButtonDown += (sender, args) =>
            {
                var container = ItemsControl.ContainerFromElement(rows, args.OriginalSource as DependencyObject) as DataGridRow;
                if (container?.Item is UnitRecord record && !rows.SelectedItems.Contains(record))
                { ClearSelection(true); rows.SelectedItem = record; }
                var cellElement = args.OriginalSource as DependencyObject;
                while (cellElement != null && !(cellElement is DataGridCell))
                    cellElement = cellElement is System.Windows.Media.Visual || cellElement is System.Windows.Media.Media3D.Visual3D
                        ? System.Windows.Media.VisualTreeHelper.GetParent(cellElement) : LogicalTreeHelper.GetParent(cellElement);
                if (container?.Item is UnitRecord target && cellElement is DataGridCell cell && cell.Column != null)
                    rows.CurrentCell = new DataGridCellInfo(target, cell.Column);
            };
            rows.ContextMenuOpening += (sender, args) => BuildRowMenu(args);
            rows.MouseDoubleClick += async (sender, args) =>
            {
                if (ItemsControl.ContainerFromElement(rows, args.OriginalSource as DependencyObject) is DataGridRow
                    && rows.SelectedItems.Count == 1 && !loading) await OpenDetailAsync();
            };
            search.TextChanged += (sender, args) =>
            {
                if (!IsLoaded || disposed || changingFilters) return;
                InvalidatePage();
                searchDelay.Stop(); searchDelay.Start();
            };
            search.KeyDown += async (sender, args) =>
            {
                if (args.Key != System.Windows.Input.Key.Enter) return;
                args.Handled = true; searchDelay.Stop(); await LoadPageAsync(1);
            };
            searchDelay.Tick += async (sender, args) => { searchDelay.Stop(); await LoadPageAsync(1); };
            UpdateActions();
        }
        private double Space(string role) { return (double)FindResource("Uten.Space." + role); }
        private void BuildLayout()
        {
            SetResourceReference(BackgroundProperty, "Uten.Background");
            SetResourceReference(ForegroundProperty, "Uten.Text");
            var layout = new Grid { Margin = (Thickness)FindResource("Uten.Padding.S24") };
            layout.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
            layout.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
            layout.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
            layout.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star), MinHeight = 120 });
            layout.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
            var header = new DockPanel { Margin = new Thickness(0, 0, 0, Space("S16")) };
            var title = new TextBlock { Text = "基本单位", Style = (Style)FindResource("Uten.PageTitle"), VerticalAlignment = VerticalAlignment.Center };
            DockPanel.SetDock(title, Dock.Left); header.Children.Add(title);
            var actions = new WrapPanel { HorizontalAlignment = HorizontalAlignment.Right };
            create.SetResourceReference(StyleProperty, "Uten.PrimaryButton");
            foreach (var button in new[] { create, edit, inlineEdit, changeStatus, delete, operations, history, headerSettings, printPreview, export, recovery, refresh })
            { button.Margin = new Thickness(Space("S8"), 0, 0, 0); actions.Children.Add(button); }
            header.Children.Add(actions); layout.Children.Add(header);
            var filterBar = new WrapPanel { Margin = new Thickness(0, 0, 0, Space("S12")) };
            filterBar.Children.Add(new TextBlock { Text = "编号、名称", VerticalAlignment = VerticalAlignment.Center,
                Margin = new Thickness(0, 0, Space("S8"), Space("S8")) });
            System.Windows.Automation.AutomationProperties.SetName(search, "按单位编号或名称搜索");
            search.SetResourceReference(StyleProperty, "Uten.CompactInput");
            search.Margin = new Thickness(0, 0, Space("S12"), Space("S8")); filterBar.Children.Add(search);
            foreach (var pair in new[] { new[] { "code", "全部编号" }, new[] { "name", "全部名称" }, new[] { "status", "全部状态" } })
            {
                string field = pair[0], titleText = pair[1];
                var box = new ComboBox { MinWidth = 130, DisplayMemberPath = "Label", ToolTip = titleText,
                    Margin = new Thickness(0, 0, Space("S8"), Space("S8")) };
                filterBoxes.Add(field, box);
                box.ItemsSource = Choices(field, titleText, null);
                box.SelectedIndex = 0;
                box.SelectionChanged += async (sender, args) =>
                {
                    if (changingFilters || !IsLoaded || disposed) return;
                    var selected = box.SelectedItem as FilterChoice;
                    if (selected?.Filter == null) filters.Remove(field); else filters[field] = selected.Filter;
                    InvalidatePage(); await LoadPageAsync(1);
                };
                filterBar.Children.Add(box);
            }
            Grid.SetRow(filterBar, 1); layout.Children.Add(filterBar);
            status.SetResourceReference(TextBlock.ForegroundProperty, "Uten.Muted");
            status.Margin = new Thickness(0, 0, 0, Space("S8")); Grid.SetRow(status, 2); layout.Children.Add(status);
            rows.Columns.Add(Column("编号", nameof(UnitRecord.Code), 120));
            rows.Columns.Add(Column("单位名称", nameof(UnitRecord.Name), 1, stretch: true));
            rows.Columns.Add(Column("状态", nameof(UnitRecord.Status), 72));
            rows.CanUserDeleteRows = false;
            rows.ContextMenu = new ContextMenu();
            rows.CanUserSortColumns = false; // The owning service orders by code; no invented page-only sorting.
            tableSurface = UtenSurfaces.Wrap(rows, UtenSurfaceRole.Table);
            Grid.SetRow(tableSurface, 3); layout.Children.Add(tableSurface);
            var footer = new DockPanel { Margin = new Thickness(0, Space("S12"), 0, 0) };
            var paging = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Right };
            previous.Margin = new Thickness(Space("S8"), 0, Space("S8"), 0);
            next.Margin = new Thickness(Space("S8"), 0, 0, 0);
            previous.SetResourceReference(MinHeightProperty, "Uten.Height.Compact"); next.SetResourceReference(MinHeightProperty, "Uten.Height.Compact");
            paging.Children.Add(previous); paging.Children.Add(pager); paging.Children.Add(next);
            DockPanel.SetDock(paging, Dock.Right); footer.Children.Add(paging);
            var selectionPanel = new StackPanel { Orientation = Orientation.Horizontal };
            clearSelection.Margin = new Thickness(Space("S8"), 0, 0, 0);
            clearSelection.SetResourceReference(MinHeightProperty, "Uten.Height.Compact");
            selectionPanel.Children.Add(selectionText); selectionPanel.Children.Add(clearSelection); footer.Children.Add(selectionPanel);
            Grid.SetRow(footer, 4); layout.Children.Add(footer);
            Content = layout;
        }
        private static DataGridTextColumn Column(string title, string property, double width, bool stretch = false)
        {
            return new DataGridTextColumn { Header = title, Binding = new Binding(property) { TargetNullValue = "—" },
                Width = new DataGridLength(width, stretch ? DataGridLengthUnitType.Star : DataGridLengthUnitType.Pixel), IsReadOnly = true };
        }
        private IList<FilterChoice> Choices(string field, string title, UnitFacetSet facets)
        {
            var result = new List<FilterChoice> { new FilterChoice { Label = title }, new FilterChoice { Label = "空值", Filter = UnitFilter.Null } };
            IReadOnlyList<UnitFacetBucket> buckets;
            if (facets != null && facets.Fields.TryGetValue(field, out buckets))
                result.AddRange(buckets.Select(bucket => new FilterChoice { Label = (bucket.Value.Length == 0 ? "空文本" : bucket.Value)
                    + (bucket.Count.HasValue ? "（" + bucket.Count.Value.ToString(CultureInfo.InvariantCulture) + "）" : ""),
                    Filter = UnitFilter.Exact(bucket.Value) }));
            else if (field == "status")
                result.AddRange(new[] { "使用", "禁用" }.Select(value => new FilterChoice { Label = value, Filter = UnitFilter.Exact(value) }));
            UnitFilter current;
            if (filters.TryGetValue(field, out current) && !result.Any(choice => SameFilter(choice.Filter, current)))
                result.Add(new FilterChoice { Label = current.IsNull ? "空值" : current.Value, Filter = current });
            return result;
        }
        private static bool SameFilter(UnitFilter left, UnitFilter right)
        { return left == null ? right == null : right != null && left.IsNull == right.IsNull && left.Value == right.Value; }
        private async void OnLoaded(object sender, RoutedEventArgs args)
        {
            if (disposed || subscribed) return;
            subscribed = true; session.SessionChanged += OnOwnerChanged; session.ReadScopeChanged += OnOwnerChanged;
            await LoadPageAsync(1); await LoadFacetsAsync();
        }
        private void OnOwnerChanged(object sender, EventArgs args)
        {
            if (disposed) return;
            Dispatcher.BeginInvoke(new Action(async () =>
            {
                if (disposed) return;
                if (scopeFence?.IsCurrent(session) == true) return; // Ordinary credential refresh retains query and editor intent.
                scopeFence = session.IsAuthenticated && session.CurrentUser?.HasPermission("unit:view") == true ? new UnitReadOwner(session) : null;
                inlineWorkspace?.RetireOwner(); columnSnapshot = null; currentRows = new UnitRecord[0]; ResetBaseColumns();
                InvalidatePage(); loadedOwner = null; rows.ItemsSource = null;
                searchDelay.Stop(); changingFilters = true;
                try
                {
                    search.Clear(); filters.Clear();
                    foreach (var entry in filterBoxes)
                    {
                        string title = entry.Key == "code" ? "全部编号" : entry.Key == "name" ? "全部名称" : "全部状态";
                        entry.Value.ItemsSource = Choices(entry.Key, title, null); entry.Value.SelectedIndex = 0;
                    }
                }
                finally { changingFilters = false; }
                if (session.IsAuthenticated && session.CurrentUser?.HasPermission("unit:view") == true)
                { await LoadPageAsync(1); await LoadFacetsAsync(); }
                else { status.Text = "当前账号没有单位资料查看权限。"; loading = false; UpdateActions(); }
            }));
        }
        private void InvalidatePage()
        {
            sequence++; pageRead?.Cancel(); ClearSelection(true); loading = true; UpdateActions();
        }
        private async Task LoadPageAsync(int target)
        {
            if (disposed || !session.IsAuthenticated || inlineWorkspace != null) return;
            pageRead?.Cancel(); pageRead?.Dispose(); pageRead = CancellationTokenSource.CreateLinkedTokenSource(lifetime.Token);
            var token = pageRead.Token; long request = ++sequence;
            loading = true; ClearSelection(false); status.Text = "正在读取单位资料…"; UpdateActions();
            try
            {
                var snapshot = await service.ListAsync(new UnitQuery(target, 20, search.Text, filters), token);
                if (disposed || request != sequence || !snapshot.IsCurrent(session)) return;
                loadedOwner = snapshot.Owner;
                currentRows = snapshot.Value.Items;
                DisplayRows(snapshot.Value.Items);
                page = snapshot.Value.Page; totalPages = snapshot.Value.TotalPages;
                pager.Text = page.ToString(CultureInfo.InvariantCulture) + " / " + Math.Max(1, totalPages).ToString(CultureInfo.InvariantCulture);
                status.Text = snapshot.Value.TotalElements == 0 ? "没有符合条件的单位。" : "共 " + snapshot.Value.TotalElements.ToString(CultureInfo.InvariantCulture) + " 项";
                var previousColumns = columnSnapshot;
                columnSnapshot = null;
                try
                {
                    var projected = await columnsService.LoadAsync(snapshot.Value.Items.Select(item => item.Id).ToArray(), token, previousColumns);
                    if (disposed || request != sequence || !snapshot.IsCurrent(session) || !projected.IsCurrent(session)) return;
                    columnSnapshot = projected; ApplyColumns();
                    if (projected.OverflowedDefinitionIds.Count > 0)
                        status.Text += "；当前资料另有 " + projected.OverflowedDefinitionIds.Count.ToString(CultureInfo.InvariantCulture)
                            + " 个自设列超出单表32列上限，暂未显示但原值仍保留，可在表头设置中调整。";
                }
                catch (ApiException error)
                {
                    if (!disposed && request == sequence)
                    { columnSnapshot = null; ResetBaseColumns(); status.Text += "；表头或自设列尚未确认：" + error.UserMessage + " 输出已暂停，请刷新重试。"; }
                }
                catch (Exception error) when (error is FormatException || error is ArgumentException || error is InvalidOperationException)
                {
                    if (!disposed && request == sequence)
                    { columnSnapshot = null; ResetBaseColumns(); status.Text += "；表头尚未完整读取，输出已暂停，请刷新重试。"; }
                }
            }
            catch (OperationCanceledException) { }
            catch (ApiException error) { if (!disposed && request == sequence) { loadedOwner = null; if (error.StatusCode == 403) ClearSelection(true); DisplayRows(null); status.Text = error.UserMessage; } }
            catch (Exception) { if (!disposed && request == sequence) { loadedOwner = null; DisplayRows(null); status.Text = "读取单位资料失败，请点击刷新重试。"; } }
            finally { if (!disposed && request == sequence) { loading = false; UpdateActions(); } }
        }
        private async Task LoadFacetsAsync()
        {
            if (disposed || !session.IsAuthenticated) return;
            try
            {
                var snapshot = await service.FacetsAsync(lifetime.Token);
                if (disposed || !snapshot.IsCurrent(session)) return;
                changingFilters = true;
                foreach (var entry in filterBoxes)
                {
                    string title = entry.Key == "code" ? "全部编号" : entry.Key == "name" ? "全部名称" : "全部状态";
                    var choices = Choices(entry.Key, title, snapshot.Value);
                    UnitFilter current; filters.TryGetValue(entry.Key, out current);
                    entry.Value.ItemsSource = choices; entry.Value.SelectedItem = choices.First(value => SameFilter(value.Filter, current));
                }
            }
            catch (Exception error) when (error is ApiException || error is OperationCanceledException || error is FormatException)
            { /* Optional facets never replace the main table result. */ }
            finally { changingFilters = false; }
        }
        private void UpdateActions()
        {
            var user = session.CurrentUser;
            bool canAct = !disposed && !loading && !openingEditor && editor == null && inlineWorkspace == null && user != null
                && user.HasPermission("unit:view") && loadedOwner?.IsCurrent(session) == true;
            create.Visibility = user?.HasPermission("unit:create") == true ? Visibility.Visible : Visibility.Collapsed;
            edit.Visibility = user?.HasPermission("unit:edit") == true ? Visibility.Visible : Visibility.Collapsed;
            changeStatus.Visibility = user?.HasPermission("unit:status") == true ? Visibility.Visible : Visibility.Collapsed;
            delete.Visibility = user?.HasPermission("unit:delete") == true ? Visibility.Visible : Visibility.Collapsed;
            operations.Visibility = user != null && (user.SuperAdmin || user.Permissions.Any(value => value.StartsWith("unit:", StringComparison.Ordinal)
                && value != "unit:view" && value != "unit:export")) ? Visibility.Visible : Visibility.Collapsed;
            create.IsEnabled = canAct; edit.IsEnabled = canAct && selection.Count == 1 && rows.SelectedItems.Count == 1;
            changeStatus.IsEnabled = delete.IsEnabled = canAct && selection.Count > 0;
            operations.IsEnabled = history.IsEnabled = printPreview.IsEnabled = canAct;
            bool projectionReady = columnSnapshot?.IsCurrent(session) == true;
            printPreview.IsEnabled = headerSettings.IsEnabled = canAct && projectionReady;
            export.Visibility = user?.HasPermission("unit:export") == true ? Visibility.Visible : Visibility.Collapsed;
            export.IsEnabled = canAct && projectionReady;
            inlineEdit.Visibility = user != null && (user.HasPermission("unit:edit") || user.HasPermission("unit:create")) ? Visibility.Visible : Visibility.Collapsed;
            inlineEdit.IsEnabled = canAct;
            previous.IsEnabled = inlineWorkspace == null && !openingEditor && !loading && page > 1;
            next.IsEnabled = inlineWorkspace == null && !openingEditor && !loading && page < totalPages;
            refresh.IsEnabled = !openingEditor && editor == null && inlineWorkspace == null;
            recovery.IsEnabled = !openingEditor && editor == null && inlineWorkspace == null && user?.HasPermission("unit:view") == true;
            selectionText.Text = selection.Count == 0 ? "" : "已选 " + selection.Count + " 项";
            clearSelection.Visibility = selection.Count == 0 ? Visibility.Collapsed : Visibility.Visible;
            clearSelection.IsEnabled = !openingEditor && editor == null && inlineWorkspace == null;
            search.IsEnabled = inlineWorkspace == null; foreach (var box in filterBoxes.Values) box.IsEnabled = inlineWorkspace == null;
        }
        private void ClearSelection(bool all)
        {
            changingSelection = true;
            try { rows.SelectedItems.Clear(); if (all) selection.Clear(); }
            finally { changingSelection = false; }
        }
        private void DisplayRows(IReadOnlyList<UnitRecord> items)
        {
            changingSelection = true;
            try
            {
                rows.ItemsSource = items;
                if (items != null) foreach (var row in items)
                    if (selection.Contains(row)) { selection.Remember(row); rows.SelectedItems.Add(row); }
            }
            finally { changingSelection = false; }
        }
        private bool CanAct()
        { return !disposed && !loading && !openingEditor && editor == null && inlineWorkspace == null && loadedOwner?.IsCurrent(session) == true; }
        private void OpenStatusMenu()
        {
            if (!CanAct() || selection.Count == 0) return;
            var menu = new ContextMenu { PlacementTarget = changeStatus, Placement = System.Windows.Controls.Primitives.PlacementMode.Bottom };
            AddMenu(menu, "启用", async () => await OpenBatchAsync(UnitBatchAction.Status, "使用"), "unit:status");
            AddMenu(menu, "停用", async () => await OpenBatchAsync(UnitBatchAction.Status, "禁用"), "unit:status");
            menu.IsOpen = true;
        }
        private void AddMenu(ContextMenu menu, string title, Action action, string permission = null)
        {
            if (permission != null && session.CurrentUser?.HasPermission(permission) != true) return;
            var item = new MenuItem { Header = title, IsEnabled = CanAct() };
            item.Click += (sender, args) => { if (CanAct()) action(); };
            menu.Items.Add(item);
        }
        private void BuildRowMenu(ContextMenuEventArgs args)
        {
            if (!CanAct() || selection.Count == 0) { args.Handled = true; return; }
            var menu = new ContextMenu();
            if (selection.Count == 1 && rows.SelectedItems.Count == 1)
            {
                AddMenu(menu, "查看详情", async () => await OpenDetailAsync());
                AddMenu(menu, "编辑", async () => await OpenEditorAsync(MutationAction.UnitUpdate), "unit:edit");
                AddMenu(menu, "查看版本历史", async () => await OpenHistoryAsync(true));
                if (columnSnapshot?.IsCurrent(session) == true && columnSnapshot.Capabilities.CanWrite)
                {
                    var cell = rows.CurrentCell;
                    string key = cell.Column?.SortMemberPath;
                    if (key != null && key.StartsWith("platform:", StringComparison.Ordinal))
                        AddMenu(menu, "编辑此自设字段", async () => await OpenPlatformValueAsync(key));
                }
            }
            AddMenu(menu, "启用", async () => await OpenBatchAsync(UnitBatchAction.Status, "使用"), "unit:status");
            AddMenu(menu, "停用", async () => await OpenBatchAsync(UnitBatchAction.Status, "禁用"), "unit:status");
            AddMenu(menu, "删除", async () => await OpenBatchAsync(UnitBatchAction.Delete), "unit:delete");
            rows.ContextMenu = menu;
            args.Handled = true; menu.PlacementTarget = rows;
            menu.Placement = System.Windows.Controls.Primitives.PlacementMode.MousePoint; menu.IsOpen = true;
        }
        private async Task OpenBatchAsync(UnitBatchAction action, string targetStatus = null)
        {
            if (!CanAct() || selection.Count == 0) return;
            var selected = selection.Values;
            var sourceOwner = loadedOwner;
            openingEditor = true; UpdateActions();
            try
            {
                var command = new UnitBatchCommand(action, selected.Select(item => item.Id), targetStatus);
                var window = new UnitBatchWindow(Window.GetWindow(this), session, command, sourceOwner, selected);
                window.ShowDialog();
                if (window.HasConfirmedResult && !disposed && sourceOwner.IsCurrent(session))
                {
                    ClearSelection(true);
                    foreach (var row in selected) if (window.FailedIds.Contains(row.Id)) selection.Remember(row);
                    await LoadPageAsync(page); await LoadFacetsAsync();
                }
            }
            catch (ArgumentException error) { if (!disposed) status.Text = error.Message; }
            catch (ApiException error) { if (!disposed) status.Text = error.UserMessage; }
            catch (OperationCanceledException) { }
            catch (Exception) { if (!disposed) status.Text = "单位操作未能完成，请先核对本机提交记录。"; }
            finally { openingEditor = false; if (!disposed) UpdateActions(); }
        }
        private async Task OpenHistoryAsync(bool records)
        {
            if (!CanAct()) return;
            string selectedId = rows.SelectedItems.Count == 1 ? (rows.SelectedItem as UnitRecord)?.Id : null;
            openingEditor = true; UpdateActions();
            try
            {
                UnitHistoryWindow window = records ? (UnitHistoryWindow)new UnitRecordHistoryWindow(Window.GetWindow(this), session, selectedId)
                    : new UnitOperationHistoryWindow(Window.GetWindow(this), session);
                window.ShowDialog();
                if (window.BusinessChanged && !disposed) { await LoadPageAsync(page); await LoadFacetsAsync(); }
            }
            catch (ApiException error) { if (!disposed) status.Text = error.UserMessage; }
            catch (Exception) { if (!disposed) status.Text = "暂时无法打开单位历史，请刷新后重试。"; }
            finally { openingEditor = false; if (!disposed) UpdateActions(); }
        }
        private async Task OpenDetailAsync()
        {
            if (!CanAct() || rows.SelectedItems.Count != 1 || !(rows.SelectedItem is UnitRecord selected)) return;
            var originalOwner = loadedOwner; long originalSequence = sequence;
            openingEditor = true; UpdateActions();
            try
            {
                var detail = await service.DetailAsync(selected.Id, lifetime.Token);
                if (disposed || originalSequence != sequence || !originalOwner.IsCurrent(session) || !detail.IsCurrent(session)) return;
                var window = new UnitDetailWindow(Window.GetWindow(this), session, detail);
                window.ShowDialog();
                if (window.BusinessChanged && !disposed) { await LoadPageAsync(page); await LoadFacetsAsync(); }
            }
            catch (OperationCanceledException) { }
            catch (ApiException error) { if (!disposed) status.Text = error.UserMessage; }
            catch (Exception) { if (!disposed) status.Text = "读取单位详情失败，请刷新后重试。"; }
            finally { openingEditor = false; if (!disposed) UpdateActions(); }
        }
        private void OpenPrint()
        {
            if (!CanAct() || columnSnapshot?.IsCurrent(session) != true) return;
            openingEditor = true; UpdateActions();
            try { new UnitPrintWindow(Window.GetWindow(this), session, new UnitQuery(1, 20, search.Text, filters), columnSnapshot).ShowDialog(); }
            catch (ApiException error) { if (!disposed) status.Text = error.UserMessage; }
            catch (Exception) { if (!disposed) status.Text = "暂时无法打开打印预览，请刷新后重试。"; }
            finally { openingEditor = false; if (!disposed) UpdateActions(); }
        }
        private void OpenExport()
        {
            if (!CanAct() || columnSnapshot?.IsCurrent(session) != true) return;
            openingEditor = true; UpdateActions();
            try { new UnitExportWindow(Window.GetWindow(this), session, new UnitQuery(1, 20, search.Text, filters), columnSnapshot.Projection, loadedOwner).ShowDialog(); }
            catch (ApiException error) { if (!disposed) status.Text = error.UserMessage; }
            catch (Exception) { if (!disposed) status.Text = "暂时无法打开单位导出，请刷新表头后重试。"; }
            finally { openingEditor = false; if (!disposed) UpdateActions(); }
        }
        private async Task OpenHeaderSettingsAsync()
        {
            if (!CanAct() || columnSnapshot?.IsCurrent(session) != true) return;
            openingEditor = true; UpdateActions();
            try
            {
                var window = new UnitColumnSettingsWindow(Window.GetWindow(this), session, columnSnapshot);
                window.ShowDialog();
                if (disposed) return;
                if (window.AppliedSnapshot?.IsCurrent(session) == true) { columnSnapshot = window.AppliedSnapshot; ApplyColumns(); }
                if (window.BusinessChanged || window.HasCatalogChanges) { await LoadPageAsync(page); await LoadFacetsAsync(); }
            }
            catch (ApiException error) { if (!disposed) status.Text = error.UserMessage; }
            catch (Exception) { if (!disposed) status.Text = "表头设置未能完成，请保留本机草稿并刷新核对。"; }
            finally { openingEditor = false; if (!disposed) UpdateActions(); }
        }
        private async Task OpenPlatformValueAsync(string key)
        {
            if (!CanAct() || rows.SelectedItems.Count != 1 || !(rows.SelectedItem is UnitRecord record) || columnSnapshot?.IsCurrent(session) != true) return;
            openingEditor = true; UpdateActions();
            try
            {
                var window = new UnitPlatformValuesWindow(Window.GetWindow(this), session, columnSnapshot, record.Id, key.Substring(9));
                window.ShowDialog();
                if (window.BusinessChanged && !disposed) await LoadPageAsync(page);
            }
            catch (ApiException error) { if (!disposed) status.Text = error.UserMessage; }
            catch (Exception) { if (!disposed) status.Text = "自设字段未能保存，请保留原输入并核对当前字段版本。"; }
            finally { openingEditor = false; if (!disposed) UpdateActions(); }
        }
        private void ResetBaseColumns()
        {
            rows.Columns.Clear(); rows.Columns.Add(Column("编号", nameof(UnitRecord.Code), 120));
            rows.Columns.Add(Column("单位名称", nameof(UnitRecord.Name), 220)); rows.Columns.Add(Column("状态", nameof(UnitRecord.Status), 72));
            rows.FrozenColumnCount = 3;
        }
        private void ApplyColumns()
        {
            if (columnSnapshot?.IsCurrent(session) != true) return;
            rows.Columns.Clear();
            foreach (var column in columnSnapshot.Projection.Columns)
            {
                var binding = column.Key == "code" ? new Binding(nameof(UnitRecord.Code)) : column.Key == "name" ? new Binding(nameof(UnitRecord.Name))
                    : column.Key == "status" ? new Binding(nameof(UnitRecord.Status)) : new Binding(".") { Converter = new PlatformValueConverter(this, column.Key) };
                binding.TargetNullValue = "—";
                var shown = new DataGridTextColumn { Header = column.Label, Width = column.Width, Binding = binding, IsReadOnly = true, SortMemberPath = column.Key };
                var text = new Style(typeof(TextBlock));
                text.Setters.Add(new Setter(TextBlock.TextAlignmentProperty, column.Type == "number" ? TextAlignment.Right : TextAlignment.Left));
                shown.ElementStyle = text; rows.Columns.Add(shown);
            }
            rows.FrozenColumnCount = columnSnapshot.Projection.PinnedColumnCount;
        }
        private sealed class PlatformValueConverter : IValueConverter
        {
            private readonly UnitsWorkspaceView host; private readonly string key;
            internal PlatformValueConverter(UnitsWorkspaceView host, string key) { this.host = host; this.key = key; }
            public object Convert(object value, Type target, object parameter, CultureInfo culture)
            { return value is UnitRecord row && host.columnSnapshot?.IsCurrent(host.session) == true ? host.columnSnapshot.DisplayText(row.Id, key) : "—"; }
            public object ConvertBack(object value, Type target, object parameter, CultureInfo culture) { throw new NotSupportedException(); }
        }
        private void OpenInline()
        {
            if (!CanAct()) return;
            try
            {
                AttachInline(new UnitInlineWorkspace(Window.GetWindow(this), session, currentRows, loadedOwner));
            }
            catch (ApiException error) { status.Text = error.UserMessage; }
            catch (Exception) { status.Text = "行内编辑尚未打开，原资料没有变更。"; }
        }
        private void AttachInline(UnitInlineWorkspace workspace)
        {
            inlineWorkspace = workspace;
            workspace.Finished += async (sender, args) =>
            {
                if (Object.ReferenceEquals(inlineWorkspace, workspace))
                { inlineWorkspace = null; tableSurface.Child = rows; }
                workspace.Dispose();
                if (!disposed) { await LoadPageAsync(page); await LoadFacetsAsync(); UpdateActions(); }
            };
            tableSurface.Child = workspace; UpdateActions();
        }
        private async Task OpenEditorAsync(MutationAction action)
        {
            if (disposed || loading || openingEditor || editor != null || loadedOwner?.IsCurrent(session) != true) return;
            var operationOwner = loadedOwner;
            long operationSequence = sequence;
            var selected = rows.SelectedItem as UnitRecord;
            if (action != MutationAction.UnitCreate && (selected == null || rows.SelectedItems.Count != 1)) return;
            openingEditor = true; UpdateActions();
            try
            {
                UnitReadSnapshot<UnitRecord> baseline = null;
                if (action != MutationAction.UnitCreate)
                {
                    baseline = await service.DetailAsync(selected.Id, lifetime.Token);
                    if (disposed || operationSequence != sequence || !operationOwner.IsCurrent(session) || !baseline.IsCurrent(session)) return;
                }
                editor = new UnitEditorWindow(Window.GetWindow(this), session, service, baseline, action);
                editor.ShowDialog();
                bool changed = editor.BusinessChanged;
                editor = null;
                if (changed && !disposed) { await LoadPageAsync(page); await LoadFacetsAsync(); }
            }
            catch (OperationCanceledException) { }
            catch (ApiException error) { if (!disposed) status.Text = error.UserMessage; }
            catch (Exception) { if (!disposed) status.Text = "暂时无法打开单位编辑，请刷新资料后重试。"; }
            finally { openingEditor = false; if (!disposed) UpdateActions(); }
        }
        private async Task OpenRecoveryAsync()
        {
            if (disposed || openingEditor || editor != null || inlineWorkspace != null) return;
            openingEditor = true; UpdateActions();
            try
            {
                var window = new UnitRecoveryWindow(Window.GetWindow(this), session);
                if (window.ShowDialog() != true || disposed || window.SelectedDraft == null) return;
                var restored = window.SelectedDraft;
                if (restored.Action == MutationAction.UnitInlineEdit)
                {
                    var current = await service.DetailAsync(restored.ResourceId, lifetime.Token);
                    if (disposed || !current.IsCurrent(session)) return;
                    AttachInline(new UnitInlineWorkspace(Window.GetWindow(this), session, new[] { current.Value }, current.Owner, restored));
                    return;
                }
                if (restored.Action == MutationAction.UnitColumnLayoutSave || restored.Action == MutationAction.UnitPlatformDefinitionCreate
                    || restored.Action == MutationAction.UnitPlatformValuesWrite)
                {
                    var ids = restored.Action == MutationAction.UnitPlatformValuesWrite ? new[] { restored.ResourceId } : currentRows.Select(row => row.Id).ToArray();
                    var source = await columnsService.LoadAsync(ids, lifetime.Token, columnSnapshot);
                    if (disposed || !source.IsCurrent(session)) return;
                    DurableDraftDialog restoredEditor;
                    if (restored.Action == MutationAction.UnitColumnLayoutSave)
                        restoredEditor = new UnitColumnSettingsWindow(Window.GetWindow(this), session, source, restored);
                    else if (restored.Action == MutationAction.UnitPlatformDefinitionCreate)
                        restoredEditor = new UnitPlatformDefinitionWindow(Window.GetWindow(this), session, source, restored);
                    else restoredEditor = new UnitPlatformValuesWindow(Window.GetWindow(this), session, source, restored.ResourceId, null, restored);
                    restoredEditor.ShowDialog();
                    if (restoredEditor.BusinessChanged && !disposed) { await LoadPageAsync(page); await LoadFacetsAsync(); }
                    return;
                }
                UnitReadSnapshot<UnitRecord> baseline = null;
                if (restored.ResourceId != null) baseline = await service.DetailAsync(restored.ResourceId, lifetime.Token);
                if (disposed || baseline != null && !baseline.IsCurrent(session)) return;
                editor = new UnitEditorWindow(Window.GetWindow(this), session, service, baseline, restored.Action, restored);
                editor.ShowDialog();
                bool changed = editor.BusinessChanged; editor = null;
                if (changed && !disposed) { await LoadPageAsync(page); await LoadFacetsAsync(); }
            }
            catch (OperationCanceledException) { }
            catch (ApiException error) { if (!disposed) status.Text = error.UserMessage; }
            catch (Exception) { if (!disposed) status.Text = "本机草稿暂时无法恢复，原记录已保留。请重新读取资料后再打开。"; }
            finally { openingEditor = false; if (!disposed) UpdateActions(); }
        }
        public void Dispose()
        {
            if (disposed) return;
            disposed = true; searchDelay.Stop(); sequence++; pageRead?.Cancel(); lifetime.Cancel();
            session.SessionChanged -= OnOwnerChanged; session.ReadScopeChanged -= OnOwnerChanged;
            editor?.RetireOwner(); inlineWorkspace?.RetireOwner();
            pageRead?.Dispose(); lifetime.Dispose();
        }
    }
}
