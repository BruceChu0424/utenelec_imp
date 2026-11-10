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
using System.Windows.Controls.Primitives;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Threading;
using Uten.Legacy.Core;
using Uten.Legacy.Desktop;
using Uten.Legacy.Desktop.Controls;
using Uten.Legacy.Desktop.Features.Units;
using Uten.Legacy.Desktop.Features.Goods;
using Uten.Legacy.Desktop.Features.Publish;
using Uten.Legacy.Core.Tests;
using Uten.Legacy.Desktop.Views;
using Uten.Legacy.Desktop.Shared;

namespace Uten.Legacy.Tests
{
    internal static class UiContractChecks
    {
        internal static int RunTableContentFit()
        {
            if (Application.Current == null)
            {
                var application = new App(); application.InitializeComponent();
                application.ShutdownMode = ShutdownMode.OnExplicitShutdown;
            }
            int checks = 0;
            Action<bool, string> check = (value, message) =>
            {
                if (!value) throw new InvalidOperationException(message);
                checks++;
            };
            var table = new UtenDataGrid();
            var plain = new DataGridTemplateColumn { Header = "列", CellTemplate = TableContentTemplate("Text", 0) };
            var withCellIcon = new DataGridTemplateColumn { Header = "列", CellTemplate = TableContentTemplate("Text", 28) };
            var header = new DataGridTextColumn { Header = "状态" };
            var withHeaderIcon = new DataGridTextColumn { Header = "状态", HeaderTemplate = TableContentTemplate(".", 20) };
            var explicitWidth = new DataGridTextColumn { Header = "手动列宽", Width = 132 };
            var input = new DataGridTemplateColumn { Header = "列宽（留空自适应）",
                CellTemplate = new DataTemplate { VisualTree = new FrameworkElementFactory(typeof(TextBox)) } };
            foreach (var column in new DataGridColumn[] { plain, withCellIcon, header, withHeaderIcon, explicitWidth, input })
                table.Columns.Add(column);
            var records = Enumerable.Range(0, 10000).Select(index =>
                new TableFitRow { Text = index == 9999 ? "末行完整" : "等待计划下单" }).ToArray();
            table.ItemsSource = records;
            var window = new Window { Content = table, Width = 900, Height = 330, WindowStyle = WindowStyle.None,
                Opacity = 0, ShowActivated = false, ShowInTaskbar = false };
            try
            {
                window.Show(); Pump(window);
                check(table.ColumnWidth.IsAuto && table.EnableRowVirtualization && table.EnableColumnVirtualization
                    && ScrollViewer.GetCanContentScroll(table), "Uten tables default to content sizing and native virtualization.");
                check(withCellIcon.ActualWidth - plain.ActualWidth >= 27, "Cell width includes the rendered icon and its gap.");
                check(withHeaderIcon.ActualWidth - header.ActualWidth >= 19, "Header width includes the rendered icon and its gap.");
                var cell = input.GetCellContent(records[0]);
                var field = cell == null ? null : FindVisual<TextBox>(cell, editor => true);
                check(field != null && field.ActualWidth >= input.ActualWidth - 25,
                    "An empty editor fills the usable part of its content-fitted cell.");
                check(table.Items.Count == records.Length && table.ItemContainerGenerator.ContainerFromIndex(9000) == null,
                    "Measuring the table leaves offscreen rows virtualized and preserves every row.");
                var leftHeader = FindVisual<DataGridColumnHeader>(table, item => item.Column == explicitWidth);
                var rightHeader = FindVisual<DataGridColumnHeader>(table, item => item.Column == input);
                var leftHandle = (Thumb)leftHeader.Template.FindName("PART_RightHeaderGripper", leftHeader);
                var rightHandle = (Thumb)rightHeader.Template.FindName("PART_LeftHeaderGripper", rightHeader);
                var divider = leftHeader.TranslatePoint(new Point(leftHeader.ActualWidth, leftHeader.ActualHeight / 2), table);
                check(ResizeHandleAt(table, new Point(divider.X - 9, divider.Y)) == leftHandle
                    && ResizeHandleAt(table, new Point(divider.X + 9, divider.Y)) == rightHandle
                    && leftHandle.Cursor == Cursors.SizeWE && rightHandle.Cursor == Cursors.SizeWE,
                    "Both sides of a column divider offer an extended horizontal resize handle.");
                check(ResizeHandleAt(table, new Point(divider.X - 11, divider.Y)) == null
                    && ResizeHandleAt(table, new Point(divider.X + 11, divider.Y)) == null,
                    "The body of each header remains available for sorting or reordering.");
                rightHandle.RaiseEvent(new DragStartedEventArgs(0, 0) { RoutedEvent = Thumb.DragStartedEvent });
                rightHandle.RaiseEvent(new DragDeltaEventArgs(20, 0) { RoutedEvent = Thumb.DragDeltaEvent });
                Pump(window);
                check(explicitWidth.ActualWidth == 152, "The right side of the divider resizes the preceding column.");
                rightHandle.RaiseEvent(new DragCompletedEventArgs(20, 0, true) { RoutedEvent = Thumb.DragCompletedEvent });
                Pump(window);
                check(explicitWidth.ActualWidth == 132, "Canceling a native resize restores the original width.");
                double wide = plain.ActualWidth;
                window.Width = 240; Pump(window);
                check(FindVisual<ScrollViewer>(table, scroll => scroll.ScrollableWidth > 0) != null
                    && Math.Abs(withCellIcon.ActualWidth - plain.ActualWidth) >= 27,
                    "Narrow windows keep content and icon widths and allow horizontal scrolling.");
                table.ScrollIntoView(records.Last()); Pump(window);
                check(table.ItemContainerGenerator.ContainerFromIndex(9999) != null,
                    "The complete result can scroll to its last row.");
                window.Width = 900;
                table.ItemsSource = new[] { new TableFitRow { Text = "自制" } };
                Pump(window);
                check(plain.ActualWidth < wide - 20, "A new result shrinks automatic widths to fit its shorter content (previous "
                    + wide + ", actual " + plain.ActualWidth + ", desired " + plain.Width.DesiredValue + ").");
                check(explicitWidth.Width.IsAbsolute && explicitWidth.ActualWidth == 132, "Refitting leaves an explicit user width in place.");
            }
            finally { window.Content = null; window.Close(); }
            return checks;
        }

        private static Thumb ResizeHandleAt(UIElement table, Point point)
        {
            var element = (DependencyObject)table.InputHitTest(point);
            while (element != null && !(element is Thumb)) element = VisualTreeHelper.GetParent(element);
            return element as Thumb;
        }

