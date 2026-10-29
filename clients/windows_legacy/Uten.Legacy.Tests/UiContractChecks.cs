using System;
using System.Collections.Generic;
using System.IO;
using System.Net.Http;
using System.Net;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Threading;
using Uten.Legacy.Core;
using Uten.Legacy.Desktop;
using Uten.Legacy.Desktop.Controls;

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
