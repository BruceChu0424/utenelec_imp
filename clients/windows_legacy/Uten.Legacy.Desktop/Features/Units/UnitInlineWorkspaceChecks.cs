using System;
using System.Collections.Generic;
using System.ComponentModel;
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
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Threading;
using Uten.Legacy.Core;
using Uten.Legacy.Core.Tests;
using Uten.Legacy.Desktop.Controls;

namespace Uten.Legacy.Desktop.Features.Units
{
    /// <summary>Injected fake HTTP, real private CurrentUser DPAPI and native WPF windows only.</summary>
    public static class UnitInlineWorkspaceChecks
    {
        private const string A = "00000000-0000-0000-0000-000000000111", B = "00000000-0000-0000-0000-000000000112",
            C = "00000000-0000-0000-0000-000000000113";
        public static int Run()
        {
            if (Application.Current == null) { var app = new App(); app.InitializeComponent(); app.ShutdownMode = ShutdownMode.OnExplicitShutdown; }
            int count = 0; Action<bool, string> check = (value, label) => { if (!value) throw new InvalidOperationException("Unit inline: " + label); count++; };
            PartialSuccess(check); ExistingEditOrder(check); UnknownAndExplicitDiscard(check); NarrowPermissions(check); ConfirmedStorageFailure(check);
            RetiredLeasePreservation(check); OwnerChangesDuringSubmission(check); RestoreDraftContracts(check);
            NativeImeAndGlobalGuard(check); NativeRestoredWorkspace(check);
            return count;
        }
        private static void PartialSuccess(Action<bool, string> check)
        {
            using (var fixture = new Fixture())
            {
                fixture.Login(); var snapshot = Wait(new UnitService(fixture.Session).ListAsync(new UnitQuery(), CancellationToken.None));
                var model = new UnitInlineWorkspaceModel(fixture.Session, snapshot.Value.Items, snapshot.Owner);
                check(model.Rows.Count(row => row.IsBlank) == 3, "owning creation default keeps three blank rows");
                check(model.Rows.All(row => row.DraftId != null), "every editable row owns a lease before the first input");
                check(fixture.Store.ListDrafts(fixture.Session.CaptureMutationOwner()).Count == 0, "memory leases alone create no draft files");
                model.Rows[0].Name = "  公斤  "; model.Rows[1].Name = "待保存中";
                var added = model.FirstBlankRow(); added.Code = ""; added.Name = "新单位";
                check(model.Rows.Count(row => row.IsBlank) == 3, "dirty creation replenishes blanks without capping/truncating real input");
                fixture.Handler.Modes.Enqueue("confirm"); fixture.Handler.Modes.Enqueue("reject");
                check(!Wait(model.SaveAllAsync()), "first rejection stops sequential SaveAll");
                check(fixture.Handler.Writes.Count == 2 && fixture.Handler.Writes[0].Path.EndsWith("/" + A), "existing rows use real inline endpoint in source order");
                var first = Json(fixture.Handler.Writes[0].Body);
                check(((Dictionary<string, object>)first["changes"])["name"].ToString() == "  公斤  ", "inline raw spacing survives unchanged");
                check(((Dictionary<string, object>)first["expected"])["name"].ToString() == "公斤", "each changed key carries the real baseline value");
                check(!first.ContainsKey("code") && !((Dictionary<string, object>)first["changes"]).ContainsKey("code"), "existing code never enters inline changes");
                check(model.Rows[0].Outcome == MutationOutcome.Confirmed && !model.Rows[0].CanEdit, "confirmed row is frozen and never requeued");
                check(model.Rows[1].Name == "待保存中" && added.Name == "新单位", "rejected and unattempted input stays intact");
                var drafts = fixture.Store.ListDrafts(fixture.Session.CaptureMutationOwner());
                check(drafts.Count == 2 && drafts.All(item => item.DraftId != model.Rows[0].DraftId), "only confirmed durable draft is cleaned");
                check(drafts.Any(item => item.Action == MutationAction.UnitCreate && item.BodyJson.Contains("新单位")), "all later create input was preserved before first dispatch");
                check(Wait(model.SaveAllAsync()), "new explicit SaveAll can finish known rejected/unsent rows");
                check(fixture.Handler.Writes.Count == 4 && fixture.Handler.Writes.Count(item => item.Path.EndsWith("/" + A)) == 1, "partial success is not submitted again");
                check(fixture.Handler.Writes[3].Path == "/api/master/units" && !Json(fixture.Handler.Writes[3].Body).ContainsKey("measurementDimension"), "new row uses action1 and omits hidden measurement rules");
                Wait(model.PreserveAndFinishAsync()); check(model.IsFinished && model.BusinessChanged, "finished state preserves truthful business change");
            }
        }
        private static void UnknownAndExplicitDiscard(Action<bool, string> check)
        {
            using (var fixture = new Fixture())
            {
                fixture.Login(); var snapshot = fixture.Snapshot();
                var model = new UnitInlineWorkspaceModel(fixture.Session, snapshot.Value.Items, snapshot.Owner);
                var owner = fixture.Session.CaptureMutationOwner();
                model.Rows[0].Name = "原未知内容"; model.Rows[1].Name = "后续未发内容";
                fixture.Handler.Modes.Enqueue("unknown");
                check(!Wait(model.SaveAllAsync()) && fixture.Handler.Writes.Count == 1, "Unknown stops every remaining row");
                check(model.HasUnresolved && !model.CanSave && !model.Rows[0].CanEdit, "Unknown original row stays frozen");
                string original = fixture.Store.LoadDraft(owner, model.Rows[0].DraftId).BodyJson;
                bool blocked = false; try { model.Rows[0].Name = "不能替换未知"; } catch (InvalidOperationException) { blocked = true; }
                check(blocked && !Wait(model.SaveAllAsync()) && fixture.Handler.Writes.Count == 1, "Unknown cannot receive a new body/request");
                Wait(model.DiscardUnsentAndFinishAsync());
                check(fixture.Store.LoadDraft(owner, model.Rows[0].DraftId).BodyJson == original, "explicit cancel never deletes pending original content");
                check(fixture.Store.LoadDraft(owner, model.Rows[1].DraftId) == null, "only explicitly discarded unsent draft is removed");
            }
        }
        private static void ExistingEditOrder(Action<bool, string> check)
        {
            using (var fixture = new Fixture())
            {
                fixture.Login(); var snapshot = fixture.Snapshot();
                var model = new UnitInlineWorkspaceModel(fixture.Session, snapshot.Value.Items, snapshot.Owner);
                model.Rows[1].Name = "先编辑"; model.Rows[0].Name = "后编辑";
                fixture.Handler.Modes.Enqueue("reject");
                check(!Wait(model.SaveAllAsync()) && fixture.Handler.Writes.Single().Path.EndsWith("/" + B),
                    "existing transactions follow owning patch-map first-edit order");
                Wait(model.PreserveAndFinishAsync());
            }
        }
        private static void NarrowPermissions(Action<bool, string> check)
        {
            using (var fixture = new Fixture(new[] { "unit:view", "unit:create" }))
            {
                fixture.Login(); var snapshot = fixture.Snapshot();
                var model = new UnitInlineWorkspaceModel(fixture.Session, snapshot.Value.Items, snapshot.Owner);
                check(model.Rows.Take(2).All(row => row.DraftId == null && !row.CanEdit), "create-only cannot edit existing rows");
                bool blocked = false; try { model.Rows[0].Code = "OTHER"; } catch (InvalidOperationException) { blocked = true; }
                check(blocked, "existing code is immutable even through public model");
                var createdRow = model.FirstBlankRow(); createdRow.Name = "创建专用";
                check(!createdRow.CanEditStatus && createdRow.Status == "使用", "create without status permission keeps source default");
                check(Wait(model.SaveAllAsync()) && fixture.Handler.Writes.Single().Path == "/api/master/units", "create-only row uses controlled create action");
                Wait(model.PreserveAndFinishAsync());
            }
            using (var fixture = new Fixture())
            {
                fixture.Login(); var snapshot = fixture.Snapshot();
                var model = new UnitInlineWorkspaceModel(fixture.Session, snapshot.Value.Items, snapshot.Owner);
                model.Rows[0].Status = "禁用";
                check(Wait(model.SaveAllAsync()), "inline status uses the same controlled row transaction");
                var patch = Json(fixture.Handler.Writes.Single().Body);
                check(((Dictionary<string, object>)patch["changes"]).Count == 1
                    && ((Dictionary<string, object>)patch["changes"])["status"].ToString() == "禁用",
                    "status-only patch does not invent a name or code update");
                Wait(model.PreserveAndFinishAsync());
            }
            using (var fixture = new Fixture())
            {
                fixture.Login(); var snapshot = fixture.Snapshot();
                var nullable = UnitRecord.Parse("{\"id\":\"" + A + "\",\"code\":\"U001\",\"name\":null,\"status\":\"使用\"}");
                var model = new UnitInlineWorkspaceModel(fixture.Session, new[] { nullable }, snapshot.Owner);
                model.Rows[0].Status = "禁用";
                check(Wait(model.SaveAllAsync()), "untouched nullable name does not invalidate a status-only source patch");
                check(!((Dictionary<string, object>)Json(fixture.Handler.Writes.Single().Body)["changes"]).ContainsKey("name"),
                    "nullable untouched fields are not fabricated into updates");
                Wait(model.PreserveAndFinishAsync());
            }
        }
        private static void RetiredLeasePreservation(Action<bool, string> check)
        {
            using (var fixture = new Fixture())
            {
                fixture.Login(); var snapshot = fixture.Snapshot(); var owner = fixture.Session.CaptureMutationOwner();
                var model = new UnitInlineWorkspaceModel(fixture.Session, snapshot.Value.Items, snapshot.Owner);
                model.Rows[0].Name = "原账号中文输入"; fixture.Store.FailSave = true;
                fixture.Session.SelectEndpoint("second"); model.RetireOwner();
                bool failed = false; try { Wait(model.FlushDraftsAsync()); } catch (ApiException) { failed = true; }
                check(failed && model.Rows[0].Name == "原账号中文输入" && !model.IsFinished, "retired storage failure retains the original object/input");
                fixture.Store.FailSave = false; Wait(model.PreserveAndFinishAsync());
                check(fixture.Store.ListDrafts(owner).Single().BodyJson.Contains("原账号中文输入"), "pre-issued lease preserves after owner retirement in original namespace");
                check(fixture.Handler.Writes.Count == 0, "retirement never submits offline input");
            }
        }
        private static void ConfirmedStorageFailure(Action<bool, string> check)
        {
            foreach (bool completionFailure in new[] { true, false })
                using (var fixture = new Fixture())
                {
                    fixture.Login(); var snapshot = fixture.Snapshot(); var owner = fixture.Session.CaptureMutationOwner();
                    var model = new UnitInlineWorkspaceModel(fixture.Session, snapshot.Value.Items, snapshot.Owner);
                    model.Rows[0].Name = "已知成功"; model.Rows[1].Name = "尚未发送";
                    fixture.Store.FailComplete = completionFailure; fixture.Store.FailDelete = !completionFailure;
                    check(!Wait(model.SaveAllAsync()), "confirmed local finalization/cleanup failure stops remaining rows");
                    check(model.BusinessChanged && model.Rows[0].Outcome == MutationOutcome.Confirmed && model.HasUnresolved,
                        "known server success is retained while local persistence is incomplete");
                    check(!Wait(model.SaveAllAsync()) && fixture.Handler.Writes.Count == 1, "confirmed local failure never authorizes another POST/PATCH");
                    check(fixture.Store.LoadDraft(owner, model.Rows[0].DraftId) != null
                        && fixture.Store.LoadDraft(owner, model.Rows[1].DraftId) != null, "all original and unattempted data survives local finalization failure");
                    Wait(model.PreserveAndFinishAsync());
                }
        }
        private static void OwnerChangesDuringSubmission(Action<bool, string> check)
        {
            using (var fixture = new Fixture())
            {
                fixture.Login(); var snapshot = fixture.Snapshot(); var owner = fixture.Session.CaptureMutationOwner();
                var model = new UnitInlineWorkspaceModel(fixture.Session, snapshot.Value.Items, snapshot.Owner);
                model.Rows[0].Name = "原正在发送"; model.Rows[1].Name = "原未发送";
                fixture.Handler.Pending = new TaskCompletionSource<HttpResponseMessage>();
                var saving = model.SaveAllAsync(); PumpUntil(() => fixture.Handler.Writes.Count == 1);
                fixture.Session.SelectEndpoint("second"); model.RetireOwner();
                fixture.Handler.Pending.SetResult(Reply(Record(A, "原正在发送")));
                Wait(saving); Wait(model.PreserveAndFinishAsync());
                check(fixture.Handler.Writes.Count == 1 && !model.Rows[0].CanEdit, "retired in-flight outcome does not drain remaining writes");
                check(fixture.Store.ListDrafts(owner).Any(item => item.BodyJson.Contains("原未发送")), "retirement retains every unattempted row under old owner");
            }
        }
        private static void NativeImeAndGlobalGuard(Action<bool, string> check)
        {
            using (var fixture = new Fixture())
            {
                fixture.Login(); var snapshot = fixture.Snapshot(); var owner = fixture.Session.CaptureMutationOwner();
                var parent = new HostWindow(); parent.Show(); parent.UpdateLayout(); Pump();
                var view = new UnitInlineWorkspace(parent, fixture.Session, snapshot.Value.Items, snapshot.Owner);
                parent.Content = view; parent.UpdateLayout(); Pump();
                check(parent.Pending.Count == 1 && parent.Pending.All(window => !window.IsVisible), "owned preservation guard is registered without displaying another editor");
                var name = Descendants<TextBox>(view).First(input => (input.DataContext as UnitInlineRow)?.Id == A
                    && System.Windows.Automation.AutomationProperties.GetName(input) == "单位名称");
                check(Math.Abs(name.ActualHeight - (double)view.FindResource("Uten.Height.Cell")) < 1, "native cell editor uses owning Cell height token");
                check(name.ActualWidth > 250, "name and blank editors stretch across actual page cells");
                name.Focus(); var composition = new TextComposition(InputManager.Current, name, "拼音中", TextCompositionAutoComplete.Off);
                TextCompositionManager.StartComposition(composition);
                name.Text = "拼音中"; name.GetBindingExpression(TextBox.TextProperty).UpdateSource();
                check(view.Model.HasComposition && !Wait(view.SaveAllAsync()) && fixture.Handler.Writes.Count == 0, "IME composition cannot be submitted halfway");
                TextCompositionManager.CompleteComposition(composition); Pump();
                string composingText = name.Text;
                Wait(view.Model.FlushDraftsAsync());
                check(fixture.Store.LoadDraft(owner, view.Model.Rows[0].DraftId).BodyJson.Contains(composingText), "all native IME text is locally preserved verbatim");
                var originalControl = name;
                check(Descendants<TextBox>(view).Any(input => ReferenceEquals(input, originalControl)), "preservation/status updates keep the actual editor instance");
                Render(parent, "unit-inline-native.png");
                fixture.Store.FailSave = true;
                var retiringComposition = new TextComposition(InputManager.Current, name, "机密旧单位 HOLD", TextCompositionAutoComplete.Off);
                TextCompositionManager.StartComposition(retiringComposition);
                name.Text = "机密旧单位 HOLD"; name.GetBindingExpression(TextBox.TextProperty).UpdateSource();
                fixture.Session.SelectEndpoint("second"); view.Dispose(); parent.Content = new TextBlock { Text = "新账号页面" };
                PumpUntil(() => parent.Pending.Any(window => window.IsVisible));
                var guard = parent.Pending.Single();
                check(!Descendants<TextBlock>(guard).Any(text => text.Text.Contains("机密旧单位")), "retired preservation failure window never shows old-owner business input");
                parent.Close(); check(parent.IsVisible && parent.Pending.Count == 1, "real native owner close remains blocked after forced workspace replacement");
                fixture.Store.FailSave = false; Wait(view.PreserveAndFinishAsync()); Pump();
                check(view.CanLeave && parent.Pending.Count == 0, "guard closes only after original lease preservation succeeds");
                check(fixture.Store.ListDrafts(owner).Any(item => item.BodyJson.Contains("机密旧单位 HOLD")), "forced replacement preserves the latest native input under original owner");
                parent.Close();
            }
        }
        private static void RestoreDraftContracts(Action<bool, string> check)
        {
            using (var fixture = new Fixture())
            {
                fixture.Login(); var snapshot = fixture.Snapshot(); var owner = fixture.Session.CaptureMutationOwner();
                string raw = "{ \"expected\" : { \"name\" : \"公斤\" }, \"changes\" : { \"name\" : \"  手工草稿  \" } }";
                var lease = fixture.Session.CreateDraftLease(MutationAction.UnitInlineEdit, Guid.NewGuid().ToString("D"), owner, A);
                var draft = Wait(fixture.Session.SaveDraftAsync(lease, 0, raw, CancellationToken.None));
                var restored = new UnitInlineWorkspaceModel(fixture.Session, snapshot.Value.Items, snapshot.Owner, draft);
                check(restored.Rows[0].DraftId == draft.DraftId && !restored.CanSave && !restored.Rows[1].SupportsEditing,
                    "recovery reuses original draft ID while unrelated current rows remain read-only");
                Wait(restored.VerifyRestoredDraftAsync());
                check(!restored.CanSave && restored.RequiresRestoredReview, "fresh row and local journal still require explicit original-value review");
                restored.AcknowledgeRestoredReview();
                check(Wait(restored.SaveAllAsync()), "reviewed, unlinked action4 draft can use the controlled sender");
                check(fixture.Handler.Writes.Single().Body == raw, "untouched restored expected/changes raw JSON is not rewritten");
                Wait(restored.PreserveAndFinishAsync());
            }
            using (var fixture = new Fixture())
            {
                fixture.Login(); var snapshot = fixture.Snapshot(); var owner = fixture.Session.CaptureMutationOwner();
                string raw = "{\"expected\":{\"name\":\"旧原值\"},\"changes\":{\"name\":\"原草稿值\"}}";
                var lease = fixture.Session.CreateDraftLease(MutationAction.UnitInlineEdit, Guid.NewGuid().ToString("D"), owner, A);
                var draft = Wait(fixture.Session.SaveDraftAsync(lease, 0, raw, CancellationToken.None));
                var restored = new UnitInlineWorkspaceModel(fixture.Session, snapshot.Value.Items, snapshot.Owner, draft);
                fixture.Handler.EnforceExpected = true;
                Wait(restored.VerifyRestoredDraftAsync()); restored.AcknowledgeRestoredReview();
                check(restored.RestoredReviewSummary.Contains("旧原值") && restored.RestoredReviewSummary.Contains("公斤"), "original and fresh expected values are both reviewable");
                check(!Wait(restored.SaveAllAsync()) && fixture.Handler.Writes.Single().Body == raw,
                    "explicit reviewed submit preserves stale expected and receives a real conflict rather than rebasing");
                restored.Rows[0].Name = "用户明确改值"; Wait(restored.FlushDraftsAsync());
                var stored = fixture.Store.LoadDraft(owner, draft.DraftId);
                check(((Dictionary<string, object>)Json(stored.BodyJson)["expected"])["name"].ToString() == "旧原值",
                    "editing restored values never silently rebases its original expected map");
                Wait(restored.PreserveAndFinishAsync());
            }
            foreach (bool confirmed in new[] { false, true })
                using (var fixture = new Fixture())
                {
                    fixture.Login(); var snapshot = fixture.Snapshot(); var owner = fixture.Session.CaptureMutationOwner();
                    string raw = "{\"expected\":{\"name\":\"公斤\"},\"changes\":{\"name\":\"原提交\"}}";
                    var lease = fixture.Session.CreateDraftLease(MutationAction.UnitInlineEdit, Guid.NewGuid().ToString("D"), owner, A);
                    var draft = Wait(fixture.Session.SaveDraftAsync(lease, 0, raw, CancellationToken.None));
                    var request = Wait(fixture.Session.PrepareMutationFromDraftAsync(Guid.NewGuid().ToString("D"), draft.DraftId, draft.Revision, owner, CancellationToken.None));
                    if (confirmed) Wait(fixture.Session.MutateAsync(request, CancellationToken.None));
                    else fixture.Store.BeginSending(request);
                    int before = fixture.Handler.Writes.Count;
                    var restored = new UnitInlineWorkspaceModel(fixture.Session, snapshot.Value.Items, snapshot.Owner, draft);
                    Wait(restored.VerifyRestoredDraftAsync());
                    check(restored.HasUnresolved && !restored.Rows[0].CanEdit && !Wait(restored.SaveAllAsync())
                        && fixture.Handler.Writes.Count == before, "Sending/Unknown or linked Confirmed draft never replays");
                    Wait(restored.PreserveAndFinishAsync());
                    check(fixture.Store.LoadDraft(owner, draft.DraftId).BodyJson == raw, "journal-frozen original raw draft remains untouched");
                }
            using (var fixture = new Fixture())
            {
                fixture.Login(); var snapshot = fixture.Snapshot(); var owner = fixture.Session.CaptureMutationOwner();
                var lease = fixture.Session.CreateDraftLease(MutationAction.UnitInlineEdit, Guid.NewGuid().ToString("D"), owner, A);
                var draft = Wait(fixture.Session.SaveDraftAsync(lease, 0, "{\"expected\":{},\"changes\":{}}", CancellationToken.None));
                fixture.Session.SelectEndpoint("second"); fixture.Login(); var other = fixture.Snapshot();
                bool rejected = false;
                try { new UnitInlineWorkspaceModel(fixture.Session, other.Value.Items, other.Owner, draft); } catch (ApiException) { rejected = true; }
                check(rejected, "action4 recovery cannot carry another issuer's draft into a new page");
            }
        }
        private static void NativeRestoredWorkspace(Action<bool, string> check)
        {
            using (var fixture = new Fixture())
            {
                fixture.Login(); var snapshot = fixture.Snapshot(); var owner = fixture.Session.CaptureMutationOwner();
                string raw = "{ \"expected\" : {\"name\":\"公斤\"}, \"changes\" : {\"name\":\"恢复后保存\"} }";
                var lease = fixture.Session.CreateDraftLease(MutationAction.UnitInlineEdit, Guid.NewGuid().ToString("D"), owner, A);
                var draft = Wait(fixture.Session.SaveDraftAsync(lease, 0, raw, CancellationToken.None));
                var parent = new HostWindow(); parent.Show(); parent.UpdateLayout(); Pump();
                var view = new UnitInlineWorkspace(parent, fixture.Session, snapshot.Value.Items, snapshot.Owner, draft);
                int finished = 0; view.Finished += (sender, args) => finished++;
                parent.Content = view; parent.UpdateLayout(); PumpUntil(() => view.Model.RestoredJournalVerified);
                check(view.Model.RequiresRestoredReview && !view.Model.CanSave && parent.Pending.Count == 1,
                    "native restored page verifies journal and holds guard before explicit review");
                check(Descendants<TextBlock>(view).Any(label => label.Text.Contains("原预期") && label.Text.Contains("本次读取")),
                    "native inline recovery shows original/fresh values on the same page");
                Render(parent, "unit-inline-restored.png");
                var acknowledge = Descendants<Button>(view).Single(button => button.Content?.ToString() == "已核对原值，继续编辑");
                acknowledge.RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
                var save = Descendants<Button>(view).Single(button => button.Content?.ToString().StartsWith("保存 ", StringComparison.Ordinal) == true);
                check(save.IsEnabled, "explicit native review unlocks the controlled save action");
                save.RaiseEvent(new RoutedEventArgs(Button.ClickEvent)); PumpUntil(() => view.CanLeave);
                check(fixture.Handler.Writes.Single().Body == raw && finished == 1 && parent.Pending.Count == 0,
                    "native successful save fires Finished once and releases preservation only after durable cleanup");
                parent.Close();
            }
        }
        private static T Wait<T>(Task<T> task) { PumpUntil(() => task.IsCompleted); return task.GetAwaiter().GetResult(); }
        private static void Wait(Task task) { PumpUntil(() => task.IsCompleted); task.GetAwaiter().GetResult(); }
        private static void Pump() { var frame = new DispatcherFrame(); Dispatcher.CurrentDispatcher.BeginInvoke(DispatcherPriority.Background, new Action(() => frame.Continue = false)); Dispatcher.PushFrame(frame); }
        private static void PumpUntil(Func<bool> condition)
        {
            if (condition()) return;
            var frame = new DispatcherFrame(); var clock = System.Diagnostics.Stopwatch.StartNew();
            var timer = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(10) };
            timer.Tick += (sender, args) => { if (condition() || clock.Elapsed > TimeSpan.FromSeconds(10)) frame.Continue = false; };
            timer.Start(); try { Dispatcher.PushFrame(frame); } finally { timer.Stop(); }
            if (!condition()) throw new InvalidOperationException("Native inline fixture timed out.");
        }
        private static IEnumerable<T> Descendants<T>(DependencyObject parent) where T : DependencyObject
        {
            for (int index = 0; index < VisualTreeHelper.GetChildrenCount(parent); index++)
            {
                var child = VisualTreeHelper.GetChild(parent, index); if (child is T value) yield return value;
                foreach (var nested in Descendants<T>(child)) yield return nested;
            }
        }
        private static void Render(Window window, string filename)
        {
            window.UpdateLayout(); var bitmap = new RenderTargetBitmap((int)window.ActualWidth, (int)window.ActualHeight, 96, 96, PixelFormats.Pbgra32);
            bitmap.Render(window); var png = new PngBitmapEncoder(); png.Frames.Add(BitmapFrame.Create(bitmap));
            using (var file = File.Create(Path.Combine(AppDomain.CurrentDomain.BaseDirectory, filename))) png.Save(file);
        }
        private static Dictionary<string, object> Json(string text) { return (Dictionary<string, object>)new JavaScriptSerializer().DeserializeObject(text); }
        private static HttpResponseMessage Reply(string json, HttpStatusCode status = HttpStatusCode.OK)
        { return new HttpResponseMessage(status) { Content = new StringContent(json, Encoding.UTF8, "application/json") }; }
        private static string Record(string id, string name, string status = "使用")
        { return new JavaScriptSerializer().Serialize(new { id, code = id == A ? "U001" : id == B ? "U002" : "U003", name, status }); }
        private sealed class HostWindow : Window, IPendingEditHost
        {
            internal readonly HashSet<Window> Pending = new HashSet<Window>();
            internal HostWindow() { SetResourceReference(StyleProperty, typeof(Window)); Width = 1080; Height = 440; ShowInTaskbar = false; ShowActivated = false; }
            public void TrackPendingEditor(Window editor)
            {
                Window ancestor = editor.Owner; while (ancestor != null && ancestor != this) ancestor = ancestor.Owner;
                if (ancestor != this) throw new InvalidOperationException("Foreign test editor.");
                Pending.Add(editor); editor.Closed += (sender, args) => Pending.Remove(editor);
            }
            protected override void OnClosing(CancelEventArgs args) { if (Pending.Count != 0) args.Cancel = true; base.OnClosing(args); }
        }
        private sealed class Fixture : IDisposable
        {
            private readonly BusinessStateTestFixture storage = new BusinessStateTestFixture();
            internal readonly Handler Handler; internal readonly SessionCoordinator Session; internal readonly FaultStore Store;
            internal Fixture(string[] permissions = null)
            {
                Handler = new Handler(permissions ?? new[] { "unit:view", "unit:edit", "unit:create", "unit:status" });
                Store = new FaultStore(storage.Store);
                Session = new SessionCoordinator(new ClientConfiguration(new[] { new ServerEndpoint("first", "First", "https://first.inline.test/api"),
                    new ServerEndpoint("second", "Second", "https://second.inline.test/api") }, "first"), Handler, new AuthStore(), Store);
            }
            internal void Login() { Wait(Session.LoginAsync("fixture", "fixture-secret", CancellationToken.None)); }
            internal UnitReadSnapshot<UnitPageResult> Snapshot() { return Wait(new UnitService(Session).ListAsync(new UnitQuery(), CancellationToken.None)); }
            public void Dispose() { Session.Dispose(); storage.Dispose(); }
        }
        private sealed class FaultStore : IBusinessStateStore
        {
            private readonly IBusinessStateStore inner; internal bool FailSave, FailComplete, FailDelete;
            internal FaultStore(IBusinessStateStore inner) { this.inner = inner; }
            public BusinessDraft SaveDraft(DraftWriteLease lease, long revision, string body) { if (FailSave) throw new IOException("private fixture save failure"); return inner.SaveDraft(lease, revision, body); }
            public IReadOnlyList<BusinessDraft> ListDrafts(MutationOwnerSnapshot owner) { return inner.ListDrafts(owner); }
            public BusinessDraft LoadDraft(MutationOwnerSnapshot owner, string id) { return inner.LoadDraft(owner, id); }
            public void DeleteDraft(MutationOwnerSnapshot owner, string id, long revision) { if (FailDelete) throw new IOException("private fixture cleanup failure"); inner.DeleteDraft(owner, id, revision); }
            public void BeginSending(MutationRequest request) { inner.BeginSending(request); }
            public void Complete(MutationResult result) { if (FailComplete) throw new IOException("private fixture complete failure"); inner.Complete(result); }
            public IReadOnlyList<MutationJournalRecord> ListJournal(MutationOwnerSnapshot owner) { return inner.ListJournal(owner); }
            public MutationJournalRecord LoadJournal(MutationOwnerSnapshot owner, string id) { return inner.LoadJournal(owner, id); }
            public MutationJournalRecord AppendReviewNote(MutationOwnerSnapshot owner, string id, string note) { return inner.AppendReviewNote(owner, id, note); }
            public void Dispose() { } // The private fixture owns the real DPAPI store.
        }
        private sealed class AuthStore : ISessionStore
        {
            public StoredSession Load() { return null; } public void Save(StoredSession value) { } public void Clear() { }
            public void EndSession(StoredSession value) { } public void EnqueueRevocation(StoredSession value) { }
            public IList<StoredSession> PendingRevocations() { return new List<StoredSession>(); } public void AcknowledgeRevocation(string id) { }
        }
        private sealed class WriteRecord { internal string Path, Body; }
        private sealed class Handler : HttpMessageHandler
        {
            private readonly string[] permissions;
            internal readonly Queue<string> Modes = new Queue<string>();
            internal readonly List<WriteRecord> Writes = new List<WriteRecord>();
            internal TaskCompletionSource<HttpResponseMessage> Pending;
            internal bool EnforceExpected;
            internal Handler(string[] permissions) { this.permissions = permissions; }
            protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken ct)
            {
                string path = request.RequestUri.AbsolutePath;
                if (path == "/api/auth/login" || path == "/api/auth/refresh") return Reply("{\"accessToken\":\"fixture-access\",\"refreshToken\":\"fixture-refresh\",\"expiresIn\":3600,\"user\":" + User() + "}");
                if (path == "/api/auth/me") return Reply(User());
                if (path == "/api/auth/logout") return Reply("{}");
                if (request.Method == HttpMethod.Get && path == "/api/master/units")
                    return Reply("{\"items\":[" + Record(A, "公斤") + "," + Record(B, "件") + "],\"page\":1,\"size\":20,\"total\":2,\"totalPages\":1}");
                if (request.Method.Method == "PATCH" && path.StartsWith("/api/master/inline-edit/units/", StringComparison.Ordinal)
                    || request.Method == HttpMethod.Post && path == "/api/master/units")
                {
                    string body = await request.Content.ReadAsStringAsync(); Writes.Add(new WriteRecord { Path = path, Body = body });
                    if (Pending != null) return await Pending.Task;
                    string mode = Modes.Count == 0 ? "confirm" : Modes.Dequeue();
                    if (mode == "unknown") throw new HttpRequestException("private fixture lost response");
                    if (mode == "reject") return Reply("{\"code\":\"CONFLICT\",\"message\":\"原字段已变化\"}", HttpStatusCode.Conflict);
                    var value = Json(body);
                    bool create = request.Method == HttpMethod.Post;
                    string id = create ? C : path.EndsWith("/" + A, StringComparison.Ordinal) ? A : B;
                    var changes = create ? value : (Dictionary<string, object>)value["changes"];
                    if (!create && EnforceExpected && changes.ContainsKey("name")
                        && ((Dictionary<string, object>)value["expected"])["name"] as string != (id == A ? "公斤" : "件"))
                        return Reply("{\"code\":\"CONFLICT\",\"message\":\"原字段已变化\"}", HttpStatusCode.Conflict);
                    string name = changes.ContainsKey("name") ? changes["name"].ToString() : id == A ? "公斤" : "件";
                    string status = changes.ContainsKey("status") ? changes["status"].ToString() : "使用";
                    return Reply(Record(id, name, status));
                }
                throw new InvalidOperationException("Unexpected private inline fixture request.");
            }
            private string User() { return new JavaScriptSerializer().Serialize(new { id = "inline-owner", loginAccount = "fixture", superAdmin = false,
                mustChangePassword = false, permissions, businessDatasetId = "00000000-0000-0000-0000-000000000001", businessResetGeneration = 0 }); }
        }
    }
}