        private static DataTemplate TableContentTemplate(string property, double iconWidth)
        {
            var row = new FrameworkElementFactory(typeof(StackPanel));
            row.SetValue(StackPanel.OrientationProperty, Orientation.Horizontal);
            if (iconWidth > 0)
            {
                var icon = new FrameworkElementFactory(typeof(System.Windows.Shapes.Ellipse));
                icon.SetValue(FrameworkElement.WidthProperty, iconWidth - 4);
                icon.SetValue(FrameworkElement.HeightProperty, 12.0);
                icon.SetValue(FrameworkElement.MarginProperty, new Thickness(0, 0, 4, 0));
                icon.SetValue(System.Windows.Shapes.Shape.FillProperty, Brushes.Teal);
                row.AppendChild(icon);
            }
            var text = new FrameworkElementFactory(typeof(TextBlock));
            text.SetBinding(TextBlock.TextProperty, new System.Windows.Data.Binding(property));
            row.AppendChild(text);
            return new DataTemplate { VisualTree = row };
        }

        private sealed class TableFitRow
        {
            public string Text { get; set; }
        }

        internal static void RunEntryPageScrollbars()
        {
            if (Application.Current == null)
            {
                var application = new App(); application.InitializeComponent();
                application.ShutdownMode = ShutdownMode.OnExplicitShutdown;
            }
            var configuration = new ClientConfiguration(new[] {
                new ServerEndpoint("first", "第一测试服务器", "https://first.company.test/api") }, "first");
            EntryPageScrollbars(configuration);
        }

        private static void EntryPageScrollbars(ClientConfiguration configuration)
        {
            using (var session = new SessionCoordinator(configuration, new NoNetworkHandler(), new MemoryStore()))
            using (var dashboard = new DashboardView(session, () => { }))
            {
                var canvas = new Grid { Width = 1280, HorizontalAlignment = HorizontalAlignment.Left };
                canvas.ColumnDefinitions.Add(new ColumnDefinition()); canvas.ColumnDefinitions.Add(new ColumnDefinition());
                canvas.Children.Add(dashboard);
                var editor = new ScrollViewer { Content = new Border { Height = 5000 }, VerticalScrollBarVisibility = ScrollBarVisibility.Auto };
                Grid.SetColumn(editor, 1); canvas.Children.Add(editor);
                var window = new Window { Content = canvas, Width = 1440, Height = 600, WindowStyle = WindowStyle.None,
                    Opacity = 0, ShowActivated = false, ShowInTaskbar = false };
                try
                {
                    window.Show(); Pump(window);
                    var scroll = FindVisual<ScrollViewer>(dashboard, item => UtenEntryPageScrollBehavior.GetEnabled(item));
                    if (scroll == null) throw new InvalidOperationException("The actual native dashboard must use the shared entry-page scroll behavior.");
                    var body = (StackPanel)scroll.Content;
                    var input = new TextBox { Text = "保留输入", Height = 44 }; body.Children.Add(input);
                    for (int index = 0; index < 400; index++) body.Children.Add(new Border { Height = 32 });
                    window.UpdateLayout(); Pump(window);
                    foreach (double width in new[] { 390d, 599d, 600d, 839d, 840d, 1024d, 1279d, 1280d, 1366d })
                    {
                        canvas.Width = width; window.UpdateLayout(); Pump(window);
                        bool narrow = width < (double)Application.Current.FindResource("Uten.Breakpoint.DesktopStart");
                        if (scroll.VerticalScrollBarVisibility != (narrow ? ScrollBarVisibility.Hidden : ScrollBarVisibility.Auto))
                            throw new InvalidOperationException("Dashboard rail must follow the shared full-window breakpoint at width " + width + ".");
                        if (scroll.ScrollableHeight <= 1000 || scroll.PanningMode != PanningMode.VerticalOnly)
                            throw new InvalidOperationException("Hiding the dashboard rail must retain complete content and touch panning.");
                        scroll.ScrollToTop(); Pump(window);
                        scroll.RaiseEvent(new System.Windows.Input.MouseWheelEventArgs(System.Windows.Input.Mouse.PrimaryDevice,
                            Environment.TickCount, -120) { RoutedEvent = UIElement.MouseWheelEvent });
                        Pump(window);
                        if (scroll.VerticalOffset <= 0) throw new InvalidOperationException("The dashboard must still scroll by mouse wheel without its rail.");
                        if (editor.VerticalScrollBarVisibility != ScrollBarVisibility.Auto || editor.ScrollableHeight <= 0)
                            throw new InvalidOperationException("Document viewers must keep their own vertical rail and scrolling.");
                    }
                    scroll.ScrollToVerticalOffset(700); Pump(window);
                    for (int iteration = 0; iteration < 60; iteration++)
                    { canvas.Width = iteration % 2 == 0 ? 600 : 1366; window.UpdateLayout(); Pump(window); }
                    if (Math.Abs(scroll.VerticalOffset - 700) > 1 || input.Text != "保留输入")
                        throw new InvalidOperationException("Repeated width changes must preserve dashboard position and input.");
                    // Unload/reload and disable restore the prior viewer settings without
                    // leaving a host subscription that can change an editor later.
                    canvas.Children.Remove(dashboard); Pump(window); canvas.Children.Add(dashboard); Pump(window);
                    canvas.Width = 600; window.UpdateLayout(); Pump(window);
                    if (scroll.VerticalScrollBarVisibility != ScrollBarVisibility.Hidden)
                        throw new InvalidOperationException("Reloaded dashboard must reattach its window-width subscription.");
                    UtenEntryPageScrollBehavior.SetEnabled(scroll, false);
                    if (scroll.VerticalScrollBarVisibility != ScrollBarVisibility.Auto || scroll.PanningMode != PanningMode.None)
                        throw new InvalidOperationException("Disabling entry-page policy must restore the viewer's original settings.");
                }
                finally { window.Content = null; window.Close(); }
            }
        }

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

        internal static int RunContinuousLists()
        {
            return RunContinuousListsCore(10001, false);
        }

        internal static int RunCompleteListStress(int goodsRows)
        {
            if (goodsRows != 35000 && goodsRows != 100000) throw new ArgumentOutOfRangeException(nameof(goodsRows));
            return RunContinuousListsCore(goodsRows, true);
        }

