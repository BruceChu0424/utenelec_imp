using System;
using System.Collections.Generic;
using System.Linq;
using System.IO;
using System.Net.Http;
using System.Net;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Threading;
using Uten.Legacy.Core;
using Uten.Legacy.Desktop;
using Uten.Legacy.Desktop.Controls;
using Uten.Legacy.Desktop.Features.Units;
using Uten.Legacy.Desktop.Features.Goods;
using Uten.Legacy.Core.Tests;

namespace Uten.Legacy.Tests
{
    internal static class UiContractChecks
    {
        internal static int RunSearchReadCoalescing()
        {
            if (Application.Current == null)
            {
                var application = new App(); application.InitializeComponent();
                application.ShutdownMode = ShutdownMode.OnExplicitShutdown;
            }
            int assertions = 0;
            Action<bool, string> check = (value, message) => { if (!value) throw new InvalidOperationException(message); assertions++; };
            var configuration = new ClientConfiguration(new[] { new ServerEndpoint("first", "Fixture", "https://first.company.test/api") }, "first");
            foreach (bool goods in new[] { true, false })
            {
                var handler = new SearchReadUiHandler();
                using (var session = new SessionCoordinator(configuration, handler, new MemoryStore()))
                {
                    session.LoginAsync("fixture", "fixture-password", CancellationToken.None).GetAwaiter().GetResult();
                    FrameworkElement view = goods ? (FrameworkElement)new GoodsWorkspaceView(session) : new UnitsWorkspaceView(session);
                    var window = new Window { Content = view, Width = 1400, Height = 850, Opacity = 0, ShowActivated = false, ShowInTaskbar = false };
                    var release = new TaskCompletionSource<bool>();
                    try
                    {
                        window.Show();
                        var table = FindVisual<DataGrid>(view, item => true);
                        PumpUntil(() => table.Items.Count > 0 && !ReadBusy(view, goods), "The native leaf must finish its first read.");
                        var search = FindVisual<TextBox>(view, item => true);
                        if (!goods) PumpUntil(() => FindVisual<ComboBox>(view, box => Equals(box.ToolTip, "全部状态")).Items.Count >= 3, "The unit status filter must load.");
                        handler.BeforeList = (uri, token) => release.Task;
                        search.Text = "needle";
                        SelectReadFilter(view, goods, 2);
                        PumpUntil(() => handler.ListReads == 2, "A changed category/filter must dispatch one current query.");
                        PumpFor(380);
                        check(handler.ListReads == 2, "A category/filter read consumes the pending text debounce instead of sending it twice.");
                        RaiseEnter(search); RaiseEnter(search); PumpFor(25);
                        check(handler.ListReads == 2, "Enter joins the actual in-flight category/filter read.");
                        handler.BeforeList = null; release.SetResult(true);
                        PumpUntil(() => !ReadBusy(view, goods) && ShownSearchName(table, goods).Contains("needle"), "The joined read must publish the latest query's actual rows.");
                        check(handler.LastQuery.Contains("needle"), "The dispatched read contains the current input.");
                        PumpFor(25); RaiseEnter(search);
                        PumpUntil(() => handler.ListReads == 3 && !ReadBusy(view, goods), "Completed same-query Enter must refresh.");
                        check(handler.ListReads == 3, "No completed-query cache suppresses an explicit refresh.");

                        if (!goods)
                        {
                            // Recovery stays available while a background read runs.
                            // Exercise the same post-confirmation callback as recovered
                            // edits without issuing any fixture business command.
                            var beforeWrite = new TaskCompletionSource<bool>();
                            handler.BeforeList = (uri, token) => beforeWrite.Task;
                            var oldRead = (Task)view.GetType().GetMethod("LoadPageAsync", System.Reflection.BindingFlags.NonPublic | System.Reflection.BindingFlags.Instance)
                                .Invoke(view, new object[] { 1 });
                            PumpUntil(() => handler.ListReads == 4, "The same-query read must precede recovery completion.");
                            var failedSelection = (UnitRecord)table.Items[0];
                            var selection = (Uten.Legacy.Desktop.Shared.PersistentRowSelection<UnitRecord>)view.GetType()
                                .GetField("selection", System.Reflection.BindingFlags.NonPublic | System.Reflection.BindingFlags.Instance).GetValue(view);
                            selection.Remember(failedSelection);
                            handler.CommittedVersion = 1; handler.BeforeList = null;
                            var afterWrite = (Task)view.GetType().GetMethod("ReloadPageAfterOperationAsync", System.Reflection.BindingFlags.NonPublic | System.Reflection.BindingFlags.Instance)
                                .Invoke(view, null);
                            PumpUntil(() => afterWrite.IsCompleted && !ReadBusy(view, false) && ShownSearchName(table, false).Contains("|v1"), "Confirmed recovery must issue a fresh same-query read.");
                            check(handler.ListReads == 5, "A confirmed write cannot join the earlier same-query flight.");
                            check(selection.Contains(failedSelection), "Retiring a pre-write read keeps failed/cross-page selection state.");
                            beforeWrite.SetResult(true); PumpUntil(() => oldRead.IsCompleted, "Cancelled pre-write fixture read must settle."); PumpFor(30);
                            check(ShownSearchName(table, false).Contains("|v1"), "A late pre-write response cannot replace confirmed post-write data.");
                            RaiseEnter(search); PumpUntil(() => handler.ListReads == 6 && !ReadBusy(view, false), "Same-query Enter still refreshes after the forced post-write read.");
                            check(handler.ListReads == 6, "Post-write retirement does not permanently suppress explicit refresh.");
                        }

                        var retired = new TaskCompletionSource<bool>();
                        int beforeRetirement = handler.ListReads;
                        handler.BeforeList = (uri, token) => SearchReadUiHandler.Parameter(uri, "keyword") == "retired" ? retired.Task : Task.CompletedTask;
                        search.Text = "retired"; SelectReadFilter(view, goods, 1);
                        PumpUntil(() => handler.ListReads == beforeRetirement + 1, "The old read must be in flight before supersession.");
                        if (goods)
                        {
                            search.Text = "newest"; SelectReadFilter(view, true, 2);
                            PumpUntil(() => handler.ListReads == beforeRetirement + 2 && !ReadBusy(view, true) && ShownSearchName(table, true).Contains("newest"), "A newer category query must replace the retired read.");
                        }
                        else
                        {
                            handler.UserId = "fixture-new-search-owner";
                            session.LoginAsync("fixture-new", "fixture-password", CancellationToken.None).GetAwaiter().GetResult();
                            PumpUntil(() => handler.ListReads == beforeRetirement + 2 && !ReadBusy(view, false) && ShownSearchName(table, false).Contains(handler.UserId), "A new owner must read its own rows rather than join the old scope.");
                        }
                        retired.SetResult(true); PumpFor(60);
                        check(!ShownSearchName(table, goods).Contains("retired"), "A cancelled older query must never overwrite the new query/owner's rows.");
                        check(handler.ListReads == beforeRetirement + 2, "Supersession does not leave another delayed duplicate query.");
                    }
                    finally { handler.BeforeList = null; release.TrySetResult(true); window.Close(); }
                }
            }
            return assertions;
        }

