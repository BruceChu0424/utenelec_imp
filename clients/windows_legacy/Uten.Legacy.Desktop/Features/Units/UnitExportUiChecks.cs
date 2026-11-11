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
        public static int RunLargeSelectionUi()
        {
            if (Application.Current == null) { var app = new App(); app.InitializeComponent(); app.ShutdownMode = ShutdownMode.OnExplicitShutdown; }
            int checks = 0;
            foreach (int count in new[] { 1001, 50001 })
            using (var fixture = new Fixture())
            {
                var ids = Enumerable.Range(1,count).Select(number => new Guid(number,0,0,new byte[8]).ToString("D")).ToArray();
                fixture.LoseSubmitReply = true;
                var window = fixture.Open(new UnitQuery(keyword:"large-frozen-scope"), ids, count + 1);
                Pump(() => Button(window,"生成当前筛选").IsEnabled);
                int ticks = 0; var timer = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(10) };
                timer.Tick += (sender,args) => ticks++; timer.Start();
                var elapsed = System.Diagnostics.Stopwatch.StartNew();
                try
                {
                    Click(Button(window,"生成当前筛选")); Pump(() => Button(window,"核对原任务").IsEnabled);
                    var body = fixture.OriginalBody;
                    var selected = new JavaScriptSerializer { MaxJsonLength = UnitExportBudget.RequestBytes }
                        .Deserialize<string[]>((string)((Dictionary<string,object>)Parse(body)["parameters"])["selectedIds"]);
                    if (!ids.SequenceEqual(selected) || fixture.Creates != 1 || ticks < 2) throw new InvalidOperationException("Large native UI lost selection, duplicated write or blocked dispatcher");
                    Click(Button(window,"核对原任务")); Pump(() => Button(window,"下载Excel").IsEnabled);
                    if (fixture.Creates != 1 || fixture.OriginalBody != body) throw new InvalidOperationException("Large original UI reconciliation changed or replayed creation");
                    fixture.Picker.Cancel = true;
                    Click(Button(window,"下载Excel")); Pump(() => fixture.Picker.Calls == 1 && Button(window,"下载Excel").IsEnabled);
                    if (fixture.Downloads != 0 || File.Exists(fixture.Output)) throw new InvalidOperationException("Cancelled large native picker generated a download");
                    Console.WriteLine("PASS WPF actual UnitExportWindow selected="+count+"; dispatcherTicks="+ticks+"; elapsedMs="+elapsed.ElapsedMilliseconds+"; original unknown->GET; cancelled save; controlled HTTP, not PG/Win7");
                    checks += 4;
                }
                finally { timer.Stop(); window.Close(); }
            }
            return checks;
        }
        public static int RunLargeSelectionBuilder()
        {
            int checks=0;var failures=new List<int>();
            foreach(int count in new[]{1000,1001,50001})
            {
                try {
                    var ids=Enumerable.Range(1,count).Select(number=>new Guid(number,0,0,new byte[8]).ToString("D")).ToArray();
                    string body=UnitExportService.CreateBody(Guid.NewGuid().ToString("D"),new UnitQuery(keyword:"bounded-output"),UnitColumnProjection.Default,ids);
                    var json=new JavaScriptSerializer{MaxJsonLength=16*1024*1024};var fields=json.Deserialize<Dictionary<string,object>>(body);var parameters=(Dictionary<string,object>)fields["parameters"];
                    var actual=json.Deserialize<string[]>((string)parameters["selectedIds"]);
                    if(!ids.SequenceEqual(actual)||!((string)parameters["filter"]).Contains("bounded-output"))throw new InvalidOperationException("Selected output scope changed");
                    checks++;Console.WriteLine("PASS native unit output builder; selected="+count+"; bytes="+Encoding.UTF8.GetByteCount(body)+"; not a database export");
                } catch(Exception error) { Console.WriteLine("FAIL native unit output builder; selected="+count+"; type="+error.GetType().Name+"; code="+(error as ApiException)?.Code);failures.Add(count); }
            }
            if(failures.Count!=0)throw new InvalidOperationException("Native selected output builder failed for "+String.Join(",",failures));
            return checks;
        }
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
                SelectedScopeReachesJobAndLegacyBody(check);
                ScopeDialogCountsAndCancellation(check);
                HistoricalScopeRequiresExplicitChoice(check);
                ScopeIsIntegratedAndUnknownRequestKeepsItsFrozenChoice(check);
                OldServerNeverExpandsSelectedOutput(check);
                RollbackBeforeSelectedActionIsRechecked(check);
                UnknownSelectedTaskKeepsOriginalProofWhenServerVersionRetires(check);
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
        private static void SelectedScopeReachesJobAndLegacyBody(Action<bool, string> check)
        {
            string id = "12345678-1234-1234-1234-123456789abc";
            using (var fixture = new Fixture())
            {
                var window = fixture.Open(new UnitQuery(keyword: "selected-filter"), new[] { id });
                Pump(() => Button(window, "生成当前筛选").IsEnabled); Click(Button(window, "生成当前筛选"));
                Pump(() => fixture.Creates == 1 && Button(window, "下载Excel").IsEnabled);
                var parameters = (Dictionary<string, object>)Parse(fixture.OriginalBody)["parameters"];
                check((string)parameters["selectedIds"] == "[\"" + id + "\"]", "selected UUID remains a private frozen job parameter");
                check(((string)parameters["filter"]).Contains("selected-filter"), "selected export retains original current filter");
                window.Close();
            }
            using (var fixture = new Fixture())
            {
                fixture.Available = false;
                var window = fixture.Open(new UnitQuery(), new[] { id });
                Pump(() => Button(window, "下载Excel").IsEnabled); Click(Button(window, "下载Excel"));
                Pump(() => File.Exists(fixture.Output));
                check(fixture.LegacyBody.Contains(id) && !fixture.LegacyPath.Contains(id), "legacy selection is body-only and never expands to all rows");
                window.Close();
            }
        }
        private static void ScopeDialogCountsAndCancellation(Action<bool, string> check)
        {
            var empty = new TableOutputScopeDialog(null, "导出", 0, 205);
            check(!Button(empty, "仅选中（0 项）").IsEnabled && Button(empty, "全部（205 项）").IsEnabled,
                "scope dialog explicitly shows full result and zero selected count");
            empty.Close(); check(empty.SelectedOnly == null, "closing a scope dialog is cancellation, never implicit all");
            var selected = new TableOutputScopeDialog(null, "打印", 2, 205);
            Button(selected, "仅选中（2 项）").RaiseEvent(new RoutedEventArgs(System.Windows.Controls.Button.ClickEvent));
            check(selected.SelectedOnly == true, "scope choice retains actual selected count and explicit selected-only decision");
        }
        private static void HistoricalScopeRequiresExplicitChoice(Action<bool, string> check)
        {
            using (var fixture = new Fixture())
            {
                fixture.JobId = Guid.NewGuid().ToString("D");
                fixture.OriginalBody = UnitExportService.CreateBody(fixture.JobId, new UnitQuery(), UnitColumnProjection.Default);
                var window = fixture.Open(new UnitQuery(), new[] { "12345678-1234-1234-1234-123456789abc" });
                Pump(() => Button(window, "生成当前筛选").IsEnabled);
                check(!Button(window, "下载Excel").IsEnabled, "new selected scope never silently downloads historical all-row artifact");
                var history = Visual<DataGrid>((DependencyObject)window.Content, value => true); history.SelectedIndex = 0;
                check(Button(window, "下载Excel").IsEnabled, "historical scope remains available only by explicit history selection");
                window.Close();
            }
        }
        private static void ScopeIsIntegratedAndUnknownRequestKeepsItsFrozenChoice(Action<bool, string> check)
        {
            string id = "12345678-1234-1234-1234-123456789abc";
            using (var fixture = new Fixture())
            {
                var window = fixture.Open(new UnitQuery(), new[] { id }, 205, false);
                Pump(() => Button(window, "生成当前筛选").IsEnabled);
                var all = Visual<RadioButton>((DependencyObject)window.Content, value => Equals(value.Content, "全部（205 项）"));
                var selected = Visual<RadioButton>((DependencyObject)window.Content, value => Equals(value.Content, "仅选中（1 项）"));
                check(all?.IsChecked == true && selected?.IsEnabled == true, "scope and selected count live in original password/export window with default complete filter");
                var visual = (FrameworkElement)window.Content;
                var bitmap = new System.Windows.Media.Imaging.RenderTargetBitmap((int)Math.Ceiling(visual.ActualWidth),
                    (int)Math.Ceiling(visual.ActualHeight),96,96,PixelFormats.Pbgra32);bitmap.Render(visual);
                var image = new System.Windows.Media.Imaging.PngBitmapEncoder();image.Frames.Add(System.Windows.Media.Imaging.BitmapFrame.Create(bitmap));
                string screenshot = Path.Combine("build","windows-wpf","table-output-export-" + (Environment.Is64BitProcess ? "x64" : "x86") + ".png");
                Directory.CreateDirectory(Path.GetDirectoryName(screenshot));using(var output=File.Create(screenshot))image.Save(output);
                selected.IsChecked = true; fixture.LoseSubmitReply = true; Click(Button(window, "生成当前筛选"));
                Pump(() => Button(window, "核对原任务").IsEnabled);
                check(!all.IsEnabled && !selected.IsEnabled && fixture.OriginalBody.Contains(id), "unknown task freezes selected scope until original request reconciliation");
                window.Close();
            }
            using (var fixture = new Fixture())
            {
                var window = fixture.Open(new UnitQuery(), new[] { id }, 205, true);
                Pump(() => Button(window, "生成当前筛选").IsEnabled); Click(Button(window, "生成当前筛选"));
                Pump(() => Button(window, "下载Excel").IsEnabled);
                Visual<RadioButton>((DependencyObject)window.Content, value => Equals(value.Content, "全部（205 项）")).IsChecked = true;
                check(!Button(window, "下载Excel").IsEnabled && Button(window, "生成当前筛选").IsEnabled,
                    "changing scope cannot silently reuse an old artifact and requires a new frozen task");
                window.Close();
            }
        }
        private static void OldServerNeverExpandsSelectedOutput(Action<bool,string> check)
        {
            string id="12345678-1234-1234-1234-123456789abc";
            foreach(int mode in new[]{0,1,2})
            using(var fixture=new Fixture())
            {
                fixture.SelectionVersion=null;fixture.Available=mode==0;fixture.CapabilityMissing=mode==2;
                var window=fixture.Open(new UnitQuery(),new[]{id},205,true);
                var all=Visual<RadioButton>((DependencyObject)window.Content,value=>Equals(value.Content,"全部（205 项）"));
                var selected=Visual<RadioButton>((DependencyObject)window.Content,value=>Equals(value.Content,"仅选中（1 项）"));
                Pump(()=>all.IsEnabled&&fixture.CapabilityReads>0);
                check(!selected.IsEnabled&&!Button(window,"生成当前筛选").IsEnabled&&!Button(window,"下载Excel").IsEnabled,
                    "old server cannot generate or download a new selected scope mode "+mode);
                check(fixture.Creates==0&&fixture.LegacyReads==0&&fixture.Picker.Calls==0,"unsupported scope publishes no task or file and never opens save picker");
                all.IsChecked=true;
                if(mode==0){Click(Button(window,"生成当前筛选"));Pump(()=>fixture.Creates==1&&Button(window,"下载Excel").IsEnabled);check(!fixture.OriginalBody.Contains("selectedIds"),"explicit old-server all scope retains durable compatibility");}
                else{Click(Button(window,"下载Excel"));Pump(()=>File.Exists(fixture.Output)&&Button(window,"下载Excel").IsEnabled);check(!fixture.LegacyBody.Contains("selectedIds"),"explicit old-server all scope retains legacy compatibility");}
                window.Close();
            }
        }
        private static void RollbackBeforeSelectedActionIsRechecked(Action<bool,string> check)
        {
            string id="12345678-1234-1234-1234-123456789abc";
            using(var fixture=new Fixture())
            {
                fixture.Available=false;var window=fixture.Open(new UnitQuery(),new[]{id});
                Pump(()=>Button(window,"下载Excel").IsEnabled);fixture.SelectionVersion=null;
                Click(Button(window,"下载Excel"));Pump(()=>fixture.CapabilityReads>=2&&!Button(window,"下载Excel").IsEnabled
                    &&Visual<RadioButton>((DependencyObject)window.Content,value=>Equals(value.Content,"全部（当前筛选）")).IsEnabled);
                check(fixture.LegacyReads==0&&fixture.Picker.Calls==0&&!File.Exists(fixture.Output),"selected legacy action rechecks a rolled-back server before delivery");
                window.Close();
            }
            using(var fixture=new Fixture())
            {
                var window=fixture.Open(new UnitQuery(),new[]{id});Pump(()=>Button(window,"生成当前筛选").IsEnabled);fixture.SelectionVersion=null;
                Click(Button(window,"生成当前筛选"));Pump(()=>fixture.CapabilityReads>=2&&!Button(window,"生成当前筛选").IsEnabled
                    &&Visual<RadioButton>((DependencyObject)window.Content,value=>Equals(value.Content,"全部（当前筛选）")).IsEnabled);
                check(fixture.Creates==0,"selected job action rechecks rolled-back protocol before any mutation");window.Close();
            }
        }
        private static void UnknownSelectedTaskKeepsOriginalProofWhenServerVersionRetires(Action<bool,string> check)
        {
            using(var fixture=new Fixture())
            {
                fixture.LoseSubmitReply=true;string id="12345678-1234-1234-1234-123456789abc";
                var window=fixture.Open(new UnitQuery(),new[]{id});Pump(()=>Button(window,"生成当前筛选").IsEnabled);
                Click(Button(window,"生成当前筛选"));Pump(()=>Button(window,"核对原任务").IsEnabled);
                string frozen=fixture.OriginalBody;fixture.SelectionVersion=null;
                Click(Button(window,"按原任务再次确认"));Pump(()=>fixture.CapabilityReads>=3&&!Button(window,"按原任务再次确认").IsEnabled&&Button(window,"核对原任务").IsEnabled);
                check(fixture.Creates==1&&fixture.OriginalBody==frozen,"retired selection version cannot replay or replace the original unknown selected task");
                check(Button(window,"核对原任务").IsEnabled,"unsupported new selection still permits readonly original-request reconciliation");
                Click(Button(window,"核对原任务"));Pump(()=>
                    fixture.State.Store.ListJournal(fixture.Session.CaptureMutationOwner()).Single(row=>row.Action==MutationAction.UnitExportSubmit).State==MutationJournalState.Confirmed
                    &&Visual<RadioButton>((DependencyObject)window.Content,value=>Equals(value.Content,"全部（当前筛选）")).IsEnabled);
                var journal=fixture.State.Store.ListJournal(fixture.Session.CaptureMutationOwner());
                check(journal.Single(row=>row.Action==MutationAction.UnitExportSubmit).State==MutationJournalState.Confirmed
                    &&fixture.Creates==1&&fixture.OriginalBody==frozen,"exact original selected proof can settle unknown without another mutation");
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
        private static Dictionary<string, object> Parse(string json) => (Dictionary<string, object>)new JavaScriptSerializer { MaxJsonLength = UnitExportBudget.RequestBytes }.DeserializeObject(json);
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
            internal string JobId, OriginalBody, DownloadBody, LegacyPath, LegacyBody;
            internal int Creates, Downloads, Authorizations, LegacyReads;
            internal int CapabilityReads;
            internal int? SelectionVersion=1;
            internal bool CapabilityMissing;
            internal bool Available = true, LoseSubmitReply, IncludeProof = true, Forbidden;
            internal string Output { get { return Picker.Output; } }
            internal Fixture()
            {
                Workbook[0] = 0x50; Workbook[1] = 0x4b; Workbook[2] = 3; Workbook[3] = 4;
                Picker.Output = Path.Combine(State.RootDirectory, "unit-export-ui.xlsx");
                var config = new ClientConfiguration(new[] { new ServerEndpoint("fixture", "Fixture", "https://export-ui.company.test/api") }, "fixture");
                Session = new SessionCoordinator(config, new Handler(Serve), new MemoryStore(), State.Store);
                Session.LoginAsync("fixture", "fixture-password", CancellationToken.None).GetAwaiter().GetResult();
            }
            internal UnitExportWindow Open(UnitQuery query, IReadOnlyList<string> selectedIds = null, long? totalCount = null, bool selectedOnly = true)
            {
                var window = new UnitExportWindow(null, Session, query, UnitColumnProjection.Default, new UnitReadOwner(Session), Picker, selectedIds, totalCount, selectedOnly);
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
                if (path.EndsWith("/capabilities")) {
                    CapabilityReads++;
                    if(CapabilityMissing)return Json("{\"code\":\"NOT_FOUND\",\"message\":\"old server\"}",HttpStatusCode.NotFound);
                    var value=new Dictionary<string,object>{{"available",Available}};
                    if(SelectionVersion.HasValue)value.Add("selectionVersion",SelectionVersion.Value);
                    return Json(new JavaScriptSerializer().Serialize(value));
                }
                if (path == "/api/report-export-jobs" && request.Method == HttpMethod.Post)
                {
                    Creates++; string body = await request.Content.ReadAsStringAsync(); var parsed = Parse(body); JobId = (string)parsed["id"];
                    CreatedIdentities.Add(JobId); if (OriginalBody != null && OriginalBody != body) throw new InvalidOperationException("Frozen body changed.");
                    OriginalBody = body;
                    if (LoseSubmitReply) { LoseSubmitReply = false; throw new HttpRequestException("fixture lost after accepted create"); }
                    return Json(Job("PENDING"));
                }
                if (path == "/api/report-export-jobs") return Json(JobId == null ? "[]" : "[" + Job("SUCCEEDED", false) + "]");
                if (path.EndsWith("/download-authorization")) { Authorizations++; return Json("{\"authorized\":true}"); }
                if (path.EndsWith("/download") || path == "/api/master/units/export")
                {
                    if (path.EndsWith("/download")) Downloads++; else { LegacyReads++; LegacyPath = request.RequestUri.PathAndQuery; LegacyBody = await request.Content.ReadAsStringAsync(); }
                    DownloadBody = await request.Content.ReadAsStringAsync();
                    var content = new ByteArrayContent(Workbook); content.Headers.ContentType = new System.Net.Http.Headers.MediaTypeHeaderValue("application/vnd.openxmlformats-officedocument.spreadsheetml.sheet");
                    return new HttpResponseMessage(HttpStatusCode.OK) { Content = content };
                }
                if (path.EndsWith("/cancel")) return Json(Job("CANCELLED"));
                if (path == "/api/report-export-jobs/" + JobId) return Json(Job("SUCCEEDED"));
                throw new InvalidOperationException("Unexpected private export UI fixture route.");
            }
            private string Job(string status, bool includeRequest = true)
            {
                var value = new Dictionary<string, object> { ["id"] = JobId, ["domain"] = "master", ["report"] = "unit", ["format"] = "xlsx",
                    ["status"] = status, ["cancelRequested"] = status == "CANCELLED", ["rows"] = 12, ["bytes"] = Workbook.Length,
                    ["snapshotAt"] = "2026-10-28T10:00:00Z", ["createdAt"] = "2026-10-28T10:00:00Z", ["finishedAt"] = null, ["error"] = null };
                if (IncludeProof && includeRequest) value["request"] = Parse(OriginalBody);
                return new JavaScriptSerializer { MaxJsonLength = UnitExportBudget.JobReplyBytes }.Serialize(value);
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
