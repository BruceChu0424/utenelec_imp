using System;
using System.Collections.Generic;
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
    /// <summary>Read original local intent and resume only an explicitly selected draft.
    /// A journal entry is never reconstructed into an automatic business retry.</summary>
    public sealed class UnitRecoveryWindow : UtenDialogWindow
    {
        private sealed class DraftRow
        {
            public BusinessDraft Draft;
            public string Action { get { return ActionName(Draft.Action); } }
            public string Target { get { return Summary(Draft.BodyJson); } }
            public string Time { get { return Draft.UpdatedAtUtc.ToLocalTime().ToString("yyyy-MM-dd HH:mm"); } }
            public bool Pending;
        }
        private sealed class JournalRow
        {
            public MutationJournalRecord Record;
            public string Action { get { return ActionName(Record.Action); } }
            public string Target { get { return Summary(Record.BodyJson); } }
            public string State { get { return StateName(Record.State); } }
            public string Time { get { return Record.CreatedAtUtc.ToLocalTime().ToString("yyyy-MM-dd HH:mm"); } }
        }
        private readonly SessionCoordinator session;
        private readonly MutationOwnerSnapshot owner;
        private readonly CancellationTokenSource lifetime = new CancellationTokenSource();
        private readonly DataGrid drafts = Table(), journal = Table();
        private readonly Button resume, delete;
        private bool ended, busy;
        public BusinessDraft SelectedDraft { get; private set; }

        public UnitRecoveryWindow(Window parent, SessionCoordinator session) : base(parent, "本机草稿与提交记录", 820)
        {
            this.session = session; owner = session.CaptureMutationOwner();
            drafts.Columns.Add(Column("操作", "Action", 100)); drafts.Columns.Add(Column("单位", "Target", 1, true));
            drafts.Columns.Add(Column("保存时间", "Time", 150));
            journal.Columns.Add(Column("操作", "Action", 100)); journal.Columns.Add(Column("单位", "Target", 1, true));
            journal.Columns.Add(Column("结果", "State", 110)); journal.Columns.Add(Column("提交时间", "Time", 150));
            Body.Children.Add(new TextBlock { Text = "本机草稿", FontWeight = FontWeights.SemiBold });
            Body.Children.Add(UtenSurfaces.Wrap(drafts, UtenSurfaceRole.Table));
            Body.Children.Add(new TextBlock { Text = "提交记录", FontWeight = FontWeights.SemiBold, Margin = new Thickness(0, Space("S16"), 0, Space("S8")) });
            Body.Children.Add(UtenSurfaces.Wrap(journal, UtenSurfaceRole.Table));
            var inspect = ActionButton("查看原提交", InspectSelected);
            delete = ActionButton("删除草稿", () => { _ = DeleteAsync(); });
            resume = ActionButton("继续编辑", ResumeSelected, primary: true);
            drafts.SelectionChanged += (sender, args) => UpdateActions();
            journal.SelectionChanged += (sender, args) => inspect.IsEnabled = journal.SelectedItem != null && !busy;
            inspect.IsEnabled = false; UpdateActions();
            session.SessionChanged += OnOwnerChanged; session.ReadScopeChanged += OnOwnerChanged;
            Loaded += async (sender, args) => await ReloadAsync();
        }
        private static DataGrid Table()
        { return new DataGrid { Height = 160, Margin = new Thickness(0, 8, 0, 0), SelectionMode = DataGridSelectionMode.Single, CanUserSortColumns = false }; }
        private static DataGridTextColumn Column(string title, string property, double width, bool stretch = false)
        { return new DataGridTextColumn { Header = title, Binding = new Binding(property), Width = new DataGridLength(width, stretch ? DataGridLengthUnitType.Star : DataGridLengthUnitType.Pixel) }; }
        private static bool IsUnitAction(MutationAction action)
        { return action != MutationAction.Unknown && Enum.IsDefined(typeof(MutationAction), action) && action.ToString().StartsWith("Unit", StringComparison.Ordinal); }
        private static bool IsFormDraft(MutationAction action)
        { return action == MutationAction.UnitCreate || action == MutationAction.UnitUpdate || action == MutationAction.UnitStatus
            || action == MutationAction.UnitInlineEdit || action == MutationAction.UnitColumnLayoutSave
            || action == MutationAction.UnitPlatformDefinitionCreate || action == MutationAction.UnitPlatformValuesWrite; }
        private static string ActionName(MutationAction action)
        { return UnitActionLabels.Title(action); }
        private static string StateName(MutationJournalState state)
        {
            switch (state)
            {
                case MutationJournalState.Confirmed: return "已确认";
                case MutationJournalState.Rejected: return "已拒绝";
                case MutationJournalState.NotSent: return "未发送";
                case MutationJournalState.Sending: return "正在提交";
                default: return "待核对";
            }
        }
        private static string Summary(string body)
        {
            try
            {
                var fields = UnitJson.Object(UnitJson.Parse(body));
                string name = UnitJson.Text(fields, "name"), code = UnitJson.Text(fields, "code");
                return String.IsNullOrEmpty(name) ? code ?? "状态调整" : String.IsNullOrEmpty(code) ? name : code + " · " + name;
            }
            catch (FormatException) { return "查看原内容"; }
        }
        private bool Current()
        {
            var user = session.CurrentUser;
            return !ended && user != null && session.IsAuthenticated && session.Generation == owner.AuthGeneration
                && session.ReadScopeRevision == owner.ReadScopeRevision && session.CurrentEndpoint?.ApiBaseUrl == owner.IssuerApiBaseUrl
                && user.Id == owner.UserId && user.BusinessDatasetId == owner.BusinessDatasetId && user.BusinessResetGeneration == owner.BusinessResetGeneration;
        }
        private async Task ReloadAsync()
        {
            busy = true; UpdateActions();
            try
            {
                var saved = await session.ListDraftsAsync(owner, lifetime.Token);
                var entries = await session.ListMutationJournalAsync(owner, lifetime.Token);
                if (!Current()) return;
                journal.ItemsSource = entries.Where(record => IsUnitAction(record.Action)).OrderByDescending(record => record.CreatedAtUtc)
                    .Select(record => new JournalRow { Record = record }).ToList();
                drafts.ItemsSource = saved.Where(draft => IsUnitAction(draft.Action)).OrderByDescending(draft => draft.UpdatedAtUtc)
                    .Select(draft => new DraftRow { Draft = draft, Pending = entries.Any(record => record.OriginDraftId == draft.DraftId
                        && (record.MayNeedManualReconciliation || record.State == MutationJournalState.Confirmed && record.OriginDraftRevision == draft.Revision)) }).ToList();
                ShowStatus("待核对的原提交会保留，不能通过恢复草稿重新发送。");
            }
            catch (OperationCanceledException) { }
            catch (ApiException error) { if (!ended) ShowStatus(error.UserMessage, true); }
            catch (Exception) { if (!ended) ShowStatus("读取本机记录失败，原文件未被清理。请检查本机存储后重新打开。", true); }
            finally { busy = false; if (!ended) UpdateActions(); }
        }
        private void UpdateActions()
        {
            if (resume == null) return;
            var selected = drafts.SelectedItem as DraftRow;
            string permission = selected?.Draft.Action == MutationAction.UnitCreate ? "unit:create" :
                selected?.Draft.Action == MutationAction.UnitUpdate || selected?.Draft.Action == MutationAction.UnitInlineEdit ? "unit:edit" :
                selected?.Draft.Action == MutationAction.UnitStatus ? "unit:status" : "unit:view";
            resume.IsEnabled = !busy && Current() && selected != null && IsFormDraft(selected.Draft.Action)
                && !selected.Pending && session.CurrentUser.HasPermission(permission);
            delete.IsEnabled = !busy && Current() && selected != null && !selected.Pending;
        }
        private void ResumeSelected()
        {
            if (!resume.IsEnabled || !Current()) return;
            SelectedDraft = ((DraftRow)drafts.SelectedItem).Draft;
            DialogResult = true;
        }
        private async Task DeleteAsync()
        {
            var selected = drafts.SelectedItem as DraftRow;
            if (!delete.IsEnabled || selected == null) return;
            if (MessageBox.Show(this, "删除这份本机草稿？已保存的业务资料和提交记录不会被删除。", "删除草稿",
                MessageBoxButton.OKCancel, MessageBoxImage.Question) != MessageBoxResult.OK) return;
            busy = true; UpdateActions();
            try
            {
                await session.DeleteDraftAsync(selected.Draft.DraftId, selected.Draft.Revision, owner, lifetime.Token);
                if (Current()) await ReloadAsync();
            }
            catch (OperationCanceledException) { }
            catch (ApiException error) { if (!ended) ShowStatus(error.UserMessage, true); }
            finally { busy = false; if (!ended) UpdateActions(); }
        }
        private void InspectSelected()
        {
            if (!Current() || !(journal.SelectedItem is JournalRow row)) return;
            var record = row.Record;
            var detail = new UtenRecordWindow(this, record, session, owner);
            detail.ShowDialog();
        }
        private void OnOwnerChanged(object sender, EventArgs args)
        { if (!ended) Dispatcher.BeginInvoke(new Action(() => { if (!Current()) { drafts.ItemsSource = journal.ItemsSource = null; Close(); } })); }
        protected override void OnClosed(EventArgs args)
        {
            ended = true; lifetime.Cancel(); session.SessionChanged -= OnOwnerChanged; session.ReadScopeChanged -= OnOwnerChanged;
            lifetime.Dispose(); base.OnClosed(args);
        }
        private sealed class UtenRecordWindow : UtenDialogWindow
        {
            private readonly SessionCoordinator session;
            private readonly MutationOwnerSnapshot owner;
            private readonly MutationJournalRecord record;
            private readonly TextBlock review = new TextBlock { TextWrapping = TextWrapping.Wrap };
            private bool ended, opening;
            internal UtenRecordWindow(Window parent, MutationJournalRecord record) : this(parent, record, null, null) { }
            internal UtenRecordWindow(Window parent, MutationJournalRecord record, SessionCoordinator session, MutationOwnerSnapshot owner)
                : base(parent, "原提交与核对依据", 720)
            {
                this.session = session; this.owner = owner; this.record = record;
                Body.Children.Add(new TextBlock { Text = StateName(record.State) + " · " + record.CreatedAtUtc.ToLocalTime().ToString("yyyy-MM-dd HH:mm:ss") });
                Body.Children.Add(new TextBlock { Text = "提交编号：" + record.RequestId, TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, Space("S12"), 0, 0) });
                Body.Children.Add(new TextBlock { Text = "原服务器：" + record.IssuerApiBaseUrl, TextWrapping = TextWrapping.Wrap });
                Body.Children.Add(new TextBlock { Text = "操作：" + ActionName(record.Action), TextWrapping = TextWrapping.Wrap });
                string targetLabel = record.Action.ToString().Contains("RecordRestore") ? "历史版本编号"
                    : record.Action.ToString().Contains("Undo") || record.Action.ToString().Contains("Redo") ? "原操作编号"
                    : record.Action.ToString().Contains("Export") ? "任务编号" : "目标单位 UUID";
                Body.Children.Add(new TextBox { Text = targetLabel + "：" + (record.ResourceId ?? record.ConfirmedResourceId ?? "见原请求中的记录集合或新增内容"),
                    IsReadOnly = true, TextWrapping = TextWrapping.Wrap, BorderThickness = new Thickness(0) });
                Body.Children.Add(new TextBlock { Text = "请求：" + record.Method + " " + record.RelativePath, TextWrapping = TextWrapping.Wrap });
                Body.Children.Add(new TextBox { Text = record.BodyJson, IsReadOnly = true, TextWrapping = TextWrapping.Wrap,
                    MaxHeight = 220, AcceptsReturn = true, VerticalScrollBarVisibility = ScrollBarVisibility.Auto, Margin = new Thickness(0, Space("S12"), 0, 0) });
                if (!String.IsNullOrEmpty(record.ResultJson))
                    Body.Children.Add(new TextBox { Text = record.ResultJson, IsReadOnly = true, TextWrapping = TextWrapping.Wrap,
                        MaxHeight = 180, AcceptsReturn = true, VerticalScrollBarVisibility = ScrollBarVisibility.Auto, Margin = new Thickness(0, Space("S12"), 0, 0) });
                if (record.MayNeedManualReconciliation)
                    Body.Children.Add(new TextBlock { Text = "请在原服务器核对单位详情和操作历史。同名记录或目标值相同不能证明本次提交成功，请勿重复提交。",
                        TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, Space("S12"), 0, 0) });
                review.Text = record.ReviewNote ?? ""; review.Margin = new Thickness(0, Space("S12"), 0, 0); Body.Children.Add(review);
                if (session != null)
                {
                    ActionButton("追加核对说明", () => { _ = AppendAsync(); });
                    session.SessionChanged += OnOwnerChanged; session.ReadScopeChanged += OnOwnerChanged;
                }
                ActionButton("关闭", () => Close());
            }
            private bool Current
            {
                get
                {
                    if (ended) return false;
                    if (session == null) return true; // Read-only isolated UI fixture constructor.
                    var user = session.CurrentUser;
                    return user != null && session.IsAuthenticated && session.Generation == owner.AuthGeneration
                        && session.ReadScopeRevision == owner.ReadScopeRevision && session.CurrentEndpoint?.ApiBaseUrl == owner.IssuerApiBaseUrl
                        && user.Id == owner.UserId && user.BusinessDatasetId == owner.BusinessDatasetId && user.BusinessResetGeneration == owner.BusinessResetGeneration;
                }
            }
            private async Task AppendAsync()
            {
                if (!Current || opening) return;
                opening = true; Actions.IsEnabled = false;
                try
                {
                    var lease = await session.CreateMutationReviewLeaseAsync(record.RequestId, owner, CancellationToken.None);
                    if (!Current) return;
                    var window = new UnitReviewNoteWindow(this, session, lease, owner);
                    window.ShowDialog();
                    if (window.NoteRecorded && Current)
                    {
                        var updated = await session.LoadMutationJournalAsync(record.RequestId, owner, CancellationToken.None);
                        if (Current) review.Text = updated?.ReviewNote ?? "";
                    }
                }
                catch (ApiException error) { if (Current) ShowStatus(error.UserMessage, true); }
                finally { opening = false; if (!ended) Actions.IsEnabled = Current; }
            }
            private void OnOwnerChanged(object sender, EventArgs args)
            {
                if (!ended) Dispatcher.BeginInvoke(new Action(() =>
                { if (!Current && !ended) { Body.Children.Clear(); Actions.IsEnabled = false; Close(); } }));
            }
            protected override void OnClosed(EventArgs args)
            {
                ended = true;
                if (session != null) { session.SessionChanged -= OnOwnerChanged; session.ReadScopeChanged -= OnOwnerChanged; }
                base.OnClosed(args);
            }
        }
    }
}
