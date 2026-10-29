using System;
using System.Collections.Generic;
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
    /// <summary>The same batch endpoints serve single and multiple selections.
    /// Complete mixed results are distinct from all-success and from Unknown.</summary>
    public sealed class UnitBatchWindow : UtenDialogWindow
    {
        private readonly SessionCoordinator session;
        private readonly UnitService service;
        private readonly UnitBatchCommand command;
        private readonly UnitReadOwner owner;
        private readonly CancellationTokenSource lifetime = new CancellationTokenSource();
        private readonly Button confirm, close;
        private readonly DataGrid results = new DataGrid { Height = 240, Visibility = Visibility.Collapsed,
            CanUserSortColumns = false, SelectionMode = DataGridSelectionMode.Single };
        private readonly Border resultSurface;
        private bool ended, retired, submitting, attempted;
        public bool HasConfirmedResult { get; private set; }
        public IReadOnlyList<string> FailedIds { get; private set; } = Array.AsReadOnly(new string[0]);
        public UnitBatchWindow(Window parent, SessionCoordinator session, UnitBatchCommand command,
            UnitReadOwner sourceOwner, IReadOnlyList<UnitRecord> selected) : base(parent,
                command.Action == UnitBatchAction.Delete ? "删除单位" : command.Status == "使用" ? "启用单位" : "停用单位", 680)
        {
            this.session = session; service = new UnitService(session); this.command = command;
            owner = sourceOwner ?? throw new ArgumentNullException(nameof(sourceOwner));
            if (!owner.IsCurrent(session)) throw new ApiException("READ_SCOPE_CHANGED", "当前选择已失效，请重新选择单位。");
            var message = new TextBlock { Text = command.Action == UnitBatchAction.Delete
                ? "确定删除所选 " + command.Ids.Count + " 个单位？存在引用的单位会由服务器阻止删除。"
                : "确定将所选 " + command.Ids.Count + " 个单位设为“" + command.Status + "”？", TextWrapping = TextWrapping.Wrap };
            Body.Children.Add(message);
            if (selected != null)
            {
                var shown = selected.Where(row => command.Ids.Contains(row.Id)).Take(8).Select(row =>
                    String.IsNullOrEmpty(row.Name) ? row.Code ?? row.Id : row.Name);
                Body.Children.Add(new TextBlock { Text = String.Join("、", shown) + (command.Ids.Count > 8 ? " 等" : ""),
                    TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, Space("S12"), 0, Space("S12")) });
            }
            results.Columns.Add(new DataGridTextColumn { Header = "单位", Binding = new Binding("DisplayName"), Width = new DataGridLength(1, DataGridLengthUnitType.Star) });
            results.Columns.Add(new DataGridTextColumn { Header = "结果", Binding = new Binding("ResultText"), Width = 90 });
            results.Columns.Add(new DataGridTextColumn { Header = "原因", Binding = new Binding(nameof(UnitBatchDisplay.Reason)), Width = new DataGridLength(1, DataGridLengthUnitType.Star) });
            resultSurface = UtenSurfaces.Wrap(results, UtenSurfaceRole.Table); resultSurface.Visibility = Visibility.Collapsed;
            Body.Children.Add(resultSurface);
            close = ActionButton("取消", () => Close());
            confirm = ActionButton("确认", () => { _ = SubmitAsync(); }, primary: true);
            session.SessionChanged += OnOwnerChanged; session.ReadScopeChanged += OnOwnerChanged;
            (parent as IPendingEditHost)?.TrackPendingEditor(this);
        }
        private bool Current { get { return !ended && !retired && owner.IsCurrent(session); } }
        private void UpdateActions()
        {
            confirm.IsEnabled = Current && !submitting && !attempted;
            CloseButton.IsEnabled = close.IsEnabled = !submitting;
        }
        private async Task SubmitAsync()
        {
            if (!Current || submitting || attempted) return;
            submitting = true; attempted = true; UpdateActions();
            try
            {
                var request = service.PrepareBatch(Guid.NewGuid().ToString("D"), command, owner);
                var result = await service.SendAsync(request, lifetime.Token);
                if (!Current) return; // Frozen result still belongs to the original owner in Core's journal.
                close.Content = "关闭";
                if (result.Outcome == MutationOutcome.Confirmed)
                {
                    HasConfirmedResult = true;
                    UnitBatchResult batch;
                    try { batch = UnitBatchResult.Parse(result.ResponseJson, command); }
                    catch (Exception error) when (error is FormatException || error is ArgumentException || error is InvalidOperationException)
                    { ShowStatus("服务器已确认返回，结果显示暂未完成。请从提交记录核对，不会再次提交。", true); return; }
                    FailedIds = Array.AsReadOnly(batch.Results.Where(item => !item.Ok).Select(item => item.Id).ToArray());
                    results.ItemsSource = batch.Results.Select(item => new UnitBatchDisplay { Id = item.Id, Label = item.Label, Ok = item.Ok, Reason = item.Reason }).ToList();
                    results.Visibility = Visibility.Visible;
                    resultSurface.Visibility = Visibility.Visible;
                    ShowStatus("成功 " + batch.Succeeded + " 项，失败 " + batch.Failed + " 项。"
                        + (batch.Failed > 0 ? "失败项将保留选择；已成功项不会重复提交。" : "")
                        + (result.IsDurablyRecorded ? "" : "本机终态尚未保存完整，请核对提交记录。"), !result.IsDurablyRecorded || batch.Failed > 0);
                }
                else if (result.Outcome == MutationOutcome.Unknown || result.NeedsManualReconciliation)
                    ShowStatus("原选择和提交编号已保留，结果待核对：" + request.RequestId + "。请核对原服务器记录，不要直接重提。", true);
                else
                {
                    ShowStatus(result.Error?.UserMessage ?? "本次没有完成，原选择已保留。", true);
                    // A definite rejection is a completed attempt; another explicit decision is made after closing.
                }
            }
            catch (ApiException error) { if (Current) ShowStatus(error.UserMessage, true); }
            catch (OperationCanceledException) { }
            catch (Exception) { if (Current) ShowStatus("本次结果暂未确认，请先核对提交记录；不会自动重试。", true); }
            finally { submitting = false; if (!ended) { UpdateActions(); if (retired) Close(); } }
        }
        private void OnOwnerChanged(object sender, EventArgs args)
        {
            if (ended) return;
            Dispatcher.BeginInvoke(new Action(() =>
            {
                if (Current || ended) return;
                retired = true; Body.Children.Clear(); lifetime.Cancel(); UpdateActions();
                ShowStatus("账号、权限或读取范围已变化，原操作记录保留在原账号中。");
                if (!submitting) Close();
            }));
        }
        protected override void OnClosing(CancelEventArgs args) { if (submitting) args.Cancel = true; base.OnClosing(args); }
        protected override void OnClosed(EventArgs args)
        {
            ended = true; lifetime.Cancel(); session.SessionChanged -= OnOwnerChanged; session.ReadScopeChanged -= OnOwnerChanged;
            lifetime.Dispose(); base.OnClosed(args);
        }
        private sealed class UnitBatchDisplay
        {
            public string Id { get; set; }
            public string Label { get; set; }
            public bool Ok { get; set; }
            public string Reason { get; set; }
            public string DisplayName { get { return String.IsNullOrEmpty(Label) ? Id : Label; } }
            public string ResultText { get { return Ok ? "成功" : "失败"; } }
        }
    }
}
