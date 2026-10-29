using System;
using System.Collections.Generic;
using System.Globalization;
using System.Linq;
using System.Threading;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Controls;
using Uten.Legacy.Core;
using Uten.Legacy.Desktop.Controls;

namespace Uten.Legacy.Desktop.Features.Units
{
    public sealed class UnitRecordHistoryWindow : UnitHistoryWindow
    {
        private sealed class Choice
        {
            public string Label { get; set; }
            public string Value { get; set; }
        }
        private readonly TextBox keyword = new TextBox(), actor = new TextBox();
        private readonly TextBox from = new TextBox(), to = new TextBox(), summaryKeyword = new TextBox();
        private readonly ComboBox action = new ComboBox(), sourceType = new ComboBox();
        private readonly WrapPanel filters = new WrapPanel();
        private readonly StackPanel scopeBar = new StackPanel { Orientation = Orientation.Horizontal };
        private readonly DataGrid revisions = HistoryTable(215), changes = HistoryTable(185);
        private readonly TextBlock detail = new TextBlock { TextWrapping = TextWrapping.Wrap };
        private readonly TextBlock paging = new TextBlock { VerticalAlignment = VerticalAlignment.Center };
        private readonly Button refresh, previous, next, before, after;
        private readonly List<long?> cursors = new List<long?> { null };
        private UnitReadSnapshot<UnitRecordHistoryPage> page;
        private UnitReadSnapshot<UnitRecordRevision> selected;
        private CancellationTokenSource pageRead, detailRead;
        private long pageSequence, detailSequence;
        private bool loading, loadingDetail;
        private string recordScopeId;