        private static bool ReadBusy(object view, bool goods) => (bool)view.GetType()
            .GetField(goods ? "listBusy" : "loading", System.Reflection.BindingFlags.NonPublic | System.Reflection.BindingFlags.Instance).GetValue(view);
        private static string ShownSearchName(DataGrid table, bool goods) => goods ? ((GoodsRecord)table.Items[0]).Name : ((UnitRecord)table.Items[0]).Name;
        private static void RaiseEnter(TextBox input) => input.RaiseEvent(new System.Windows.Input.KeyEventArgs(System.Windows.Input.Keyboard.PrimaryDevice,
            PresentationSource.FromVisual(input), 0, System.Windows.Input.Key.Enter) { RoutedEvent = System.Windows.Input.Keyboard.KeyDownEvent });
        private static void PumpFor(int milliseconds)
        {
            var elapsed = System.Diagnostics.Stopwatch.StartNew();
            PumpUntil(() => elapsed.ElapsedMilliseconds >= milliseconds, "Timed native input fixture must complete.");
        }
        private static void SelectReadFilter(DependencyObject view, bool goods, int index)
        {
            if (goods) FindVisual<TreeView>(view, item => true).Items.Cast<TreeViewItem>().ElementAt(index).IsSelected = true;
            else FindVisual<ComboBox>(view, box => Equals(box.ToolTip, "全部状态")).SelectedIndex = index;
        }

        private sealed class SearchReadUiHandler : HttpMessageHandler
        {
            internal int ListReads;
            internal string LastQuery, UserId = "fixture-search-owner";
            internal int CommittedVersion;
            internal Func<Uri, CancellationToken, Task> BeforeList;
            internal static string Parameter(Uri uri, string name)
            {
                foreach (string part in uri.Query.TrimStart('?').Split('&'))
                {
                    int equal = part.IndexOf('=');
                    if (equal > 0 && part.Substring(0, equal) == name) return Uri.UnescapeDataString(part.Substring(equal + 1));
                }
                return "";
            }
            protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken token)
            {
                string path = request.RequestUri.AbsolutePath, body;
                var serializer = new System.Web.Script.Serialization.JavaScriptSerializer();
                if (path.EndsWith("/auth/login") || path.EndsWith("/auth/refresh"))
                    body = "{\"accessToken\":\"access.fixture\",\"refreshToken\":\"refresh.fixture\",\"expiresIn\":900,\"user\":{\"id\":\"" + UserId
                        + "\",\"loginAccount\":\"fixture\",\"superAdmin\":false,\"mustChangePassword\":false,\"permissions\":[\"goods:view\",\"material_category:view\",\"unit:view\"],"
                        + "\"businessDatasetId\":\"00000000-0000-0000-0000-000000000001\",\"businessResetGeneration\":0}}";
                else if (path == "/api/master/material-categories/tree")
                    body = "[{\"id\":\"00000000-0000-4000-8000-000000000001\",\"name\":\"分类甲\",\"code\":\"A\",\"children\":[]},{\"id\":\"00000000-0000-4000-8000-000000000002\",\"name\":\"分类乙\",\"code\":\"B\",\"children\":[]}]";
                else if (path == "/api/master/units/facets")
                    body = "{\"status\":[{\"value\":\"使用\",\"count\":1},{\"value\":\"禁用\",\"count\":1}]}";
                else if (path == "/api/master/goods" || path == "/api/master/units")
                {
                    int snapshotVersion = CommittedVersion;
                    LastQuery = request.RequestUri.Query; Interlocked.Increment(ref ListReads);
                    var hold = BeforeList;
                    if (hold != null) await hold(request.RequestUri, token);
                    token.ThrowIfCancellationRequested();
                    string marker = Parameter(request.RequestUri, "keyword") + "|" + Parameter(request.RequestUri, "categoryId") + "|" + UserId + "|v" + snapshotVersion;
                    var rows = Enumerable.Range(1, path.EndsWith("/goods") ? 20 : 1).Select(index => new Dictionary<string, object> {
                        ["id"] = "00000000-0000-4000-8000-" + index.ToString("D12"), ["code"] = "T" + index, ["name"] = marker, ["status"] = "使用" }).ToArray();
                    body = serializer.Serialize(new { items = rows, page = 1, size = 20, total = rows.Length, totalPages = 1 });
                }
                else return new HttpResponseMessage(HttpStatusCode.NotFound) { Content = new StringContent("{\"code\":\"NOT_FOUND\",\"message\":\"fixture optional metadata unavailable\"}", Encoding.UTF8, "application/json") };
                return new HttpResponseMessage(HttpStatusCode.OK) { Content = new StringContent(body, Encoding.UTF8, "application/json") };
            }
        }

