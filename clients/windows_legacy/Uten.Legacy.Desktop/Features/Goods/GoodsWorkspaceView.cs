using System;
using System.Collections.Generic;
using System.Threading;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Data;
using System.Windows.Input;
using System.Windows.Threading;
using Uten.Legacy.Core;
using Uten.Legacy.Desktop.Controls;
using Uten.Legacy.Desktop.Features.Units;
using Uten.Legacy.Desktop.Shared;

namespace Uten.Legacy.Desktop.Features.Goods
{
    // Native WPF read path only. Editing, exports, BOM and lifecycle commands are not migrated here.
    public sealed class GoodsWorkspaceView : UserControl
    {
        private readonly SessionCoordinator session;
        private readonly GoodsReadService service;
        private readonly TextBox search = new TextBox { MinWidth = 230, VerticalContentAlignment = VerticalAlignment.Center };
        private readonly TreeView categories = new TreeView { BorderThickness = new Thickness(0) };
        private readonly DataGrid rows = new DataGrid { IsReadOnly = true, AutoGenerateColumns = false,
            CanUserAddRows = false, CanUserDeleteRows = false, SelectionMode = DataGridSelectionMode.Single,
            HeadersVisibility = DataGridHeadersVisibility.Column, EnableRowVirtualization = true,
            EnableColumnVirtualization = true, GridLinesVisibility = DataGridGridLinesVisibility.Horizontal };
        private readonly TextBlock status = new TextBlock { TextWrapping = TextWrapping.Wrap, VerticalAlignment = VerticalAlignment.Center };
        private readonly TextBlock shownScope = new TextBlock { Text = "货品资料", VerticalAlignment = VerticalAlignment.Center };
        private readonly TextBlock pageText = new TextBlock { VerticalAlignment = VerticalAlignment.Center, MinWidth = 145 };
        private readonly Button retry = new Button { Content = "重新读取", MinWidth = 84 };
        private readonly Border detail = new RoundedSurface { Visibility = Visibility.Collapsed,
            BorderThickness = new Thickness(0, 1, 0, 0), MaxHeight = 190 };
        private readonly WrapPanel detailFields = new WrapPanel();
        private readonly TextBlock detailTitle = new TextBlock { FontSize = 15, FontWeight = FontWeights.SemiBold };
        private readonly TextBlock detailStatus = new TextBlock { TextWrapping = TextWrapping.Wrap };
        private readonly Button detailRetry = new Button { Content = "重试详情", Visibility = Visibility.Collapsed,
            HorizontalAlignment = HorizontalAlignment.Left };
        // Cross-module FLOW entry: opens the owning unit by its real UUID relationship key.
        private readonly Button openUnit = new Button { Content = "查看单位资料", Visibility = Visibility.Collapsed,
            HorizontalAlignment = HorizontalAlignment.Left };
        private readonly DebouncedSearchInput searchDelay;
        private CancellationTokenSource lifetime;
        private CancellationTokenSource listRead;
        private CancellationTokenSource treeRead;
        private CancellationTokenSource detailRead;
        private long listGeneration, treeGeneration, detailGeneration;
        private string selectedCategory;
        private string selectedCategoryName = "全部货品";
        private string unitUuid;
        private bool listBusy, subscribed, replacingCategories;
        private long observedSessionGeneration, observedReadRevision;

        public GoodsWorkspaceView(SessionCoordinator session)
        {
            this.session = session ?? throw new ArgumentNullException(nameof(session));
            SetResourceReference(StyleProperty, "Uten.Workspace");
            service = new GoodsReadService(session);
            BuildLayout();
            Loaded += OnLoaded;
            Unloaded += OnUnloaded;
            categories.SelectedItemChanged += OnCategoryChanged;
            rows.SelectionChanged += OnRowSelected;
            detailRetry.Click += (sender, args) => OnRowSelected(rows, null);
            openUnit.Click += async (sender, args) => await OpenUnitByUuidAsync();
            retry.Click += async (sender, args) => await LoadAsync();
            searchDelay = new DebouncedSearchInput(search, () =>
            {
                Cancel(listRead); listGeneration++; Cancel(detailRead); detailGeneration++;
                detail.Visibility = Visibility.Collapsed; listBusy = true; UpdateListState();
                status.Text = "搜索条件已变化，正在准备读取…";
            }, () => LoadPageAsync(1), () => IsLoaded && lifetime != null && !lifetime.IsCancellationRequested);
        }