        private static int RunContinuousListsCore(int goodsRows, bool stress)
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
                int totalRows = goods ? goodsRows : 501, completeReads = (totalRows + 99) / 100;
                var handler = new SearchReadUiHandler { TotalItems = totalRows };
                using (var session = new SessionCoordinator(configuration, handler, new MemoryStore()))
                {
                    session.LoginAsync("fixture", "fixture-password", CancellationToken.None).GetAwaiter().GetResult();
                    FrameworkElement view = goods ? (FrameworkElement)new GoodsWorkspaceView(session) : new UnitsWorkspaceView(session);
                    var window = new Window { Content = view, Width = 1400, Height = 850, Opacity = 0, ShowActivated = false, ShowInTaskbar = false };
                    var held = new TaskCompletionSource<bool>();
                    var loadTime = System.Diagnostics.Stopwatch.StartNew();
                    try
                    {
                        window.Show();
                        var table = FindVisual<DataGrid>(view, item => true);
                        // A larger functional fixture gets its own explicit wait budget.
                        // The application still uses its unchanged 30-second HTTP deadline;
                        // this is not a relaxed production performance acceptance threshold.
                        PumpUntil(() => table.Items.Count == totalRows && !ReadBusy(view, goods), "All native rows must arrive before the single result is accepted.", stress ? 45 : 8);
                        loadTime.Stop();
                        check(handler.ListReads == 1 && handler.FramesRead == completeReads && handler.RequestedSizes.All(size => size == 100), "All native rows use one HTTP request with equal bounded 100-row frames.");
                        check(FindVisual<Button>(view, button => Equals(button.Content, "上一页") || Equals(button.Content, "下一页")) == null,
                            "Continuous native tables expose no page navigation buttons.");
                        check(table.EnableRowVirtualization && table.EnableColumnVirtualization, "Complete summaries retain native row and column virtualization.");
                        object source = table.ItemsSource;
                        var columns = table.Columns.ToArray();
                        int maximumRealizedRows = 0;
                        for (int index = 0; index < (stress ? 50 : 12); index++)
                        {
                            table.ScrollIntoView(table.Items[index % 2 == 0 ? totalRows - 1 : 0]); window.UpdateLayout(); Pump(window);
                            maximumRealizedRows = Math.Max(maximumRealizedRows, CountVisual<DataGridRow>(table));
                        }
                        check(handler.ListReads == 1 && ReferenceEquals(source, table.ItemsSource), "Scrolling a complete native result causes no network or ItemsSource replacement.");
                        check(table.Columns.SequenceEqual(columns), "Scrolling cannot recreate native table columns.");
                        check(maximumRealizedRows > 0 && maximumRealizedRows < 200,
                            "Actual realized row containers stay bounded by the viewport, not the complete row count.");
                        check((goods ? ((GoodsRecord)table.Items[totalRows - 1]).Id : ((UnitRecord)table.Items[totalRows - 1]).Id).EndsWith(totalRows.ToString("D12")), "The final row remains reachable with its server identity.");
                        if (stress && goods)
                        {
                            check(table.Items.Cast<GoodsRecord>().Select(item => item.Id).SequenceEqual(Enumerable.Range(1, totalRows)
                                .Select(index => "00000000-0000-4000-8000-" + index.ToString("D12"))),
                                "Every accepted stress row has the exact ordered server identity without omissions or duplicates.");
                            window.WindowState = WindowState.Minimized; PumpFor(20);
                            window.WindowState = WindowState.Normal; PumpFor(20);
                            check(ReferenceEquals(source, table.ItemsSource) && handler.ListReads == 1,
                                "Minimize/restore preserves the accepted snapshot without a new read.");
                            Console.WriteLine("OBSERVE native functional fixture rows=" + totalRows + "; completeLoadMs=" + loadTime.ElapsedMilliseconds
                                + "; realizedRowsMax=" + maximumRealizedRows + "; scrollCycles=50; httpReads=1; finalRow=" + totalRows
                                + "; no low-end hardware or production latency claim");
                        }
                        if (!goods)
                        {
                            table.SelectAll(); PumpFor(20);
                            var selection = (Uten.Legacy.Desktop.Shared.PersistentRowSelection<UnitRecord>)view.GetType()
                                .GetField("selection", System.Reflection.BindingFlags.NonPublic | System.Reflection.BindingFlags.Instance).GetValue(view);
                            check(selection.Count == 501, "Select-all retains the complete explicit selection.");
                            var batch = (Task)view.GetType().GetMethod("OpenBatchAsync", System.Reflection.BindingFlags.NonPublic | System.Reflection.BindingFlags.Instance)
                                .Invoke(view, new object[] { UnitBatchAction.Delete, null });
                            PumpUntil(() => batch.IsCompleted, "An oversized selection must be rejected locally.");
                            check(selection.Count == 501 && handler.BusinessWrites == 0, "The original 500-item command limit rejects 501 without writes, split commands or losing selection.");
                        }
                        var search = FindVisual<TextBox>(view, item => true);
                        handler.BeforeList = (uri, token) => SearchReadUiHandler.Parameter(uri, "keyword") == "held" && SearchReadUiHandler.Parameter(uri, "page") == "2" ? held.Task : Task.CompletedTask;
                        search.Text = "held"; RaiseEnter(search);
                        PumpUntil(() => handler.ListReads == 2 && handler.FramesRead == completeReads + 1, "A replacement waits for its actual held second frame in the same HTTP request.");
                        check(ReferenceEquals(source, table.ItemsSource), "An incomplete replacement cannot publish its first batch over complete accepted rows.");
                        search.Text = "replacement"; RaiseEnter(search);
                        PumpUntil(() => !ReadBusy(view, goods) && table.Items.Count == totalRows && ShownSearchName(table, goods).Contains("replacement"), "A superseding query must read and publish all its own rows.", stress ? 45 : 8);
                        int reads = handler.ListReads;
                        held.SetResult(true); PumpFor(60);
                        check(ShownSearchName(table, goods).Contains("replacement") && handler.ListReads == reads, "A retired later batch neither publishes nor dispatches the old query's remaining pages.");
                        check(reads == 3, "Initial, retired and replacement queries each send one complete HTTP request.");
                        if (goods)
                        {
                            object accepted = table.ItemsSource;
                            for (int cancellation = 0; cancellation < (stress ? 12 : 1); cancellation++)
                            {
                                int beforeRetry = handler.ListReads;
                                handler.BeforeList = (uri, token) => Task.Delay(Timeout.Infinite, token);
                                FindVisual<Button>(view, button => Equals(button.Content, "重新读取")).RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
                                PumpUntil(() => handler.ListReads == beforeRetry + 1 && !window.IsEnabled,
                                    "The actual goods retry button must own the waiting dialog while its read is blocked.");
                                var busy = Application.Current.Windows.OfType<UtenDialogWindow>()
                                    .Single(dialog => dialog.Owner == window && dialog.Title == "正在读取货品");
                                check(Application.Current.Windows.OfType<UtenDialogWindow>().Count(dialog => dialog.Owner == window && dialog.Title == "正在读取货品") == 1,
                                    "One actual retry action owns exactly one existing Uten busy dialog.");
                                FindVisual<Button>(busy, button => Equals(button.Content, "取消")).RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
                                PumpUntil(() => window.IsEnabled && !ReadBusy(view, true) && !busy.IsVisible,
                                    "Cancellation must drain the owned read and remove the waiting dialog.");
                                check(handler.ListReads == beforeRetry + 1 && ReferenceEquals(accepted, table.ItemsSource) && handler.BusinessWrites == 0,
                                    "Cancelling retry preserves the complete accepted result and never replays a write or starts tail pages.");
                                var cancelledStatus = (TextBlock)view.GetType().GetField("status", System.Reflection.BindingFlags.NonPublic | System.Reflection.BindingFlags.Instance).GetValue(view);
                                check(cancelledStatus.Text.Contains("已取消读取") && !cancelledStatus.Text.Contains("正在读取"),
                                    "Cancelled native reads must finish their visible loading state while preserving accepted rows.");
                            }
                            handler.BeforeList = null;
                        }
                        Snapshot(view, (goods ? "goods-continuous-list" : "units-continuous-list") + (stress ? "-stress-" + goodsRows : "") + ".png");
                    }
                    finally { handler.BeforeList = null; held.TrySetResult(true); window.Close(); }
                }
            }
            foreach (string defect in new[] { "scope", "total", "duplicate", "empty" })
            {
                int calls = 0;
                try
                {
                    CompletePagedSnapshot.ReadAsync<int>((page, size, token) =>
                    {
                        calls++;
                        return Task.FromResult(new SnapshotPage<int> { Items = page == 1 ? new[] { 1 } : defect == "empty" ? new int[0] : new[] { defect == "duplicate" ? 1 : 2 },
                            Page = page, Size = 1, Total = page == 2 && defect == "total" ? 3 : 2, TotalPages = page == 2 && defect == "total" ? 3 : 2,
                            ReadScopeVersion = page == 2 && defect == "scope" ? "changed" : "first" });
                    }, item => item.ToString(), () => true, CancellationToken.None).GetAwaiter().GetResult();
                    throw new InvalidOperationException("Malformed native sequence was accepted: " + defect);
                }
                catch (ApiException error) { check(error.Code == "SNAPSHOT_CHANGED" && calls == 2, "Malformed native sequences fail atomically: " + defect); }
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
            internal int FramesRead;
            internal int TotalItems = -1, BusinessWrites;
            internal readonly List<int> RequestedSizes = new List<int>();
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
                if (request.Method != HttpMethod.Get && !(request.Method == HttpMethod.Post && (path == "/api/master/goods/summaries" || path == "/api/master/units/summaries"))
                    && !path.EndsWith("/auth/login") && !path.EndsWith("/auth/refresh")) Interlocked.Increment(ref BusinessWrites);
                var serializer = new System.Web.Script.Serialization.JavaScriptSerializer();
                if (path.EndsWith("/auth/login") || path.EndsWith("/auth/refresh"))
                    body = "{\"accessToken\":\"access.fixture\",\"refreshToken\":\"refresh.fixture\",\"expiresIn\":900,\"user\":{\"id\":\"" + UserId
                        + "\",\"loginAccount\":\"fixture\",\"superAdmin\":false,\"mustChangePassword\":false,\"permissions\":[\"goods:view\",\"material_category:view\",\"unit:view\"],"
                        + "\"businessDatasetId\":\"00000000-0000-0000-0000-000000000001\",\"businessResetGeneration\":0}}";
                else if (path == "/api/master/material-categories/tree")
                    body = "[{\"id\":\"00000000-0000-4000-8000-000000000001\",\"name\":\"分类甲\",\"code\":\"A\",\"children\":[]},{\"id\":\"00000000-0000-4000-8000-000000000002\",\"name\":\"分类乙\",\"code\":\"B\",\"children\":[]}]";
                else if (path == "/api/master/units/facets")
                    body = "{\"status\":[{\"value\":\"使用\",\"count\":1},{\"value\":\"禁用\",\"count\":1}]}";
                else if (path.EndsWith("/summaries", StringComparison.Ordinal) && request.RequestUri.Query == "?complete=true")
                {
                    bool goods = path == "/api/master/goods/summaries";
                    if (request.Method != HttpMethod.Post || !request.Headers.Accept.Any(item => item.MediaType == "application/x-ndjson"))
                        throw new InvalidOperationException("Complete lists use the reviewed NDJSON POST.");
                    var query = serializer.Deserialize<Dictionary<string, object>>(await request.Content.ReadAsStringAsync());
                    var filter = (Dictionary<string, object>)query["filter"];
                    string keyword = filter.ContainsKey("keyword") ? (string)filter["keyword"] : "";
                    string category = filter.ContainsKey("categoryId") ? (string)filter["categoryId"] : "";
                    int total = TotalItems < 0 ? goods ? 20 : 1 : TotalItems;
                    string marker = keyword + "|" + category + "|" + UserId + "|v" + CommittedVersion;
                    int batches = Math.Max(1, (total + 99) / 100);
                    string scope = goods ? "goods-scope" : "unit-scope", data = new string('d', 64), revision = new string('a', 64);
                    LastQuery = "?page=1&size=100&keyword=" + Uri.EscapeDataString(keyword) + "&categoryId=" + Uri.EscapeDataString(category);
                    Interlocked.Increment(ref ListReads);
                    return Ndjson(new DeferredFrameStream(async (page, ct) => {
                        if (page > batches + 1) return null;
                        if (page == batches + 1) return serializer.Serialize(new { type = "complete", total, readScopeVersion = scope,
                            readDataVersion = data, readSnapshotRevision = revision });
                        var uri = new Uri(request.RequestUri.GetLeftPart(UriPartial.Path) + "?page=" + page + "&size=100&keyword="
                            + Uri.EscapeDataString(keyword) + "&categoryId=" + Uri.EscapeDataString(category));
                        var hold = BeforeList; if (hold != null) await hold(uri, ct);
                        ct.ThrowIfCancellationRequested();
                        Interlocked.Increment(ref FramesRead); lock (RequestedSizes) RequestedSizes.Add(100);
                        var rows = Enumerable.Range((page - 1) * 100 + 1, Math.Max(0, Math.Min(100, total - (page - 1) * 100)))
                            .Select(index => new Dictionary<string, object> { ["id"] = "00000000-0000-4000-8000-" + index.ToString("D12"),
                                ["code"] = "T" + index, ["name"] = marker, ["status"] = "使用" }).ToArray();
                        return serializer.Serialize(new { type = "page", value = new { items = rows, page, size = 100, total,
                            totalPages = (total + 99) / 100, readScopeVersion = scope, readDataVersion = data, readSnapshotRevision = revision } });
                    }));
                }
                else if (path == "/api/master/goods/summaries" || path == "/api/master/units")
                {
                    bool goodsSummary = path == "/api/master/goods/summaries";
                    var queryUri = request.RequestUri;
                    if (goodsSummary)
                    {
                        if (request.Method != HttpMethod.Post) throw new InvalidOperationException("Goods summaries require the exact read-only POST.");
                        var query = serializer.Deserialize<Dictionary<string, object>>(await request.Content.ReadAsStringAsync());
                        var filter = (Dictionary<string, object>)query["filter"];
                        queryUri = new Uri(request.RequestUri.GetLeftPart(UriPartial.Path) + "?page=" + query["page"] + "&size=" + query["size"]
                            + "&keyword=" + Uri.EscapeDataString(filter.ContainsKey("keyword") ? (string)filter["keyword"] : "")
                            + "&categoryId=" + Uri.EscapeDataString(filter.ContainsKey("categoryId") ? (string)filter["categoryId"] : ""));
                        if ((int)query["page"] > 1 && request.RequestUri.Query != "?readSnapshotRevision=" + new string('a', 64))
                            throw new InvalidOperationException("Goods tail must retain the real first snapshot proof.");
                    }
                    int snapshotVersion = CommittedVersion;
                    LastQuery = queryUri.Query; Interlocked.Increment(ref ListReads);
                    var hold = BeforeList;
                    if (hold != null) await hold(queryUri, token);
                    token.ThrowIfCancellationRequested();
                    string marker = Parameter(queryUri, "keyword") + "|" + Parameter(queryUri, "categoryId") + "|" + UserId + "|v" + snapshotVersion;
                    int page = TotalItems < 0 && !goodsSummary ? 1 : Int32.Parse(Parameter(queryUri, "page"));
                    int size = TotalItems < 0 && !goodsSummary ? 20 : Int32.Parse(Parameter(queryUri, "size"));
                    lock (RequestedSizes) RequestedSizes.Add(size);
                    int total = TotalItems < 0 ? goodsSummary ? 20 : 1 : TotalItems;
                    int start = (page - 1) * size;
                    var rows = Enumerable.Range(start + 1, Math.Max(0, Math.Min(size, total - start))).Select(index => new Dictionary<string, object> {
                        ["id"] = "00000000-0000-4000-8000-" + index.ToString("D12"), ["code"] = "T" + index, ["name"] = marker, ["status"] = "使用" }).ToArray();
                    body = serializer.Serialize(new { items = rows, page, size, total, totalPages = (total + size - 1) / size,
                        readScopeVersion = goodsSummary ? "goods-scope" : null, readDataVersion = goodsSummary ? new string('d', 64) : null,
                        readSnapshotRevision = goodsSummary ? new string('a', 64) : null });
                }
                else return new HttpResponseMessage(HttpStatusCode.NotFound) { Content = new StringContent("{\"code\":\"NOT_FOUND\",\"message\":\"fixture optional metadata unavailable\"}", Encoding.UTF8, "application/json") };
                return new HttpResponseMessage(HttpStatusCode.OK) { Content = new StringContent(body, Encoding.UTF8, "application/json") };
            }
        }

        private static HttpResponseMessage Ndjson(Stream stream)
        {
            var response = new HttpResponseMessage(HttpStatusCode.OK) { Content = new StreamContent(stream) };
            response.Content.Headers.ContentType = new System.Net.Http.Headers.MediaTypeHeaderValue("application/x-ndjson");
            return response;
        }
        private static HttpResponseMessage CompleteFixture(string pageJson)
        {
            var json = new System.Web.Script.Serialization.JavaScriptSerializer();
            var value = json.Deserialize<Dictionary<string, object>>(pageJson);
            var final = new Dictionary<string, object> { ["type"] = "complete", ["total"] = value["total"],
                ["readScopeVersion"] = value["readScopeVersion"], ["readDataVersion"] = value["readDataVersion"],
                ["readSnapshotRevision"] = value["readSnapshotRevision"] };
            return Ndjson(new MemoryStream(Encoding.UTF8.GetBytes(json.Serialize(new { type = "page", value }) + "\n" + json.Serialize(final) + "\n")));
        }
        private sealed class DeferredFrameStream : Stream
        {
            private readonly Func<int, CancellationToken, Task<string>> frame;
            private byte[] current = new byte[0]; private int offset, page = 1;
            internal DeferredFrameStream(Func<int, CancellationToken, Task<string>> frame) { this.frame = frame; }
            public override async Task<int> ReadAsync(byte[] buffer, int start, int count, CancellationToken token)
            {
                token.ThrowIfCancellationRequested();
                if (offset == current.Length)
                {
                    string value = await frame(page++, token); if (value == null) return 0;
                    current = Encoding.UTF8.GetBytes(value + "\n"); offset = 0;
                }
                int copied = Math.Min(count, current.Length - offset); Array.Copy(current, offset, buffer, start, copied); offset += copied; return copied;
            }
            public override bool CanRead => true; public override bool CanSeek => false; public override bool CanWrite => false;
            public override long Length => throw new NotSupportedException();
            public override long Position { get => throw new NotSupportedException(); set => throw new NotSupportedException(); }
            public override void Flush() { } public override int Read(byte[] buffer, int offset, int count) => ReadAsync(buffer, offset, count, CancellationToken.None).GetAwaiter().GetResult();
            public override long Seek(long offset, SeekOrigin origin) => throw new NotSupportedException();
            public override void SetLength(long value) => throw new NotSupportedException();
            public override void Write(byte[] buffer, int offset, int count) => throw new NotSupportedException();
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
                session.StartApplicationAsync(CancellationToken.None, waitForPendingRevocations: false).GetAwaiter().GetResult();
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
            WindowCloseRetiresSession(configuration);
            SessionWatchShowsOnlyForTheActiveOwner(configuration);
            PublishRetirementPreservesLatestInput(configuration);
            GoodsCurrencyUi(configuration);
            EntryPageScrollbars(configuration);
        }

        internal static void RunSessionLifecycle()
        {
            if (Application.Current == null)
            {
                var application = new App(); application.InitializeComponent();
                application.ShutdownMode = ShutdownMode.OnExplicitShutdown;
            }
            WindowCloseRetiresSession(new ClientConfiguration(new[] {
                new ServerEndpoint("first", "第一测试服务器", "https://first.company.test/api") }, "first"));
            SessionWatchShowsOnlyForTheActiveOwner(new ClientConfiguration(new[] {
                new ServerEndpoint("first", "第一测试服务器", "https://first.company.test/api") }, "first"));
            PublishRetirementPreservesLatestInput(new ClientConfiguration(new[] {
                new ServerEndpoint("first", "第一测试服务器", "https://first.company.test/api") }, "first"));
        }

        private static void PublishRetirementPreservesLatestInput(ClientConfiguration configuration)
        {
            foreach (var blocked in new[] { false, true })
            using (var state = new BusinessStateTestFixture())
            {
                var handler = new WatchUiHandler();
                var store = new DpapiPublishDraftStore(System.IO.Path.Combine(state.RootDirectory, "publish"));
                using (var session = new SessionCoordinator(configuration, handler, new MemoryStore()))
                {
                    session.LoginAsync("fixture", "fixture-password", CancellationToken.None).GetAwaiter().GetResult();
                    var main = new MainWindow(session, configuration, true) { Opacity = 0, ShowActivated = false, ShowInTaskbar = false };
                    var view = new ClientReleasePublishView(session, store);
                    var flags = System.Reflection.BindingFlags.Instance | System.Reflection.BindingFlags.NonPublic;
                    System.IO.FileStream locked = null; bool closed = false; main.Closed += (sender, args) => closed = true;
                    try
                    {
                        main.Show(); Pump(main);
                        typeof(MainWindow).GetMethod("ApplySession", System.Reflection.BindingFlags.Instance | System.Reflection.BindingFlags.NonPublic | System.Reflection.BindingFlags.DeclaredOnly).Invoke(main, null);
                        Pump(main);
                        ((ContentControl)main.FindName("WorkspaceContent")).Content = view;
                        PumpUntil(() => (bool)typeof(ClientReleasePublishView).GetField("ready", flags).GetValue(view), "Private native publish view must initialize its original-owner lease.");
                        var notes = (TextBox)typeof(ClientReleasePublishView).GetField("releaseNotes", flags).GetValue(view);
                        var save = typeof(ClientReleasePublishView).GetMethod("SaveDraft", flags);
                        var lease = (ClientReleasePublishDraftLease)typeof(ClientReleasePublishView).GetField("lease", flags).GetValue(view);
                        notes.Text = "previously saved"; save.Invoke(view, null);
                        var path = System.IO.Path.Combine(state.RootDirectory, "publish", lease.NamespaceHash, lease.DraftId + ".dpapi");
                        if (blocked) locked = new System.IO.FileStream(path, System.IO.FileMode.Open, System.IO.FileAccess.ReadWrite, System.IO.FileShare.None);
                        notes.Text = "  最新尚未经过防抖的发布说明  ";
                        var watched = Task.Run(() => session.WatchSessionAsync(CancellationToken.None));
                        PumpUntil(() => handler.Watches == 1, "Background watch must subscribe before replacement.");
                        handler.WatchReply.SetResult(new HttpResponseMessage(HttpStatusCode.OK) { Content = new StringContent(
                            "{\"status\":\"replaced\",\"code\":\"SESSION_REPLACED\",\"message\":\"fixture replacement\"}", Encoding.UTF8, "application/json") });
                        PumpUntil(() => watched.IsCompleted && (bool)typeof(ClientReleasePublishView).GetField("disposed", flags).GetValue(view), "Background replacement must retire and dispose the original publish workspace on its dispatcher.");
                        watched.GetAwaiter().GetResult();
                        if (blocked)
                        {
                            main.Close();
                            if (closed) throw new InvalidOperationException("Publish preservation failure must retain a global owner-close guard and the last input.");
                            locked.Dispose(); locked = null;
                            var guard = Application.Current.Windows.OfType<Window>().Single(item => item.Title == "发布草稿保全");
                            var retry = FindVisual<Button>(guard, item => Equals(item.Content, "重试保全并关闭"));
                            retry.RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
                            for (int repeat = 0; repeat < 20; repeat++) retry.RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
                            if (retry.IsEnabled || !Application.Current.Windows.OfType<Window>().Any(item => item.Title == "正在保全发布草稿"))
                                throw new InvalidOperationException("Native preservation retry must show its owned waiting dialog and guard repeat clicks while disk IO runs off the dispatcher.");
                            PumpUntil(() => !Application.Current.Windows.OfType<Window>().Any(item => item.Title == "发布草稿保全"), "Retry must preserve the original lease before releasing its owner guard.");
                        }
                        var raw = store.Read(lease.NamespaceHash + "/" + lease.DraftId);
                        var snapshot = ClientReleasePublishContract.ValidateAndRestore(raw);
                        if ((string)snapshot.Context["releaseNotes"] != "  最新尚未经过防抖的发布说明  ")
                            throw new InvalidOperationException("Real-time native retirement must retain the latest undebounced original-owner publish input.");
                        handler.UserId = "different-publisher";
                        session.LoginAsync("next", "fixture-password", CancellationToken.None).GetAwaiter().GetResult();
                        var nextNamespace = ClientReleasePublishDraftLease.ComputeNamespaceHash(session.CurrentEndpoint.ApiBaseUrl, session.CurrentUser);
                        if (store.List(nextNamespace).Count != 0 || store.Read(lease.NamespaceHash + "/" + lease.DraftId) != raw)
                            throw new InvalidOperationException("Retired publish metadata must never migrate into or overwrite a new account namespace.");
                    }
                    finally
                    {
                        locked?.Dispose();
                        typeof(ClientReleasePublishView).GetMethod("SaveDraft", flags).Invoke(view, null);
                        Pump(main); if (!closed) main.Close(); view.Dispose();
                    }
                }
            }
        }

        private static void SessionWatchShowsOnlyForTheActiveOwner(ClientConfiguration configuration)
        {
            var handler = new WatchUiHandler();
            using (var session = new SessionCoordinator(configuration, handler, new MemoryStore()))
            {
                var window = new MainWindow(session, configuration) { Opacity = 0, ShowActivated = false, ShowInTaskbar = false };
                // Exercise the actual loaded native owner and its watch. Skip only the
                // production update-outcome/profile startup reads in this private fixture.
                window.Loaded -= (RoutedEventHandler)Delegate.CreateDelegate(typeof(RoutedEventHandler), window,
                    typeof(MainWindow).GetMethod("OnLoaded", System.Reflection.BindingFlags.Instance | System.Reflection.BindingFlags.NonPublic | System.Reflection.BindingFlags.DeclaredOnly));
                bool popupObserved = false;
                var dismiss = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(20) };
                dismiss.Tick += (sender, args) =>
                {
                    var popup = Application.Current.Windows.OfType<Window>().FirstOrDefault(value => value.Title == "当前设备已下线");
                    if (popup == null) return;
                    popupObserved = true;
                    var reason = FindVisual<TextBlock>(popup, value => value.Text.Contains("Android 测试设备"));
                    if (reason == null) throw new InvalidOperationException("Native replacement popup must preserve the authoritative device name.");
                    popup.Close();
                };
                try
                {
                    window.Show(); Pump(window);
                    if (handler.Watches != 0 || session.IsAuthenticated)
                        throw new InvalidOperationException("An untouched native login window must never start an authenticated watch or popup.");
                    session.LoginAsync("fixture", "fixture-password", CancellationToken.None).GetAwaiter().GetResult();
                    PumpUntil(() => handler.Watches == 1, "The native owner must start one watch after login without a manual refresh.");
                    HumanActivityPulsesOnlyForRecentOwnedInput(window, handler);
                    dismiss.Start();
                    handler.WatchReply.SetResult(new HttpResponseMessage(HttpStatusCode.OK) { Content = new StringContent(
                        "{\"status\":\"replaced\",\"code\":\"SESSION_REPLACED\",\"message\":\"账号已在 Android 测试设备登录，本设备已自动下线\"}", Encoding.UTF8, "application/json") });
                    PumpUntil(() => popupObserved && !session.IsAuthenticated, "A server replacement must retire and notify the active native owner without a manual refresh.");
                    if (((FrameworkElement)window.FindName("WorkspacePanel")).Visibility != Visibility.Collapsed)
                        throw new InvalidOperationException("Native replacement must retire the previous workspace before displaying the notice.");
                }
                finally { dismiss.Stop(); window.Close(); }
            }
        }

        private static void HumanActivityPulsesOnlyForRecentOwnedInput(MainWindow window, WatchUiHandler handler)
        {
            var flags = System.Reflection.BindingFlags.Instance | System.Reflection.BindingFlags.NonPublic | System.Reflection.BindingFlags.DeclaredOnly;
            var inputTime = typeof(MainWindow).GetField("lastHumanInput", flags);
            var pulseMethod = typeof(MainWindow).GetMethod("PulseHumanActivityAsync", flags);
            var recordMethod = typeof(MainWindow).GetMethod("RecordHumanInput", flags);
            Func<Task> pulse = () => (Task)pulseMethod.Invoke(window, null);
            Action<DependencyObject> wheelInput = target => InputManager.Current.ProcessInput(new MouseWheelEventArgs(Mouse.PrimaryDevice, Environment.TickCount, 120)
                { RoutedEvent = Mouse.PreviewMouseWheelEvent, Source = target });
            var timer = (DispatcherTimer)typeof(MainWindow).GetField("activityPulse", flags).GetValue(window);
            if (timer.Interval != TimeSpan.FromSeconds(30)) throw new InvalidOperationException("Native activity renewal must retain its 30-second cadence.");
            inputTime.SetValue(window, 0L);
            pulse().GetAwaiter().GetResult();
            if (handler.ActivityPulses != 0) throw new InvalidOperationException("An idle native watch must never renew human activity.");
            wheelInput(window);
            pulse().GetAwaiter().GetResult();
            if (handler.ActivityPulses != 1) throw new InvalidOperationException("Real InputManager mouse input in the owner must permit one human activity pulse.");
            inputTime.SetValue(window, System.Diagnostics.Stopwatch.GetTimestamp() - System.Diagnostics.Stopwatch.Frequency * 31L);
            pulse().GetAwaiter().GetResult();
            if (handler.ActivityPulses != 1) throw new InvalidOperationException("Expired local input must never extend the server idle lifetime.");
            var child = new Window { Owner = window, Content = new TextBox(), Width = 160, Height = 80, Opacity = 0, ShowActivated = false, ShowInTaskbar = false };
            var unrelated = new Window { Content = new TextBox(), Width = 160, Height = 80, Opacity = 0, ShowActivated = false, ShowInTaskbar = false };
            try
            {
                child.Show(); unrelated.Show();
                inputTime.SetValue(window, 0L);
                // A synthetic mouse report is retargeted to the physical pointer by WPF's
                // input manager. Check explicit source ownership at the shared handler
                // boundary, while the owner case above exercises actual ProcessInput.
                recordMethod.Invoke(window, new object[] { new MouseWheelEventArgs(Mouse.PrimaryDevice, Environment.TickCount, 120)
                    { RoutedEvent = Mouse.PreviewMouseWheelEvent, Source = (DependencyObject)unrelated.Content } });
                pulse().GetAwaiter().GetResult();
                if (handler.ActivityPulses != 1) throw new InvalidOperationException("An unrelated native window must not renew this login.");
                wheelInput((DependencyObject)child.Content);
                handler.ActivityReply = new TaskCompletionSource<HttpResponseMessage>();
                var pending = pulse();
                for (int repeat = 0; repeat < 30; repeat++) pulse().GetAwaiter().GetResult();
                if (handler.ActivityPulses != 2 || pending.IsCompleted)
                    throw new InvalidOperationException("Owned-dialog input must renew once while rapid duplicate activity ticks remain single-flight.");
                handler.ActivityReply.SetResult(new HttpResponseMessage(HttpStatusCode.OK) { Content = new StringContent("{}", Encoding.UTF8, "application/json") });
                PumpUntil(() => pending.IsCompleted, "The owned activity pulse must finish without losing its login scope.");
                pending.GetAwaiter().GetResult(); handler.ActivityReply = null;
            }
            finally { child.Close(); unrelated.Close(); }
        }

        private sealed class WatchUiHandler : HttpMessageHandler
        {
            internal int Watches;
            internal int ActivityPulses;
            internal string UserId = "fixture-user";
            internal TaskCompletionSource<HttpResponseMessage> ActivityReply;
            internal readonly TaskCompletionSource<HttpResponseMessage> WatchReply = new TaskCompletionSource<HttpResponseMessage>();
            protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken)
            {
                var path = request.RequestUri.AbsolutePath;
                if (path.EndsWith("/auth/session/watch")) { Interlocked.Increment(ref Watches); return WatchReply.Task; }
                if (path.EndsWith("/auth/me"))
                {
                    if (request.Headers.Contains("X-Uten-Automatic") || request.Headers.Authorization?.Parameter != "access-watch-ui")
                        throw new InvalidOperationException("A recent human activity pulse must use the current staff bearer without the automatic header.");
                    Interlocked.Increment(ref ActivityPulses);
                    if (ActivityReply != null) return ActivityReply.Task;
                }
                var body = path.EndsWith("/auth/login")
                    ? "{\"accessToken\":\"access-watch-ui\",\"refreshToken\":\"refresh-watch-ui\",\"expiresIn\":900,\"user\":{\"id\":\"" + UserId + "\",\"loginAccount\":\"fixture\",\"superAdmin\":false,\"businessDatasetId\":\"11111111-1111-1111-1111-111111111111\",\"businessResetGeneration\":0,\"permissions\":[\"client_release:publish\"]}}"
                    : path.EndsWith("/auth/logout") ? "{}" : path.EndsWith("/admin/client-releases") ? "[]" : "{\"metrics\":[],\"todos\":[]}";
                return Task.FromResult(new HttpResponseMessage(HttpStatusCode.OK) { Content = new StringContent(body, Encoding.UTF8, "application/json") });
            }
        }

        private static void WindowCloseRetiresSession(ClientConfiguration configuration)
        {
            var store = new MemoryStore();
            var handler = new WindowSessionHandler();
            using (var session = new SessionCoordinator(configuration, handler, store))
            {
                // Construct the real owner, but do not run startup/update-outcome disk reads.
                var window = new MainWindow(session, configuration);
                session.LoginAsync("fixture", "fixture-password", CancellationToken.None).GetAwaiter().GetResult();
                window.WindowState = WindowState.Minimized;
                if (!session.IsAuthenticated || store.Load() == null || handler.Logouts != 0)
                    throw new InvalidOperationException("Minimizing the native owner must preserve its live login.");
                window.Close();
                if (session.IsAuthenticated || store.Load() != null || store.PendingRevocations().Count != 1)
                    throw new InvalidOperationException("Closing the native owner must retire local login before the server reply.");
                if (handler.Logouts != 1 || window.CloseSessionTask.IsCompleted)
                    throw new InvalidOperationException("Normal native close must begin one issuer-bound revocation attempt.");
                handler.LogoutReply.SetResult(new HttpResponseMessage(HttpStatusCode.NoContent));
                PumpUntil(() => window.CloseSessionTask.IsCompleted, "Closing must finish its acknowledged revocation.");
                window.CloseSessionTask.GetAwaiter().GetResult();
                if (store.PendingRevocations().Count != 0)
                    throw new InvalidOperationException("Acknowledged native close must clear its exact queued revocation.");
            }
        }

        private sealed class WindowSessionHandler : HttpMessageHandler
        {
            internal int Logouts;
            internal readonly TaskCompletionSource<HttpResponseMessage> LogoutReply = new TaskCompletionSource<HttpResponseMessage>();
            protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken)
            {
                if (request.RequestUri.AbsolutePath.EndsWith("/auth/login"))
                    return Task.FromResult(new HttpResponseMessage(HttpStatusCode.OK) { Content = new StringContent(
                        "{\"accessToken\":\"access-window\",\"refreshToken\":\"refresh-window\",\"expiresIn\":900,"
                        + "\"user\":{\"id\":\"fixture-user\",\"loginAccount\":\"fixture\",\"superAdmin\":false,\"permissions\":[]}}",
                        Encoding.UTF8, "application/json") });
                if (!request.RequestUri.AbsolutePath.EndsWith("/auth/logout") || request.Headers.Authorization != null)
                    throw new InvalidOperationException("Native window close must send only its issuer-bound logout without bearer.");
                Interlocked.Increment(ref Logouts);
                return LogoutReply.Task;
            }
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
                else if (path == "/api/master/goods/summaries" && request.Method == HttpMethod.Post) body = "{\"items\":[" + string.Join(",", Enumerable.Range(0, 20).Select(Record))
                    + "],\"page\":1,\"size\":100,\"total\":20,\"totalPages\":1,\"readScopeVersion\":\"goods-currency\",\"readDataVersion\":\"" + new string('d', 64)
                    + "\",\"readSnapshotRevision\":\"" + new string('a', 64) + "\"}";
                else if (path.StartsWith("/api/master/goods/", StringComparison.Ordinal))
                    body = Record(int.Parse(path.Substring(path.Length - 12), System.Globalization.CultureInfo.InvariantCulture) - 1);
                else throw new InvalidOperationException("Unexpected private goods currency UI fixture request.");
                if (path == "/api/master/goods/summaries" && request.RequestUri.Query == "?complete=true") return Task.FromResult(CompleteFixture(body));
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
                        Task.Run(() => session.WatchSessionAsync(CancellationToken.None)).GetAwaiter().GetResult();
                        if (session.IsAuthenticated) throw new InvalidOperationException("The background replacement watch must retire the draft owner's login.");
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
                    var tableHost = new Window { Content = view, Width = 1100, Height = 640,
                        Opacity = 0, ShowActivated = false, ShowInTaskbar = false };
                    try
                    {
                        int previousReads = handler.UnitListReads;
                        var unmountedRead = (Task)typeof(UnitsWorkspaceView).GetMethod("LoadPageAsync",
                            System.Reflection.BindingFlags.Instance | System.Reflection.BindingFlags.NonPublic)
                            .Invoke(view, new object[] { 1 });
                        unmountedRead.GetAwaiter().GetResult();
                        if (view.IsLoaded || handler.UnitListReads != previousReads)
                            throw new InvalidOperationException("An unmounted native workspace must not dispatch business reads.");
                        // Raising Loaded manually does not set FrameworkElement.IsLoaded.
                        // The shared read coordinator deliberately rejects unmounted views;
                        // use the real owning-window lifecycle, as the application does.
                        tableHost.Show();
                        PumpUntil(() => view.IsLoaded, "The unit workspace must be attached to its actual native window before reads.");
                        LayoutElement(view, 1100, 640);
                        var table = FindVisual<DataGrid>(view, item => true);
                        PumpUntil(() => table?.Items.Count == 1, "Native unit table must consume the actual scoped service response.");
                        if (handler.UnitListReads <= previousReads)
                            throw new InvalidOperationException("The loaded native unit table must issue a real scoped service read.");
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
                    finally { tableHost.Content = null; tableHost.Close(); view.Dispose(); }
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
        private static int CountVisual<T>(DependencyObject root) where T : DependencyObject
        {
            int count = root is T ? 1 : 0;
            for (int index = 0; index < VisualTreeHelper.GetChildrenCount(root); index++)
                count += CountVisual<T>(VisualTreeHelper.GetChild(root, index));
            return count;
        }
        private static void Snapshot(FrameworkElement content, string fileName)
        {
            var bitmap = new RenderTargetBitmap((int)Math.Ceiling(content.ActualWidth), (int)Math.Ceiling(content.ActualHeight), 96, 96, PixelFormats.Pbgra32);
            bitmap.Render(content); var encoder = new PngBitmapEncoder(); encoder.Frames.Add(BitmapFrame.Create(bitmap));
            using (var output = File.Create(Path.Combine(AppDomain.CurrentDomain.BaseDirectory, fileName))) encoder.Save(output);
        }
        private static void PumpUntil(Func<bool> complete, string failure, int timeoutSeconds = 8)
        {
            var timer = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(10) };
            var deadline = System.Diagnostics.Stopwatch.StartNew(); var frame = new DispatcherFrame();
            timer.Tick += (sender, args) => { if (complete() || deadline.Elapsed > TimeSpan.FromSeconds(timeoutSeconds)) frame.Continue = false; };
            timer.Start();
            try { Dispatcher.PushFrame(frame); } finally { timer.Stop(); }
            if (!complete()) throw new InvalidOperationException(failure);
        }
        private sealed class UnitUiHandler : HttpMessageHandler
        {
            internal string UserId = "fixture-unit-user";
            internal int BusinessWrites;
            internal int UnitListReads;
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
                else if (path.EndsWith("/auth/session/watch")) body = "{\"status\":\"replaced\",\"code\":\"SESSION_REPLACED\",\"message\":\"fixture replacement\"}";
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
                else if (path == "/api/master/units/summaries" && request.Method == HttpMethod.Post)
                {
                    Interlocked.Increment(ref UnitListReads);
                    return CompleteFixture("{\"items\":[{\"id\":\"ffda6731-4bce-4fa1-a5a5-2acf55fd6d01\",\"code\":\"U001\",\"name\":\"确认保存单位\",\"status\":\"使用\"}],\"page\":1,\"size\":100,\"total\":1,\"totalPages\":1,\"readScopeVersion\":\""
                        + Proof + "\",\"readDataVersion\":\"" + new string('d', 64) + "\",\"readSnapshotRevision\":\"" + new string('a', 64) + "\"}");
                }
                else if (path == "/api/master/units" && request.Method == HttpMethod.Get)
                {
                    Interlocked.Increment(ref UnitListReads);
                    body = "{\"items\":[{\"id\":\"ffda6731-4bce-4fa1-a5a5-2acf55fd6d01\",\"code\":\"U001\",\"name\":\"确认保存单位\",\"status\":\"使用\"}],\"page\":1,\"size\":20,\"total\":1,\"totalPages\":1,\"readScopeVersion\":\"" + Proof + "\"}";
                }
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