        internal static void RunGoodsCurrency()
        {
            if (Application.Current == null)
            {
                var application = new App(); application.InitializeComponent();
                application.ShutdownMode = ShutdownMode.OnExplicitShutdown;
            }
            GoodsCurrencyUi(new ClientConfiguration(new[] {
                new ServerEndpoint("first", "第一测试服务器", "https://first.company.test/api") }, "first"));
        }
        internal static void Run()
        {
            var application = new App();
            application.InitializeComponent();
            application.ShutdownMode = ShutdownMode.OnExplicitShutdown;
            var configuration = new ClientConfiguration(new[] {
                new ServerEndpoint("first", "第一测试服务器", "https://first.company.test/api"),
                new ServerEndpoint("second", "第二测试服务器", "https://second.company.test/api")
            }, "first");
            using (var session = new SessionCoordinator(configuration, new NoNetworkHandler(), new MemoryStore()))
            using (var publisher = new Uten.Legacy.Desktop.Features.Publish.ClientReleasePublishView(session))
            {
                // Construct the actual native caller with application resources, without
                // loading/authenticating it or dispatching a server request.
                publisher.Measure(new Size(1440, 1000));
                publisher.Arrange(new Rect(0, 0, 1440, 1000));
                var host = publisher.Content as Grid;
                var content = host == null ? null : host.Children.OfType<DockPanel>().SingleOrDefault();
                var header = content == null ? null : content.Children.OfType<Border>().SingleOrDefault();
                if (header == null || DockPanel.GetDock(header) != Dock.Top)
                    throw new InvalidOperationException("Publish workspace must keep its header above one correctly parented target editor.");
            }
            var pendingStore = new MemoryStore();
            pendingStore.EnqueueRevocation(new StoredSession("refresh.fixture", "https://first.company.test/api", "first", "fixture-user"));
            using (var session = new SessionCoordinator(configuration, new NoNetworkHandler(), pendingStore))
            {
                session.RestoreAsync(CancellationToken.None, waitForPendingRevocations: false).GetAwaiter().GetResult();
                if (pendingStore.PendingRevocations().Count != 1 || session.IsAuthenticated)
                    throw new InvalidOperationException("Nonblocking startup must keep queued logout without restoring an identity.");
            }
            using (var session = new SessionCoordinator(configuration, new NoNetworkHandler(), new FailedLogoutStore()))
            {
                var window = new MainWindow(session, configuration, true);
                try
                {
                    var content = (FrameworkElement)window.Content;
                    content.Measure(new Size(800, 540)); content.Arrange(new Rect(0, 0, 800, 540)); content.UpdateLayout();
                    var selector = (ComboBox)window.FindName("EndpointBox");
                    selector.SelectedValue = "second";
                    if (!Equals(selector.SelectedValue, "first") || session.CurrentEndpoint.Id != "first")
                        throw new InvalidOperationException("Failed server switch must restore the displayed origin.");
                    var primary = (Button)window.FindName("LoginButton");
                    if (((SolidColorBrush)primary.Foreground).Color != Colors.White)
                        throw new InvalidOperationException("Brand primary action requires its white foreground.");
                    var input = (TextBox)window.FindName("AccountBox");
                    double expectedInputHeight = (double)application.FindResource("Uten.Height.Input");
                    if (Math.Abs(input.ActualHeight - expectedInputHeight) > 0.5)
                        throw new InvalidOperationException("Normal form input height must follow the shared Uten input role, without doubled padding.");
                    var clipSurface = new RoundedSurface { CornerRadius = (CornerRadius)application.FindResource("Uten.Radius.Table"), Child = new Border { Background = Brushes.Red } };
                    clipSurface.Measure(new Size(100, 100)); clipSurface.Arrange(new Rect(0, 0, 100, 100)); clipSurface.UpdateLayout();
                    if (clipSurface.Clip == null || clipSurface.Clip.FillContains(new Point(0, 0)) || !clipSurface.Clip.FillContains(new Point(50, 50)))
                        throw new InvalidOperationException("Rounded table surfaces must clip their children, not only paint a rounded outline.");
                    if (window.FindName("WorkspacePanel") is FrameworkElement workspace && workspace.Visibility != Visibility.Collapsed)
                        throw new InvalidOperationException("Unauthenticated users must not enter the workspace.");
                }
                finally { window.Close(); }
            }
            var handler = new PermissionChangeHandler();
            using (var session = new SessionCoordinator(configuration, handler, new MemoryStore()))
            {
                var window = new MainWindow(session, configuration, true);
                try
                {
                    session.LoginAsync("fixture", "fixture-password", CancellationToken.None).GetAwaiter().GetResult();
                    Pump(window);
                    var host = (ContentControl)window.FindName("WorkspaceContent");
                    object previous = host.Content;
                    if (previous == null) throw new InvalidOperationException("Authenticated workspace was not opened.");
                    long authGeneration = session.Generation;
                    session.GetAsync("/master/goods", CancellationToken.None).GetAwaiter().GetResult();
                    handler.Proof = "scope-b";
                    try
                    {
                        session.GetAsync("/master/goods", CancellationToken.None).GetAwaiter().GetResult();
                        throw new InvalidOperationException("Changed read proof must reject the triggering reply.");
                    }
                    catch (ApiException error) { if (error.Code != "READ_SCOPE_CHANGED") throw; }
                    Pump(window);
                    if (session.Generation != authGeneration || ReferenceEquals(previous, host.Content))
                        throw new InvalidOperationException("Read scope changes must retire displayed data without replacing authentication.");
                    previous = host.Content;
                    handler.ChangePermissions = true;
                    try { session.GetAsync("/fixture-read", CancellationToken.None).GetAwaiter().GetResult(); }
                    catch (ApiException error) { if (error.Code != "SESSION_CHANGED") throw; }
                    Pump(window);
                    if (ReferenceEquals(previous, host.Content))
                        throw new InvalidOperationException("Same-user permission changes must retire the old dashboard.");
                    if (((Button)window.FindName("GoodsNavButton")).Visibility != Visibility.Collapsed)
                        throw new InvalidOperationException("Revoked goods permission must retire the navigation entry.");
                }
                finally { window.Close(); }
            }
            UnitDraftAndMutationUi(configuration);
            OwnerCloseWaitsForDraft(configuration);
            GoodsCurrencyUi(configuration);
        }

