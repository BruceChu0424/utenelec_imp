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
using Uten.Legacy.Core.Tests;

namespace Uten.Legacy.Tests
{
    internal static class UiContractChecks
    {
        internal static void Run()
        {
            var application = new App();
            application.InitializeComponent();
            application.ShutdownMode = ShutdownMode.OnExplicitShutdown;
            var configuration = new ClientConfiguration(new[] {
                new ServerEndpoint("first", "第一测试服务器", "https://first.company.test/api"),
                new ServerEndpoint("second", "第二测试服务器", "https://second.company.test/api")
            }, "first");
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
                    session.LoginAsync("fixture", "fixture-password", null, CancellationToken.None).GetAwaiter().GetResult();
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
        }

        private static void OwnerCloseWaitsForDraft(ClientConfiguration configuration)
        {
            using (var state = new BusinessStateTestFixture())
            {
                var blocked = new BlockingDraftStore(state.Store);
                var handler = new UnitUiHandler();
                using (var session = new SessionCoordinator(configuration, handler, new MemoryStore(), blocked))
                {
                    session.LoginAsync("fixture", "fixture-password", null, CancellationToken.None).GetAwaiter().GetResult();
                    var oldOwner = session.CaptureMutationOwner();
                    var main = new MainWindow(session, configuration, true) { Opacity = 0, ShowActivated = false, ShowInTaskbar = false };
                    UnitEditorWindow editor = null;
                    bool mainClosed = false, editorClosed = false;
                    main.Closed += (sender, args) => mainClosed = true;
                    try
                    {
                        // A real HWND owner is needed: owner-driven close ignores a child's
                        // Closing cancellation. Opacity=0/ShowActivated=false avoids visible UI.
                        main.Show();
                        editor = new UnitEditorWindow(main, session, new UnitService(session), null, MutationAction.UnitCreate);
                        editor.Closed += (sender, args) => editorClosed = true;
                        Layout(editor);
                        var input = FindVisual<TextBox>((DependencyObject)editor.Content, item =>
                            System.Windows.Automation.AutomationProperties.GetName(item) == "单位名称");
                        input.Text = "父窗口阻塞输入";
                        editor.Close();
                        PumpUntil(() => blocked.SaveEntered.IsSet, "The private blocking store must reach the close-preservation checkpoint.");
                        if (input.IsEnabled) throw new InvalidOperationException("Closing preservation must freeze input while disk I/O is pending.");
                        main.Close();
                        if (mainClosed) throw new InvalidOperationException("The real owner must not close while its editor is preserving a draft.");
                        handler.UserId = "fixture-new-owner";
                        session.LoginAsync("fixture-new", "fixture-password", null, CancellationToken.None).GetAwaiter().GetResult();
                        Pump(main);
                        main.Close();
                        if (mainClosed) throw new InvalidOperationException("Replacing a workspace must not lose a retired editor's global exit guard.");
                        blocked.ContinueSave.Set();
                        PumpUntil(() => editorClosed, "The original owner's draft must finish before releasing the global exit guard.");
                        if (!state.Store.ListDrafts(oldOwner).Any(draft => draft.BodyJson.Contains("父窗口阻塞输入")))
                            throw new InvalidOperationException("The original namespace must retain the last editable input before owner retirement.");
                        main.Close();
                        if (!mainClosed) throw new InvalidOperationException("Completed preservation must release the main-window guard.");
                    }
                    finally
                    {
                        blocked.ContinueSave.Set();
                        if (editor != null && !editorClosed) { editor.RetireOwner(); PumpUntil(() => editorClosed, "Fixture editor cleanup must preserve its private draft."); }
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
                    session.LoginAsync("fixture", "fixture-password", null, CancellationToken.None).GetAwaiter().GetResult();
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
                    session.LoginAsync("fixture-other", "fixture-password", null, CancellationToken.None).GetAwaiter().GetResult();
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
                    var inspector = (Window)inspectorType.GetConstructors(System.Reflection.BindingFlags.NonPublic | System.Reflection.BindingFlags.Instance)[0]
                        .Invoke(new object[] { null, pending });
                    try
                    {
                        Layout(inspector);
                        if (pending.State != MutationJournalState.Unknown || FindVisual<TextBox>((DependencyObject)inspector.Content,
                            item => item.IsReadOnly && item.Text.Contains(statusRequest.ResourceId)) == null)
                            throw new InvalidOperationException("A status-only unknown submission must show its exact target UUID for manual reconciliation.");
                    }
                    finally { inspector.Close(); }

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
                        var queryInput = FindVisual<TextBox>(view, item => System.Windows.Automation.AutomationProperties.GetName(item) == "按单位编号或名称搜索");
                        queryInput.Text = "续期保留筛选";
                        handler.RefreshOnce = true;
                        session.GetAsync("/fixture-refresh", CancellationToken.None).GetAwaiter().GetResult();
                        Dispatcher.CurrentDispatcher.Invoke(DispatcherPriority.ContextIdle, new Action(() => { }));
                        if (queryInput.Text != "续期保留筛选") throw new InvalidOperationException("Ordinary token refresh must preserve the current unit query.");
                        var codeFilter = FindVisual<ComboBox>(view, item => Equals(item.ToolTip, "全部编号"));
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
