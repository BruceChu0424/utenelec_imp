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
        private readonly TextBox search = new TextBox { MinWidth = 220, ToolTip = "按单位编号或名称搜索" };
        private readonly DataGrid rows = new DataGrid { SelectionMode = DataGridSelectionMode.Extended, SelectionUnit = DataGridSelectionUnit.FullRow };
        private readonly TextBlock status = new TextBlock { TextWrapping = TextWrapping.Wrap, VerticalAlignment = VerticalAlignment.Center };
        private readonly TextBlock pager = new TextBlock { VerticalAlignment = VerticalAlignment.Center };
        private readonly Button create = new Button { Content = "新增单位" };
        private readonly Button edit = new Button { Content = "编辑" };
        private readonly Button changeStatus = new Button { Content = "更改状态" };
        private readonly Button refresh = new Button { Content = "刷新" };
        private readonly Button recovery = new Button { Content = "本机草稿与记录" };
        private readonly Button previous = new Button { Content = "上一页" };
        private readonly Button next = new Button { Content = "下一页" };
        private readonly Dictionary<string, ComboBox> filterBoxes = new Dictionary<string, ComboBox>();
        private readonly Dictionary<string, UnitFilter> filters = new Dictionary<string, UnitFilter>(StringComparer.Ordinal);
        private readonly DispatcherTimer searchDelay = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(300) };
        private readonly CancellationTokenSource lifetime = new CancellationTokenSource();
        private CancellationTokenSource pageRead;
        private UnitEditorWindow editor;
        private UnitReadOwner loadedOwner;
        private UnitReadOwner scopeFence;
        private bool disposed, subscribed, loading, openingEditor, changingFilters;
        private long sequence;
        private int page = 1, totalPages;
        public bool CanCloseForUpdate { get { return !openingEditor && editor == null; } }

        public UnitsWorkspaceView(SessionCoordinator session)
        {
            this.session = session ?? throw new ArgumentNullException(nameof(session));
            SetResourceReference(StyleProperty, "Uten.Workspace");
            scopeFence = new UnitReadOwner(session);
            service = new UnitService(session);
            BuildLayout();
            Loaded += OnLoaded;
            Unloaded += (sender, args) => Dispose();
            refresh.Click += async (sender, args) => { await LoadPageAsync(page); await LoadFacetsAsync(); };
            previous.Click += async (sender, args) => await LoadPageAsync(Math.Max(1, page - 1));
            next.Click += async (sender, args) => await LoadPageAsync(page + 1);
            create.Click += async (sender, args) => await OpenEditorAsync(MutationAction.UnitCreate);
            edit.Click += async (sender, args) => await OpenEditorAsync(MutationAction.UnitUpdate);
            changeStatus.Click += async (sender, args) => await OpenEditorAsync(MutationAction.UnitStatus);
            recovery.Click += async (sender, args) => await OpenRecoveryAsync();
            rows.SelectionChanged += (sender, args) => UpdateActions();
            rows.MouseDoubleClick += async (sender, args) =>
            {
                if (ItemsControl.ContainerFromElement(rows, args.OriginalSource as DependencyObject) is DataGridRow
                    && rows.SelectedItems.Count == 1 && edit.IsEnabled) await OpenEditorAsync(MutationAction.UnitUpdate);
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
            var title = new TextBlock { Text = "单位资料", Style = (Style)FindResource("Uten.PageTitle"), VerticalAlignment = VerticalAlignment.Center };
            DockPanel.SetDock(title, Dock.Left); header.Children.Add(title);
            var actions = new WrapPanel { HorizontalAlignment = HorizontalAlignment.Right };
            create.SetResourceReference(StyleProperty, "Uten.PrimaryButton");
            foreach (var button in new[] { create, edit, changeStatus, recovery, refresh })
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
            rows.Columns.Add(Column("单位编号", nameof(UnitRecord.Code), 190));
            rows.Columns.Add(Column("单位名称", nameof(UnitRecord.Name), 1, stretch: true));
            rows.Columns.Add(Column("状态", nameof(UnitRecord.Status), 130));
            rows.CanUserDeleteRows = false;
            rows.CanUserSortColumns = false; // The owning service orders by code; no invented page-only sorting.
            var surface = UtenSurfaces.Wrap(rows, UtenSurfaceRole.Table);
            Grid.SetRow(surface, 3); layout.Children.Add(surface);
            var footer = new DockPanel { Margin = new Thickness(0, Space("S12"), 0, 0) };
            var paging = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Right };
            previous.Margin = new Thickness(Space("S8"), 0, Space("S8"), 0);
            next.Margin = new Thickness(Space("S8"), 0, 0, 0);
            previous.SetResourceReference(MinHeightProperty, "Uten.Height.Compact"); next.SetResourceReference(MinHeightProperty, "Uten.Height.Compact");
            paging.Children.Add(previous); paging.Children.Add(pager); paging.Children.Add(next);
            DockPanel.SetDock(paging, Dock.Right); footer.Children.Add(paging);
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
            sequence++; pageRead?.Cancel(); rows.SelectedItems.Clear(); loading = true; UpdateActions();
        }
        private async Task LoadPageAsync(int target)
        {
            if (disposed || !session.IsAuthenticated) return;
            pageRead?.Cancel(); pageRead?.Dispose(); pageRead = CancellationTokenSource.CreateLinkedTokenSource(lifetime.Token);
            var token = pageRead.Token; long request = ++sequence;
            loading = true; rows.SelectedItems.Clear(); status.Text = "正在读取单位资料…"; UpdateActions();
            try
            {
                var snapshot = await service.ListAsync(new UnitQuery(target, 20, search.Text, filters), token);
                if (disposed || request != sequence || !snapshot.IsCurrent(session)) return;
                loadedOwner = snapshot.Owner;
                rows.ItemsSource = snapshot.Value.Items; page = snapshot.Value.Page; totalPages = snapshot.Value.TotalPages;
                pager.Text = page.ToString(CultureInfo.InvariantCulture) + " / " + Math.Max(1, totalPages).ToString(CultureInfo.InvariantCulture);
                status.Text = snapshot.Value.TotalElements == 0 ? "没有符合条件的单位。" : "共 " + snapshot.Value.TotalElements.ToString(CultureInfo.InvariantCulture) + " 项";
            }
            catch (OperationCanceledException) { }
            catch (ApiException error) { if (!disposed && request == sequence) { loadedOwner = null; rows.ItemsSource = null; status.Text = error.UserMessage; } }
            catch (Exception) { if (!disposed && request == sequence) { loadedOwner = null; rows.ItemsSource = null; status.Text = "读取单位资料失败，请点击刷新重试。"; } }
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
            bool canAct = !disposed && !loading && !openingEditor && editor == null && user != null
                && user.HasPermission("unit:view") && loadedOwner?.IsCurrent(session) == true;
            create.Visibility = user?.HasPermission("unit:create") == true ? Visibility.Visible : Visibility.Collapsed;
            edit.Visibility = user?.HasPermission("unit:edit") == true ? Visibility.Visible : Visibility.Collapsed;
            changeStatus.Visibility = user?.HasPermission("unit:status") == true ? Visibility.Visible : Visibility.Collapsed;
            create.IsEnabled = canAct; edit.IsEnabled = canAct && rows.SelectedItems.Count == 1;
            changeStatus.IsEnabled = canAct && rows.SelectedItems.Count == 1;
            previous.IsEnabled = !loading && page > 1; next.IsEnabled = !loading && page < totalPages;
            refresh.IsEnabled = !openingEditor && editor == null;
            recovery.IsEnabled = !openingEditor && editor == null && user?.HasPermission("unit:view") == true;
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
            if (disposed || openingEditor || editor != null) return;
            openingEditor = true; UpdateActions();
            try
            {
                var window = new UnitRecoveryWindow(Window.GetWindow(this), session);
                if (window.ShowDialog() != true || disposed || window.SelectedDraft == null) return;
                var restored = window.SelectedDraft;
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
            editor?.RetireOwner();
            pageRead?.Dispose(); lifetime.Dispose();
        }
    }
}
