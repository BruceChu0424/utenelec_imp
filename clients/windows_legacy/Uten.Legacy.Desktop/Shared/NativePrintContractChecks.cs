using System;
using System.Collections.Generic;
using System.Globalization;
using System.Linq;
using System.Net;
using System.Net.Http;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;
using System.Threading.Tasks;
using System.Web.Script.Serialization;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Documents;
using System.Windows.Media;
using System.Windows.Threading;
using Uten.Legacy.Core;
using Uten.Legacy.Core.Tests;
using Uten.Legacy.Desktop.Features.Units;

namespace Uten.Legacy.Desktop.Shared
{
    public static class NativePrintContractChecks
    {
        public static int Run()
        {
            int assertions = 0;
            Action<bool, string> check = (value, label) => { if (!value) throw new InvalidOperationException("Native print: " + label); assertions++; };
            Task task = null;
            Dispatcher.CurrentDispatcher.BeginInvoke(new Action(() => task = RunAsync(check)));
            var frame = new DispatcherFrame(); var timer = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(10) };
            var deadline = System.Diagnostics.Stopwatch.StartNew();
            timer.Tick += (sender, args) => { if (task != null && task.IsCompleted || deadline.Elapsed > TimeSpan.FromSeconds(30)) frame.Continue = false; };
            timer.Start(); try { Dispatcher.PushFrame(frame); } finally { timer.Stop(); }
            if (task == null || !task.IsCompleted) throw new InvalidOperationException("Native print fixture timed out.");
            task.GetAwaiter().GetResult(); return assertions;
        }
        private static async Task RunAsync(Action<bool, string> check)
        {
            await CompleteSequences(check);
            var source = new List<IReadOnlyList<string>>();
            for (int row = 0; row < 250; row++) source.Add(Array.AsReadOnly(new[] {
                "U" + row.ToString("D4"), row == 249 ? "末行不可丢失·龘" : "单位中文原文 " + row, "使用" }));
            bool current = true;
            var document = await NativeTableDocument.CreateAsync("单位资料", "当前筛选的完整结果",
                Array.AsReadOnly(new[] { "编号", "单位名称", "状态" }), source, new double[] { 120, 220, 72 }, () => current, CancellationToken.None);
            check(document.PageCount > 1 && document.RowCount == 250, "all members paginate");
            var font = new Typeface(NativeTableDocument.FullChineseFont(), FontStyles.Normal, FontWeights.Normal, FontStretches.Normal);
            GlyphTypeface glyph;
            check(font.TryGetGlyphTypeface(out glyph) && glyph.FontUri.OriginalString.ToLowerInvariant().Contains("printassets/notosansscfull.ttf")
                && glyph.CharacterToGlyphMap.ContainsKey(0x9f98), "complete Chinese font is private embedded print asset");
            var printedRows = new List<string>();
            for (int index = 0; index < document.PageCount; index++)
            {
                var page = document.GetPage(index);
                foreach (var text in Visuals<TextBlock>(page.Visual)) if (text.Text.StartsWith("U", StringComparison.Ordinal)) printedRows.Add(text.Text);
            }
            check(printedRows.Count == 250 && printedRows.Distinct().Count() == 250, "no missing or duplicated paper rows");
            check(Visuals<TextBlock>(document.GetPage(document.PageCount - 1).Visual).Any(text => text.Text == "末行不可丢失·龘"), "last row verbatim on final page");
            check(document.GetPage(document.PageCount) == DocumentPage.Missing, "page range never fabricates pages");
            var cancel = new Destination { Decision = false };
            check(!NativePrintGate.Submit(document, "单位资料", () => current, cancel) && cancel.Submissions == 0, "native dialog cancellation is not delivery");
            var changed = new Destination { OnChoose = () => current = false };
            try { NativePrintGate.Submit(document, "单位资料", () => current, changed); throw new InvalidOperationException("Expected retired print gate."); }
            catch (ApiException error) { check(error.Code == "READ_SCOPE_CHANGED" && changed.Submissions == 0, "owner retired during native selector sends nothing"); }
            current = true;
            var accepted = new Destination();
            check(NativePrintGate.Submit(document, "单位资料", () => current, accepted) && accepted.Submissions == 1, "explicit accepted selection submits once to queue adapter");
            var range = new SelectedPagesPaginator(document, 1, 1, new Size(800, 500));
            check(range.PageCount == 1 && range.GetPage(0).Size == new Size(800, 500) && range.GetPage(1) == DocumentPage.Missing, "range is bounded and fits chosen paper");
            try { new SelectedPagesPaginator(document, document.PageCount, 1, new Size(800, 500)); throw new InvalidOperationException("Expected range rejection."); }
            catch (ArgumentException) { check(true, "out-of-range not silently truncated"); }
            current = false;
            try { range.GetPage(0); throw new InvalidOperationException("Expected retired paginator."); }
            catch (ApiException) { check(true, "late spool page cannot read retired data"); }
            await PrintViewPermissionAndAllPages(check);
        }
        private static async Task CompleteSequences(Action<bool, string> check)
        {
            var sizes = new List<int>();
            var result = await CompletePagedSnapshot.ReadAsync((page, size, token) =>
            {
                sizes.Add(size);
                return Task.FromResult(new SnapshotPage<string> { Page = page, Size = 2, Total = 5, TotalPages = 3,
                    Items = page == 1 ? new[] { "1", "2" } : page == 2 ? new[] { "3", "4" } : new[] { "5" } });
            }, id => id, () => true, CancellationToken.None);
            check(result.SequenceEqual(new[] { "1", "2", "3", "4", "5" }) && sizes.Count == 3 && sizes.All(value => value == 100), "server size clamp respected");
            foreach (string failure in new[] { "duplicate", "missing", "drift", "empty", "oversized" })
            {
                try
                {
                    await CompletePagedSnapshot.ReadAsync((page, size, token) => Task.FromResult(new SnapshotPage<string> {
                        Page = page, Size = 2, Total = failure == "oversized" ? 100001 : failure == "drift" && page == 2 ? 3 : 4,
                        TotalPages = failure == "oversized" ? 50001 : 2,
                        Items = page == 1 ? new[] { "1", "2" } : failure == "duplicate" ? new[] { "2", "4" }
                            : failure == "missing" ? new[] { "3" } : failure == "empty" ? new string[0] : new[] { "3", "4" }
                    }), id => id, () => true, CancellationToken.None);
                    throw new InvalidOperationException("Expected complete snapshot rejection.");
                }
                catch (ApiException) { check(true, failure + " cannot publish a partial snapshot"); }
            }
            try
            {
                await CompletePagedSnapshot.ReadAsync((page, size, token) => Task.FromResult(new SnapshotPage<string> {
                    Page = 1, Size = 100, Total = 1, TotalPages = 1, Items = new[] { "large" }
                }), id => id, () => true, CancellationToken.None, measureBytes: value => 100, maximumBytes: 64);
                throw new InvalidOperationException("Expected text budget rejection.");
            }
            catch (ApiException error) { check(error.Code == "SNAPSHOT_TOO_LARGE", "text bound applied while collecting"); }
            var selection = new PersistentRowSelection<string>(value => value);
            selection.Remember("first-page"); selection.Remember("next-page");
            check(selection.Count == 2 && selection.Contains("first-page"), "pagination retains membership");
            selection.Forget("next-page"); selection.Clear(); check(selection.Count == 0, "query retirement can clear all selection");
        }
        private static async Task PrintViewPermissionAndAllPages(Action<bool, string> check)
        {
            using (var state = new BusinessStateTestFixture())
            {
                int pages = 0, writes = 0;
                var config = new ClientConfiguration(new[] { new ServerEndpoint("print", "Fixture", "https://print.company.test/api") }, "print");
                using (var session = new SessionCoordinator(config, new Handler((request, token) =>
                {
                    string body;
                    if (request.RequestUri.AbsolutePath.EndsWith("/auth/login"))
                        body = "{\"accessToken\":\"access.fixture\",\"refreshToken\":\"refresh.fixture\",\"expiresIn\":900,\"user\":{\"id\":\"print-user\",\"loginAccount\":\"fixture\","
                            + "\"superAdmin\":false,\"mustChangePassword\":false,\"permissions\":[\"unit:view\"],\"businessDatasetId\":\"00000000-0000-0000-0000-000000000001\",\"businessResetGeneration\":0}}";
                    else
                    {
                        if (request.Method != HttpMethod.Get) { writes++; throw new InvalidOperationException("No print business write expected."); }
                        pages++;
                        int page = Int32.Parse(Regex.Match(request.RequestUri.Query, @"[?&]page=(\d+)").Groups[1].Value, CultureInfo.InvariantCulture);
                        var rows = new List<object>();
                        for (int id = (page - 1) * 100 + 1; id <= Math.Min(page * 100, 205); id++)
                            rows.Add(new { id = new Guid(id, 0, 0, new byte[8]).ToString("D"), code = "U" + id, name = "单位" + id, status = "使用" });
                        body = new JavaScriptSerializer().Serialize(new { items = rows, page, size = 100, total = 205, totalPages = 3 });
                    }
                    return Task.FromResult(new HttpResponseMessage(HttpStatusCode.OK) { Content = new StringContent(body, Encoding.UTF8, "application/json") });
                }), new MemoryStore(), state.Store))
                {
                    await session.LoginAsync("fixture", "fixture-password", CancellationToken.None);
                    var snapshot = await UnitPrintSnapshot.LoadAsync(session, new UnitQuery(), CancellationToken.None);
                    check(snapshot.Rows.Count == 205 && pages == 3 && writes == 0 && snapshot.IsCurrent(session), "view-only full print uses all scoped pages, never export authority");
                }
            }
        }
        private static IEnumerable<T> Visuals<T>(DependencyObject root) where T : DependencyObject
        {
            if (root is T value) yield return value;
            for (int index = 0; index < VisualTreeHelper.GetChildrenCount(root); index++)
                foreach (var child in Visuals<T>(VisualTreeHelper.GetChild(root, index))) yield return child;
        }
        private sealed class Destination : INativePrintDestination
        {
            internal bool Decision = true; internal Action OnChoose; internal int Submissions;
            public bool Choose(int pages) { OnChoose?.Invoke(); return Decision; }
            public void Submit(DocumentPaginator paginator, string title) { var page = paginator.GetPage(0); if (page == DocumentPage.Missing) throw new InvalidOperationException(); Submissions++; }
        }
        private sealed class Handler : HttpMessageHandler
        {
            private readonly Func<HttpRequestMessage, CancellationToken, Task<HttpResponseMessage>> send;
            internal Handler(Func<HttpRequestMessage, CancellationToken, Task<HttpResponseMessage>> send) { this.send = send; }
            protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken token) { return send(request, token); }
        }
        private sealed class MemoryStore : ISessionStore
        {
            private StoredSession active;
            public StoredSession Load() => active; public void Save(StoredSession session) { active = session; }
            public void Clear() { active = null; } public void EndSession(StoredSession session) { active = null; }
            public void EnqueueRevocation(StoredSession session) { } public IList<StoredSession> PendingRevocations() => new List<StoredSession>();
            public void AcknowledgeRevocation(string id) { }
        }
    }
}
