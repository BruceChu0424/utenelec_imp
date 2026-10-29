using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Net;
using System.Net.Http;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using System.Web.Script.Serialization;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Threading;
using Uten.Legacy.Core;
using Uten.Legacy.Core.Tests;
using Uten.Legacy.Desktop.Features.Columns;
using Uten.Legacy.Desktop.Shared;

namespace Uten.Legacy.Desktop.Features.Units
{
    public static class UnitExportUiChecks
    {
        public static int Run()
        {
            var before = SynchronizationContext.Current;
            SynchronizationContext.SetSynchronizationContext(new DispatcherSynchronizationContext(Dispatcher.CurrentDispatcher));
            try
            {
                if (Application.Current == null) { var app = new App(); app.InitializeComponent(); app.ShutdownMode = ShutdownMode.OnExplicitShutdown; }
                int count = 0; Action<bool, string> check = (value, label) => { if (!value) throw new InvalidOperationException("Unit export UI: " + label); count++; };
                FrozenFilterAndDownload(check); LostReplyReconcilesWithoutAnotherPost(check); LegacyIsOnlyCapabilityFallback(check);
                CancelledSaveChoosesNoDownload(check); ForbiddenRetiresVisibleData(check);
                return count;
            }
            finally { SynchronizationContext.SetSynchronizationContext(before); }
        }
        private static void FrozenFilterAndDownload(Action<bool, string> check)
        {
            using (var fixture = new Fixture())
            {
                var query = new UnitQuery(keyword: " M&1 ", filters: new Dictionary<string, UnitFilter> { ["name"] = UnitFilter.Null });
                var window = fixture.Open(query); var create = Button(window, "生成当前筛选");
                Pump(() => create.IsEnabled); Click(create);
                Pump(() => fixture.Creates == 1 && Button(window, "下载Excel").IsEnabled);
                var filter = Parse((string)((Dictionary<string, object>)Parse(fixture.OriginalBody)["parameters"])["filter"]);
                check((string)filter["keyword"] == "M&1" && ((object[])filter["nullFields"])[0].Equals("name"), "actual master adapter uses one raw filter JSON parameter");
                check(!fixture.OriginalBody.Contains("password"), "job body contains no password");
                var password = Visual<PasswordBox>((DependencyObject)window.Content, value => true); password.Password = "fixture-download-secret";
                Click(Button(window, "下载Excel")); Pump(() => File.Exists(fixture.Output) && Button(window, "下载Excel").IsEnabled);
                check(File.ReadAllBytes(fixture.Output).SequenceEqual(fixture.Workbook), "full file reached chosen destination");
                check(fixture.Downloads == 1 && fixture.Authorizations == 1 && fixture.Picker.Calls == 1, "download is freshly authorized before native save selection");
                check(password.Password.Length == 0 && fixture.DownloadBody.Contains("fixture-download-secret"), "password transmitted only for download then cleared");
                var owner = fixture.Session.CaptureMutationOwner();
                check(fixture.State.Store.ListJournal(owner).All(record => !record.BodyJson.Contains("fixture-download-secret")), "password absent from durable job journal");
                window.Close();
            }
        }
        private static void LostReplyReconcilesWithoutAnotherPost(Action<bool, string> check)
        {
            using (var fixture = new Fixture())
            {
                fixture.LoseSubmitReply = true;
                var window = fixture.Open(new UnitQuery()); Pump(() => Button(window, "生成当前筛选").IsEnabled);
                Click(Button(window, "生成当前筛选")); Pump(() => Button(window, "核对原任务").IsEnabled);
                check(!Button(window, "下载Excel").IsEnabled && fixture.Creates == 1, "unknown create cannot masquerade as a ready download");
                Click(Button(window, "核对原任务")); Pump(() => Button(window, "下载Excel").IsEnabled);
                var journal = fixture.State.Store.ListJournal(fixture.Session.CaptureMutationOwner());
                check(fixture.Creates == 1 && journal.Single(record => record.Action == MutationAction.UnitExportSubmit).State == MutationJournalState.Confirmed,
                    "GET matching persisted request proves exactly the original submit without another POST");
                window.Close();
            }
            using (var fixture = new Fixture())
            {
                fixture.LoseSubmitReply = true; fixture.IncludeProof = false;
                var window = fixture.Open(new UnitQuery()); Pump(() => Button(window, "生成当前筛选").IsEnabled);
                Click(Button(window, "生成当前筛选")); Pump(() => Button(window, "核对原任务").IsEnabled);
                Click(Button(window, "核对原任务")); Pump(() => Button(window, "按原任务再次确认").IsEnabled);
                check(!Button(window, "下载Excel").IsEnabled && fixture.Creates == 1, "old server status alone leaves Unknown");
                string originalId = fixture.JobId, originalBody = fixture.OriginalBody;
                Click(Button(window, "按原任务再次确认")); Pump(() => fixture.Creates == 2 && Button(window, "下载Excel").IsEnabled);
                check(fixture.JobId == originalId && fixture.OriginalBody == originalBody && fixture.CreatedIdentities.Count == 1,
                    "explicit retry reuses the same named job and byte-frozen conditions");
                check(fixture.State.Store.ListJournal(fixture.Session.CaptureMutationOwner()).Count(record => record.State == MutationJournalState.Unknown) == 1,
                    "confirmed equivalent acknowledgement does not falsely change the original Unknown causality");
                window.Close();
            }
        }
        private static void LegacyIsOnlyCapabilityFallback(Action<bool, string> check)
        {
            using (var fixture = new Fixture())
            {
                fixture.Available = false; var window = fixture.Open(new UnitQuery(keyword: "legacy"));
                Pump(() => Button(window, "下载Excel").IsEnabled); Click(Button(window, "下载Excel"));
                Pump(() => File.Exists(fixture.Output) && Button(window, "下载Excel").IsEnabled);
                check(fixture.Creates == 0 && fixture.LegacyReads == 1 && fixture.Downloads == 0, "only unavailable job capability uses the fixed legacy export read");
                check(fixture.LegacyPath.Contains("keyword=legacy") && !fixture.LegacyPath.Contains("page="), "legacy read retains complete filter and projection");
                window.Close();
            }
        }
        private static void CancelledSaveChoosesNoDownload(Action<bool, string> check)
        {
            using (var fixture = new Fixture())
            {
                fixture.Available = false; fixture.Picker.Cancel = true; var window = fixture.Open(new UnitQuery());
                Pump(() => Button(window, "下载Excel").IsEnabled); Click(Button(window, "下载Excel"));
                Pump(() => fixture.Picker.Calls == 1 && Button(window, "下载Excel").IsEnabled);
                check(fixture.Downloads == 0 && fixture.LegacyReads == 0 && !File.Exists(fixture.Output), "native picker cancellation is no delivery and performs no artifact POST");
                window.Close();
            }
        }
        private static void ForbiddenRetiresVisibleData(Action<bool, string> check)
        {
            using (var fixture = new Fixture())
            {
                var window = fixture.Open(new UnitQuery()); Pump(() => Button(window, "生成当前筛选").IsEnabled);
                Click(Button(window, "生成当前筛选")); Pump(() => Button(window, "下载Excel").IsEnabled);
                fixture.Forbidden = true; Click(Button(window, "刷新"));
                Pump(() => !Button(window, "下载Excel").IsEnabled);
                var table = Visual<DataGrid>((DependencyObject)window.Content, value => true);
                check(table == null || table.Items.Count == 0, "permission failure removes old job metadata, not merely hides an unshown fixture");
                check(fixture.Downloads == 0, "forbidden refresh never downloads"); window.Close();
            }
        }
        private static Button Button(Window window, string text)
        { return Visual<Button>((DependencyObject)window.Content, value => Equals(value.Content, text)) ?? throw new InvalidOperationException("Missing fixture button " + text); }
        private static void Click(Button button)
        { Dispatcher.CurrentDispatcher.BeginInvoke(new Action(() => button.RaiseEvent(new RoutedEventArgs(System.Windows.Controls.Button.ClickEvent)))); }
        private static T Visual<T>(DependencyObject root, Func<T, bool> condition) where T : DependencyObject
        {
            if (root is T value && condition(value)) return value;
            for (int index = 0; index < VisualTreeHelper.GetChildrenCount(root); index++)
            { var found = Visual(VisualTreeHelper.GetChild(root, index), condition); if (found != null) return found; }
            return null;
        }
        private static void Pump(Func<bool> complete)
        {
            var frame = new DispatcherFrame(); var timer = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(10) };
            var deadline = System.Diagnostics.Stopwatch.StartNew();
            timer.Tick += (sender, args) => { if (complete() || deadline.Elapsed > TimeSpan.FromSeconds(10)) frame.Continue = false; };
            timer.Start(); try { Dispatcher.PushFrame(frame); } finally { timer.Stop(); }
            if (!complete()) throw new InvalidOperationException("Unit export native fixture timed out.");
        }
        private static Dictionary<string, object> Parse(string json) => (Dictionary<string, object>)new JavaScriptSerializer { MaxJsonLength = 65536 }.DeserializeObject(json);
        private sealed class Picker : IWorkbookSavePicker
        {
            internal int Calls; internal string Output; internal bool Cancel;
            public string Choose(Window owner) { Calls++; return Cancel ? null : Output; }
        }
        private sealed class Fixture : IDisposable
        {
            internal readonly BusinessStateTestFixture State = new BusinessStateTestFixture();
            internal readonly SessionCoordinator Session;
            internal readonly Picker Picker = new Picker();
            internal readonly byte[] Workbook = new byte[1024];
            internal readonly HashSet<string> CreatedIdentities = new HashSet<string>();
            internal string JobId, OriginalBody, DownloadBody, LegacyPath;
            internal int Creates, Downloads, Authorizations, LegacyReads;
            internal bool Available = true, LoseSubmitReply, IncludeProof = true, Forbidden;
            internal string Output { get { return Picker.Output; } }
            internal Fixture()
            {
                Workbook[0] = 0x50; Workbook[1] = 0x4b; Workbook[2] = 3; Workbook[3] = 4;
                Picker.Output = Path.Combine(State.RootDirectory, "unit-export-ui.xlsx");
                var config = new ClientConfiguration(new[] { new ServerEndpoint("fixture", "Fixture", "https://export-ui.company.test/api") }, "fixture");
                Session = new SessionCoordinator(config, new Handler(Serve), new MemoryStore(), State.Store);
                Session.LoginAsync("fixture", "fixture-password", null, CancellationToken.None).GetAwaiter().GetResult();
            }
            internal UnitExportWindow Open(UnitQuery query)
            {
                var window = new UnitExportWindow(null, Session, query, UnitColumnProjection.Default, new UnitReadOwner(Session), Picker);
                var content = (FrameworkElement)window.Content; content.Measure(new Size(900, 800)); content.Arrange(new Rect(0, 0, 900, content.DesiredSize.Height)); content.UpdateLayout();
                Dispatcher.CurrentDispatcher.BeginInvoke(new Action(() => window.RaiseEvent(new RoutedEventArgs(FrameworkElement.LoadedEvent))));
                return window;
            }
            private async Task<HttpResponseMessage> Serve(HttpRequestMessage request, CancellationToken token)
            {
                string path = request.RequestUri.AbsolutePath;
                if (path.EndsWith("/auth/login"))
                    return Json("{\"accessToken\":\"access.fixture\",\"refreshToken\":\"refresh.fixture\",\"expiresIn\":900,\"user\":{\"id\":\"export-ui-user\",\"loginAccount\":\"fixture\","
                        + "\"superAdmin\":false,\"mustChangePassword\":false,\"permissions\":[\"unit:view\",\"unit:export\"],\"businessDatasetId\":\"00000000-0000-0000-0000-000000000001\",\"businessResetGeneration\":0}}");
                if (Forbidden) return Json("{\"code\":\"FORBIDDEN\",\"message\":\"fixture revoked\"}", HttpStatusCode.Forbidden);
                if (path.EndsWith("/capabilities")) return Json("{\"available\":" + (Available ? "true" : "false") + "}");
                if (path == "/api/report-export-jobs" && request.Method == HttpMethod.Post)
                {
                    Creates++; string body = await request.Content.ReadAsStringAsync(); var parsed = Parse(body); JobId = (string)parsed["id"];
                    CreatedIdentities.Add(JobId); if (OriginalBody != null && OriginalBody != body) throw new InvalidOperationException("Frozen body changed.");
                    OriginalBody = body;
                    if (LoseSubmitReply) { LoseSubmitReply = false; throw new HttpRequestException("fixture lost after accepted create"); }
                    return Json(Job("PENDING"));
                }
                if (path == "/api/report-export-jobs") return Json(JobId == null ? "[]" : "[" + Job("SUCCEEDED") + "]");
                if (path.EndsWith("/download-authorization")) { Authorizations++; return Json("{\"authorized\":true}"); }
                if (path.EndsWith("/download") || path == "/api/master/units/export")
                {
                    if (path.EndsWith("/download")) Downloads++; else { LegacyReads++; LegacyPath = request.RequestUri.PathAndQuery; }
                    DownloadBody = await request.Content.ReadAsStringAsync();
                    var content = new ByteArrayContent(Workbook); content.Headers.ContentType = new System.Net.Http.Headers.MediaTypeHeaderValue("application/vnd.openxmlformats-officedocument.spreadsheetml.sheet");
                    return new HttpResponseMessage(HttpStatusCode.OK) { Content = content };
                }
                if (path.EndsWith("/cancel")) return Json(Job("CANCELLED"));
                if (path == "/api/report-export-jobs/" + JobId) return Json(Job("SUCCEEDED"));
                throw new InvalidOperationException("Unexpected private export UI fixture route.");
            }
            private string Job(string status)
            {
                var value = new Dictionary<string, object> { ["id"] = JobId, ["domain"] = "master", ["report"] = "unit", ["format"] = "xlsx",
                    ["status"] = status, ["cancelRequested"] = status == "CANCELLED", ["rows"] = 12, ["bytes"] = Workbook.Length,
                    ["snapshotAt"] = "2026-10-28T10:00:00Z", ["createdAt"] = "2026-10-28T10:00:00Z", ["finishedAt"] = null, ["error"] = null };
                if (IncludeProof) value["request"] = Parse(OriginalBody);
                return new JavaScriptSerializer().Serialize(value);
            }
            public void Dispose() { Session.Dispose(); State.Dispose(); }
        }
        private static HttpResponseMessage Json(string json, HttpStatusCode status = HttpStatusCode.OK)
        { return new HttpResponseMessage(status) { Content = new StringContent(json, Encoding.UTF8, "application/json") }; }
        private sealed class Handler : HttpMessageHandler
        {
            private readonly Func<HttpRequestMessage, CancellationToken, Task<HttpResponseMessage>> serve;
            internal Handler(Func<HttpRequestMessage, CancellationToken, Task<HttpResponseMessage>> serve) { this.serve = serve; }
            protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken token) { return serve(request, token); }
        }
        private sealed class MemoryStore : ISessionStore
        {
            private StoredSession session;
            public StoredSession Load() => session; public void Save(StoredSession value) { session = value; } public void Clear() { session = null; }
            public void EndSession(StoredSession value) { session = null; } public void EnqueueRevocation(StoredSession value) { }
            public IList<StoredSession> PendingRevocations() => new List<StoredSession>(); public void AcknowledgeRevocation(string id) { }
        }
    }
}