        public UnitRecordHistoryWindow(Window parent, SessionCoordinator session, string recordId = null)
            : base(parent, session, "单位修改历史与版本对照", 1080)
        {
            if (recordId != null) UnitHistoryContract.RequireUuid(recordId);
            recordScopeId = recordId;
            if (recordId != null)
            {
                scopeBar.Margin = new Thickness(0, 0, 0, Space("S8"));
                scopeBar.Children.Add(new TextBlock { Text = "当前单位的修改历史", VerticalAlignment = VerticalAlignment.Center });
                var all = new Button { Content = "显示全部单位", Margin = new Thickness(Space("S12"), 0, 0, 0) };
                all.Click += async (sender, args) => { recordScopeId = null; InvalidateFilters(); scopeBar.Visibility = Visibility.Collapsed; cursors.Clear(); cursors.Add(null); await LoadPageAsync(); };
                scopeBar.Children.Add(all); Body.Children.Add(scopeBar);
            }
            AddFilter("编号、名称或摘要", keyword, 180); AddFilter("操作人", actor, 130);
            AddChoice("动作", action, new[] { "CREATE", "EDIT", "DELETE", "STATUS", "RESTORE" }, UnitHistoryContract.ActionLabel);
            AddChoice("修改范围", sourceType, new[] { "RECORD", "EXTENSION" }, UnitHistoryContract.SourceLabel);
            AddFilter("开始日期 yyyy-MM-dd", from, 145); AddFilter("结束日期 yyyy-MM-dd", to, 145);
            AddFilter("摘要关键词", summaryKeyword, 170);
            Body.Children.Add(filters);
            Body.Children.Add(Note("按版本顺序向前翻页。列表只显示概要，选中版本后读取完整差异和当前可恢复范围。"));
            revisions.Columns.Add(Column("编号", "RecordCode", 105)); revisions.Columns.Add(Column("单位", "RecordName", 130));
            revisions.Columns.Add(Column("动作", "ActionLabel", 90)); revisions.Columns.Add(Column("范围", "SourceLabel", 100));
            revisions.Columns.Add(Column("操作人", "ActorName", 115)); revisions.Columns.Add(Column("时间", "RecordedAtDisplay", 165));
            revisions.Columns.Add(Column("摘要", "Summary", 1, true)); Body.Children.Add(UtenSurfaces.Wrap(revisions, UtenSurfaceRole.Table));
            var pager = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Right,
                Margin = new Thickness(0, Space("S8"), 0, Space("S8")) };
            previous = new Button { Content = "上一页", Margin = new Thickness(0, 0, Space("S8"), 0) };
            next = new Button { Content = "下一页", Margin = new Thickness(Space("S8"), 0, 0, 0) };
            pager.Children.Add(previous); pager.Children.Add(paging); pager.Children.Add(next); Body.Children.Add(pager);
            detail.Margin = new Thickness(0, Space("S8"), 0, Space("S12")); Body.Children.Add(detail);
            changes.Columns.Add(Column("字段", "Label", 170)); changes.Columns.Add(DiffColumn("修改前", "BeforeValue"));
            changes.Columns.Add(DiffColumn("修改后", "AfterValue")); Body.Children.Add(UtenSurfaces.Wrap(changes, UtenSurfaceRole.Table));
            refresh = ActionButton("查询 / 刷新", () => { cursors.Clear(); cursors.Add(null); _ = LoadPageAsync(); });
            before = ActionButton("恢复到修改前", () => { _ = RestoreAsync(true); });
            after = ActionButton("恢复到修改后", () => { _ = RestoreAsync(false); }, primary: true);
            ActionButton("关闭", () => Close());
            previous.Click += async (sender, args) => { if (cursors.Count > 1) { cursors.RemoveAt(cursors.Count - 1); await LoadPageAsync(); } };
            next.Click += async (sender, args) => { if (page?.Value.NextCursor != null) { cursors.Add(page.Value.NextCursor); await LoadPageAsync(); } };
            revisions.SelectionChanged += async (sender, args) => await LoadDetailAsync();
            foreach (var input in new[] { keyword, actor, from, to, summaryKeyword })
                input.TextChanged += (sender, args) => InvalidateFilters();
            action.SelectionChanged += (sender, args) => InvalidateFilters(); sourceType.SelectionChanged += (sender, args) => InvalidateFilters();
            Loaded += async (sender, args) => await LoadPageAsync(); UpdateActions();
        }
        private void AddFilter(string label, TextBox input, double width)
        {
            input.Width = width; input.SetResourceReference(StyleProperty, "Uten.CompactInput");
            System.Windows.Automation.AutomationProperties.SetName(input, label);
            var group = new StackPanel { Margin = new Thickness(0, 0, Space("S8"), Space("S8")) };
            group.Children.Add(new TextBlock { Text = label, Margin = new Thickness(0, 0, 0, Space("S4")) }); group.Children.Add(input); filters.Children.Add(group);
        }
        private static DataGridTextColumn DiffColumn(string label, string property)
        {
            var column = Column(label, property, 1, true);
            var text = new Style(typeof(TextBlock)); text.Setters.Add(new Setter(TextBlock.TextWrappingProperty, TextWrapping.Wrap));
            column.ElementStyle = text;
            return column;
        }
        private void AddChoice(string label, ComboBox input, string[] values, Func<string, string> display)
        {
            input.MinWidth = 120; input.DisplayMemberPath = "Label";
            var options = new List<Choice> { new Choice { Label = "全部" } };
            options.AddRange(values.Select(value => new Choice { Value = value, Label = display(value) })); input.ItemsSource = options; input.SelectedIndex = 0;
            var group = new StackPanel { Margin = new Thickness(0, 0, Space("S8"), Space("S8")) };
            group.Children.Add(new TextBlock { Text = label, Margin = new Thickness(0, 0, 0, Space("S4")) }); group.Children.Add(input); filters.Children.Add(group);
        }
        private void InvalidateFilters()
        {
            if (Ended || Retired) return;
            pageSequence++; pageRead?.Cancel(); detailSequence++; detailRead?.Cancel();
            page = null; selected = null; revisions.ItemsSource = changes.ItemsSource = null; detail.Text = "筛选条件已变化，请点击查询。";
            loading = loadingDetail = false; UpdateActions();
        }
        private UnitHistoryQuery Query()
        {
            return new UnitHistoryQuery(recordScopeId, cursors[cursors.Count - 1], (action.SelectedItem as Choice)?.Value,
                null, Empty(actor.Text), Empty(keyword.Text), Empty(from.Text), Empty(to.Text), 50,
                (sourceType.SelectedItem as Choice)?.Value, Empty(summaryKeyword.Text));
        }
        private static string Empty(string value) { return String.IsNullOrWhiteSpace(value) ? null : value; }
        private async Task LoadPageAsync()
        {
            if (!Current || Mutating && !NeedsRefresh) return;
            pageRead?.Cancel(); pageRead?.Dispose(); pageRead = CancellationTokenSource.CreateLinkedTokenSource(Lifetime.Token);
            var token = pageRead.Token; long request = ++pageSequence;
            detailSequence++; detailRead?.Cancel(); selected = null; changes.ItemsSource = null; detail.Text = "请选择一个历史版本查看差异。";
            loading = true; UpdateActions();
            try
            {
                var query = Query(); var result = await Service.RecordsAsync(query, token); await ReadPendingGateAsync(token);
                if (!Current || request != pageSequence || !result.IsCurrent(Session)) return;
                page = result; revisions.ItemsSource = result.Value.Entries; NeedsRefresh = false;
                paging.Text = "第 " + cursors.Count.ToString(CultureInfo.InvariantCulture) + " 页";
                if (!Unresolved && JournalConfirmed) ShowStatus(result.Value.Entries.Count == 0 ? "没有符合条件的单位历史。" : "请选择版本查看真实差异和可恢复范围。");
            }
            catch (OperationCanceledException) { }
            catch (ApiException error) { if (Current && request == pageSequence) { page = null; ShowStatus(error.UserMessage, true); } }
            catch (Exception error) when (error is FormatException || error is ArgumentException)
            { if (Current && request == pageSequence) { page = null; ShowStatus("筛选值或历史响应无效。请核对 UUID、日期及筛选条件后重试。", true); } }
            catch (Exception) { if (Current && request == pageSequence) { page = null; ShowStatus("读取修改历史失败，请点击查询重试。", true); } }
            finally { if (!Ended && request == pageSequence) { loading = false; UpdateActions(); } }
        }
        private async Task LoadDetailAsync()
        {
            long request = ++detailSequence; detailRead?.Cancel(); detailRead?.Dispose(); detailRead = null;
            selected = null; changes.ItemsSource = null; loadingDetail = false;
            var row = revisions.SelectedItem as UnitRecordRevision;
            if (!Current || loading || row == null || page?.IsCurrent(Session) != true) { UpdateActions(); return; }
            detailRead = CancellationTokenSource.CreateLinkedTokenSource(Lifetime.Token); var token = detailRead.Token;
            loadingDetail = true; detail.Text = "正在读取完整历史差异…"; UpdateActions();
            try
            {
                var result = await Service.DetailAsync(row.Id, token);
                if (!Current || request != detailSequence || !result.IsCurrent(Session)) return;
                selected = result; changes.ItemsSource = result.Value.Changes;
                detail.Text = "历史版本 " + result.Value.Id.ToString(CultureInfo.InvariantCulture) + " · " + result.Value.RecordedAtDisplay
                    + "\n" + result.Value.RecordCode + " · " + result.Value.RecordLabel + "\n" + result.Value.Summary
                    + "\n" + result.Value.AffectedCount.ToString(CultureInfo.InvariantCulture) + " 项资料参与此版本"
                    + (String.IsNullOrEmpty(result.Value.BlockedReason) ? "" : "\n" + result.Value.BlockedReason);
            }
            catch (OperationCanceledException) { }
            catch (ApiException error) { if (Current && request == detailSequence) detail.Text = error.UserMessage; }
            catch (Exception) { if (Current && request == detailSequence) detail.Text = "读取版本差异失败，请重新选择该版本重试。"; }
            finally { if (!Ended && request == detailSequence) { loadingDetail = false; UpdateActions(); } }
        }
        private async Task RestoreAsync(bool beforeState)
        {
            var source = selected;
            if (!Current || Mutating || loading || loadingDetail || Unresolved || NeedsRefresh || source?.IsCurrent(Session) != true
                || !(beforeState ? source.Value.CanRestoreBefore : source.Value.CanRestoreAfter)) return;
            string target = beforeState ? "修改前" : "修改后";
            if (!Confirm("恢复版本", "确认将“" + source.Value.RecordLabel + "”恢复到该版本的" + target + "状态？\n本次涉及 "
                + source.Value.AffectedCount.ToString(CultureInfo.InvariantCulture) + " 项资料，服务器将重新检查权限、后续修改、编号和引用。")) return;
            await ExecuteCommandAsync(() => Service.PrepareRestore(Guid.NewGuid().ToString("D"), source, beforeState), "已恢复到所选版本的" + target + "状态");
        }
        protected override Task ReloadAfterMutationAsync() { return LoadPageAsync(); }
        protected override void UpdateActions()
        {
            if (refresh == null) return;
            bool available = Current && !Mutating && !loading && !loadingDetail && !Unresolved && !NeedsRefresh && JournalConfirmed && selected?.IsCurrent(Session) == true;
            before.IsEnabled = available && selected.Value.CanRestoreBefore; after.IsEnabled = available && selected.Value.CanRestoreAfter;
            refresh.IsEnabled = Current && !Mutating && !loading;
            previous.IsEnabled = Current && !Mutating && !loading && page != null && cursors.Count > 1;
            next.IsEnabled = Current && !Mutating && !loading && page?.Value.NextCursor != null;
            scopeBar.IsEnabled = filters.IsEnabled = revisions.IsEnabled = Current && !Mutating;
            CloseButton.IsEnabled = !Mutating;
        }
        protected override void ClearData()
        {
            pageSequence++; detailSequence++; pageRead?.Cancel(); detailRead?.Cancel(); page = null; selected = null;
            revisions.ItemsSource = changes.ItemsSource = null; detail.Text = paging.Text = "";
            scopeBar.Visibility = Visibility.Collapsed;
            recordScopeId = null;
            foreach (var box in new[] { keyword, actor, from, to, summaryKeyword }) box.Clear();
            cursors.Clear(); cursors.Add(null);
        }
        protected override void OnClosed(EventArgs args) { base.OnClosed(args); pageRead?.Dispose(); detailRead?.Dispose(); }
    }
}
