using System;
using System.ComponentModel;
using System.Linq;
using System.Threading;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Data;
using Uten.Legacy.Core;
using Uten.Legacy.Desktop.Controls;

namespace Uten.Legacy.Desktop.Features.Units
{
    /// <summary>Shared lifecycle for native history dialogs. No business form is reconstructed from a history row.</summary>
    public abstract class UnitHistoryWindow : UtenDialogWindow
    {
        protected readonly SessionCoordinator Session;
        protected readonly UnitHistoryService Service;
        protected readonly UnitReadOwner OwnerFence;
        protected readonly CancellationTokenSource Lifetime = new CancellationTokenSource();
        protected bool Ended, Retired, Mutating, Unresolved, NeedsRefresh, JournalConfirmed;
        private bool subscribed;
        public bool BusinessChanged { get; private set; }
        public event EventHandler Changed;

        protected UnitHistoryWindow(Window parent, SessionCoordinator session, string title, double width)
            : base(parent, title, width)
        {
            Session = session ?? throw new ArgumentNullException(nameof(session)); Service = new UnitHistoryService(session);
            OwnerFence = new UnitReadOwner(session);
            // Derived construction may reject invalid filter arguments. Register only a fully built window.
            Loaded += (sender, args) =>
            {
                if (subscribed || Ended) return;
                if (!Current) { Close(); return; }
                session.SessionChanged += OnOwnerChanged; session.ReadScopeChanged += OnOwnerChanged;
                subscribed = true;
                (parent as IPendingEditHost)?.TrackPendingEditor(this);
            };
        }
        protected bool Current { get { return !Ended && !Retired && OwnerFence.IsCurrent(Session); } }
        protected abstract void ClearData();
        protected abstract void UpdateActions();
        protected abstract Task ReloadAfterMutationAsync();
        protected async Task ReadPendingGateAsync(CancellationToken ct)
        {
            JournalConfirmed = false;
            try
            {
                var journal = await Service.JournalAsync(ct);
                if (!Current || !journal.IsCurrent(Session)) return;
                JournalConfirmed = true;
                Unresolved = Unresolved || UnitHistoryService.HasUnresolved(journal.Value);
                if (Unresolved) ShowStatus("本机有结果待核对的单位历史提交。请先在原服务器核对提交记录；当前仍可查看历史，不能再次执行历史操作。", true);
            }
            catch (ApiException error)
            {
                if (!Current) throw;
                ShowStatus(error.UserMessage + " 当前只允许查看历史，请恢复本机记录存储后刷新核对。", true);
            }
        }
        protected async Task ExecuteCommandAsync(Func<MutationRequest> prepare, string success)
        {
            if (!Current || Mutating || Unresolved || NeedsRefresh) return;
            Mutating = true; UpdateActions();
            try
            {
                // Read durable state before a fresh explicit decision. Core rechecks atomically before sending.
                await ReadPendingGateAsync(Lifetime.Token);
                if (!Current || Unresolved || !JournalConfirmed) return;
                var request = prepare();
                var result = await Service.SendAsync(request, Lifetime.Token);
                if (result.Outcome == MutationOutcome.Confirmed)
                {
                    BusinessChanged = true;
                    if (!result.IsDurablyRecorded)
                    {
                        Unresolved = true;
                        if (Current) ShowStatus("服务器已确认操作，本机结果记录尚未保存完整。原提交编号：" + request.RequestId + "。请保留原记录，不要再次提交。", true);
                    }
                    else if (Current)
                    {
                        NeedsRefresh = true;
                        ShowStatus(success);
                        try { await ReloadAfterMutationAsync(); }
                        catch (Exception) { if (Current) ShowStatus(success + "，但最新历史暂未读到。请刷新核对；不要重复提交原操作。", true); }
                    }
                    // A subscriber error cannot turn known business success into a retryable command.
                    try { Changed?.Invoke(this, EventArgs.Empty); } catch (Exception) { }
                }
                else if (result.Outcome == MutationOutcome.Unknown)
                {
                    Unresolved = true;
                    if (Current) ShowStatus("结果待核对，原提交编号：" + request.RequestId + "。请查看原服务器资料与操作历史；目标值相同不能证明本次提交成功，不要重复提交。", true);
                }
                else
                {
                    NeedsRefresh = true;
                    if (Current) ShowStatus((result.Error?.UserMessage ?? "本次操作没有确认成功。") + " 请先刷新历史再作新的决定。", true);
                }
            }
            catch (OperationCanceledException) { if (Current) { NeedsRefresh = true; ShowStatus("操作已停止，请刷新并核对本机提交记录。", true); } }
            catch (ApiException error) { if (Current) { NeedsRefresh = true; ShowStatus(error.UserMessage, true); } }
            catch (Exception) { if (Current) { NeedsRefresh = true; ShowStatus("暂时无法完成本次操作，请先核对本机提交记录；不会自动重试。", true); } }
            finally
            {
                Mutating = false;
                if (!Ended) { UpdateActions(); if (Retired) Close(); }
            }
        }
        private void OnOwnerChanged(object sender, EventArgs args)
        {
            if (Ended) return;
            Dispatcher.BeginInvoke(new Action(() =>
            {
                if (Ended || OwnerFence.IsCurrent(Session)) return; // Ordinary token rotation keeps filters/selection.
                Retired = true; ClearData(); Body.Visibility = Visibility.Collapsed; Lifetime.Cancel();
                ShowStatus("账号、权限或数据范围已变化。原提交正在完成本机记录保全。", true); UpdateActions();
                if (!Mutating) Close();
            }));
        }
        protected override void OnClosing(CancelEventArgs args)
        {
            if (Mutating) { args.Cancel = true; ShowStatus("正在确认并记录本次提交结果，请稍候再关闭。", true); }
            base.OnClosing(args);
        }
        protected override void OnClosed(EventArgs args)
        {
            Ended = true; Lifetime.Cancel(); Session.SessionChanged -= OnOwnerChanged; Session.ReadScopeChanged -= OnOwnerChanged;
            ClearData(); Lifetime.Dispose(); base.OnClosed(args);
        }
        protected static DataGrid HistoryTable(double height)
        { return new DataGrid { Height = height, SelectionMode = DataGridSelectionMode.Single, SelectionUnit = DataGridSelectionUnit.FullRow, CanUserSortColumns = false }; }
        protected static DataGridTextColumn Column(string label, string property, double width, bool stretch = false)
        { return new DataGridTextColumn { Header = label, Binding = new Binding(property) { TargetNullValue = "—" }, IsReadOnly = true,
            Width = new DataGridLength(width, stretch ? DataGridLengthUnitType.Star : DataGridLengthUnitType.Pixel) }; }
        protected TextBlock Note(string text)
        { return new TextBlock { Text = text, TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, Space("S8"), 0, Space("S8")) }; }
        protected bool Confirm(string title, string message)
        { return new HistoryConfirmation(this, title, message).ShowDialog() == true && Current; }
        private sealed class HistoryConfirmation : UtenDialogWindow
        {
            internal HistoryConfirmation(Window parent, string title, string message) : base(parent, title, 600)
            {
                Body.Children.Add(new TextBlock { Text = message, TextWrapping = TextWrapping.Wrap });
                ActionButton("取消", () => Close());
                ActionButton("确认" + title, () => { DialogResult = true; }, primary: true);
            }
        }
    }

    public sealed class UnitOperationHistoryWindow : UnitHistoryWindow
    {
        private readonly DataGrid operations = HistoryTable(235), events = HistoryTable(135);
        private readonly TextBlock summary = new TextBlock { TextWrapping = TextWrapping.Wrap };
        private readonly Button refresh, undo, redo;
        private readonly bool preferRedo;
        private UnitReadSnapshot<UnitOperationHistory> snapshot;
        private CancellationTokenSource read;
        private long sequence;
        private bool loading;
        public UnitOperationHistoryWindow(Window parent, SessionCoordinator session, bool preferRedo = false)
            : base(parent, session, "本人操作记录与撤回", 920)
        {
            this.preferRedo = preferRedo;
            Body.Children.Add(Note("最近 10 次本人资料操作及最近 30 条撤回事件。能否执行由当前权限、引用与后续修改决定。"));
            operations.Columns.Add(Column("操作", "Label", 1, true)); operations.Columns.Add(Column("状态", "StateLabel", 90));
            operations.Columns.Add(Column("影响项", "AffectedCount", 80)); operations.Columns.Add(Column("时间", "CreatedAtDisplay", 165));
            Body.Children.Add(UtenSurfaces.Wrap(operations, UtenSurfaceRole.Table));
            summary.Margin = new Thickness(0, Space("S12"), 0, Space("S12")); Body.Children.Add(summary);
            Body.Children.Add(Note("撤回与取消撤回事件"));
            events.Columns.Add(Column("动作", "ActionLabel", 100)); events.Columns.Add(Column("操作", "Label", 1, true)); events.Columns.Add(Column("时间", "CreatedAtDisplay", 165));
            Body.Children.Add(UtenSurfaces.Wrap(events, UtenSurfaceRole.Table));
            refresh = ActionButton("刷新", () => { _ = ReloadAsync(); });
            undo = ActionButton("撤回所选操作", () => { _ = ApplyAsync(false); }, primary: !preferRedo);
            redo = ActionButton("取消所选撤回", () => { _ = ApplyAsync(true); }, primary: preferRedo);
            ActionButton("关闭", () => Close());
            operations.SelectionChanged += (sender, args) => UpdateActions();
            Loaded += async (sender, args) => await ReloadAsync(); UpdateActions();
        }
        private async Task ReloadAsync()
        {
            if (!Current || Mutating && !NeedsRefresh) return;
            read?.Cancel(); read?.Dispose(); read = CancellationTokenSource.CreateLinkedTokenSource(Lifetime.Token);
            var token = read.Token; long request = ++sequence; loading = true; UpdateActions();
            string selected = (operations.SelectedItem as UnitOperationEntry)?.Id;
            try
            {
                var result = await Service.OperationsAsync(token); await ReadPendingGateAsync(token);
                if (!Current || request != sequence || !result.IsCurrent(Session)) return;
                snapshot = result; operations.ItemsSource = result.Value.Entries; events.ItemsSource = result.Value.Events;
                operations.SelectedItem = result.Value.Entries.FirstOrDefault(row => row.Id == selected)
                    ?? result.Value.Entries.FirstOrDefault(row => preferRedo ? row.CanRedo : row.CanUndo) ?? result.Value.Entries.FirstOrDefault();
                NeedsRefresh = false;
                if (!Unresolved && JournalConfirmed) ShowStatus(result.Value.Entries.Count == 0 ? "当前没有本人单位操作记录。" : "已读取本人单位操作历史。");
            }
            catch (OperationCanceledException) { }
            catch (ApiException error) { if (Current && request == sequence) { snapshot = null; ShowStatus(error.UserMessage, true); } }
            catch (Exception) { if (Current && request == sequence) { snapshot = null; ShowStatus("读取操作历史失败，请点击刷新重试。", true); } }
            finally { if (!Ended && request == sequence) { loading = false; UpdateActions(); } }
        }
        private async Task ApplyAsync(bool redoAction)
        {
            var row = operations.SelectedItem as UnitOperationEntry;
            if (!Current || loading || Mutating || Unresolved || NeedsRefresh || row == null || !(redoAction ? row.CanRedo : row.CanUndo)) return;
            var source = snapshot;
            string verb = redoAction ? "取消撤回" : "撤回";
            if (!Confirm(verb, "确认" + verb + "“" + row.Label + "”？本次将影响 " + row.AffectedCount + " 项资料。\n" + row.Summary)) return;
            await ExecuteCommandAsync(() => Service.PrepareReplay(Guid.NewGuid().ToString("D"), source, row.Id, redoAction), "已" + verb + "所选操作");
        }
        protected override Task ReloadAfterMutationAsync() { return ReloadAsync(); }
        protected override void UpdateActions()
        {
            if (refresh == null) return;
            var row = operations.SelectedItem as UnitOperationEntry;
            bool available = Current && !loading && !Mutating && !Unresolved && !NeedsRefresh && JournalConfirmed && snapshot?.IsCurrent(Session) == true;
            refresh.IsEnabled = Current && !loading && !Mutating;
            undo.IsEnabled = available && row?.CanUndo == true; redo.IsEnabled = available && row?.CanRedo == true;
            operations.IsEnabled = events.IsEnabled = Current && !Mutating;
            summary.Text = row == null ? "请选择一项本人操作。" : row.Summary + (String.IsNullOrEmpty(row.BlockedReason) ? "" : "\n" + row.BlockedReason);
            CloseButton.IsEnabled = !Mutating;
        }
        protected override void ClearData() { sequence++; snapshot = null; operations.ItemsSource = events.ItemsSource = null; summary.Text = ""; read?.Cancel(); }
        protected override void OnClosed(EventArgs args) { base.OnClosed(args); read?.Dispose(); }
    }
}
