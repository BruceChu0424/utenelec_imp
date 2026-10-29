using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Globalization;
using System.Linq;
using System.Threading;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Data;
using System.Windows.Threading;
using Uten.Legacy.Core;
using Uten.Legacy.Desktop.Controls;
using Uten.Legacy.Desktop.Features.Columns;
using Uten.Legacy.Desktop.Shared;

namespace Uten.Legacy.Desktop.Features.Units
{
    public sealed class UnitExportWindow : UtenDialogWindow
    {
        private sealed class JobRow
        {
            public string Id;
            public MutationExportJob Job;
            public MutationJournalRecord Pending;
            public string State { get { return Job == null ? "待核对" : StateText(Job.Status); } }
            public string Rows { get { return Job == null ? "—" : Job.Rows.ToString(CultureInfo.InvariantCulture); } }
            public string Created
            {
                get
                {
                    DateTimeOffset time;
                    return Job != null && DateTimeOffset.TryParse(Job.CreatedAt, CultureInfo.InvariantCulture, DateTimeStyles.None, out time)
                        ? time.ToLocalTime().ToString("yyyy-MM-dd HH:mm") : Pending?.CreatedAtUtc.ToLocalTime().ToString("yyyy-MM-dd HH:mm") ?? "";
                }
            }
            public string Identity { get { return Id; } }
        }
        private readonly SessionCoordinator session;
        private readonly UnitExportService service;
        private readonly UnitReadOwner owner;
        private readonly MutationOwnerSnapshot mutationOwner;
        private readonly UnitQuery query;
        private readonly UnitColumnProjection projection;
        private readonly IWorkbookSavePicker picker;
        private readonly CancellationTokenSource lifetime = new CancellationTokenSource();
        private readonly DispatcherTimer poll = new DispatcherTimer { Interval = TimeSpan.FromSeconds(3) };
        private readonly DataGrid jobs = new DataGrid { Height = 220, SelectionMode = DataGridSelectionMode.Single, CanUserSortColumns = false };
        private readonly PasswordBox password = new PasswordBox { MaxLength = 128 };
        private readonly Button create, refresh, reconcile, confirmOriginal, cancelJob, download, cancelDownload;
        private readonly TextBlock saved = new TextBlock { TextWrapping = TextWrapping.Wrap };
        private CancellationTokenSource transfer;
        private JobRow currentJob;
        private string pendingLocalId, pendingBody, pendingJobId;
        private bool ended, retired, busy, loading, available, capabilityKnown, closeAfterBusy;
        private string highlightedId;
        public UnitExportWindow(Window parent, SessionCoordinator session, UnitQuery query, UnitColumnProjection projection, UnitReadOwner sourceOwner,
            IWorkbookSavePicker picker = null)
            : base(parent, "导出单位资料", 900)
        {
            this.session = session; service = new UnitExportService(session); this.query = query; this.projection = projection;
            this.picker = picker ?? new NativeWorkbookSavePicker();
            owner = sourceOwner ?? throw new ArgumentNullException(nameof(sourceOwner));
            mutationOwner = session.CaptureMutationOwner();
            if (!owner.IsCurrent(session) || !owner.Matches(mutationOwner) || session.CurrentUser?.HasPermission("unit:export") != true)
                throw new ApiException("READ_SCOPE_CHANGED", "导出条件的账号或权限已变化，请重新打开。");
            Body.Children.Add(new TextBlock { Text = "生成当前完整筛选的 Excel，或选择最近的原任务继续。选择历史任务下载时，使用该任务原来的筛选和读取时点。",
                TextWrapping = TextWrapping.Wrap });
            jobs.Margin = new Thickness(0, Space("S12"), 0, Space("S12"));
            jobs.Columns.Add(new DataGridTextColumn { Header = "创建时间", Binding = new Binding("Created"), Width = 190 });
            jobs.Columns.Add(new DataGridTextColumn { Header = "状态", Binding = new Binding("State"), Width = 100 });
            jobs.Columns.Add(new DataGridTextColumn { Header = "行数", Binding = new Binding("Rows"), Width = 80 });
            jobs.Columns.Add(new DataGridTextColumn { Header = "任务编号", Binding = new Binding("Identity"), Width = new DataGridLength(1, DataGridLengthUnitType.Star) });
            Body.Children.Add(UtenSurfaces.Wrap(jobs, UtenSurfaceRole.Table));
            Body.Children.Add(new TextBlock { Text = "Excel 打开密码（可选，仅在下载时使用）", Margin = new Thickness(0, Space("S12"), 0, Space("S6")) });
            Body.Children.Add(password); saved.Margin = new Thickness(0, Space("S12"), 0, 0); Body.Children.Add(saved);
            create = ActionButton("生成当前筛选", () => { _ = CreateAsync(false); }, primary: true);
            refresh = ActionButton("刷新", () => { _ = ReloadAsync(); });
            reconcile = ActionButton("核对原任务", () => { _ = ReconcileAsync(); });
            confirmOriginal = ActionButton("按原任务再次确认", () => { _ = CreateAsync(true); });
            cancelJob = ActionButton("取消任务", () => { _ = CancelJobAsync(); });
            download = ActionButton("下载Excel", () => { _ = DownloadAsync(); });
            cancelDownload = ActionButton("停止下载", () => transfer?.Cancel());
            jobs.SelectionChanged += (sender, args) => { currentJob = jobs.SelectedItem as JobRow; UpdateActions(); };
            session.SessionChanged += OnOwnerChanged; session.ReadScopeChanged += OnOwnerChanged;
            poll.Tick += async (sender, args) => { if (!busy && !loading && Current) await ReloadAsync(); };
            (parent as IPendingEditHost)?.TrackPendingEditor(this);
            Loaded += async (sender, args) => await LoadAsync();
            UpdateActions();
        }
        private bool Current { get { return !ended && !retired && owner.IsCurrent(session) && session.CurrentUser?.HasPermission("unit:export") == true; } }
        private static string StateText(string state)
        {
            switch (state) { case "PENDING": return "排队中"; case "RUNNING": return "生成中"; case "SUCCEEDED": return "已生成";
                case "FAILED": return "失败"; case "CANCELLED": return "已取消"; case "EXPIRED": return "已过期"; default: return "待核对"; }
        }
        private async Task LoadAsync()
        {
            loading = true; UpdateActions();
            try
            {
                var capability = await service.AvailableAsync(lifetime.Token);
                if (!Current || !capability.IsCurrent(session)) return;
                available = capability.Value; capabilityKnown = true;
                if (available) { await ReloadAsync(); poll.Start(); }
                else ShowStatus("当前服务器未启用后台任务，下载将按当前完整筛选生成 Excel。");
            }
            catch (ApiException error) { HandleError(error); }
            catch (OperationCanceledException) { }
            catch (Exception) { if (Current) ShowStatus("读取导出能力失败，请重新打开；没有创建或重复提交任务。", true); }
            finally { loading = false; if (!ended) UpdateActions(); }
        }
        private async Task ReloadAsync()
        {
            if (!Current || busy) return;
            loading = true; UpdateActions();
            string selected = highlightedId ?? currentJob?.Id;
            try
            {
                var recent = await service.RecentAsync(lifetime.Token);
                var local = await session.ListMutationJournalAsync(mutationOwner, lifetime.Token);
                if (!Current || !recent.IsCurrent(session)) return;
                var rows = recent.Value.Select(job => new JobRow { Id = job.Id, Job = job }).ToDictionary(row => row.Id, StringComparer.Ordinal);
                foreach (var record in local.Where(record => record.Action == MutationAction.UnitExportSubmit && record.MayNeedManualReconciliation))
                {
                    // An explicit same-server-key, byte-identical submit can provide a
                    // strong server acknowledgement even on readers without GET proof.
                    // Retain the original Unknown journal; do not relabel its causality.
                    bool covered = local.Any(known => known.Action == MutationAction.UnitExportSubmit && known.State == MutationJournalState.Confirmed
                        && known.ResourceId == record.ResourceId && known.BodyJson == record.BodyJson
                        && known.ReceiptStrategy == MutationReceiptStrategy.ExportJobCreation);
                    if (covered) continue;
                    JobRow row;
                    if (!rows.TryGetValue(record.ResourceId, out row)) { row = new JobRow { Id = record.ResourceId }; rows.Add(row.Id, row); }
                    row.Pending = record;
                }
                var data = rows.Values.OrderByDescending(row => row.Created, StringComparer.Ordinal).ToList();
                jobs.ItemsSource = data; jobs.SelectedItem = data.FirstOrDefault(row => row.Id == selected);
                highlightedId = null;
                if (currentJob == null && data.Count != 0) jobs.SelectedIndex = 0;
            }
            catch (ApiException error) { HandleError(error); }
            catch (OperationCanceledException) { }
            catch (Exception) { if (Current) ShowStatus("读取导出任务失败，原任务和待核对内容仍保留。", true); }
            finally { loading = false; if (!ended) UpdateActions(); }
        }
        private void UpdateActions()
        {
            if (create == null) return;
            bool ready = Current && !busy && !loading && !closeAfterBusy;
            bool selectedUnknown = currentJob?.Pending != null || pendingLocalId != null && (currentJob == null || currentJob.Id == pendingJobId);
            create.IsEnabled = ready && capabilityKnown && available && !selectedUnknown && pendingLocalId == null;
            refresh.IsEnabled = ready && capabilityKnown && available;
            reconcile.IsEnabled = confirmOriginal.IsEnabled = ready && selectedUnknown;
            cancelJob.IsEnabled = ready && currentJob?.Job != null && (currentJob.Job.Status == "PENDING" || currentJob.Job.Status == "RUNNING") && !currentJob.Job.CancelRequested;
            download.IsEnabled = ready && capabilityKnown && (!available || currentJob?.Job?.Status == "SUCCEEDED" && currentJob.Pending == null);
            password.IsEnabled = ready; jobs.IsEnabled = ready;
            cancelDownload.Visibility = transfer == null ? Visibility.Collapsed : Visibility.Visible;
            CloseButton.IsEnabled = !busy;
        }
        private async Task CreateAsync(bool sameOriginal)
        {
            if (!Current || busy || loading || !available) return;
            string body, jobId;
            if (sameOriginal)
            {
                if (!confirmOriginal.IsEnabled) return;
                var original = currentJob?.Pending;
                body = original?.BodyJson ?? pendingBody; jobId = original?.ResourceId ?? pendingJobId;
                if (body == null || jobId == null) return;
            }
            else
            {
                if (!create.IsEnabled) return;
                jobId = Guid.NewGuid().ToString("D"); body = UnitExportService.CreateBody(jobId, query, projection);
            }
            busy = true; UpdateActions();
            try
            {
                var request = service.PrepareSubmit(Guid.NewGuid().ToString("D"), body, owner);
                pendingBody = body; pendingJobId = jobId; pendingLocalId = request.RequestId;
                highlightedId = jobId;
                var result = await session.MutateAsync(request, lifetime.Token);
                if (!Current) return;
                if (result.Outcome == MutationOutcome.Confirmed)
                {
                    pendingLocalId = pendingBody = pendingJobId = null; highlightedId = jobId;
                    ShowStatus("原任务已确认，文件生成后可下载。" + (result.IsDurablyRecorded ? "" : "本机终态尚未保存完整，请核对原记录。"), !result.IsDurablyRecorded);
                }
                else if (result.Outcome == MutationOutcome.Unknown || result.NeedsManualReconciliation)
                    ShowStatus("任务提交结果待核对。原任务编号和完整条件已保留；可只读核对，或明确按同一原任务再次确认，不会另建任务编号。", true);
                else
                {
                    pendingLocalId = pendingBody = pendingJobId = null;
                    ShowStatus(result.Error?.UserMessage ?? "本次未确认创建导出任务。", true);
                }
            }
            catch (ApiException error) { HandleError(error); }
            catch (OperationCanceledException) { }
            catch (Exception) { if (Current) ShowStatus("提交结果尚未确认，请从本机原记录核对；不会自动再次提交。", true); }
            finally
            {
                busy = false; if (!ended) { UpdateActions(); if (retired || closeAfterBusy) Close(); else await ReloadAsync(); }
            }
        }
        private async Task ReconcileAsync()
        {
            if (!reconcile.IsEnabled) return;
            string requestId = currentJob?.Pending?.RequestId ?? pendingLocalId;
            if (requestId == null) return;
            busy = true; UpdateActions();
            try
            {
                var result = await session.ReconcileUnitExportAsync(requestId, mutationOwner, lifetime.Token);
                if (!Current) return;
                if (result.Outcome == MutationOutcome.Confirmed)
                {
                    pendingLocalId = pendingBody = pendingJobId = null;
                    ShowStatus("服务器原请求与本机冻结条件一致，已核对原任务。" + (result.IsDurablyRecorded ? "" : "本机终态尚未完整保存。"), !result.IsDurablyRecorded);
                }
                else ShowStatus("尚未获得与原条件一致的创建凭据，原结果仍待核对；不会凭同名或同状态认领。", true);
            }
            catch (ApiException error) { HandleError(error); }
            catch (OperationCanceledException) { }
            finally { busy = false; if (!ended) { UpdateActions(); if (retired || closeAfterBusy) Close(); else await ReloadAsync(); } }
        }
        private async Task CancelJobAsync()
        {
            if (!cancelJob.IsEnabled) return;
            string id = currentJob.Id; busy = true; UpdateActions();
            try
            {
                var request = service.PrepareCancel(Guid.NewGuid().ToString("D"), id, owner);
                var result = await session.MutateAsync(request, lifetime.Token);
                if (Current) ShowStatus(result.Outcome == MutationOutcome.Confirmed ? "已获得任务当前状态；取消是否完成以任务状态为准。"
                    : result.Error?.UserMessage ?? "取消结果待核对，请先刷新原任务，不会自动重发。", result.Outcome != MutationOutcome.Confirmed);
            }
            catch (ApiException error) { HandleError(error); }
            catch (OperationCanceledException) { }
            finally { busy = false; if (!ended) { UpdateActions(); if (retired || closeAfterBusy) Close(); else await ReloadAsync(); } }
        }
        private async Task DownloadAsync()
        {
            if (!download.IsEnabled) return;
            busy = true; UpdateActions(); string secret = password.Password;
            try
            {
                if (available) await service.AuthorizeDownloadAsync(currentJob.Id, owner, lifetime.Token);
                if (!Current) return;
                string destination = picker.Choose(this);
                if (destination == null || !Current) return;
                transfer = CancellationTokenSource.CreateLinkedTokenSource(lifetime.Token); UpdateActions();
                var progress = new Progress<long>(bytes => { if (Current) ShowStatus("正在保存 Excel：" + (bytes / 1024d / 1024d).ToString("0.0") + " MiB"); });
                UnitExportFile file = available
                    ? await session.DownloadUnitExportJobAsync(currentJob.Id, secret, destination, mutationOwner, transfer.Token, progress)
                    : await session.DownloadLegacyUnitExportAsync(UnitExportService.LegacyParameters(query), secret, projection?.ToJson(),
                        destination, mutationOwner, transfer.Token, progress);
                if (Current) { saved.Text = file.Path; ShowStatus("Excel 已完整保存。"); }
            }
            catch (OperationCanceledException) { if (Current) ShowStatus("已停止下载，原任务仍保留，没有保存部分文件。"); }
            catch (ApiException error) { HandleError(error); }
            catch (Exception) { if (Current) ShowStatus("Excel 未能保存，请检查任务和目标目录；不会自动重新下载。", true); }
            finally
            {
                secret = null; password.Clear(); transfer?.Dispose(); transfer = null; busy = false;
                if (!ended) { UpdateActions(); if (retired || closeAfterBusy) Close(); }
            }
        }
        private void OnOwnerChanged(object sender, EventArgs args)
        {
            if (ended) return;
            Dispatcher.BeginInvoke(new Action(() =>
            {
                if (Current || ended) return;
                retired = true; poll.Stop(); password.Clear(); jobs.ItemsSource = null; Body.Children.Clear(); lifetime.Cancel(); UpdateActions();
                if (!busy) Close();
            }));
        }
        private void HandleError(ApiException error)
        {
            if (!Current) return;
            if (error.StatusCode == 403)
            {
                retired = true; poll.Stop(); password.Clear(); jobs.ItemsSource = null; saved.Text = "";
                Body.Visibility = Visibility.Collapsed; lifetime.Cancel(); UpdateActions();
            }
            ShowStatus(error.UserMessage, true);
        }
        protected override void OnClosing(CancelEventArgs args)
        {
            base.OnClosing(args);
            if (busy) { closeAfterBusy = true; transfer?.Cancel(); lifetime.Cancel(); args.Cancel = true; }
        }
        protected override void OnClosed(EventArgs args)
        {
            ended = true; poll.Stop(); lifetime.Cancel(); password.Clear();
            session.SessionChanged -= OnOwnerChanged; session.ReadScopeChanged -= OnOwnerChanged; lifetime.Dispose(); base.OnClosed(args);
        }
    }
}