        private static TextBlock Label(string text, double size = 12)
        {
            var result = new TextBlock { Text = text, FontSize = size, VerticalAlignment = VerticalAlignment.Center };
            result.SetResourceReference(TextBlock.ForegroundProperty, "Uten.Text");
            return result;
        }
        private double Space(string role) { return (double)FindResource("Uten.Space." + role); }
        private Thickness Spacing(string left = null, string top = null, string right = null, string bottom = null)
        {
            return new Thickness(left == null ? 0 : Space(left), top == null ? 0 : Space(top),
                right == null ? 0 : Space(right), bottom == null ? 0 : Space(bottom));
        }
        private void BuildLayout()
        {
            SetResourceReference(BackgroundProperty, "Uten.Background");
            SetResourceReference(ForegroundProperty, "Uten.Text");
            var grid = new Grid();
            grid.SetResourceReference(MarginProperty, "Uten.Padding.S24");
            grid.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
            grid.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
            grid.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star), MinHeight = 160 });
            grid.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
            grid.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
            var toolbar = new DockPanel { Margin = Spacing(bottom: "S12") };
            var title = Label("货品资料"); title.SetResourceReference(StyleProperty, "Uten.PageTitle");
            DockPanel.SetDock(title, Dock.Left); toolbar.Children.Add(title);
            var searchPanel = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Right };
            var searchLabel = Label("名称、编码或规格"); searchLabel.Margin = Spacing(left: "S24", right: "S8");
            search.SetResourceReference(StyleProperty, "Uten.CompactInput");
            search.SetResourceReference(MinHeightProperty, "Uten.Height.Compact");
            search.ToolTip = "按名称、编码或规格搜索货品。";
            searchPanel.Children.Add(searchLabel); searchPanel.Children.Add(search);
            toolbar.Children.Add(searchPanel);
            grid.Children.Add(toolbar);
            var statusPanel = new DockPanel { Margin = Spacing(bottom: "S8") };
            retry.SetResourceReference(MinHeightProperty, "Uten.Height.Standard");
            DockPanel.SetDock(retry, Dock.Right); statusPanel.Children.Add(retry); statusPanel.Children.Add(status);
            Grid.SetRow(statusPanel, 1); grid.Children.Add(statusPanel);
            status.SetResourceReference(TextBlock.ForegroundProperty, "Uten.Muted");
            var body = new Grid();
            body.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(220), MinWidth = 160 });
            body.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(Space("S8")) });
            body.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star), MinWidth = 240 });
            var categoryPanel = new DockPanel();
            var categoryTitle = Label("货品分类"); categoryTitle.SetResourceReference(MarginProperty, "Uten.Padding.S12");
            categories.SetResourceReference(Control.PaddingProperty, "Uten.Padding.S8");
            DockPanel.SetDock(categoryTitle, Dock.Top); categoryPanel.Children.Add(categoryTitle); categoryPanel.Children.Add(categories);
            var categorySurface = UtenSurfaces.Wrap(categoryPanel); body.Children.Add(categorySurface);
            var splitter = new GridSplitter { HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Stretch };
            splitter.SetResourceReference(WidthProperty, "Uten.Space.S4");
            Grid.SetColumn(splitter, 1); body.Children.Add(splitter);
            VirtualizingPanel.SetVirtualizationMode(rows, VirtualizationMode.Recycling);
            rows.SetResourceReference(Control.BackgroundProperty, "Uten.Surface");
            rows.SetResourceReference(Control.ForegroundProperty, "Uten.Text");
            rows.SetResourceReference(Control.BorderBrushProperty, "Uten.Border");
            // Match MasterDataTableView's content-driven rows (12 x 8 cell padding),
            // not the separate 32px cell-editor role. Headers have a 44px minimum.
            rows.RowHeight = double.NaN;
            rows.ColumnHeaderHeight = double.NaN;
            rows.BorderThickness = new Thickness(0);
            var cellStyle = new Style(typeof(DataGridCell), TryFindResource(typeof(DataGridCell)) as Style);
            cellStyle.Setters.Add(new Setter(Control.PaddingProperty, Spacing("S12", "S8", "S12", "S8")));
            rows.CellStyle = cellStyle;
            var headerStyle = new Style(typeof(DataGridColumnHeader), TryFindResource(typeof(DataGridColumnHeader)) as Style);
            headerStyle.Setters.Add(new Setter(MinHeightProperty, new DynamicResourceExtension("Uten.Height.Input")));
            headerStyle.Setters.Add(new Setter(Control.PaddingProperty, Spacing(left: "S12", right: "S12")));
            rows.ColumnHeaderStyle = headerStyle;
            var tableSurface = UtenSurfaces.Wrap(rows, UtenSurfaceRole.Table, outlined: false);
            Grid.SetColumn(tableSurface, 2); body.Children.Add(tableSurface);
            Grid.SetRow(body, 2); grid.Children.Add(body);
            var footer = new DockPanel { Margin = Spacing(top: "S8", bottom: "S8") };
            DockPanel.SetDock(pageText, Dock.Right); footer.Children.Add(pageText); footer.Children.Add(shownScope);
            Grid.SetRow(footer, 3); grid.Children.Add(footer);
            var details = new StackPanel(); details.Children.Add(detailTitle); details.Children.Add(detailStatus);
            details.Children.Add(detailRetry); details.Children.Add(openUnit); details.Children.Add(detailFields);
            detail.Child = new ScrollViewer { Content = details, VerticalScrollBarVisibility = ScrollBarVisibility.Auto };
            detail.SetResourceReference(Border.PaddingProperty, "Uten.Padding.S16");
            detail.SetResourceReference(Border.CornerRadiusProperty, "Uten.Radius.Card");
            detail.SetResourceReference(Border.BackgroundProperty, "Uten.Surface");
            detail.SetResourceReference(Border.BorderBrushProperty, "Uten.Border");
            detailRetry.Margin = Spacing(top: "S8");
            detailRetry.SetResourceReference(MinHeightProperty, "Uten.Height.Compact");
            Grid.SetRow(detail, 4); grid.Children.Add(detail);
            Content = grid;
        }
        private void ConfigureColumns()
        {
            rows.Columns.Clear();
            AddColumn("编码", "Code", 120); AddColumn("名称", "Name", 190); AddColumn("规格", "Spec", 140);
            AddColumn("颜色", "ColorName", 90); AddColumn("单位", "UnitName", 70);
            AddColumn("来源", "SourceType", 90); AddColumn("库存数量", "StockQuantity", 100);
            if (CanViewPrice)
            {
                AddColumn("售价", "Price", 100);
                var currencyStyle = new Style(typeof(TextBlock));
                currencyStyle.Setters.Add(new Setter(TextBlock.FontWeightProperty, FontWeights.SemiBold));
                currencyStyle.Setters.Add(new Setter(TextBlock.ForegroundProperty,
                    new Binding("CurrencyColorRole") { Converter = new CurrencyBrushConverter() }));
                rows.Columns.Add(new DataGridTextColumn { Header = "币种", Binding = new Binding("Currency"),
                    Width = 100, ElementStyle = currencyStyle, CanUserSort = false, IsReadOnly = true });
            }
            if (Allowed("goods:discount:view")) AddColumn("折扣倍率", "Discount", 100);
        }
        private void AddColumn(string header, string binding, double width)
        {
            rows.Columns.Add(new DataGridTextColumn { Header = header, Binding = new Binding(binding), Width = width,
                CanUserSort = false, IsReadOnly = true });
        }
        private bool Allowed(string permission)
        {
            return session.CurrentUser != null && session.CurrentUser.HasPermission(permission);
        }
        private bool CanViewPrice { get { return Allowed("goods:price:view") || Allowed("goods:price:edit"); } }
        private async void OnLoaded(object sender, RoutedEventArgs args)
        {
            if (subscribed) return;
            subscribed = true; session.SessionChanged += OnSessionChanged; session.ReadScopeChanged += OnSessionChanged;
            observedSessionGeneration = session.Generation; observedReadRevision = session.ReadScopeRevision;
            lifetime = new CancellationTokenSource();
            ClearData(); ConfigureColumns();
            await LoadAsync();
        }
        private void OnUnloaded(object sender, RoutedEventArgs args)
        {
            if (subscribed) { session.SessionChanged -= OnSessionChanged; session.ReadScopeChanged -= OnSessionChanged; }
            subscribed = false; searchDelay.Stop(); Cancel(lifetime); CancelReads();
            TableSelection.Clear(rows);
            detail.Visibility = Visibility.Collapsed;
        }
        private void OnSessionChanged(object sender, EventArgs args)
        {
            if (!Dispatcher.CheckAccess()) { Dispatcher.BeginInvoke(new Action(() => OnSessionChanged(sender, args))); return; }
            if (!subscribed || !IsLoaded) return;
            if (observedSessionGeneration == session.Generation && observedReadRevision == session.ReadScopeRevision) return;
            observedSessionGeneration = session.Generation; observedReadRevision = session.ReadScopeRevision;
            searchDelay.Stop(); CancelReads(); ClearData(); ConfigureColumns();
            status.Text = "账号或服务器连接已变化，请重新读取资料。";
        }
        private void CancelReads()
        {
            listGeneration++; treeGeneration++; detailGeneration++;
            Cancel(listRead); Cancel(treeRead); Cancel(detailRead);
            listBusy = false; UpdateListState();
        }
        private static void Cancel(CancellationTokenSource source)
        {
            if (source != null) source.Cancel();
        }
        private void ClearData()
        {
            rows.ItemsSource = null;
            replacingCategories = true;
            try { categories.Items.Clear(); } finally { replacingCategories = false; }
            detail.Visibility = Visibility.Collapsed;
            detailFields.Children.Clear(); selectedCategory = null;
            selectedCategoryName = "全部货品"; shownScope.Text = "货品资料"; pageText.Text = "尚未读取";
            UpdateListState();
        }
        public async Task LoadAsync()
        {
            if (!IsLoaded || lifetime == null || lifetime.IsCancellationRequested) return;
            if (!Allowed(GoodsReadService.GoodsViewPermission)) { ClearData(); status.Text = "当前账号没有货品查看权限。"; return; }
            await Task.WhenAll(LoadTreeAsync(), LoadPageAsync(1));
        }
        private async Task LoadTreeAsync()
        {
            Cancel(treeRead); long generation = ++treeGeneration;
            treeRead = CancellationTokenSource.CreateLinkedTokenSource(lifetime.Token);
            CancellationToken token = treeRead.Token; long ownerGeneration = session.Generation, ownerReadRevision = session.ReadScopeRevision;
            if (!Allowed(GoodsReadService.CategoryViewPermission))
            {
                replacingCategories = true;
                try { categories.Items.Clear(); categories.Items.Add(new TreeViewItem { Header = "当前账号无分类查看权限", IsEnabled = false }); }
                finally { replacingCategories = false; }
                return;
            }
            try
            {
                var result = await service.CategoriesAsync(token);
                if (token.IsCancellationRequested || generation != treeGeneration || ownerGeneration != session.Generation || ownerReadRevision != session.ReadScopeRevision || !IsLoaded) return;
                replacingCategories = true;
                try
                {
                    categories.Items.Clear();
                    var all = new TreeViewItem { Header = "全部货品", Tag = null, IsSelected = selectedCategory == null };
                    categories.Items.Add(all);
                    foreach (GoodsCategory category in result) categories.Items.Add(CategoryItem(category, selectedCategory));
                }
                finally { replacingCategories = false; }
            }
            catch (OperationCanceledException) { }
            catch (Exception)
            {
                if (!token.IsCancellationRequested && generation == treeGeneration && ownerGeneration == session.Generation && ownerReadRevision == session.ReadScopeRevision && IsLoaded)
                {
                    replacingCategories = true;
                    try { categories.Items.Clear(); categories.Items.Add(new TreeViewItem { Header = "分类读取失败，请重新读取", IsEnabled = false }); }
                    finally { replacingCategories = false; }
                }
            }
        }
        private static TreeViewItem CategoryItem(GoodsCategory category, string selected)
        {
            var item = new TreeViewItem { Header = category.ToString(), Tag = category, IsSelected = category.Id == selected };
            foreach (GoodsCategory child in category.Children) item.Items.Add(CategoryItem(child, selected));
            return item;
        }
        private async void OnCategoryChanged(object sender, RoutedPropertyChangedEventArgs<object> args)
        {
            if (replacingCategories || args.NewValue == null) return;
            var item = args.NewValue as TreeViewItem;
            var category = item == null ? null : item.Tag as GoodsCategory;
            selectedCategory = category == null ? null : category.Id;
            selectedCategoryName = category == null ? "全部货品" : category.ToString();
            await LoadPageAsync(1);
        }
        private Task LoadPageAsync(int requestedPage)
        {
            if (!IsLoaded || lifetime == null || lifetime.IsCancellationRequested || !Allowed(GoodsReadService.GoodsViewPermission)) return Task.CompletedTask;
            long owner = session.Generation, revision = session.ReadScopeRevision, expectedRead = listGeneration + 1;
            var key = Tuple.Create(selectedCategory, (search.Text ?? "").Trim(), owner, revision);
            return searchDelay.RunReadAsync(key,
                () => IsLoaded && !lifetime.IsCancellationRequested && listGeneration == expectedRead
                    && session.Generation == owner && session.ReadScopeRevision == revision,
                () => LoadPageCoreAsync(requestedPage));
        }

        private async Task LoadPageCoreAsync(int requestedPage)
        {
            if (!IsLoaded || lifetime == null || lifetime.IsCancellationRequested || !Allowed(GoodsReadService.GoodsViewPermission)) return;
            Cancel(listRead); long generation = ++listGeneration;
            listRead = CancellationTokenSource.CreateLinkedTokenSource(lifetime.Token);
            CancellationToken token = listRead.Token; long ownerGeneration = session.Generation, ownerReadRevision = session.ReadScopeRevision;
            string categoryId = selectedCategory, categoryCaption = selectedCategoryName, keyword = search.Text;
            Cancel(detailRead); detailGeneration++; detail.Visibility = Visibility.Collapsed;
            listBusy = true; UpdateListState(); status.Text = "正在读取货品，列表保留上次结果…";
            try
            {
                GoodsPage first = null;
                var result = await CompletePagedSnapshot.ReadAsync<GoodsRecord>(async (batch, size, ct) =>
                {
                    var response = await service.ListAsync(categoryId, keyword, batch, size, ct).ConfigureAwait(false);
                    if (first == null) first = response;
                    return new SnapshotPage<GoodsRecord> { Items = response.Items, Page = response.Page,
                        Size = response.Size, Total = response.Total, TotalPages = response.TotalPages,
                        ReadScopeVersion = response.ReadScopeVersion };
                }, item => item.Id,
                    () => !token.IsCancellationRequested && generation == listGeneration
                        && ownerGeneration == session.Generation && ownerReadRevision == session.ReadScopeRevision,
                    token, maximumRows: Int32.MaxValue);
                if (token.IsCancellationRequested || generation != listGeneration || ownerGeneration != session.Generation || ownerReadRevision != session.ReadScopeRevision || !IsLoaded) return;
                rows.ItemsSource = result;
                pageText.Text = "共 " + first.Total + " 项";
                shownScope.Text = categoryCaption + (string.IsNullOrWhiteSpace(keyword) ? "" : " · 搜索：“" + keyword.Trim() + "”");
                status.Text = result.Count == 0 ? "当前范围没有货品。" : "";
            }
            catch (OperationCanceledException) { }
            catch (ApiException error) when (error.Code == "READ_SCOPE_CHANGED" || error.StatusCode == 403)
            {
                if (generation == listGeneration && ownerGeneration == session.Generation && IsLoaded)
                { ClearData(); status.Text = error.UserMessage; }
            }
            catch (Exception)
            {
                if (!token.IsCancellationRequested && generation == listGeneration && ownerGeneration == session.Generation && ownerReadRevision == session.ReadScopeRevision && IsLoaded)
                    status.Text = "无法读取货品，已保留上次列表。请检查连接与查看权限后重新读取。";
            }
            finally
            {
                if (generation == listGeneration && IsLoaded) { listBusy = false; UpdateListState(); }
            }
        }
        private void UpdateListState()
        {
            rows.IsEnabled = !listBusy;
        }
        private async void OnRowSelected(object sender, SelectionChangedEventArgs args)
        {
            var selected = rows.SelectedItem as GoodsRecord;
            Cancel(detailRead); long generation = ++detailGeneration;
            if (selected == null) { detail.Visibility = Visibility.Collapsed; return; }
            if (listBusy || lifetime == null || lifetime.IsCancellationRequested) return;
            detailRead = CancellationTokenSource.CreateLinkedTokenSource(lifetime.Token);
            CancellationToken token = detailRead.Token; long ownerGeneration = session.Generation, ownerReadRevision = session.ReadScopeRevision;
            detailFields.Children.Clear(); detailTitle.Text = selected.Code + "  " + selected.Name;
            detailStatus.Text = "正在读取详情…"; detailRetry.Visibility = Visibility.Collapsed;
            openUnit.Visibility = Visibility.Collapsed; detail.Visibility = Visibility.Visible;
            try
            {
                GoodsRecord result = await service.DetailAsync(selected.Id, token);
                if (token.IsCancellationRequested || generation != detailGeneration || ownerGeneration != session.Generation || ownerReadRevision != session.ReadScopeRevision || !IsLoaded) return;
                detailStatus.Text = "";
                Field("编码", result.Code); Field("名称", result.Name); Field("分类", result.Text("categoryName"));
                Field("规格", result.Spec); Field("颜色", result.ColorName);
                Field("单位", result.UnitName); Field("单位关系", result.UnitRelationship);
                Field("来源", result.SourceType); Field("所属仓库", result.Text("owningWarehouseName"));
                Field("归属车间", result.Text("owningWorkshopName")); Field("发料方式", result.Text("issueMethod"));
                Field("英文名称", result.Text("nameEn")); Field("英文名称来源", result.Text("nameEnSource"));
                Field("历史迁移编号", result.LegacyId); Field("备注", result.Text("paper"));
                if (CanViewPrice && !result.Flag("priceMasked"))
                {
                    Field("售价", result.Price);
                    Field("币种", result.Currency, "Uten.Currency." + result.CurrencyColorRole);
                }
                if (Allowed("goods:discount:view") && !result.Flag("discountMasked")) Field("折扣倍率", result.Discount);
                // Only a real unit UUID may navigate; the legacy snapshot fallback keeps
                // its display fact without inventing a relationship key.
                unitUuid = result.UnitId;
                openUnit.Visibility = result.UnitId != null && Allowed("unit:view") ? Visibility.Visible : Visibility.Collapsed;
                openUnit.Margin = Spacing(top: "S8");
                openUnit.SetResourceReference(MinHeightProperty, "Uten.Height.Compact");
            }
            catch (OperationCanceledException) { }
            catch (ApiException error) when (error.Code == "READ_SCOPE_CHANGED" || error.StatusCode == 403)
            {
                if (generation == detailGeneration && ownerGeneration == session.Generation && IsLoaded)
                { ClearData(); status.Text = error.UserMessage; }
            }
            catch (Exception)
            {
                if (!token.IsCancellationRequested && generation == detailGeneration && ownerGeneration == session.Generation && ownerReadRevision == session.ReadScopeRevision && IsLoaded)
                {
                    detailStatus.Text = "详情读取失败，请重试；若持续失败，请检查连接与查看权限。";
                    detailRetry.Visibility = Visibility.Visible;
                }
            }
        }
        private void Field(string name, string value, string foregroundResource = null)
        {
            var text = Label(name + "：" + value);
            text.Margin = Spacing(top: "S8", right: "S24"); text.MinWidth = 170; text.TextWrapping = TextWrapping.Wrap;
            if (foregroundResource != null)
            {
                text.SetResourceReference(TextBlock.ForegroundProperty, foregroundResource);
                text.FontWeight = FontWeights.SemiBold;
            }
            detailFields.Children.Add(text);
        }
        // 单位→货品 FLOW: navigate to the owning unit master by the authoritative UUID.
        // The unit window carries its own edit/status/delete guards and reference protection.
        private async Task OpenUnitByUuidAsync()
        {
            var target = unitUuid;
            if (string.IsNullOrEmpty(target) || !Allowed("unit:view") || lifetime == null || lifetime.IsCancellationRequested) return;
            try
            {
                var snapshot = await new UnitService(session).DetailAsync(target, lifetime.Token);
                if (lifetime.Token.IsCancellationRequested || !IsLoaded || !snapshot.IsCurrent(session)) return;
                var window = new UnitDetailWindow(Window.GetWindow(this), session, snapshot);
                TableSelection.Clear(rows);
                window.ShowDialog();
                if (window.BusinessChanged) status.Text = "单位资料已更新，货品列表重新读取后同步。";
            }
            catch (OperationCanceledException) { }
            catch (ApiException error)
            {
                if (IsLoaded) status.Text = "单位详情未能读取：" + error.UserMessage;
            }
            catch (Exception)
            {
                if (IsLoaded) status.Text = "单位详情暂时不可用，请稍后重试；货品资料未变更。";
            }
        }
    }
}