        private static void GoodsCurrencyUi(ClientConfiguration configuration)
        {
            foreach (var permission in new[] { "", "goods:price:view", "goods:price:edit" })
            using (var session = new SessionCoordinator(configuration, new GoodsCurrencyUiHandler(permission), new MemoryStore()))
            {
                session.LoginAsync("fixture", "fixture-password", CancellationToken.None).GetAwaiter().GetResult();
                var view = new GoodsWorkspaceView(session);
                var window = new Window { Content = view, Width = 1400, Height = 850, Opacity = 0, ShowActivated = false, ShowInTaskbar = false };
                try
                {
                    window.Show();
                    var table = FindVisual<DataGrid>(view, item => true);
                    PumpUntil(() => table.Items.Count == 20 && table.IsEnabled, "Goods must load its complete server page through the native caller.");
                    int price = table.Columns.ToList().FindIndex(column => Equals(column.Header, "售价"));
                    int currency = table.Columns.ToList().FindIndex(column => Equals(column.Header, "币种"));
                    if (permission.Length == 0)
                    {
                        if (price >= 0 || currency >= 0) throw new InvalidOperationException("Goods currency must share the price visibility permission.");
                        table.SelectedItem = table.Items[0];
                        PumpUntil(() => FindVisual<TextBlock>(view, item => item.Text == "编码：HP0") != null,
                            "Goods detail must finish loading for a price-hidden account.");
                        if (FindVisual<TextBlock>(view, item => item.Text.StartsWith("币种：", StringComparison.Ordinal)
                            || item.Text.StartsWith("售价：", StringComparison.Ordinal)) != null)
                            throw new InvalidOperationException("Price-hidden goods detail must not leak currency or price.");
                        continue;
                    }
                    if (price < 0 || currency != price + 1) throw new InvalidOperationException("Currency must appear immediately after price for price viewers and editors.");
                    table.SelectedItem = table.Items[0];
                    PumpUntil(() => FindVisual<TextBlock>(view, item => item.Text == "币种：人民币") != null,
                        "Native goods detail must show its saved master currency.");
                    var currencyText = FindVisual<TextBlock>(view, item => item.Text == "币种：人民币");
                    var expected = (SolidColorBrush)Application.Current.FindResource("Uten.Currency.Cny");
                    if (!(currencyText.Foreground is SolidColorBrush shown) || shown.Color != expected.Color)
                        throw new InvalidOperationException("Native goods detail currency must consume the generated Dart-owned color.");
                    // Repeated real selection interrupts prior detail requests. Only the last
                    // row's complete detail may publish, and leaving clears transient intent.
                    for (int iteration = 0; iteration < 60; iteration++) table.SelectedItem = table.Items[iteration % 20];
                    table.SelectedItem = table.Items[1];
                    PumpUntil(() => FindVisual<TextBlock>(view, item => item.Text == "币种：美金") != null,
                        "Rapid native goods selection must publish the final row's currency.");
                    if (permission == "goods:price:view")
                    {
                        window.Content = null; Pump(window);
                        if (table.SelectedItems.Count != 0 || table.CurrentCell.IsValid)
                            throw new InvalidOperationException("Leaving goods must clear both row and current-cell selection.");
                        window.Content = view;
                        PumpUntil(() => table.Items.Count == 20 && table.IsEnabled, "Returning to goods must reload after retiring prior reads.");
                        if (table.SelectedItems.Count != 0) throw new InvalidOperationException("Returning to goods must not restore the old selected row.");
                        LayoutElement(view, 1400, 800); Snapshot(view, "goods-currency-workspace-fixture.png");
                    }
                }
                finally { window.Close(); }
            }
        }

