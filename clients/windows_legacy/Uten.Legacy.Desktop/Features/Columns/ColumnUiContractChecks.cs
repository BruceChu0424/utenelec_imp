using System;
using System.Collections.ObjectModel;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Reflection;
using System.Threading;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Threading;
using Uten.Legacy.Core;
using Uten.Legacy.Desktop.Controls;

namespace Uten.Legacy.Desktop.Features.Columns
{
    /// <summary>Actual native editors over private in-memory HTTP and isolated DPAPI fixtures; never a company request.</summary>
    public static class ColumnUiContractChecks
    {
        public static int RunWrites() { return Task.Run(WriteContracts).GetAwaiter().GetResult(); }
        private static async Task<int> WriteContracts()
        {
            int count = 0; Action<bool, string> check = (condition, label) => { if (!condition) throw new InvalidOperationException("Column write: " + label); count++; };
            using (var fixture = new ColumnServiceContractChecks.Fixture())
            {
                await fixture.Login(); var service = new UnitColumnsService(fixture.Session); var source = await service.LoadAsync(new[] { ColumnServiceContractChecks.RecordId }, CancellationToken.None);
                var layout = new UnitColumnLayout(source.Projection.Columns.Select(column => column.Key), widths: new Dictionary<string, double> { ["name"] = 244.5 }, addedIds: source.Layout.AddedIds);
                var request = service.PrepareLayout(Guid.NewGuid().ToString("D"), source, layout);
                var result = await service.SendAsync(request, CancellationToken.None);
                check(result.Outcome == MutationOutcome.Confirmed && result.IsDurablyRecorded && fixture.Handler.LastWritePath.EndsWith(UnitColumnLayout.PreferenceKey, StringComparison.Ordinal), "personal layout uses approved fixed preference route and durable completion");
                check(!request.EnforcesExpectedVersion && !request.ServerIdempotencyAvailable, "preference LWW does not become a fake server CAS or receipt");
                request = service.PrepareDefinitionCreate(Guid.NewGuid().ToString("D"), source, new PlatformColumnCreateInput("  原列名  ", "TEXT"));
                result = await service.SendAsync(request, CancellationToken.None);
                check(result.Outcome == MutationOutcome.Confirmed && fixture.Handler.LastWriteBody.Contains("  原列名  "), "definition creation preserves raw user name to owning API");
                var fresh = await service.DefinitionAsync(ColumnServiceContractChecks.NumberId, CancellationToken.None);
                request = service.PrepareDefinitionUse(Guid.NewGuid().ToString("D"), fresh); result = await service.SendAsync(request, CancellationToken.None);
                check(result.Outcome == MutationOutcome.Confirmed && request.BodyJson == null && !fixture.Handler.LastWriteHadContent, "usage selection uses true no-body POST");
                request = service.PrepareDefinitionDelete(Guid.NewGuid().ToString("D"), fresh); result = await service.SendAsync(request, CancellationToken.None);
                check(result.Outcome == MutationOutcome.Confirmed && request.BodyJson == null && !fixture.Handler.LastWriteHadContent, "directory retirement uses true no-body DELETE");
            }
            using (var fixture = new ColumnServiceContractChecks.Fixture())
            {
                await fixture.Login(); fixture.Handler.StoredValues[ColumnServiceContractChecks.TextId] = "不能丢的原文字";
                var service = new UnitColumnsService(fixture.Session); var source = await service.LoadAsync(new[] { ColumnServiceContractChecks.RecordId }, CancellationToken.None);
                var request = service.PrepareValue(Guid.NewGuid().ToString("D"), source, ColumnServiceContractChecks.RecordId, ColumnServiceContractChecks.NumberId, "  1.0000000000000000001  ");
                var result = await service.SendAsync(request, CancellationToken.None);
                check(result.Outcome == MutationOutcome.Confirmed && result.IsDurablyRecorded && fixture.Handler.StoredValues[ColumnServiceContractChecks.TextId] == "不能丢的原文字", "single-cell intent preserves all persisted siblings under real field-row CAS");
                check(fixture.Handler.LastWriteBody.Contains("  1.0000000000000000001  ") && fixture.Handler.LastWriteBody.Contains("9007199254740993"), "raw decimal input and exact field version remain frozen on wire");
            }
            using (var fixture = new ColumnServiceContractChecks.Fixture())
            {
                await fixture.Login(); var service = new UnitColumnsService(fixture.Session); var fresh = await service.DefinitionAsync(ColumnServiceContractChecks.NumberId, CancellationToken.None);
                fixture.Handler.LoseWriteReply = true;
                var result = await service.SendAsync(service.PrepareDefinitionDelete(Guid.NewGuid().ToString("D"), fresh), CancellationToken.None);
                check(result.Outcome == MutationOutcome.Unknown && result.IsDurablyRecorded, "lost no-body retirement reply remains Unknown rather than guessed success");
                int writes = fixture.Handler.BusinessWrites;
                result = await service.SendAsync(service.PrepareDefinitionDelete(Guid.NewGuid().ToString("D"), fresh), CancellationToken.None);
                check(result.Outcome == MutationOutcome.NotSent && fixture.Handler.BusinessWrites == writes, "new local ID cannot replay unresolved catalog target");
            }
            return count;
        }
        public static int Run()
        {
            var previous = SynchronizationContext.Current;
            SynchronizationContext.SetSynchronizationContext(new DispatcherSynchronizationContext(Dispatcher.CurrentDispatcher));
            try { return RunUi(); } finally { SynchronizationContext.SetSynchronizationContext(previous); }
        }
        private static int RunUi()
        {
            if (Application.Current == null) { var app = new App(); app.InitializeComponent(); app.ShutdownMode = ShutdownMode.OnExplicitShutdown; }
            int count = 0; Action<bool, string> check = (condition, label) => { if (!condition) throw new InvalidOperationException("Column UI: " + label); count++; };
            using (var fixture = new ColumnServiceContractChecks.Fixture())
            {
                fixture.Login().GetAwaiter().GetResult(); var service = new UnitColumnsService(fixture.Session);
                var source = Await(service.LoadAsync(new[] { ColumnServiceContractChecks.RecordId }, CancellationToken.None));
                var window = new UnitColumnSettingsWindow(null, fixture.Session, source); var settings = Field<ObservableCollection<ColumnSettingRow>>(window, "rows");
                settings[0].WidthText = "120.";
                check(!Save(window).IsEnabled, "incomplete pixel text cannot become a valid numeric layout");
                CloseAndWait(window);
                var owner = fixture.Session.CaptureMutationOwner(); var draft = fixture.Session.ListDraftsAsync(owner, CancellationToken.None).GetAwaiter().GetResult().Single();
                check(draft.BodyJson.Contains("\"code\":\"120.\"") && fixture.Handler.BusinessWrites == 0, "unfinished pixel suffix is preserved as original draft text without a write");
                var restored = new UnitColumnSettingsWindow(null, fixture.Session, source, draft); restored.RaiseEvent(new RoutedEventArgs(FrameworkElement.LoadedEvent));
                PumpUntil(() => Field<Button>(restored, "review").IsEnabled);
                var restoredRows = Field<ObservableCollection<ColumnSettingRow>>(restored, "rows"); restoredRows[0].WidthText = "144";
                Field<Button>(restored, "review").RaiseEvent(new RoutedEventArgs(Button.ClickEvent)); PumpUntil(() => Save(restored).IsEnabled);
                Snapshot(restored, "unit-column-settings-fixture.png"); Save(restored).RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
                PumpUntil(() => restored.BusinessChanged && !restored.IsLoaded && restored.AppliedSnapshot != null);
                check(restored.Result?.Outcome == MutationOutcome.Confirmed && restored.AppliedSnapshot.Projection.Columns[0].Width == 144,
                    "reviewed layout restore uses the actual native save and shared projection");
                check(fixture.Session.ListDraftsAsync(owner, CancellationToken.None).GetAwaiter().GetResult().Count == 0, "confirmed personal layout cleans only its own original draft");
            }
            using (var fixture = new ColumnServiceContractChecks.Fixture())
            {
                fixture.Login().GetAwaiter().GetResult(); var source = Await(new UnitColumnsService(fixture.Session).LoadAsync(new[] { ColumnServiceContractChecks.RecordId }, CancellationToken.None));
                var window = new UnitPlatformDefinitionWindow(null, fixture.Session, source); Field<TextBox>(window, "name").Text = "  原生备注  ";
                Snapshot(window, "unit-column-definition-fixture.png"); Save(window).RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
                PumpUntil(() => window.CreatedDefinition != null);
                check(window.BusinessChanged && window.CreatedDefinition.Name == "原生备注" && fixture.Handler.LastWriteBody.Contains("  原生备注  "), "native definition editor sends original input and reads authoritative returned definition");
            }
            using (var fixture = new ColumnServiceContractChecks.Fixture())
            {
                fixture.Login().GetAwaiter().GetResult(); fixture.Handler.StoredValues[ColumnServiceContractChecks.TextId] = "保留的兄弟字段";
                var service = new UnitColumnsService(fixture.Session); var source = Await(service.LoadAsync(new[] { ColumnServiceContractChecks.RecordId }, CancellationToken.None));
                var window = new UnitPlatformValuesWindow(null, fixture.Session, source, ColumnServiceContractChecks.RecordId, ColumnServiceContractChecks.NumberId);
                var targets = Field<ObservableCollection<PlatformValueTarget>>(window, "targets");
                check(targets.Single(row => row.Id == ColumnServiceContractChecks.NumberId).CanEdit && !targets.Single(row => row.Id == ColumnServiceContractChecks.TextId).CanEdit,
                    "normal editor permits only the actually clicked cell");
                targets.Single(row => row.Id == ColumnServiceContractChecks.NumberId).TargetText = " 2.0000000000000000001 ";
                Snapshot(window, "unit-column-values-fixture.png"); Save(window).RaiseEvent(new RoutedEventArgs(Button.ClickEvent)); PumpUntil(() => window.SavedRow != null);
                check(window.BusinessChanged && fixture.Handler.StoredValues[ColumnServiceContractChecks.TextId] == "保留的兄弟字段", "actual single-cell UI save preserves unchanged sibling values");
                source = Await(service.LoadAsync(new[] { ColumnServiceContractChecks.RecordId }, CancellationToken.None));
                var draftWindow = new UnitPlatformValuesWindow(null, fixture.Session, source, ColumnServiceContractChecks.RecordId, ColumnServiceContractChecks.NumberId);
                Field<ObservableCollection<PlatformValueTarget>>(draftWindow, "targets").Single(row => row.Id == ColumnServiceContractChecks.NumberId).TargetText = "9";
                CloseAndWait(draftWindow); var owner = fixture.Session.CaptureMutationOwner(); var draft = fixture.Session.ListDraftsAsync(owner, CancellationToken.None).GetAwaiter().GetResult().Single();
                long original = ColumnJson.Integer(ColumnJson.Object(ColumnJson.Parse(draft.BodyJson)), "expectedVersion");
                fixture.Handler.RowVersion++; fixture.Handler.StoredValues[ColumnServiceContractChecks.TextId] = "他人后来修改的字段";
                source = Await(service.LoadAsync(new[] { ColumnServiceContractChecks.RecordId }, CancellationToken.None));
                var restored = new UnitPlatformValuesWindow(null, fixture.Session, source, ColumnServiceContractChecks.RecordId, null, draft);
                restored.RaiseEvent(new RoutedEventArgs(FrameworkElement.LoadedEvent));
                var choices = Field<ObservableCollection<PlatformValueTarget>>(restored, "targets"); PumpUntil(() => Field<Button>(restored, "review").IsEnabled);
                choices.Single(row => row.Id == ColumnServiceContractChecks.NumberId).UseDraft = true;
                string beforeReview = (string)typeof(UnitPlatformValuesWindow).GetMethod("BuildCurrentBody", BindingFlags.Instance | BindingFlags.NonPublic).Invoke(restored, null);
                check(ColumnJson.Integer(ColumnJson.Object(ColumnJson.Parse(beforeReview)), "expectedVersion") == original && !Save(restored).IsEnabled,
                    "restored row intent never silently adopts a fresh server version");
                Field<Button>(restored, "review").RaiseEvent(new RoutedEventArgs(Button.ClickEvent)); PumpUntil(() => Save(restored).IsEnabled);
                Save(restored).RaiseEvent(new RoutedEventArgs(Button.ClickEvent)); PumpUntil(() => restored.SavedRow != null);
                check(fixture.Handler.StoredValues[ColumnServiceContractChecks.NumberId] == "9" && fixture.Handler.StoredValues[ColumnServiceContractChecks.TextId] == "他人后来修改的字段",
                    "explicit recovery review applies selected old target and preserves unselected current fields");
            }
            return count;
        }
        private static T Field<T>(object window, string name) where T : class { return (T)window.GetType().GetField(name, BindingFlags.Instance | BindingFlags.NonPublic).GetValue(window); }
        private static Button Save(DurableDraftDialog window) { return (Button)typeof(DurableDraftDialog).GetProperty("SubmitButton", BindingFlags.Instance | BindingFlags.NonPublic).GetValue(window, null); }
        private static T Await<T>(Task<T> task) { PumpUntil(() => task.IsCompleted); return task.GetAwaiter().GetResult(); }
        private static void CloseAndWait(Window window) { bool closed = false; window.Closed += (sender, args) => closed = true; window.Close(); PumpUntil(() => closed); }
        private static void PumpUntil(Func<bool> condition)
        {
            var frame = new DispatcherFrame(); var watch = System.Diagnostics.Stopwatch.StartNew(); var timer = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(10) };
            timer.Tick += (sender, args) => { if (condition() || watch.Elapsed > TimeSpan.FromSeconds(10)) frame.Continue = false; };
            timer.Start(); try { Dispatcher.PushFrame(frame); } finally { timer.Stop(); }
            if (!condition()) throw new InvalidOperationException("Private native columns fixture timed out.");
        }
        private static void Snapshot(Window window, string name)
        {
            var content = (FrameworkElement)window.Content; content.Measure(new Size(window.Width, Double.PositiveInfinity)); content.Arrange(new Rect(0, 0, window.Width, content.DesiredSize.Height)); content.UpdateLayout();
            var frame = new DispatcherFrame(); Dispatcher.CurrentDispatcher.BeginInvoke(DispatcherPriority.Background, new Action(() => frame.Continue = false)); Dispatcher.PushFrame(frame); content.UpdateLayout();
            var bitmap = new RenderTargetBitmap((int)Math.Ceiling(content.ActualWidth), (int)Math.Ceiling(content.ActualHeight), 96, 96, PixelFormats.Pbgra32); bitmap.Render(content);
            var encoder = new PngBitmapEncoder(); encoder.Frames.Add(BitmapFrame.Create(bitmap)); using (var file = File.Create(Path.Combine(AppDomain.CurrentDomain.BaseDirectory, name))) encoder.Save(file);
        }
    }
}
