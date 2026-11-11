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
        private readonly IReadOnlyList<string> selectedIds;
        private readonly RadioButton allScope = new RadioButton { GroupName = "unit-output-scope" };
        private readonly RadioButton selectedScope = new RadioButton { GroupName = "unit-output-scope" };
        private bool selectedOnly;
        private IReadOnlyList<string> CurrentSelectedIds { get { return selectedOnly ? selectedIds : null; } }
        private readonly IWorkbookSavePicker picker;
        private readonly CancellationTokenSource lifetime = new CancellationTokenSource();
        private readonly DispatcherTimer poll = new DispatcherTimer { Interval = TimeSpan.FromSeconds(3) };
        private readonly DataGrid jobs = new UtenDataGrid { Height = 220, SelectionMode = DataGridSelectionMode.Single, CanUserSortColumns = false };
        private readonly PasswordBox password = new PasswordBox { MaxLength = 128 };
        private readonly Button create, refresh, reconcile, confirmOriginal, cancelJob, download, cancelDownload;
        private readonly TextBlock saved = new TextBlock { TextWrapping = TextWrapping.Wrap };
        private CancellationTokenSource transfer;
        private JobRow currentJob;
        private string pendingLocalId, pendingBody, pendingJobId;
        private bool pendingSelected;
        private bool ended, retired, busy, loading, available, capabilityKnown, closeAfterBusy;
        private int selectionVersion;
        private string highlightedId;
        public UnitExportWindow(Window parent, SessionCoordinator session, UnitQuery query, UnitColumnProjection projection, UnitReadOwner sourceOwner,
            IWorkbookSavePicker picker = null, IReadOnlyList<string> selectedIds = null, long? totalCount = null, bool selectedOnly = true)
            : base(parent, "导出单位资料", 900)
        {
            this.session = session; service = new UnitExportService(session); this.query = query; this.projection = projection;
            this.selectedIds = selectedIds == null ? null : Array.AsReadOnly(selectedIds.ToArray());
            this.selectedOnly = selectedOnly && this.selectedIds?.Count > 0;
            this.picker = picker ?? new NativeWorkbookSavePicker();
            owner = sourceOwner ?? throw new ArgumentNullException(nameof(sourceOwner));
            mutationOwner = session.CaptureMutationOwner();
            if (!owner.IsCurrent(session) || !owner.Matches(mutationOwner) || session.CurrentUser?.HasPermission("unit:export") != true)
                throw new ApiException("READ_SCOPE_CHANGED", "导出条件的账号或权限已变化，请重新打开。");
            var scopeChoices = new WrapPanel { Orientation = Orientation.Horizontal };
            allScope.Content = totalCount.HasValue ? "全部（" + totalCount.Value + " 项）" : "全部（当前筛选）";
            selectedScope.Content = "仅选中（" + (this.selectedIds?.Count ?? 0) + " 项）";
            selectedScope.Margin = new Thickness(Space("S16"), 0, 0, 0);
            allScope.IsChecked = !this.selectedOnly; selectedScope.IsChecked = this.selectedOnly;
            allScope.Checked += (sender, args) => ChangeScope(false);
            selectedScope.Checked += (sender, args) => ChangeScope(true);
            scopeChoices.Children.Add(allScope); scopeChoices.Children.Add(selectedScope); Body.Children.Add(scopeChoices);
            jobs.Margin = new Thickness(0, Space("S12"), 0, Space("S12"));
            jobs.Columns.Add(new DataGridTextColumn { Header = "创建时间", Binding = new Binding("Created") });
            jobs.Columns.Add(new DataGridTextColumn { Header = "状态", Binding = new Binding("State") });
            jobs.Columns.Add(new DataGridTextColumn { Header = "行数", Binding = new Binding("Rows") });
            jobs.Columns.Add(new DataGridTextColumn { Header = "任务编号", Binding = new Binding("Identity") });
            Body.Children.Add(UtenSurfaces.Wrap(jobs, UtenSurfaceRole.Table));
            Body.Children.Add(new TextBlock { Text = "Excel 打开密码（可选，仅在下载时使用）", Margin = new Thickness(0, Space("S12"), 0, Space("S6")) });
            Body.Children.Add(password); saved.Margin = new Thickness(0, Space("S12"), 0, 0); Body.Children.Add(saved);
            create = ActionButton("生成当前筛选", () => { _ = CreateAsync(false); }, primary: true);
            refresh = ActionButton("刷新", () => { _ = RefreshAsync(); });
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
        private void ChangeScope(bool selected)
        {
            if (busy || loading || pendingLocalId != null || currentJob?.Pending != null || selected && (selectedIds == null || selectedIds.Count == 0)) return;
            selectedOnly = selected; currentJob = null; highlightedId = null; jobs.SelectedItem = null; UpdateActions();
        }
        private static string StateText(string state)
        {
            switch (state) { case "PENDING": return "排队中"; case "RUNNING": return "生成中"; case "WAITING_PRECISION": return "待确认精度"; case "SUCCEEDED": return "已生成";
                case "FAILED": return "失败"; case "CANCELLED": return "已取消"; case "EXPIRED": return "已过期"; default: return "待核对"; }
        }
        private async Task LoadAsync()
        {
            loading = true; UpdateActions();
            try
            {
                var capability = await service.AvailableAsync(lifetime.Token);
                if (!Current || !capability.IsCurrent(session)) return;
                available = capability.Value.Available; selectionVersion = capability.Value.SelectionVersion; capabilityKnown = true;
                if (available) { await ReloadAsync(); poll.Start(); }
                else ShowStatus("当前服务器未启用后台任务，下载将按本次范围生成 Excel。");
                if(selectedOnly && selectionVersion<1)ShowStatus(UnitExportService.SelectionUnsupported().UserMessage,true);
            }
            catch (ApiException error) { HandleError(error); }
            catch (OperationCanceledException) { }
            catch (Exception) { if (Current) ShowStatus("读取导出能力失败，请重新打开；没有创建或重复提交任务。", true); }
            finally { loading = false; if (!ended) UpdateActions(); }
        }
        private async Task RefreshSelectedCapabilityAsync(bool expectedJobs)
        {
            var capability=await service.AvailableAsync(lifetime.Token);
            if(!Current||!capability.IsCurrent(session))throw new OperationCanceledException();
            available=capability.Value.Available;selectionVersion=capability.Value.SelectionVersion;capabilityKnown=true;
            service.RequireSelectionSupport();
            if(available!=expectedJobs)throw new ApiException("EXPORT_CAPABILITY_CHANGED","服务器导出方式已变化，请重新打开导出；没有提交或下载，也不会自动切换范围。");
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
                // History has its own frozen scope. A new output-range choice must
                // never silently select a prior all-row artifact for download.
            }
            catch (ApiException error) { HandleError(error); }
            catch (OperationCanceledException) { }
            catch (Exception) { if (Current) ShowStatus("读取导出任务失败，原任务和待核对内容仍保留。", true); }
            finally { loading = false; if (!ended) UpdateActions(); }
        }
        private async Task RefreshAsync()
        {
            if (!Current || busy || loading) return;
            using (UtenBusyDialog.Show(this, "正在读取原导出任务")) await ReloadAsync();
        }
        private void UpdateActions()
        {
            if (create == null) return;
            bool ready = Current && !busy && !loading && !closeAfterBusy;
            bool selectedUnknown = currentJob?.Pending != null || pendingLocalId != null && (currentJob == null || currentJob.Id == pendingJobId);
            allScope.IsEnabled = ready && !selectedUnknown && pendingLocalId == null;
            selectedScope.IsEnabled = allScope.IsEnabled && selectedIds?.Count > 0 && capabilityKnown && selectionVersion>=1;
            selectedScope.ToolTip = selectionVersion>=1?null:"当前服务器尚不支持选中导出，请更新服务端后重试。";
            ToolTipService.SetShowOnDisabled(selectedScope,true);
            bool rangeSupported=!selectedOnly||selectionVersion>=1;
            create.IsEnabled = ready && rangeSupported && capabilityKnown && available && !selectedUnknown && pendingLocalId == null;
            refresh.IsEnabled = ready && capabilityKnown && available;
            reconcile.IsEnabled = ready && selectedUnknown;
            bool originalSelected = currentJob?.Pending?.HasExportSelection ?? pendingSelected;
            confirmOriginal.IsEnabled = ready && available && selectedUnknown && (selectionVersion>=1 || !originalSelected);
            cancelJob.IsEnabled = ready && currentJob?.Job != null && (currentJob.Job.Status == "PENDING" || currentJob.Job.Status == "RUNNING") && !currentJob.Job.CancelRequested;
            download.IsEnabled = ready && rangeSupported && capabilityKnown && (!available || currentJob?.Job?.Status == "SUCCEEDED" && currentJob.Pending == null);
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
                jobId = Guid.NewGuid().ToString("D");
                body = null;
            }
            busy = true; UpdateActions();
            try
            {
                using (var waiting = UtenBusyDialog.Show(this, "正在保全导出范围并提交原任务"))
                {
                var selected = CurrentSelectedIds;
                if (body == null) body = await Task.Run(() => UnitExportService.CreateBody(jobId, query, projection, selected), lifetime.Token);
                if (!Current) return;
                bool hasSelection = sameOriginal ? currentJob?.Pending?.HasExportSelection ?? pendingSelected : selected != null;
                if (hasSelection) await RefreshSelectedCapabilityAsync(true);
                var request = await Task.Run(() => service.PrepareSubmit(Guid.NewGuid().ToString("D"), body, owner), lifetime.Token);
                if (!Current) return;
                pendingSelected = request.HasExportSelection;
                pendingBody = body; pendingJobId = jobId; pendingLocalId = request.RequestId;
                highlightedId = jobId;
                // A fast transport may complete synchronously. The original
                // body/proof validation and durable journal still run off the
                // dispatcher, with the same frozen owner and command.
                var result = await Task.Run(() => session.MutateAsync(request, lifetime.Token), lifetime.Token);
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
                using (UtenBusyDialog.Show(this, "正在只读核对原任务"))
                {
                var result = await Task.Run(() => session.ReconcileUnitExportAsync(requestId, mutationOwner, lifetime.Token), lifetime.Token);
                if (!Current) return;
                if (result.Outcome == MutationOutcome.Confirmed)
                {
                    pendingLocalId = pendingBody = pendingJobId = null;
                    ShowStatus("服务器原请求与本机冻结条件一致，已核对原任务。" + (result.IsDurablyRecorded ? "" : "本机终态尚未完整保存。"), !result.IsDurablyRecorded);
                }
                else ShowStatus("尚未获得与原条件一致的创建凭据，原结果仍待核对；不会凭同名或同状态认领。", true);
                }
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
                using (UtenBusyDialog.Show(this, "正在提交原任务取消请求"))
                {
                var request = service.PrepareCancel(Guid.NewGuid().ToString("D"), id, owner);
                var result = await session.MutateAsync(request, lifetime.Token);
                if (Current) ShowStatus(result.Outcome == MutationOutcome.Confirmed ? "已获得任务当前状态；取消是否完成以任务状态为准。"
                    : result.Error?.UserMessage ?? "取消结果待核对，请先刷新原任务，不会自动重发。", result.Outcome != MutationOutcome.Confirmed);
                }
            }
            catch (ApiException error) { HandleError(error); }
            catch (OperationCanceledException) { }
            finally { busy = false; if (!ended) { UpdateActions(); if (retired || closeAfterBusy) Close(); else await ReloadAsync(); } }
        }
        private async Task DownloadAsync()
        {
            if (!download.IsEnabled) return;
            busy = true; UpdateActions(); string secret = password.Password; bool fromJob=available;
            try
            {
                using (UtenBusyDialog.Show(this, "正在核对导出范围与下载权限"))
                {
                    if(selectedOnly)await RefreshSelectedCapabilityAsync(fromJob);
                    if (fromJob) await service.AuthorizeDownloadAsync(currentJob.Id, owner, lifetime.Token);
                }
                if (!Current) return;
                string destination = picker.Choose(this);
                if (destination == null || !Current) return;
                if(selectedOnly) using (UtenBusyDialog.Show(this, "正在核对选中范围")) await RefreshSelectedCapabilityAsync(fromJob);
                transfer = CancellationTokenSource.CreateLinkedTokenSource(lifetime.Token); UpdateActions();
                // 2026-11-09 与 Flutter「统一进度弹窗」同步：下载全程持有一块进度弹窗。
                // 服务端不回总长（分块传输总量未知）→ 扫动条 + 已收字节详情，不伪造
                // 百分比；「取消」= 取消传输令牌，已提交的任务与幂等语义不受影响。
                using (var waiting = UtenBusyDialog.Show(this, "正在保存 Excel", () => transfer.Cancel()))
                {
                    var progress = new Progress<long>(bytes =>
                    {
                        waiting.Stage("正在保存 Excel：" + (bytes / 1024d / 1024d).ToString("0.0") + " MiB");
                        if (Current) ShowStatus("正在保存 Excel：" + (bytes / 1024d / 1024d).ToString("0.0") + " MiB");
                    });
                    UnitExportFile file = fromJob
                        ? await session.DownloadUnitExportJobAsync(currentJob.Id, secret, destination, mutationOwner, transfer.Token, progress)
                        : await session.DownloadLegacyUnitExportAsync(UnitExportService.LegacyParameters(query), secret, projection?.ToJson(),
                            destination, mutationOwner, transfer.Token, progress, CurrentSelectedIds, selectionVersion);
                    if (Current) { saved.Text = file.Path; ShowStatus("Excel 已完整保存。"); }
                }
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
