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
using System.Windows.Threading;
using Uten.Legacy.Core;
using Uten.Legacy.Core.Tests;
using Uten.Legacy.Desktop.Controls;

namespace Uten.Legacy.Desktop.Features.Columns
{
    public static class DurableDraftDialogChecks
    {
        public static int Run()
        {
            var previous = SynchronizationContext.Current;
            SynchronizationContext.SetSynchronizationContext(new DispatcherSynchronizationContext(Dispatcher.CurrentDispatcher));
            try { return RunOnUi(); } finally { SynchronizationContext.SetSynchronizationContext(previous); }
        }
        private static int RunOnUi()
        {
            if (Application.Current == null) { var application = new App(); application.InitializeComponent(); application.ShutdownMode = ShutdownMode.OnExplicitShutdown; }
            int count = 0; Action<bool, string> check = (condition, label) => { if (!condition) throw new InvalidOperationException("Durable draft dialog: " + label); count++; };
            using (var fixture = new Fixture())
            {
                fixture.Login(); var owner = fixture.Session.CaptureMutationOwner(); var editor = new Editor(fixture.Session);
                editor.NameInput.Text = "  原输入  "; fixture.Store.SaveGate = new ManualResetEventSlim(false); fixture.Store.FailSave = true;
                editor.Close(); PumpUntil(() => fixture.Store.SaveStarted);
                check(!editor.ClosedFlag && !editor.NameInput.IsEnabled, "preserving close freezes inputs until the exact final body is stored");
                fixture.Store.SaveGate.Set(); PumpUntil(() => editor.NameInput.IsEnabled);
                check(!editor.ClosedFlag && editor.NameInput.Text == "  原输入  ", "failed draft preservation retains original input and open window");
                fixture.Store.FailSave = false; editor.Close(); PumpUntil(() => editor.ClosedFlag);
                check(fixture.Store.ListDrafts(owner).Single().BodyJson.Contains("  原输入  ") && fixture.Handler.Writes == 0, "retrying local close preserves raw input without business HTTP");
            }
            using (var fixture = new Fixture())
            {
                fixture.Login(); var owner = fixture.Session.CaptureMutationOwner(); fixture.Handler.LoseReply = true;
                var editor = new Editor(fixture.Session); editor.NameInput.Text = "结果未知"; editor.Submit.RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
                PumpUntil(() => fixture.Handler.Writes == 1 && editor.Result?.Outcome == MutationOutcome.Unknown);
                check(!editor.Submit.IsEnabled && !editor.NameInput.IsEnabled, "unknown result freezes the original intent");
                var draft = fixture.Store.ListDrafts(owner).Single(); editor.Close(); PumpUntil(() => editor.ClosedFlag);
                var restored = new Editor(fixture.Session, draft); restored.RaiseEvent(new RoutedEventArgs(FrameworkElement.LoadedEvent));
                PumpUntil(() => restored.Frozen);
                check(!restored.Submit.IsEnabled && restored.RawBody == draft.BodyJson && fixture.Handler.Writes == 1, "unknown original draft cannot be revived into a second request");
                restored.Close(); PumpUntil(() => restored.ClosedFlag);
            }
            using (var fixture = new Fixture())
            {
                fixture.Login(); fixture.Store.FailComplete = true;
                var editor = new Editor(fixture.Session); editor.NameInput.Text = "已确认但本机终态失败"; editor.Submit.RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
                PumpUntil(() => editor.Result?.Outcome == MutationOutcome.Confirmed);
                check(editor.BusinessChanged && !editor.Result.IsDurablyRecorded && !editor.Submit.IsEnabled && fixture.Handler.Writes == 1,
                    "server confirmation remains permanent and nonretryable after local finalization failure");
                editor.Close(); PumpUntil(() => editor.ClosedFlag);
            }
            using (var fixture = new Fixture())
            {
                fixture.Login(); var owner = fixture.Session.CaptureMutationOwner(); var editor = new Editor(fixture.Session, throwOnConfirmed: true);
                editor.NameInput.Text = "已确认但显示失败"; editor.Submit.RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
                PumpUntil(() => editor.Result?.Outcome == MutationOutcome.Confirmed && editor.Frozen);
                check(editor.BusinessChanged && !editor.Submit.IsEnabled && fixture.Store.ListDrafts(owner).Count == 0 && fixture.Handler.Writes == 1,
                    "derived confirmation display failure cannot reenable a known successful POST");
                editor.Close(); PumpUntil(() => editor.ClosedFlag);
            }
            using (var fixture = new Fixture())
            {
                fixture.Login(); var originalOwner = fixture.Session.CaptureMutationOwner(); fixture.Store.FailSave = true;
                var editor = new Editor(fixture.Session); editor.NameInput.Text = "退役原输入";
                fixture.Session.SelectEndpoint("second"); PumpUntil(() => editor.RetiredFlag && fixture.Store.SaveFailures == 1);
                check(!editor.ClosedFlag && editor.Hidden && editor.NameInput.Text == "退役原输入", "retired owner hides sensitive fields while retaining failed local preservation");
                fixture.Store.FailSave = false; editor.Close(); PumpUntil(() => editor.ClosedFlag);
                fixture.Login(); var nextOwner = fixture.Session.CaptureMutationOwner();
                check(fixture.Store.ListDrafts(originalOwner).Single().BodyJson.Contains("退役原输入") && fixture.Store.ListDrafts(nextOwner).Count == 0,
                    "retired lease writes only its original issuer namespace");
            }
            using (var fixture = new Fixture())
            {
                fixture.Login(); var originalOwner = fixture.Session.CaptureMutationOwner(); var editor = new Editor(fixture.Session);
                editor.NameInput.Text = "辅助读前退役"; fixture.Session.SelectEndpoint("second");
                try { using (editor.StartAuxiliary()) { check(false, "auxiliary read must not enter after owner changes"); } }
                catch (ApiException error) { check(error.Code == "READ_SCOPE_CHANGED" && editor.RetiredFlag, "auxiliary entry fences owner before queued UI retirement callback"); }
                PumpUntil(() => editor.ClosedFlag);
                check(fixture.Store.ListDrafts(originalOwner).Single().BodyJson.Contains("辅助读前退役") && fixture.Handler.Writes == 0,
                    "auxiliary entry rejection still preserves the original draft without a write");
            }
            using (var fixture = new Fixture())
            {
                fixture.Login(); var owner = fixture.Session.CaptureMutationOwner();
                var lease = fixture.Session.CreateDraftLease(MutationAction.UnitCreate, Guid.NewGuid().ToString("D"), owner);
                var original = "{\"name\":\"探针原文A\"}";
                var draft = fixture.Session.SaveDraftAsync(lease, 0, original, CancellationToken.None).GetAwaiter().GetResult();
                var request = fixture.Session.PrepareMutationFromDraftAsync(Guid.NewGuid().ToString("D"), draft.DraftId, draft.Revision, owner, CancellationToken.None).GetAwaiter().GetResult();
                fixture.Store.BeginSending(request);
                fixture.Store.JournalGate = new ManualResetEventSlim(false);
                var editor = new Editor(fixture.Session, draft);
                check(!editor.NameInput.IsEnabled && !editor.Submit.IsEnabled, "restored inputs are disabled even before the first journal probe starts");
                editor.RaiseEvent(new RoutedEventArgs(FrameworkElement.LoadedEvent)); PumpUntil(() => fixture.Store.JournalStarted);
                check(!editor.NameInput.IsEnabled && editor.RawBody == original, "blocking journal probe cannot accept a new visible input B");
                fixture.Store.JournalGate.Set(); PumpUntil(() => editor.Frozen);
                check(!editor.NameInput.IsEnabled && !editor.Submit.IsEnabled, "late Unknown probe keeps the editor frozen");
                editor.Close(); PumpUntil(() => editor.ClosedFlag);
                check(fixture.Store.LoadDraft(owner, draft.DraftId).BodyJson == original && fixture.Handler.Writes == 0,
                    "Unknown probe close retains original A byte for byte without overwriting or business request");
            }
            using (var fixture = new Fixture())
            {
                fixture.Login(); var owner = fixture.Session.CaptureMutationOwner();
                var lease = fixture.Session.CreateDraftLease(MutationAction.UnitCreate, Guid.NewGuid().ToString("D"), owner);
                var original = "{\"name\":\"关闭后晚到探针A\"}";
                var draft = fixture.Session.SaveDraftAsync(lease, 0, original, CancellationToken.None).GetAwaiter().GetResult();
                fixture.Store.JournalGate = new ManualResetEventSlim(false);
                var editor = new Editor(fixture.Session, draft); editor.RaiseEvent(new RoutedEventArgs(FrameworkElement.LoadedEvent));
                PumpUntil(() => fixture.Store.JournalStarted); editor.Close(); PumpUntil(() => editor.ClosedFlag);
                int updates = editor.EnableUpdates;
                fixture.Store.JournalGate.Set(); PumpUntil(() => fixture.Store.JournalFinished); Pump();
                check(editor.EnableUpdates == updates && fixture.Store.LoadDraft(owner, draft.DraftId).BodyJson == original,
                    "late probe after close cannot touch controls or replace the persisted original");
            }
            return count;
        }
        private static void Pump() { var frame = new DispatcherFrame(); Dispatcher.CurrentDispatcher.BeginInvoke(DispatcherPriority.Background, new Action(() => frame.Continue = false)); Dispatcher.PushFrame(frame); }
        private static void PumpUntil(Func<bool> condition)
        {
            var frame = new DispatcherFrame(); var watch = System.Diagnostics.Stopwatch.StartNew(); var timer = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(10) };
            timer.Tick += (sender, args) => { if (condition() || watch.Elapsed > TimeSpan.FromSeconds(8)) frame.Continue = false; };
            timer.Start(); try { Dispatcher.PushFrame(frame); } finally { timer.Stop(); }
            if (!condition()) throw new InvalidOperationException("Private durable-dialog fixture timed out.");
        }
        private sealed class Editor : DurableDraftDialog
        {
            internal readonly TextBox NameInput = new TextBox();
            private bool edited; private readonly bool throwOnConfirmed;
            internal bool ClosedFlag, RetiredFlag;
            internal int EnableUpdates;
            internal Button Submit { get { return SubmitButton; } }
            internal string RawBody { get { return BuildCurrentBody(); } }
            internal bool Hidden { get { return Body.Visibility == Visibility.Collapsed; } }
            internal bool Frozen { get { return HasUnresolvedOutcome; } }
            internal IDisposable StartAuxiliary() { return BeginEditorOperation(); }
            internal Editor(SessionCoordinator session, BusinessDraft restored = null, bool throwOnConfirmed = false)
                : base(null, session, "私有草稿测试", MutationAction.UnitCreate, restoredDraft: restored)
            {
                this.throwOnConfirmed = throwOnConfirmed; string initial = BuildCurrentBody();
                if (restored != null) NameInput.Text = (string)new JavaScriptSerializer().Deserialize<Dictionary<string, object>>(restored.BodyJson)["name"];
                Body.Children.Add(NameInput); NameInput.TextChanged += (sender, args) => { edited = true; MarkDraftChanged(); };
                Closed += (sender, args) => ClosedFlag = true; InitializeDraftUi("保存", initial);
            }
            protected override string BuildCurrentBody() { return RestoredDraft != null && !edited ? RestoredDraft.BodyJson : new JavaScriptSerializer().Serialize(new Dictionary<string, object> { ["name"] = NameInput.Text }); }
            protected override bool CanSubmitBody { get { return !String.IsNullOrWhiteSpace(NameInput.Text); } }
            protected override void SetEditorEnabled(bool enabled) { EnableUpdates++; base.SetEditorEnabled(enabled); }
            protected override void RetireSensitiveContent() { RetiredFlag = true; base.RetireSensitiveContent(); }
            protected override Task OnConfirmedAsync(MutationResult response) { if (throwOnConfirmed) throw new InvalidOperationException("fixture projection failure"); return Task.CompletedTask; }
        }
        private sealed class Fixture : IDisposable
        {
            private readonly BusinessStateTestFixture state = new BusinessStateTestFixture();
            internal readonly Handler Handler = new Handler(); internal readonly FaultStore Store; internal readonly SessionCoordinator Session;
            internal Fixture()
            {
                Store = new FaultStore(state.Store);
                Session = new SessionCoordinator(new ClientConfiguration(new[] { new ServerEndpoint("first", "First", "https://first.dialog.test/api"),
                    new ServerEndpoint("second", "Second", "https://second.dialog.test/api") }, "first"), Handler, new AuthStore(), Store);
            }
            internal void Login() { Session.LoginAsync("fixture", "fixture-secret", null, CancellationToken.None).GetAwaiter().GetResult(); }
            public void Dispose() { Session.Dispose(); state.Dispose(); }
        }
        private sealed class FaultStore : IBusinessStateStore
        {
            private readonly IBusinessStateStore inner;
            internal bool FailSave, FailComplete; internal volatile bool SaveStarted;
            internal int SaveFailures;
            internal ManualResetEventSlim SaveGate;
            internal ManualResetEventSlim JournalGate;
            internal volatile bool JournalStarted, JournalFinished;
            internal FaultStore(IBusinessStateStore inner) { this.inner = inner; }
            public BusinessDraft SaveDraft(DraftWriteLease lease, long revision, string json) { bool fail = FailSave; SaveStarted = true; SaveGate?.Wait(); if (fail) { Interlocked.Increment(ref SaveFailures); throw new IOException("fixture local save failure"); } return inner.SaveDraft(lease, revision, json); }
            public IReadOnlyList<BusinessDraft> ListDrafts(MutationOwnerSnapshot owner) { return inner.ListDrafts(owner); }
            public BusinessDraft LoadDraft(MutationOwnerSnapshot owner, string id) { return inner.LoadDraft(owner, id); }
            public void DeleteDraft(MutationOwnerSnapshot owner, string id, long revision) { inner.DeleteDraft(owner, id, revision); }
            public void BeginSending(MutationRequest request) { inner.BeginSending(request); }
            public void Complete(MutationResult response) { if (FailComplete) throw new IOException("fixture terminal journal failure"); inner.Complete(response); }
            public IReadOnlyList<MutationJournalRecord> ListJournal(MutationOwnerSnapshot owner) { JournalStarted = true; JournalGate?.Wait(); try { return inner.ListJournal(owner); } finally { JournalFinished = true; } }
            public MutationJournalRecord LoadJournal(MutationOwnerSnapshot owner, string id) { return inner.LoadJournal(owner, id); }
            public MutationJournalRecord AppendReviewNote(MutationOwnerSnapshot owner, string id, string note) { return inner.AppendReviewNote(owner, id, note); }
            public void Dispose() { SaveGate?.Dispose(); JournalGate?.Dispose(); }
        }
        private sealed class AuthStore : ISessionStore
        {
            private readonly List<StoredSession> pending = new List<StoredSession>();
            public StoredSession Load() { return null; } public void Save(StoredSession value) { } public void Clear() { }
            public void EndSession(StoredSession value) { if (value != null) pending.Add(value); } public void EnqueueRevocation(StoredSession value) { pending.Add(value); }
            public IList<StoredSession> PendingRevocations() { return pending.ToList(); } public void AcknowledgeRevocation(string id) { pending.RemoveAll(value => value.Id == id); }
        }
        private sealed class Handler : HttpMessageHandler
        {
            internal int Writes; internal bool LoseReply;
            protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken ct)
            {
                string path = request.RequestUri.AbsolutePath;
                if (path == "/api/auth/login" || path == "/api/auth/refresh") return Task.FromResult(Reply("{\"accessToken\":\"fixture-access\",\"refreshToken\":\"fixture-refresh\",\"expiresIn\":3600,\"user\":" + User + "}"));
                if (path == "/api/auth/me") return Task.FromResult(Reply(User));
                if (path == "/api/auth/logout") return Task.FromResult(Reply("{}"));
                if (path == "/api/master/units" && request.Method == HttpMethod.Post)
                {
                    Writes++; if (LoseReply) throw new HttpRequestException("fixture lost write response");
                    return Task.FromResult(Reply("{\"id\":\"00000000-0000-0000-0000-000000000071\",\"name\":\"fixture\",\"code\":\"U001\",\"status\":\"使用\"}"));
                }
                throw new InvalidOperationException("Unexpected private durable-dialog route.");
            }
            private const string User = "{\"id\":\"dialog-fixture-owner\",\"loginAccount\":\"fixture\",\"superAdmin\":false,\"mustChangePassword\":false,\"permissions\":[\"unit:view\",\"unit:create\",\"unit:edit\",\"unit:status\"],\"businessDatasetId\":\"00000000-0000-0000-0000-000000000001\",\"businessResetGeneration\":0}";
            private static HttpResponseMessage Reply(string text) { return new HttpResponseMessage(HttpStatusCode.OK) { Content = new StringContent(text, Encoding.UTF8, "application/json") }; }
        }
    }
}
