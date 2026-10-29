using System;
using System.Collections.Generic;
using System.Linq;
using System.ComponentModel;
using System.Threading;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using Uten.Legacy.Core;
using Uten.Legacy.Desktop.Controls;
using Uten.Legacy.Desktop.Shared;
using Uten.Legacy.Desktop.Features.Columns;

namespace Uten.Legacy.Desktop.Features.Units
{
    public sealed class UnitPrintWindow : UtenDialogWindow
    {
        private readonly SessionCoordinator session;
        private readonly UnitQuery query;
        private readonly UnitReadOwner owner;
        private readonly UnitColumnsSnapshot columns;
        private readonly CancellationTokenSource lifetime = new CancellationTokenSource();
        private readonly DocumentPageView paper = new DocumentPageView();
        private readonly ScrollViewer preview = new ScrollViewer { Height = 470, VerticalScrollBarVisibility = ScrollBarVisibility.Auto,
            HorizontalScrollBarVisibility = ScrollBarVisibility.Auto };
        private readonly ComboBox zoom = new ComboBox { Width = 100, ItemsSource = new[] { "75%", "100%", "125%", "150%", "200%" }, SelectedIndex = 1 };
        private readonly TextBlock pageLabel = new TextBlock { VerticalAlignment = VerticalAlignment.Center };
        private readonly Button previous, next, print;
        private NativeTableDocument document;
        private bool ended, retired, printing;
        private int page;
        public bool SubmittedToPrintQueue { get; private set; }
        public UnitPrintWindow(Window parent, SessionCoordinator session, UnitQuery query) : this(parent, session, query, null) { }
        public UnitPrintWindow(Window parent, SessionCoordinator session, UnitQuery query, UnitColumnsSnapshot columns) : base(parent, "预览 · 单位资料", 1080)
        {
            this.session = session; this.query = query; owner = new UnitReadOwner(session); this.columns = columns;
            if (columns != null && !columns.IsCurrent(session)) throw new ApiException("READ_SCOPE_CHANGED", "打印的原表头范围已变化，请刷新后重试。");
            preview.Height = Math.Max(180, Math.Min(470, SystemParameters.WorkArea.Height - 290));
            preview.Content = paper; Body.Children.Add(preview);
            var footer = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Center,
                Margin = new Thickness(0, Space("S8"), 0, 0) };
            previous = new Button { Content = "上一页", Margin = new Thickness(0, 0, Space("S8"), 0) };
            next = new Button { Content = "下一页", Margin = new Thickness(Space("S8"), 0, 0, 0) };
            previous.Click += (sender, args) => ShowPage(page - 1); next.Click += (sender, args) => ShowPage(page + 1);
            footer.Children.Add(previous); footer.Children.Add(pageLabel); footer.Children.Add(next); Body.Children.Add(footer);
            zoom.Margin = new Thickness(Space("S16"), 0, 0, 0); footer.Children.Add(zoom);
            zoom.SelectionChanged += (sender, args) => SetZoom();
            print = ActionButton("打印", Print);
            ActionButton("关闭", () => Close());
            session.SessionChanged += OnOwnerChanged; session.ReadScopeChanged += OnOwnerChanged;
            (parent as IPendingEditHost)?.TrackPendingEditor(this);
            Loaded += async (sender, args) => await LoadAsync();
            UpdateActions();
        }
        private bool Current { get { return !ended && !retired && owner.IsCurrent(session) && session.CurrentUser?.HasPermission("unit:view") == true; } }
        private async Task LoadAsync()
        {
            try
            {
                ShowStatus("正在完整读取当前筛选的单位资料…");
                var progress = new Progress<long>(count => { if (Current) ShowStatus("正在完整读取，已读取 " + count + " 项…"); });
                var snapshot = await UnitPrintSnapshot.LoadAsync(session, query, lifetime.Token, progress);
                if (!Current || !snapshot.IsCurrent(session)) return;
                var projected = columns?.Projection ?? UnitColumnProjection.Default;
                var rows = new List<IReadOnlyList<string>>(snapshot.Rows.Count); long textBytes = 0;
                var columnReader = new UnitColumnsService(session);
                for (int offset = 0; offset < snapshot.Rows.Count; offset += 200)
                {
                    if (!Current) return;
                    int count = Math.Min(200, snapshot.Rows.Count - offset);
                    UnitColumnsSnapshot values = null;
                    if (columns != null && projected.Columns.Any(column => column.PlatformId != null))
                    {
                        var ids = new string[count];
                        for (int index = 0; index < count; index++) ids[index] = snapshot.Rows[offset + index].Id;
                        values = await columnReader.LoadRowsAsync(ids, columns, lifetime.Token);
                        if (!Current || !values.IsCurrent(session)) return;
                    }
                    for (int index = 0; index < count; index++)
                    {
                        if (!Current) return;
                        var item = snapshot.Rows[offset + index]; var cells = new string[projected.Columns.Count];
                        for (int field = 0; field < cells.Length; field++)
                        {
                            string key = projected.Columns[field].Key;
                            if (key == "code") cells[field] = item.Code ?? "";
                            else if (key == "name") cells[field] = item.Name ?? "";
                            else if (key == "status") cells[field] = item.Status ?? "";
                            else
                            {
                                PlatformColumnRow row; PlatformColumnCell cell;
                                if (values == null || !values.Rows.TryGetValue(item.Id, out row) || !row.Cells.TryGetValue(key, out cell) || cell.Masked || cell.Error != null)
                                    throw new ApiException("COLUMN_VALUES_UNAVAILABLE", "所选自设列未能完整验读，已停止打印，不会用0或占位替代。");
                                cells[field] = cell.Value ?? "";
                            }
                            textBytes += (long)cells[field].Length * 2;
                            if (textBytes > 64L * 1024 * 1024) throw new ApiException("PRINT_TOO_LARGE", "完整打印文字过多，请缩小筛选范围或减少自设列。");
                        }
                        rows.Add(Array.AsReadOnly(cells));
                        if (index % 40 == 0) await System.Windows.Threading.Dispatcher.Yield(System.Windows.Threading.DispatcherPriority.Background);
                    }
                }
                ShowStatus("正在分页…");
                document = await NativeTableDocument.CreateAsync("单位资料", "当前筛选的完整结果",
                    projected.Columns.Select(column => column.Label).ToArray(), rows,
                    projected.Columns.Select(column => column.Width).ToArray(), () => Current, lifetime.Token);
                if (!Current) return;
                paper.Width = document.PageSize.Width; paper.Height = document.PageSize.Height;
                paper.DocumentPaginator = document; SetZoom(); ShowPage(0);
                ShowStatus(snapshot.Rows.Count == 0 ? "没有符合当前筛选的单位。" : "当前筛选完整读取 " + snapshot.Rows.Count + " 项。");
            }
            catch (OperationCanceledException) { }
            catch (ApiException error) { if (Current) ShowStatus(error.UserMessage, true); }
            catch (Exception error) when (error is FormatException || error is ArgumentException || error is InvalidOperationException)
            { if (Current) ShowStatus(error is FormatException ? error.Message : "生成打印预览失败，请重新打开后重试。", true); }
            finally { if (!ended) UpdateActions(); }
        }
        private void ShowPage(int target)
        {
            if (!Current || document == null || printing || target < 0 || target >= document.PageCount) return;
            page = target; paper.PageNumber = page; pageLabel.Text = (page + 1) + " / " + document.PageCount; UpdateActions();
        }
        private void UpdateActions()
        {
            if (print == null) return;
            bool ready = Current && !printing && document != null;
            previous.IsEnabled = ready && page > 0;
            next.IsEnabled = ready && page + 1 < document.PageCount;
            print.IsEnabled = ready && document.RowCount > 0;
            zoom.IsEnabled = ready;
            CloseButton.IsEnabled = !printing;
        }
        private void SetZoom()
        {
            double[] factors = { .75, 1, 1.25, 1.5, 2 };
            if (zoom.SelectedIndex < 0 || zoom.SelectedIndex >= factors.Length) return;
            double factor = factors[zoom.SelectedIndex];
            paper.LayoutTransform = new System.Windows.Media.ScaleTransform(factor, factor);
        }
        private void Print()
        {
            if (!print.IsEnabled) return;
            printing = true; UpdateActions();
            try
            {
                bool queued = NativePrintGate.Submit(document, "单位资料", () => Current, new NativeWpfPrintDestination());
                if (queued) SubmittedToPrintQueue = true;
                if (Current) ShowStatus(queued ? "已提交到系统打印队列，请在打印机中核对完成情况。" : "已取消打印。");
            }
            catch (ApiException error) { if (Current) ShowStatus(error.UserMessage, true); }
            catch (Exception) { if (Current) ShowStatus("未能确认打印提交结果，请先检查系统打印队列，不要连续重复打印。", true); }
            finally { printing = false; if (!ended) { UpdateActions(); if (retired) Close(); } }
        }
        private void OnOwnerChanged(object sender, EventArgs args)
        {
            if (ended) return;
            Dispatcher.BeginInvoke(new Action(() =>
            {
                if (Current || ended) return;
                retired = true; paper.DocumentPaginator = null; document = null; Body.Children.Clear(); lifetime.Cancel();
                ShowStatus("账号、权限或数据范围已变化，预览已失效。", true); UpdateActions();
                if (!printing) Close();
            }));
        }
        protected override void OnClosing(CancelEventArgs args) { if (printing) args.Cancel = true; base.OnClosing(args); }
        protected override void OnClosed(EventArgs args)
        {
            ended = true; lifetime.Cancel(); paper.DocumentPaginator = null; document = null;
            session.SessionChanged -= OnOwnerChanged; session.ReadScopeChanged -= OnOwnerChanged; lifetime.Dispose(); base.OnClosed(args);
        }
    }
}
