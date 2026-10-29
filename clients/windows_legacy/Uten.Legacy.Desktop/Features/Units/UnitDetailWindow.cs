using System;
using System.Threading;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Controls;
using Uten.Legacy.Core;
using Uten.Legacy.Desktop.Controls;

namespace Uten.Legacy.Desktop.Features.Units
{
    public sealed class UnitDetailWindow : UtenDialogWindow
    {
        private readonly SessionCoordinator session;
        private readonly UnitService service;
        private readonly UnitReadOwner owner;
        private readonly CancellationTokenSource lifetime = new CancellationTokenSource();
        private readonly StackPanel values = new StackPanel();
        private UnitReadSnapshot<UnitRecord> detail;
        private Button statusAction;
        private bool ended, childOpen, retired;
        public bool BusinessChanged { get; private set; }
        public UnitDetailWindow(Window parent, SessionCoordinator session, UnitReadSnapshot<UnitRecord> detail)
            : base(parent, String.IsNullOrEmpty(detail?.Value.Name) ? detail?.Value.Code ?? "单位详情" : detail.Value.Name, 600)
        {
            this.session = session; this.detail = detail ?? throw new ArgumentNullException(nameof(detail));
            service = new UnitService(session); owner = detail.Owner;
            if (!owner.IsCurrent(session)) throw new ApiException("READ_SCOPE_CHANGED", "单位详情已失效，请重新读取。");
            Body.Children.Add(values); ShowValues();
            ActionButton("版本历史", () => { _ = HistoryAsync(); });
            if (session.CurrentUser.HasPermission("unit:edit")) ActionButton("编辑", () => { _ = EditAsync(); }, primary: true);
            if (session.CurrentUser.HasPermission("unit:status"))
                statusAction = ActionButton(detail.Value.Status == "使用" ? "停用" : "启用", () => { _ = BatchAsync(false); });
            if (session.CurrentUser.HasPermission("unit:delete")) ActionButton("删除", () => { _ = BatchAsync(true); });
            ActionButton("关闭", () => Close());
            session.SessionChanged += OnOwnerChanged; session.ReadScopeChanged += OnOwnerChanged;
            (parent as IPendingEditHost)?.TrackPendingEditor(this);
        }
        private bool Current { get { return !ended && !retired && owner.IsCurrent(session); } }
        private void ShowValues()
        {
            SetHeading(String.IsNullOrEmpty(detail.Value.Name) ? detail.Value.Code ?? "单位详情" : detail.Value.Name);
            if (statusAction != null) statusAction.Content = detail.Value.Status == "使用" ? "停用" : "启用";
            values.Children.Clear();
            AddValue("编号", detail.Value.Code);
            AddValue("单位名称", detail.Value.Name);
            AddValue("状态", detail.Value.Status);
        }
        private void AddValue(string label, string text)
        {
            var line = new Grid { Margin = new Thickness(0, Space("S8"), 0, Space("S8")) };
            line.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(100) }); line.ColumnDefinitions.Add(new ColumnDefinition());
            var caption = new TextBlock { Text = label }; caption.SetResourceReference(TextBlock.ForegroundProperty, "Uten.Muted");
            var value = new TextBlock { Text = text ?? "—", TextWrapping = TextWrapping.Wrap };
            Grid.SetColumn(value, 1); line.Children.Add(caption); line.Children.Add(value); values.Children.Add(line);
        }
        private async Task EditAsync()
        {
            if (!Current || childOpen) return; childOpen = true; Actions.IsEnabled = false;
            try
            {
                var editor = new UnitEditorWindow(this, session, service, detail, MutationAction.UnitUpdate);
                editor.ShowDialog();
                if (editor.BusinessChanged && Current) { BusinessChanged = true; await ReloadAsync(); }
            }
            catch (ApiException error) { if (Current) ShowStatus(error.UserMessage, true); }
            catch (Exception) { if (Current) ShowStatus("暂时无法打开编辑，请重新读取单位详情。", true); }
            finally { childOpen = false; if (!ended) { Actions.IsEnabled = Current; if (retired) Close(); } }
        }
        private async Task BatchAsync(bool delete)
        {
            if (!Current || childOpen) return; childOpen = true; Actions.IsEnabled = false;
            try
            {
                var command = new UnitBatchCommand(delete ? UnitBatchAction.Delete : UnitBatchAction.Status,
                    new[] { detail.Value.Id }, delete ? null : detail.Value.Status == "使用" ? "禁用" : "使用");
                var window = new UnitBatchWindow(this, session, command, detail.Owner, new[] { detail.Value });
                window.ShowDialog();
                if (window.HasConfirmedResult && Current)
                {
                    BusinessChanged = true;
                    if (delete && window.FailedIds.Count == 0) Close(); else await ReloadAsync();
                }
            }
            catch (ApiException error) { if (Current) ShowStatus(error.UserMessage, true); }
            catch (Exception) { if (Current) ShowStatus("本次操作结果请先核对提交记录，不会自动重试。", true); }
            finally { childOpen = false; if (!ended) { Actions.IsEnabled = Current; if (retired) Close(); } }
        }
        private async Task HistoryAsync()
        {
            if (!Current || childOpen) return; childOpen = true; Actions.IsEnabled = false;
            try
            {
                var history = new UnitRecordHistoryWindow(this, session, detail.Value.Id);
                history.ShowDialog();
                if (history.BusinessChanged && Current) { BusinessChanged = true; await ReloadAsync(); }
            }
            catch (ApiException error) { if (Current) ShowStatus(error.UserMessage, true); }
            catch (Exception) { if (Current) ShowStatus("暂时无法打开版本历史，请稍后重试。", true); }
            finally { childOpen = false; if (!ended) { Actions.IsEnabled = Current; if (retired) Close(); } }
        }
        private async Task ReloadAsync()
        {
            try
            {
                var updated = await service.DetailAsync(detail.Value.Id, lifetime.Token);
                if (!Current || !updated.IsCurrent(session)) return;
                detail = updated; ShowValues();
            }
            catch (OperationCanceledException) { }
            catch (ApiException error) { if (Current) ShowStatus("操作结果已保留；详情刷新：" + error.UserMessage, true); }
        }
        private void OnOwnerChanged(object sender, EventArgs args)
        {
            if (ended) return;
            Dispatcher.BeginInvoke(new Action(() =>
            {
                if (Current || ended) return;
                retired = true; SetHeading("单位详情已失效"); Body.Children.Clear(); Actions.IsEnabled = false; lifetime.Cancel(); Close();
            }));
        }
        protected override void OnClosed(EventArgs args)
        {
            ended = true; lifetime.Cancel(); session.SessionChanged -= OnOwnerChanged; session.ReadScopeChanged -= OnOwnerChanged;
            lifetime.Dispose(); base.OnClosed(args);
        }
    }
}