        private sealed class GoodsCurrencyUiHandler : HttpMessageHandler
        {
            private readonly string pricePermission;
            internal GoodsCurrencyUiHandler(string pricePermission) { this.pricePermission = pricePermission; }
            private string Record(int index)
            {
                string name = index % 3 == 0 ? "人民币" : index % 3 == 1 ? "美金" : "港币";
                return "{\"id\":\"00000000-0000-0000-0000-" + (index + 1).ToString("D12") + "\",\"code\":\"HP" + index
                    + "\",\"name\":\"币种读取样例 " + index + "\",\"price\":12.3400,\"currencyCode\":\"00" + (index % 3 + 1)
                    + "\",\"currencyName\":\"" + name + "\",\"unitName\":\"个\"}";
            }
            protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken)
            {
                string path = request.RequestUri.AbsolutePath, body;
                if (path.EndsWith("/auth/login") || path.EndsWith("/auth/refresh"))
                    body = "{\"accessToken\":\"access.fixture\",\"refreshToken\":\"refresh.fixture\",\"expiresIn\":900,\"user\":{\"id\":\"fixture-goods-user\","
                        + "\"loginAccount\":\"fixture\",\"superAdmin\":false,\"mustChangePassword\":false,\"permissions\":[\"goods:view\""
                        + (pricePermission.Length == 0 ? "" : ",\"" + pricePermission + "\"") + "],\"businessResetGeneration\":0,"
                        + "\"businessDatasetId\":\"00000000-0000-0000-0000-000000000001\"}}";
                else if (path == "/api/master/goods") body = "{\"items\":[" + string.Join(",", Enumerable.Range(0, 20).Select(Record))
                    + "],\"page\":1,\"size\":20,\"total\":9704,\"totalPages\":486}";
                else if (path.StartsWith("/api/master/goods/", StringComparison.Ordinal))
                    body = Record(int.Parse(path.Substring(path.Length - 12), System.Globalization.CultureInfo.InvariantCulture) - 1);
                else throw new InvalidOperationException("Unexpected private goods currency UI fixture request.");
                return Task.FromResult(new HttpResponseMessage(HttpStatusCode.OK) { Content = new StringContent(body, Encoding.UTF8, "application/json") });
            }
        }

        private static void OwnerCloseWaitsForDraft(ClientConfiguration configuration)
        {
            using (var state = new BusinessStateTestFixture())
            {
                var blocked = new BlockingDraftStore(state.Store);
                var handler = new UnitUiHandler();
                using (var session = new SessionCoordinator(configuration, handler, new MemoryStore(), blocked))
                {
                    session.LoginAsync("fixture", "fixture-password", CancellationToken.None).GetAwaiter().GetResult();
                    var oldOwner = session.CaptureMutationOwner();
                    var main = new MainWindow(session, configuration, true) { Opacity = 0, ShowActivated = false, ShowInTaskbar = false };
                    UnitEditorWindow editor = null;
                    UtenDialogWindow intermediate = null;
                    bool mainClosed = false, editorClosed = false, intermediateClosed = false;
                    main.Closed += (sender, args) => mainClosed = true;
                    try
                    {
                        // A real HWND owner is needed: owner-driven close ignores a child's
                        // Closing cancellation. Opacity=0/ShowActivated=false avoids visible UI.
                        main.Show();
                        intermediate = new UtenDialogWindow(main, "Fixture intermediate owner") { Opacity = 0, ShowActivated = false, ShowInTaskbar = false };
                        intermediate.Closed += (sender, args) => intermediateClosed = true; intermediate.Show();
                        editor = new UnitEditorWindow(intermediate, session, new UnitService(session), null, MutationAction.UnitCreate);
                        editor.Closed += (sender, args) => editorClosed = true;
                        Layout(editor);
                        var input = FindVisual<TextBox>((DependencyObject)editor.Content, item =>
                            System.Windows.Automation.AutomationProperties.GetName(item) == "单位名称");
                        input.Text = "父窗口阻塞输入";
                        editor.Close();
                        PumpUntil(() => blocked.SaveEntered.IsSet, "The private blocking store must reach the close-preservation checkpoint.");
                        if (input.IsEnabled) throw new InvalidOperationException("Closing preservation must freeze input while disk I/O is pending.");
                        intermediate.Close();
                        if (intermediateClosed) throw new InvalidOperationException("An intermediate owned dialog must not bypass a preserving descendant.");
                        main.Close();
                        if (mainClosed) throw new InvalidOperationException("The real owner must not close while its editor is preserving a draft.");
                        handler.UserId = "fixture-new-owner";
                        session.LoginAsync("fixture-new", "fixture-password", CancellationToken.None).GetAwaiter().GetResult();
                        Pump(main);
                        main.Close();
                        if (mainClosed) throw new InvalidOperationException("Replacing a workspace must not lose a retired editor's global exit guard.");
                        blocked.ContinueSave.Set();
                        PumpUntil(() => editorClosed, "The original owner's draft must finish before releasing the global exit guard.");
                        PumpUntil(() => intermediateClosed, "The intermediate owner may close only after descendant preservation completes.");
                        if (!state.Store.ListDrafts(oldOwner).Any(draft => draft.BodyJson.Contains("父窗口阻塞输入")))
                            throw new InvalidOperationException("The original namespace must retain the last editable input before owner retirement.");
                        main.Close();
                        if (!mainClosed) throw new InvalidOperationException("Completed preservation must release the main-window guard.");
                    }
                    finally
                    {
                        blocked.ContinueSave.Set();
                        if (editor != null && !editorClosed) { editor.RetireOwner(); PumpUntil(() => editorClosed, "Fixture editor cleanup must preserve its private draft."); }
                        if (intermediate != null && !intermediateClosed) intermediate.Close();
                        if (!mainClosed) main.Close();
                    }
                }
            }
        }
        private sealed class BlockingDraftStore : IBusinessStateStore
        {
            private readonly IBusinessStateStore inner;
            internal readonly ManualResetEventSlim SaveEntered = new ManualResetEventSlim(false);
            internal readonly ManualResetEventSlim ContinueSave = new ManualResetEventSlim(false);
            internal BlockingDraftStore(IBusinessStateStore inner) { this.inner = inner; }
            public BusinessDraft SaveDraft(DraftWriteLease lease, long revision, string body)
            {
                SaveEntered.Set();
                if (!ContinueSave.Wait(TimeSpan.FromSeconds(12))) throw new TimeoutException("Private blocking fixture timed out.");
                return inner.SaveDraft(lease, revision, body);
            }
            public IReadOnlyList<BusinessDraft> ListDrafts(MutationOwnerSnapshot owner) { return inner.ListDrafts(owner); }
            public BusinessDraft LoadDraft(MutationOwnerSnapshot owner, string id) { return inner.LoadDraft(owner, id); }
            public void DeleteDraft(MutationOwnerSnapshot owner, string id, long revision) { inner.DeleteDraft(owner, id, revision); }
            public void BeginSending(MutationRequest request) { inner.BeginSending(request); }
            public void Complete(MutationResult result) { inner.Complete(result); }
            public IReadOnlyList<MutationJournalRecord> ListJournal(MutationOwnerSnapshot owner) { return inner.ListJournal(owner); }
            public MutationJournalRecord LoadJournal(MutationOwnerSnapshot owner, string id) { return inner.LoadJournal(owner, id); }
            public MutationJournalRecord AppendReviewNote(MutationOwnerSnapshot owner, string id, string note) { return inner.AppendReviewNote(owner, id, note); }
            public void Dispose() { ContinueSave.Set(); inner.Dispose(); }
        }

        private static void UnitDraftAndMutationUi(ClientConfiguration configuration)
        {
            using (var state = new BusinessStateTestFixture())
            {
                var handler = new UnitUiHandler();
                using (var session = new SessionCoordinator(configuration, handler, new MemoryStore(), state.Store))
                {
                    session.LoginAsync("fixture", "fixture-password", CancellationToken.None).GetAwaiter().GetResult();
                    var service = new UnitService(session);
                    var owner = session.CaptureMutationOwner();
                    var editor = new UnitEditorWindow(null, session, service, null, MutationAction.UnitCreate);
                    Layout(editor);
                    if (editor.FontSize != (double)Application.Current.FindResource("Uten.FontSize.Body"))
                        throw new InvalidOperationException("Derived native dialogs must explicitly inherit the owning Window typography style.");
                    var name = FindVisual<TextBox>((DependencyObject)editor.Content, item =>
                        System.Windows.Automation.AutomationProperties.GetName(item) == "单位名称");
                    if (name == null) throw new InvalidOperationException("Unit form must expose its real labelled native name input.");
                    name.Text = "草稿单位";
                    Layout(editor);
                    Snapshot((FrameworkElement)editor.Content, "unit-editor-fixture.png");
                    bool closed = false; editor.Closed += (sender, args) => closed = true;
                    editor.Close();
                    PumpUntil(() => closed, "Closing a dirty unit form must wait for durable preservation without reentrant Close.");
                    var saved = session.ListDraftsAsync(owner, CancellationToken.None).GetAwaiter().GetResult();
                    if (saved.Count != 1 || !saved[0].BodyJson.Contains("草稿单位") || handler.BusinessWrites != 0)
                        throw new InvalidOperationException("Closing a unit draft must preserve input without sending business HTTP.");

                    var retiredEditor = new UnitEditorWindow(null, session, service, null, MutationAction.UnitCreate, saved[0]);
                    Layout(retiredEditor);
                    FindVisual<TextBox>((DependencyObject)retiredEditor.Content, item =>
                        System.Windows.Automation.AutomationProperties.GetName(item) == "单位名称").Text = "退役前输入";
                    bool retiredClosed = false; retiredEditor.Closed += (sender, args) => retiredClosed = true;
                    handler.UserId = "fixture-other-user";
                    session.LoginAsync("fixture-other", "fixture-password", CancellationToken.None).GetAwaiter().GetResult();
                    PumpUntil(() => retiredClosed, "Retired form must preserve only its original owner's draft and close.");
                    var oldDrafts = state.Store.ListDrafts(owner);
                    var newOwner = session.CaptureMutationOwner();
                    if (oldDrafts.Count != 1 || !oldDrafts[0].BodyJson.Contains("退役前输入")
                        || session.ListDraftsAsync(newOwner, CancellationToken.None).GetAwaiter().GetResult().Count != 0)
                        throw new InvalidOperationException("Retired input must stay in its original namespace and cannot enter a new account.");

                    var submitted = new UnitEditorWindow(null, session, service, null, MutationAction.UnitCreate);
                    Layout(submitted);
                    FindVisual<TextBox>((DependencyObject)submitted.Content, item =>
                        System.Windows.Automation.AutomationProperties.GetName(item) == "单位名称").Text = "确认保存单位";
                    var button = FindVisual<Button>((DependencyObject)submitted.Content, item => Equals(item.Content, "新增"));
                    if (button == null || !button.IsEnabled) throw new InvalidOperationException("An authorized valid unit form must enable its real save action.");
                    bool submitClosed = false; submitted.Closed += (sender, args) => submitClosed = true;
                    // Enter the real dispatcher input path so async UI continuations capture
                    // WPF's synchronization context, as they do under Application.Run.
                    Dispatcher.CurrentDispatcher.BeginInvoke(new Action(() => button.RaiseEvent(new RoutedEventArgs(Button.ClickEvent))));
                    try { PumpUntil(() => submitClosed, "Confirmed native save must close after durable submission accounting."); }
                    catch (InvalidOperationException)
                    {
                        var message = FindVisual<TextBlock>((DependencyObject)submitted.Content, item =>
                            System.Windows.Automation.AutomationProperties.GetName(item) == "操作结果");
                        string states = String.Join(",", state.Store.ListJournal(newOwner).Select(item => item.State + "/" + item.ErrorCode));
                        throw new InvalidOperationException("Native UI fixture submission incomplete; business writes=" + handler.BusinessWrites
                            + "; journal=" + states + "; status=" + (message?.Text ?? "(no fixture status)"));
                    }
                    var journal = session.ListMutationJournalAsync(newOwner, CancellationToken.None).GetAwaiter().GetResult();
                    if (!submitted.BusinessChanged || handler.BusinessWrites != 1 || journal.Count != 1
                        || journal[0].State != MutationJournalState.Confirmed
                        || session.ListDraftsAsync(newOwner, CancellationToken.None).GetAwaiter().GetResult().Count != 0)
                        throw new InvalidOperationException("Real native save must account for one confirmed mutation and clean only its own draft.");
                    var statusRequest = service.PrepareStatus(Guid.NewGuid().ToString("D"),
                        "ffda6731-4bce-4fa1-a5a5-2acf55fd6d01", "禁用", newOwner);
                    service.SendAsync(statusRequest, CancellationToken.None).GetAwaiter().GetResult();
                    var pending = session.LoadMutationJournalAsync(statusRequest.RequestId, newOwner, CancellationToken.None).GetAwaiter().GetResult();
                    var inspectorType = typeof(UnitRecoveryWindow).GetNestedType("UtenRecordWindow", System.Reflection.BindingFlags.NonPublic);
                    var inspector = (Window)inspectorType.GetConstructor(System.Reflection.BindingFlags.NonPublic | System.Reflection.BindingFlags.Instance,
                        null, new[] { typeof(Window), typeof(MutationJournalRecord) }, null)
                        .Invoke(new object[] { null, pending });
                    try
                    {
                        Layout(inspector);
                        if (pending.State != MutationJournalState.Unknown || FindVisual<TextBox>((DependencyObject)inspector.Content,
                            item => item.IsReadOnly && item.Text.Contains(statusRequest.ResourceId)) == null)
                            throw new InvalidOperationException("A status-only unknown submission must show its exact target UUID for manual reconciliation.");
                    }
                    finally { inspector.Close(); }

                    var noteLease = session.CreateMutationReviewLeaseAsync(pending.RequestId, newOwner, CancellationToken.None).GetAwaiter().GetResult();
                    var noteWindow = new UnitReviewNoteWindow(null, session, noteLease, newOwner);
                    Layout(noteWindow);
                    var noteInput = FindVisual<TextBox>((DependencyObject)noteWindow.Content, item =>
                        System.Windows.Automation.AutomationProperties.GetName(item) == "核对说明");
                    noteInput.Text = "已核对原UUID和操作时间，原提交仍保留未知事实。";
                    bool noteClosed = false; noteWindow.Closed += (sender, args) => noteClosed = true; noteWindow.Close();
                    PumpUntil(() => noteClosed, "Local review note must be preserved before its window closes.");
                    var reviewed = session.LoadMutationJournalAsync(pending.RequestId, newOwner, CancellationToken.None).GetAwaiter().GetResult();
                    if (!noteWindow.NoteRecorded || reviewed.State != MutationJournalState.Unknown || !reviewed.ReviewNote.Contains("已核对原UUID"))
                        throw new InvalidOperationException("A local annotation must preserve text without claiming success or replaying the unknown operation.");

                    var view = new UnitsWorkspaceView(session);
                    try
                    {
                        Dispatcher.CurrentDispatcher.BeginInvoke(new Action(() => view.RaiseEvent(new RoutedEventArgs(FrameworkElement.LoadedEvent))));
                        var table = FindVisual<DataGrid>(view, item => true);
                        LayoutElement(view, 1100, 640);
                        table = FindVisual<DataGrid>(view, item => true);
                        PumpUntil(() => table?.Items.Count == 1, "Native unit table must consume the actual scoped service response.");
                        LayoutElement(view, 1100, 640); Snapshot(view, "units-workspace-fixture.png");
                        if (table.CanUserSortColumns || table.AutoGenerateColumns || !table.IsReadOnly || table.Columns.Count != 3)
                            throw new InvalidOperationException("Unit daily table must keep its three owning columns and server ordering.");
                        if (!(table.ItemContainerGenerator.ContainerFromIndex(0) is DataGridRow row) || row.ActualHeight < 30)
                            throw new InvalidOperationException("Native body cells must actually apply owning 12x8 padding, not collapse to a bare text line.");
                        table.SelectedItem = table.Items[0];
                        var closeDetail = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(10) };
                        bool sawDetail = false, detailClearedSelection = false;
                        Console.WriteLine("CHECK native unit detail selection");
                        closeDetail.Tick += (sender, args) =>
                        {
                            var detailWindow = Application.Current.Windows.OfType<UnitDetailWindow>().FirstOrDefault();
                            if (detailWindow == null) return;
                            sawDetail = true;
                            detailClearedSelection = table.SelectedItems.Count == 0;
                            detailWindow.Close();
                        };
                        closeDetail.Start();
                        try
                        {
                            var open = (Task)typeof(UnitsWorkspaceView).GetMethod("OpenDetailAsync", System.Reflection.BindingFlags.Instance | System.Reflection.BindingFlags.NonPublic).Invoke(view, null);
                            PumpUntil(() => open.IsCompleted, "Unit detail must open and return through its actual native caller.");
                            open.GetAwaiter().GetResult();
                        }
                        finally { closeDetail.Stop(); }
                        if (!sawDetail || !detailClearedSelection || table.SelectedItems.Count != 0)
                            throw new InvalidOperationException("Returning from unit detail must leave no remembered row selection.");
                        Console.WriteLine("PASS native unit detail selection");
                        var queryInput = FindVisual<TextBox>(view, item => System.Windows.Automation.AutomationProperties.GetName(item) == "按单位编号或名称搜索");
                        queryInput.Text = "续期保留筛选";
                        handler.RefreshOnce = true;
                        session.GetAsync("/fixture-refresh", CancellationToken.None).GetAwaiter().GetResult();
                        Dispatcher.CurrentDispatcher.Invoke(DispatcherPriority.ContextIdle, new Action(() => { }));
                        if (queryInput.Text != "续期保留筛选") throw new InvalidOperationException("Ordinary token refresh must preserve the current unit query.");
                        var codeFilter = FindVisual<ComboBox>(view, item => Equals(item.ToolTip, "全部编号"));
                        // Table and facet reads are intentionally independent.
                        // Dispatcher idle does not mean their background I/O finished.
                        PumpUntil(() => codeFilter.Items.Count >= 3, "The fixture must first finish loading a real code facet.");
                        if (codeFilter.Items.Count < 3) throw new InvalidOperationException("The fixture must first load a real code facet.");
                        handler.Proof = "scope-b"; handler.FailFacets = true;
                        try { session.GetAsync("/master/units?page=1&size=20", CancellationToken.None).GetAwaiter().GetResult(); }
                        catch (ApiException error) { if (error.Code != "READ_SCOPE_CHANGED") throw; }
                        PumpUntil(() => queryInput.Text.Length == 0 && codeFilter.Items.Count == 2,
                            "Retiring a scope must clear old code/name facet values even when the replacement facet request fails.");
                    }
                    finally { view.Dispose(); }
                }
            }
        }
        private static void Layout(Window window)
        {
            var element = (FrameworkElement)window.Content;
            element.Measure(new Size(560, 760));
            element.Arrange(new Rect(0, 0, 560, element.DesiredSize.Height)); element.UpdateLayout();
        }
        private static void LayoutElement(FrameworkElement element, double width, double height)
        { element.Measure(new Size(width, height)); element.Arrange(new Rect(0, 0, width, height)); element.UpdateLayout(); }
        private static T FindVisual<T>(DependencyObject root, Func<T, bool> match) where T : DependencyObject
        {
            if (root is T found && match(found)) return found;
            for (int index = 0; index < VisualTreeHelper.GetChildrenCount(root); index++)
            {
                var result = FindVisual(VisualTreeHelper.GetChild(root, index), match);
                if (result != null) return result;
            }
            return null;
        }
        private static void Snapshot(FrameworkElement content, string fileName)
        {
            var bitmap = new RenderTargetBitmap((int)Math.Ceiling(content.ActualWidth), (int)Math.Ceiling(content.ActualHeight), 96, 96, PixelFormats.Pbgra32);
            bitmap.Render(content); var encoder = new PngBitmapEncoder(); encoder.Frames.Add(BitmapFrame.Create(bitmap));
            using (var output = File.Create(Path.Combine(AppDomain.CurrentDomain.BaseDirectory, fileName))) encoder.Save(output);
        }
        private static void PumpUntil(Func<bool> complete, string failure)
        {
            var timer = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(10) };
            var deadline = System.Diagnostics.Stopwatch.StartNew(); var frame = new DispatcherFrame();
            timer.Tick += (sender, args) => { if (complete() || deadline.Elapsed > TimeSpan.FromSeconds(8)) frame.Continue = false; };
            timer.Start();
            try { Dispatcher.PushFrame(frame); } finally { timer.Stop(); }
            if (!complete()) throw new InvalidOperationException(failure);
        }
        private sealed class UnitUiHandler : HttpMessageHandler
        {
            internal string UserId = "fixture-unit-user";
            internal int BusinessWrites;
            internal bool RefreshOnce, FailFacets;
            internal string Proof = "scope-a";
            protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken)
            {
                string path = request.RequestUri.AbsolutePath;
                string body;
                if (path.EndsWith("/auth/login") || path.EndsWith("/auth/refresh"))
                    body = "{\"accessToken\":\"access.fixture\",\"refreshToken\":\"refresh.fixture\",\"expiresIn\":900,\"user\":{\"id\":\"" + UserId
                        + "\",\"loginAccount\":\"fixture\",\"superAdmin\":false,\"mustChangePassword\":false,\"permissions\":[\"unit:view\",\"unit:create\",\"unit:edit\",\"unit:status\"],"
                        + "\"businessDatasetId\":\"00000000-0000-0000-0000-000000000001\",\"businessResetGeneration\":0}}";
                else if (path.EndsWith("/auth/logout")) body = "{}";
                else if (path == "/api/fixture-refresh" && RefreshOnce)
                {
                    RefreshOnce = false;
                    return new HttpResponseMessage(HttpStatusCode.Unauthorized)
                    { Content = new StringContent("{\"code\":\"UNAUTHORIZED\",\"message\":\"fixture expiry\"}", Encoding.UTF8, "application/json") };
                }
                else if (path == "/api/fixture-refresh") body = "{}";
                else if (request.Method.Method == "PATCH" && path.EndsWith("/status"))
                {
                    BusinessWrites++;
                    return new HttpResponseMessage(HttpStatusCode.ServiceUnavailable)
                    { Content = new StringContent("{\"code\":\"SERVICE_UNAVAILABLE\",\"message\":\"fixture post-dispatch failure\"}", Encoding.UTF8, "application/json") };
                }
                else if (path == "/api/master/units" && request.Method == HttpMethod.Post)
                {
                    BusinessWrites++;
                    var values = new System.Web.Script.Serialization.JavaScriptSerializer().Deserialize<Dictionary<string, object>>(await request.Content.ReadAsStringAsync());
                    body = new System.Web.Script.Serialization.JavaScriptSerializer().Serialize(new Dictionary<string, object> {
                        ["id"] = "ffda6731-4bce-4fa1-a5a5-2acf55fd6d01", ["code"] = "U001", ["name"] = values["name"], ["status"] = values["status"] });
                }
                else if (path == "/api/master/units" && request.Method == HttpMethod.Get)
                    body = "{\"items\":[{\"id\":\"ffda6731-4bce-4fa1-a5a5-2acf55fd6d01\",\"code\":\"U001\",\"name\":\"确认保存单位\",\"status\":\"使用\"}],\"page\":1,\"size\":20,\"total\":1,\"totalPages\":1,\"readScopeVersion\":\"" + Proof + "\"}";
                else if (path == "/api/master/units/ffda6731-4bce-4fa1-a5a5-2acf55fd6d01" && request.Method == HttpMethod.Get)
                    body = "{\"id\":\"ffda6731-4bce-4fa1-a5a5-2acf55fd6d01\",\"code\":\"U001\",\"name\":\"确认保存单位\",\"status\":\"使用\"}";
                else if (path == "/api/master/units/facets" && FailFacets)
                    return new HttpResponseMessage(HttpStatusCode.ServiceUnavailable)
                    { Content = new StringContent("{\"code\":\"SERVICE_UNAVAILABLE\",\"message\":\"fixture facets offline\"}", Encoding.UTF8, "application/json") };
                else if (path == "/api/master/units/facets") body = "{\"code\":[{\"value\":\"U001\",\"count\":1}]}";
                else if (path == "/api/dashboard/overview") body = "{\"metrics\":[],\"todos\":[]}";
                else throw new InvalidOperationException("Unexpected private native UI fixture request.");
                var response = new HttpResponseMessage(HttpStatusCode.OK) { Content = new StringContent(body, Encoding.UTF8, "application/json") };
                if (path == "/api/master/units" && request.Method == HttpMethod.Get) response.Headers.TryAddWithoutValidation("X-Uten-Read-Scope-Version", Proof);
                return response;
            }
        }

        private static void Pump(Window window) { window.Dispatcher.Invoke(DispatcherPriority.ContextIdle, new Action(() => { })); }

        private sealed class NoNetworkHandler : HttpMessageHandler
        {
            protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken)
            { throw new InvalidOperationException("An offline UI contract test must make no network request."); }
        }
        private sealed class FailedLogoutStore : ISessionStore
        {
            public StoredSession Load() { return null; }
            public void Save(StoredSession value) { throw new IOException("fixture persistence unavailable"); }
            public void Clear() { throw new IOException("fixture persistence unavailable"); }
            public void EndSession(StoredSession value) { throw new IOException("fixture persistence unavailable"); }
            public void EnqueueRevocation(StoredSession value) { throw new IOException("fixture persistence unavailable"); }
            public IList<StoredSession> PendingRevocations() { return new List<StoredSession>(); }
            public void AcknowledgeRevocation(string id) { }
        }
        private sealed class MemoryStore : ISessionStore
        {
            private StoredSession active;
            private readonly List<StoredSession> pending = new List<StoredSession>();
            public StoredSession Load() { return active; }
            public void Save(StoredSession value) { active = value; }
            public void Clear() { active = null; }
            public void EndSession(StoredSession value) { if ((value ?? active) != null) pending.Add(value ?? active); active = null; }
            public void EnqueueRevocation(StoredSession value) { pending.Add(value); }
            public IList<StoredSession> PendingRevocations() { return new List<StoredSession>(pending); }
            public void AcknowledgeRevocation(string id) { pending.RemoveAll(item => item.Id == id); }
        }
        private sealed class PermissionChangeHandler : HttpMessageHandler
        {
            internal bool ChangePermissions;
            internal string Proof = "scope-a";
            protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken)
            {
                string path = request.RequestUri.AbsolutePath;
                if (path == "/api/master/goods")
                {
                    var proofResponse = new HttpResponseMessage(HttpStatusCode.OK) { Content = new StringContent("{\"items\":[],\"readScopeVersion\":\"" + Proof + "\"}", Encoding.UTF8, "application/json") };
                    proofResponse.Headers.TryAddWithoutValidation("X-Uten-Read-Scope-Version", Proof);
                    return Task.FromResult(proofResponse);
                }
                bool rejectedRead = path == "/api/fixture-read" && ChangePermissions;
                string permissions = ChangePermissions ? "[]" : "[\"goods:view\"]";
                string body = rejectedRead ? "{\"code\":\"UNAUTHORIZED\",\"message\":\"fixture refresh\"}"
                    : "{\"accessToken\":\"access.fixture\",\"refreshToken\":\"refresh.fixture\",\"expiresIn\":900,\"mustChangePassword\":false,"
                    + "\"user\":{\"id\":\"fixture-user\",\"loginAccount\":\"fixture\",\"name\":\"fixture\",\"superAdmin\":false,"
                    + "\"mustChangePassword\":false,\"permissions\":" + permissions + ",\"businessResetGeneration\":0,"
                    + "\"businessDatasetId\":\"00000000-0000-0000-0000-000000000001\"}}";
                return Task.FromResult(new HttpResponseMessage(rejectedRead ? HttpStatusCode.Unauthorized : HttpStatusCode.OK)
                    { Content = new StringContent(body, Encoding.UTF8, "application/json") });
            }
        }
    }
}
