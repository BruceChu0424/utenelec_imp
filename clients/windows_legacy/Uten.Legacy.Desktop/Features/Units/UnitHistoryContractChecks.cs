using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Net;
using System.Net.Http;
using System.Reflection;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using System.Web.Script.Serialization;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Threading;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using Uten.Legacy.Core;
using Uten.Legacy.Core.Tests;

namespace Uten.Legacy.Desktop.Features.Units
{
    /// <summary>Debug-only offline checks: all HTTP uses this file's in-memory handler, storage is a private fixture.</summary>
    public static class UnitHistoryContractChecks
    {
        private const string OperationId = "00000000-0000-0000-0000-000000000051";
        private const string RecordId = "00000000-0000-0000-0000-000000000052";
        private const long RevisionId = 9007199254740993L;
        private const long OperationVersion = 9007199254740995L;
        public static int Run()
        {
            int count = RunModels();
            Action<bool, string> check = (condition, label) => { if (!condition) throw new InvalidOperationException("Unit history: " + label); count++; };
            HttpContracts(check).GetAwaiter().GetResult();
            return count;
        }
        public static int RunModels()
        {
            int count = 0; Action<bool, string> check = (condition, label) => { if (!condition) throw new InvalidOperationException("Unit history: " + label); count++; };
            var operations = UnitHistoryContract.ParseOperations(Operations(false));
            check(operations.Entries[0].Version == OperationVersion, "operation version exceeds double precision without rounding");
            check(UnitHistoryContract.ReplayBody(operations.Entries[0].Version) == "{\"expectedVersion\":9007199254740995}", "version token is exact Int64");
            check(operations.Entries[0].CanUndo && !operations.Entries[0].CanRedo && operations.Entries[0].AffectedCount == 1, "server capabilities are retained");
            check(operations.Events[0].Id == "9007199254740997" && operations.Events[0].OperationId == OperationId, "event identifier is opaque text");
            var detail = UnitHistoryContract.ParseRecordDetail(Revision(true));
            check(detail.Id == RevisionId && detail.ExpectedHead == "9007199254740993:9223372036854775807", "revision ID and opaque command head retained");
            check(detail.Changes[0].BeforeValue == "0.123456789012345678901234567890" && detail.Changes[0].AfterValue == "—", "displayed values are server text without numeric recalculation");
            check(detail.CanRestoreBefore && !detail.CanRestoreAfter, "before and after restore capabilities remain independent");
            var body = UnitJson.Object(UnitJson.Parse(UnitHistoryContract.RestoreBody(detail.ExpectedHead, true)));
            check((string)body["expectedHead"] == detail.ExpectedHead && (bool)body["before"], "restore body uses original string head and boolean direction");
            var page = UnitHistoryContract.ParseRecordPage("{\"entries\":[" + Revision(false) + "],\"nextCursor\":\"9223372036854775807\"}");
            check(page.NextCursor == Int64.MaxValue && !page.Entries[0].CanRestoreBefore, "list capabilities cannot substitute for selected detail");
            var query = new UnitHistoryQuery(RecordId, Int64.MaxValue, "EDIT", actorKeyword: "A&B", keyword: "kg + 箱", dateFrom: "2026-10-28",
                dateTo: "2026-10-28T23:59:59+08:00", sourceType: "EXTENSION", summaryKeyword: "x/y").ToRelativePath();
            check(query.StartsWith("/master/record-history?entityType=units&size=50&recordId=" + RecordId + "&cursor=9223372036854775807", StringComparison.Ordinal), "cursor, selected record and entity use actual API");
            check(query.Contains("actorKeyword=A%26B") && query.Contains("keyword=kg%20%2B%20%E7%AE%B1") && query.Contains("summaryKeyword=x%2Fy"), "all free text is escaped");
            check(UnitHistoryContract.RecordDetailPath(Int64.MaxValue).Contains("9223372036854775807?entityType=units"), "detail long target exact path");
            Reject<FormatException>(() => UnitHistoryContract.ParseOperations(Operations(false).Replace(OperationVersion.ToString(CultureInfo.InvariantCulture), "1.5")), check, "floating operation version rejected");
            Reject<FormatException>(() => UnitHistoryContract.ParseRecordDetail(Revision(true).Replace("\"units\"", "\"goods\"")), check, "foreign entity rejected");
            Reject<FormatException>(() => UnitHistoryContract.ParseRecordDetail(Revision(true).Replace("\"" + RevisionId + "\"", "\"01\"")), check, "noncanonical history target rejected");
            Reject<ArgumentException>(() => new UnitHistoryQuery(dateFrom: "2026-10-28T12:00:00"), check, "timestamp must include its timezone");
            Reject<ArgumentOutOfRangeException>(() => new UnitHistoryQuery(size: 101), check, "server page bound respected");
            Reject<ArgumentException>(() => new UnitHistoryQuery(action: "APPROVE"), check, "unknown action not invented");
            return count;
        }
        private static async Task HttpContracts(Action<bool, string> check)
        {
            using (var fixture = new Fixture())
            {
                await fixture.Login(); var service = new UnitHistoryService(fixture.Session);
                var source = await service.OperationsAsync(CancellationToken.None);
                check(fixture.Handler.LastPath == "/api/master/operation-history?entityType=units", "operation read query matches controller");
                var command = service.PrepareReplay(Guid.NewGuid().ToString("D"), source, OperationId, false);
                check(command.RelativePath == "master/operation-history/" + OperationId + "/undo?entityType=units" && command.BodyJson == UnitHistoryContract.ReplayBody(OperationVersion), "typed undo exact route and frozen version");
                check(!command.ServerIdempotencyAvailable, "operation version is not mislabelled a receipt");
                var result = await service.SendAsync(command, CancellationToken.None);
                check(result.Outcome == MutationOutcome.Confirmed && result.IsDurablyRecorded && fixture.Handler.Writes == 1, "undo uses durable typed Core write once");
                var restoredSource = await service.DetailAsync(RevisionId, CancellationToken.None);
                var restore = service.PrepareRestore(Guid.NewGuid().ToString("D"), restoredSource, true);
                check(restore.RelativePath == "master/record-history/9007199254740993/restore?entityType=units", "restore long target follows controller");
                result = await service.SendAsync(restore, CancellationToken.None);
                check(result.Outcome == MutationOutcome.Confirmed && result.IsDurablyRecorded && fixture.Handler.Writes == 2, "void 200 restore response is confirmed without invented Unit DTO");
                var query = new UnitHistoryQuery(recordId: RecordId, cursor: Int64.MaxValue, actorKeyword: "A&B");
                await service.RecordsAsync(query, CancellationToken.None);
                check(fixture.Handler.LastPath.EndsWith("&actorKeyword=A%26B", StringComparison.Ordinal), "service retains query escaping");
                fixture.Handler.WrongRevision = true;
                try { await service.DetailAsync(RevisionId, CancellationToken.None); check(false, "mismatched selected revision rejected"); }
                catch (FormatException) { check(true, "mismatched selected revision rejected"); }
                fixture.Handler.WrongRevision = false;
                source = await service.OperationsAsync(CancellationToken.None); fixture.Handler.LoseReply = true;
                command = service.PrepareReplay(Guid.NewGuid().ToString("D"), source, OperationId, true);
                result = await service.SendAsync(command, CancellationToken.None);
                check(result.Outcome == MutationOutcome.Unknown && result.IsDurablyRecorded, "lost write reply remains durably unknown");
                var journal = await service.JournalAsync(CancellationToken.None);
                check(UnitHistoryService.HasUnresolved(journal.Value), "new window can detect prior unknown history attempt");
                int writes = fixture.Handler.Writes;
                command = service.PrepareReplay(Guid.NewGuid().ToString("D"), source, OperationId, true);
                result = await service.SendAsync(command, CancellationToken.None);
                check(result.Outcome == MutationOutcome.NotSent && fixture.Handler.Writes == writes, "fresh local ID cannot replay unresolved history target");
            }
            using (var fixture = new Fixture())
            {
                await fixture.Login(); var service = new UnitHistoryService(fixture.Session);
                fixture.Handler.PendingOperations = new TaskCompletionSource<HttpResponseMessage>();
                var pending = service.OperationsAsync(CancellationToken.None);
                fixture.Session.SelectEndpoint("second"); fixture.Handler.PendingOperations.SetResult(Reply(Operations(false)));
                try { await pending; check(false, "late response rejected after server switch"); }
                catch (ApiException) { check(true, "late response rejected after server switch"); }
                catch (OperationCanceledException) { check(true, "late response cancelled after server switch"); }
            }
            using (var fixture = new Fixture(new[] { "unit:view", "unit:status" }, "STATUS"))
            {
                await fixture.Login(); var service = new UnitHistoryService(fixture.Session);
                var source = await service.OperationsAsync(CancellationToken.None);
                var command = service.PrepareReplay(Guid.NewGuid().ToString("D"), source, OperationId, false);
                var result = await service.SendAsync(command, CancellationToken.None);
                check(result.Outcome == MutationOutcome.Confirmed && fixture.Handler.Writes == 1,
                    "status-only original operation is not blocked by an invented blanket edit permission");
            }
        }
        public static int RunReadUi()
        {
            var previous = SynchronizationContext.Current;
            SynchronizationContext.SetSynchronizationContext(new DispatcherSynchronizationContext(Dispatcher.CurrentDispatcher));
            try { return RunReadUiCore(); } finally { SynchronizationContext.SetSynchronizationContext(previous); }
        }
        private static int RunReadUiCore()
        {
            int count = 0; Action<bool, string> check = (condition, label) => { if (!condition) throw new InvalidOperationException("Unit history UI: " + label); count++; };
            if (Application.Current == null) { var application = new App(); application.InitializeComponent(); application.ShutdownMode = ShutdownMode.OnExplicitShutdown; }
            using (var fixture = new Fixture())
            {
                fixture.Login().GetAwaiter().GetResult();
                var window = new UnitRecordHistoryWindow(null, fixture.Session, RecordId);
                try
                {
                    window.RaiseEvent(new RoutedEventArgs(FrameworkElement.LoadedEvent));
                    var rows = Field<DataGrid>(window, "revisions"); PumpUntil(() => rows.Items.Count == 1);
                    rows.SelectedIndex = 0; var diff = Field<DataGrid>(window, "changes"); PumpUntil(() => diff.Items.Count == 1);
                    check(Field<Button>(window, "before").IsEnabled && !Field<Button>(window, "after").IsEnabled, "native restore uses selected server direction capabilities");
                    Snapshot(window, "unit-record-history-fixture.png");
                    var search = Field<TextBox>(window, "keyword"); search.Text = "保留的查询";
                    Field<Button>(window, "refresh").RaiseEvent(new RoutedEventArgs(Button.ClickEvent)); PumpUntil(() => rows.Items.Count == 1);
                    fixture.Handler.ReauthRead = true;
                    fixture.Session.GetAsync("/fixture-refresh", CancellationToken.None).GetAwaiter().GetResult(); Pump();
                    check(search.Text == "保留的查询" && rows.Items.Count == 1, "ordinary auth refresh preserves query and table");
                    bool closed = false; window.Closed += (sender, args) => closed = true;
                    fixture.Session.SelectEndpoint("second"); PumpUntil(() => closed);
                    check(rows.ItemsSource == null && diff.ItemsSource == null && search.Text.Length == 0, "retired owner clears all prior read data before close");
                }
                finally { window.Close(); }
            }
            return count;
        }
        public static int RunUi()
        {
            var previous = SynchronizationContext.Current;
            SynchronizationContext.SetSynchronizationContext(new DispatcherSynchronizationContext(Dispatcher.CurrentDispatcher));
            try { return RunUiCore(); } finally { SynchronizationContext.SetSynchronizationContext(previous); }
        }
        private static int RunUiCore()
        {
            int count = RunReadUi();
            Action<bool, string> check = (condition, label) => { if (!condition) throw new InvalidOperationException("Unit history UI: " + label); count++; };
            using (var fixture = new Fixture())
            {
                fixture.Login().GetAwaiter().GetResult();
                var window = new UnitOperationHistoryWindow(null, fixture.Session);
                try
                {
                    window.RaiseEvent(new RoutedEventArgs(FrameworkElement.LoadedEvent));
                    var rows = Field<DataGrid>(window, "operations"); PumpUntil(() => rows.Items.Count == 1);
                    check(Field<Button>(window, "undo").IsEnabled && !Field<Button>(window, "redo").IsEnabled, "native personal history uses selected undo capability");
                    Snapshot(window, "unit-operation-history-fixture.png");
                }
                finally { window.Close(); }
            }
            using (var fixture = new Fixture())
            {
                fixture.Login().GetAwaiter().GetResult();
                var originalOwner = fixture.Session.CaptureMutationOwner();
                var window = new UnitOperationHistoryWindow(null, fixture.Session);
                bool closed = false; window.Closed += (sender, args) => closed = true;
                try
                {
                    window.RaiseEvent(new RoutedEventArgs(FrameworkElement.LoadedEvent));
                    var rows = Field<DataGrid>(window, "operations"); PumpUntil(() => rows.Items.Count == 1);
                    var snapshot = Field<UnitReadSnapshot<UnitOperationHistory>>(window, "snapshot");
                    fixture.Handler.PendingWrite = new TaskCompletionSource<HttpResponseMessage>();
                    var service = new UnitHistoryService(fixture.Session);
                    Func<MutationRequest> prepare = () => service.PrepareReplay(Guid.NewGuid().ToString("D"), snapshot, OperationId, false);
                    var method = typeof(UnitHistoryWindow).GetMethod("ExecuteCommandAsync", BindingFlags.Instance | BindingFlags.NonPublic);
                    var pending = (Task)method.Invoke(window, new object[] { prepare, "已撤回所选操作" });
                    PumpUntil(() => fixture.Handler.Writes == 1); window.Close();
                    check(!closed && !Field<Button>(window, "undo").IsEnabled, "history close and repeat are blocked until durable write accounting finishes");
                    fixture.Session.SelectEndpoint("second"); Pump();
                    check(rows.ItemsSource == null, "retired history immediately clears data while original submission is pending");
                    fixture.Handler.PendingWrite.SetResult(Reply(Operations(true)));
                    PumpUntil(() => pending.IsCompleted && closed); pending.GetAwaiter().GetResult();
                    var journal = fixture.ReadJournal(originalOwner);
                    check(journal.Count == 1 && journal[0].State == MutationJournalState.Unknown && fixture.Handler.Writes == 1,
                        "late history reply is retained only as original-owner Unknown without a second write");
                }
                finally
                {
                    fixture.Handler.PendingWrite?.TrySetCanceled();
                    if (!closed)
                    {
                        PumpUntil(() => !(bool)typeof(UnitHistoryWindow).GetField("Mutating", BindingFlags.Instance | BindingFlags.NonPublic).GetValue(window));
                        window.Close();
                    }
                }
            }
            return count;
        }
        private static void Snapshot(Window window, string name)
        {
            var content = (FrameworkElement)window.Content;
            double width = window.Width;
            content.Measure(new Size(width, Double.PositiveInfinity)); content.Arrange(new Rect(0, 0, width, content.DesiredSize.Height)); content.UpdateLayout();
            Pump(); content.UpdateLayout();
            var bitmap = new RenderTargetBitmap((int)Math.Ceiling(content.ActualWidth), (int)Math.Ceiling(content.ActualHeight), 96, 96, PixelFormats.Pbgra32);
            bitmap.Render(content); var png = new PngBitmapEncoder(); png.Frames.Add(BitmapFrame.Create(bitmap));
            using (var file = File.Create(Path.Combine(AppDomain.CurrentDomain.BaseDirectory, name))) png.Save(file);
        }
        private static T Field<T>(object target, string name) where T : class
        { return (T)target.GetType().GetField(name, BindingFlags.Instance | BindingFlags.NonPublic).GetValue(target); }
        private static void Pump() { var frame = new DispatcherFrame(); Dispatcher.CurrentDispatcher.BeginInvoke(DispatcherPriority.Background, new Action(() => frame.Continue = false)); Dispatcher.PushFrame(frame); }
        private static void PumpUntil(Func<bool> condition)
        {
            var frame = new DispatcherFrame(); var deadline = System.Diagnostics.Stopwatch.StartNew();
            var timer = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(10) };
            timer.Tick += (sender, args) => { if (condition() || deadline.Elapsed > TimeSpan.FromSeconds(8)) frame.Continue = false; };
            timer.Start(); try { Dispatcher.PushFrame(frame); } finally { timer.Stop(); }
            if (!condition()) throw new InvalidOperationException("Controlled native history fixture timed out.");
        }
        private static void Reject<T>(Action action, Action<bool, string> check, string label) where T : Exception
        { try { action(); } catch (T) { check(true, label); return; } check(false, label); }
        private static string Operations(bool undone, long? version = null)
        {
            return "{\"entries\":[{\"id\":\"" + OperationId + "\",\"operationType\":\"EDIT\",\"label\":\"编辑单位\",\"summary\":\"名称变更\",\"createdAt\":\"2026-10-28T12:00:00+08:00\",\"state\":\""
                + (undone ? "UNDONE" : "APPLIED") + "\",\"version\":" + (version ?? OperationVersion + (undone ? 1 : 0)).ToString(CultureInfo.InvariantCulture) + ",\"affectedCount\":1,\"canUndo\":" + (undone ? "false" : "true")
                + ",\"canRedo\":" + (undone ? "true" : "false") + ",\"blockedReason\":null}],\"events\":[{\"id\":\"9007199254740997\",\"operationId\":\"" + OperationId
                + "\",\"action\":\"UNDO\",\"label\":\"编辑单位\",\"createdAt\":\"2026-10-28T12:00:00+08:00\",\"operationType\":\"EDIT\"}]}";
        }
        private static string Revision(bool detailed)
        {
            return "{\"id\":\"" + RevisionId + "\",\"recordId\":\"" + RecordId + "\",\"recordLabel\":\"公斤\",\"recordCode\":\"U001\",\"recordName\":\"公斤\",\"action\":\"EDIT\",\"actorId\":null,\"actorName\":\"本机测试\","
                + "\"recordedAt\":\"2026-10-28T12:00:00+08:00\",\"expectedHead\":\"9007199254740993:9223372036854775807\",\"affectedCount\":1,\"entityType\":\"units\",\"sourceType\":\"RECORD\",\"summary\":\"名称变更\",\"canRestoreBefore\":"
                + (detailed ? "true" : "false") + ",\"canRestoreAfter\":false,\"blockedReason\":\"修改后：当前资料已经与此版本一致\",\"changes\":[{\"table\":\"units\",\"rowId\":\"" + RecordId
                + "\",\"field\":\"name\",\"label\":\"名称\",\"beforeValue\":\"0.123456789012345678901234567890\",\"afterValue\":\"—\"}]}";
        }
        private static HttpResponseMessage Reply(string text, HttpStatusCode status = HttpStatusCode.OK)
        { return new HttpResponseMessage(status) { Content = new StringContent(text, Encoding.UTF8, "application/json") }; }
        private sealed class Fixture : IDisposable
        {
            private readonly BusinessStateTestFixture storage = new BusinessStateTestFixture();
            internal readonly Handler Handler; internal readonly SessionCoordinator Session;
            internal Fixture(string[] permissions = null, string operationType = "EDIT")
            {
                Handler = new Handler(permissions ?? new[] { "unit:view", "unit:edit", "unit:status" }, operationType);
                Session = new SessionCoordinator(new ClientConfiguration(new[] { new ServerEndpoint("first", "First", "https://first.history.test/api"),
                    new ServerEndpoint("second", "Second", "https://second.history.test/api") }, "first"), Handler, new AuthStore(), storage.Store);
            }
            internal Task Login() { return Session.LoginAsync("fixture", "fixture-secret", null, CancellationToken.None); }
            internal IReadOnlyList<MutationJournalRecord> ReadJournal(MutationOwnerSnapshot owner) { return storage.Store.ListJournal(owner); }
            public void Dispose() { Session.Dispose(); storage.Dispose(); }
        }
        private sealed class AuthStore : ISessionStore
        {
            private readonly List<StoredSession> pending = new List<StoredSession>();
            public StoredSession Load() { return null; } public void Save(StoredSession value) { } public void Clear() { }
            public void EndSession(StoredSession value) { if (value != null) pending.Add(value); }
            public void EnqueueRevocation(StoredSession value) { pending.Add(value); }
            public IList<StoredSession> PendingRevocations() { return pending; }
            public void AcknowledgeRevocation(string id) { pending.RemoveAll(value => value.Id == id); }
        }
        private sealed class Handler : HttpMessageHandler
        {
            internal string LastPath; internal int Writes; internal bool LoseReply, ReauthRead, WrongRevision;
            private readonly string[] permissions;
            private readonly string operationType;
            private bool undone;
            private long operationVersion = OperationVersion;
            internal TaskCompletionSource<HttpResponseMessage> PendingOperations;
            internal TaskCompletionSource<HttpResponseMessage> PendingWrite;
            internal Handler(string[] permissions, string operationType) { this.permissions = permissions; this.operationType = operationType; }
            private string OperationReply() { return Operations(undone, operationVersion).Replace("\"EDIT\"", "\"" + operationType + "\""); }
            protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken ct)
            {
                LastPath = request.RequestUri.PathAndQuery; string path = request.RequestUri.AbsolutePath;
                if (path == "/api/auth/login" || path == "/api/auth/refresh") return Reply("{\"accessToken\":\"fixture-access\",\"refreshToken\":\"fixture-refresh\",\"expiresIn\":3600,\"user\":" + User() + "}");
                if (path == "/api/auth/me") return Reply(User()); if (path == "/api/auth/logout") return Reply("{}");
                if (path == "/api/fixture-refresh")
                {
                    if (ReauthRead) { ReauthRead = false; return Reply("{\"code\":\"UNAUTHORIZED\",\"message\":\"fixture refresh\"}", HttpStatusCode.Unauthorized); }
                    return Reply("{}");
                }
                if (request.Method == HttpMethod.Get)
                {
                    if (path == "/api/master/operation-history") return PendingOperations == null ? Reply(OperationReply()) : await PendingOperations.Task;
                    if (path == "/api/master/record-history") return Reply("{\"entries\":[" + Revision(false) + "],\"nextCursor\":null}");
                    if (path == "/api/master/record-history/" + RevisionId) return Reply(WrongRevision ? Revision(true).Replace("\"id\":\"" + RevisionId + "\"", "\"id\":\"51\"") : Revision(true));
                }
                if (request.Method == HttpMethod.Post && (path == "/api/master/operation-history/" + OperationId + "/undo"
                    || path == "/api/master/operation-history/" + OperationId + "/redo" || path == "/api/master/record-history/" + RevisionId + "/restore"))
                {
                    await request.Content.ReadAsStringAsync(); Writes++;
                    if (!path.EndsWith("/restore", StringComparison.Ordinal)) { undone = path.EndsWith("/undo", StringComparison.Ordinal); operationVersion++; }
                    if (LoseReply) throw new HttpRequestException("fixture lost reply");
                    if (PendingWrite != null) return await PendingWrite.Task;
                    return Reply(path.EndsWith("/restore", StringComparison.Ordinal) ? "" : OperationReply());
                }
                throw new InvalidOperationException("Unexpected controlled history request: " + request.Method + " " + path);
            }
            private string User()
            {
                return "{\"id\":\"history-fixture-owner\",\"employeeId\":\"" + RecordId + "\",\"loginAccount\":\"fixture\",\"superAdmin\":false,\"mustChangePassword\":false,\"permissions\":" + new JavaScriptSerializer().Serialize(permissions) + ","
                    + "\"businessDatasetId\":\"00000000-0000-0000-0000-000000000001\",\"businessResetGeneration\":0}";
            }
        }
    }
}
