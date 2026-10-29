using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Threading;
using System.Threading.Tasks;
using System.Web.Script.Serialization;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Threading;
using Uten.Legacy.Core;
using Uten.Legacy.Desktop.Controls;

namespace Uten.Legacy.Desktop.Features.Units
{
    /// <summary>Daily fields match the owning Unit form. Measurement keys stay omitted.
    /// Local draft revision is never sent as an invented server concurrency version.</summary>
    public sealed class UnitEditorWindow : UtenDialogWindow
    {
        private readonly SessionCoordinator session;
        private readonly UnitService service;
        private readonly UnitReadSnapshot<UnitRecord> baseline;
        private readonly MutationAction action;
        private readonly MutationOwnerSnapshot owner;
        private readonly DraftWriteLease draftLease;
        private readonly TextBox code = new TextBox();
        private readonly TextBox name = new TextBox();
        private readonly ComboBox status = new ComboBox();
        private readonly StackPanel fields = new StackPanel();
        private readonly SemaphoreSlim draftLock = new SemaphoreSlim(1, 1);
        private readonly CancellationTokenSource lifetime = new CancellationTokenSource();
        private readonly DispatcherTimer debounce = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(500) };
        private readonly Button save, keepDraft;
        private readonly string restoredBody;
        private readonly Dictionary<string, object> restoredFields;
        private readonly HashSet<string> editedFields = new HashSet<string>(StringComparer.Ordinal);
        private string initialBody, persistedBody;
        private long draftRevision;
        private bool initialized, submitting, preservingClose, allowedClose, retired, unresolved, ended;
        public bool BusinessChanged { get; private set; }

        public UnitEditorWindow(Window parent, SessionCoordinator session, UnitService service,
            UnitReadSnapshot<UnitRecord> baseline, MutationAction action, BusinessDraft restoredDraft = null)
            : base(parent, action == MutationAction.UnitCreate ? "新增单位" :
                action == MutationAction.UnitStatus ? "更改单位状态" : "编辑单位")
        {
            this.session = session ?? throw new ArgumentNullException(nameof(session));
            this.service = service ?? throw new ArgumentNullException(nameof(service));
            this.baseline = baseline; this.action = action;
            if (action != MutationAction.UnitCreate && (baseline == null || !baseline.IsCurrent(session)))
                throw new ApiException("READ_SCOPE_CHANGED", "单位详情已过期，请重新读取。");
            if (action != MutationAction.UnitCreate && action != MutationAction.UnitUpdate && action != MutationAction.UnitStatus)
                throw new ArgumentException("Unsupported daily unit action.", nameof(action));
            owner = service.CaptureWriteOwner();
            if (session.CurrentUser?.HasPermission("unit:view") != true || baseline != null && !baseline.Owner.Matches(owner))
                throw new ApiException("READ_SCOPE_CHANGED", "单位页面的账号或读取范围已变化，请重新打开资料。");
            if (restoredDraft != null && (restoredDraft.Action != action || restoredDraft.ResourceId != baseline?.Value.Id))
                throw new ApiException("DRAFT_CONFLICT", "草稿对应的操作或单位已变化，请先核对原内容。");
            if (restoredDraft != null && (restoredDraft.IssuerApiBaseUrl != owner.IssuerApiBaseUrl || restoredDraft.UserId != owner.UserId
                || restoredDraft.BusinessDatasetId != owner.BusinessDatasetId || restoredDraft.BusinessResetGeneration != owner.BusinessResetGeneration))
                throw new ApiException("DRAFT_OWNER_CHANGED", "这份草稿属于原服务器、原账号和原业务数据集，不能带入当前页面。");
            draftLease = session.CreateDraftLease(action, restoredDraft?.DraftId ?? Guid.NewGuid().ToString("D"), owner,
                baseline?.Value.Id, action == MutationAction.UnitUpdate ? baseline.Value.Status : null);
            code.Text = baseline?.Value.Code ?? ""; name.Text = baseline?.Value.Name ?? "";
            status.ItemsSource = new[] { "使用", "禁用" };
            status.SelectedItem = baseline?.Value.Status ?? "使用";
            status.IsEnabled = session.CurrentUser.HasPermission("unit:status");
            if (action != MutationAction.UnitStatus)
            {
                Field("单位编号", code); code.ToolTip = "留空自动生成";
                Field("单位名称", name);
            }
            Field("状态", status); Body.Children.Add(fields);
            if (action == MutationAction.UnitStatus)
            {
                var target = new TextBlock { Text = (baseline.Value.Code ?? "—") + " · " + (baseline.Value.Name ?? "—"),
                    TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 0, 0, Space("S12")) };
                Body.Children.Insert(0, target);
            }
            keepDraft = ActionButton("保存草稿并关闭", () => Close());
            save = ActionButton(action == MutationAction.UnitCreate ? "新增" : "保存", () => { _ = SubmitAsync(); }, primary: true);
            save.IsDefault = true;
            initialBody = persistedBody = CurrentBody();
            if (restoredDraft != null)
            {
                restoredBody = restoredDraft.BodyJson; restoredFields = UnitJson.Object(UnitJson.Parse(restoredBody));
                code.Text = UnitJson.Text(restoredFields, "code") ?? ""; name.Text = UnitJson.Text(restoredFields, "name") ?? "";
                status.SelectedItem = UnitJson.Text(restoredFields, "status");
                draftRevision = restoredDraft.Revision; persistedBody = restoredBody;
            }
            code.TextChanged += (sender, args) => Changed("code"); name.TextChanged += (sender, args) => Changed("name");
            status.SelectionChanged += (sender, args) => Changed("status");
            debounce.Tick += async (sender, args) =>
            {
                debounce.Stop();
                try { await FlushDraftAsync(); }
                catch (Exception) { if (!ended) ShowStatus("本机草稿暂未保存，请检查存储空间后重试；原输入仍保留在窗口中。", true); }
            };
            session.SessionChanged += OnOwnerChanged; session.ReadScopeChanged += OnOwnerChanged;
            Loaded += (sender, args) => { if (action == MutationAction.UnitStatus) status.Focus(); else name.Focus(); };
            initialized = true; UpdateActions();
            (parent as IPendingEditHost)?.TrackPendingEditor(this);
        }
        private void Field(string title, Control input)
        {
            System.Windows.Automation.AutomationProperties.SetName(input, title);
            fields.Children.Add(new TextBlock { Text = title, Margin = new Thickness(0, Space("S12"), 0, Space("S6")) });
            fields.Children.Add(input);
        }
        private void Changed(string field)
        {
            if (!initialized || ended || retired || unresolved) return;
            if (restoredFields != null) editedFields.Add(field);
            debounce.Stop(); debounce.Start(); UpdateActions();
        }
        private string CurrentBody()
        {
            if (restoredFields != null)
            {
                if (editedFields.Count == 0) return restoredBody;
                var updated = new Dictionary<string, object>(restoredFields, StringComparer.Ordinal);
                foreach (string key in editedFields)
                    updated[key] = key == "code" ? code.Text : key == "name" ? name.Text : status.SelectedItem as string;
                return new JavaScriptSerializer().Serialize(updated);
            }
            return action == MutationAction.UnitStatus
                ? new JavaScriptSerializer().Serialize(new Dictionary<string, object> { ["status"] = status.SelectedItem as string })
                : UnitSaveInput.Daily(name.Text, code.Text, status.SelectedItem as string).ToJson();
        }
        private bool OwnerIsCurrent()
        {
            var user = session.CurrentUser;
            return session.IsAuthenticated && user != null && owner.AuthGeneration == session.Generation
                && owner.ReadScopeRevision == session.ReadScopeRevision && owner.IssuerApiBaseUrl == session.CurrentEndpoint?.ApiBaseUrl
                && owner.UserId == user.Id && owner.BusinessDatasetId == user.BusinessDatasetId
                && owner.BusinessResetGeneration == user.BusinessResetGeneration;
        }
        private async Task FlushDraftAsync()
        {
            await draftLock.WaitAsync();
            try
            {
                string body = CurrentBody();
                if (body == persistedBody || unresolved) return;
                // This issued local lease remains bound to the original owner even after retirement.
                var saved = await session.SaveDraftAsync(draftLease, draftRevision, body, CancellationToken.None);
                draftRevision = saved.Revision; persistedBody = saved.BodyJson;
                if (!ended && !retired && !submitting) ShowStatus("草稿已保存在本机。");
            }
            finally { draftLock.Release(); }
        }
        private void UpdateActions()
        {
            if (save == null) return;
            bool valid = action == MutationAction.UnitStatus || !String.IsNullOrWhiteSpace(name.Text);
            save.IsEnabled = !submitting && !preservingClose && !retired && !unresolved && valid && CurrentBody() != initialBody;
            fields.IsEnabled = !submitting && !preservingClose && !retired && !unresolved;
            if (!retired && !unresolved) status.IsEnabled = !submitting && !preservingClose && session.CurrentUser?.HasPermission("unit:status") == true;
            CloseButton.IsEnabled = keepDraft.IsEnabled = !submitting && !preservingClose;
            keepDraft.Content = unresolved ? "关闭并保留原记录" : "保存草稿并关闭";
        }
        private async Task SubmitAsync()
        {
            if (!save.IsEnabled || ended) return;
            submitting = true; debounce.Stop(); UpdateActions();
            try
            {
                if (!OwnerIsCurrent()) { RetireOwner(); return; }
                await FlushDraftAsync();
                if (!OwnerIsCurrent()) { RetireOwner(); return; }
                // Freeze the exact persisted body; a fresh click creates a new explicit local intent.
                string requestId = Guid.NewGuid().ToString("D");
                var request = await session.PrepareMutationFromDraftAsync(requestId, draftLease.DraftId, draftRevision,
                    owner, lifetime.Token, action == MutationAction.UnitUpdate ? baseline.Value.Status : null);
                var result = await service.SendAsync(request, lifetime.Token);
                if (result.Outcome == MutationOutcome.Confirmed)
                {
                    BusinessChanged = true;
                    if (!result.IsDurablyRecorded)
                    {
                        unresolved = true;
                        ShowStatus("服务器已确认保存，本机提交记录尚未保存完整。请保留原记录，不要再次提交。", true);
                        return;
                    }
                    try { await session.DeleteDraftAsync(draftLease.DraftId, draftRevision, owner, CancellationToken.None); }
                    catch (Exception)
                    {
                        // Business success is authoritative; local cleanup never authorizes a second POST.
                        unresolved = true;
                        ShowStatus("已保存单位资料，本机草稿尚未清理。重新打开时请先核对提交记录。", true);
                        return;
                    }
                    allowedClose = true; Close();
                }
                else if (result.Outcome == MutationOutcome.Unknown)
                {
                    unresolved = true;
                    ShowStatus("本次提交结果待核对，原内容和编号已保留：" + result.Request.RequestId
                        + "。请在原服务器核对详情和操作历史，不要重复提交。", true);
                }
                else ShowStatus(result.Error?.UserMessage ?? "本次未保存，原输入与草稿已保留。", true);
            }
            catch (OperationCanceledException) { if (!ended) ShowStatus("操作已停止，请先核对提交记录；原草稿仍保留。", true); }
            catch (ApiException error) { if (!ended) ShowStatus(error.UserMessage, true); }
            catch (Exception) { if (!ended) ShowStatus("暂时无法完成本次操作，请先核对本机提交记录；不会自动重试。", true); }
            finally
            {
                submitting = false;
                if (!ended)
                {
                    UpdateActions();
                    if (retired) _ = PreserveAndCloseAsync();
                }
            }
        }
        private void OnOwnerChanged(object sender, EventArgs args)
        {
            if (ended) return;
            Dispatcher.BeginInvoke(new Action(() => { if (!ended && !OwnerIsCurrent()) RetireOwner(); }));
        }
        public void RetireOwner()
        {
            if (ended || retired) return;
            retired = true; debounce.Stop();
            // Retain the object for durable preservation, but never show old-owner input to a new session.
            fields.Visibility = Visibility.Collapsed;
            foreach (var child in Body.Children) if (!ReferenceEquals(child, fields) && child is UIElement element) element.Visibility = Visibility.Collapsed;
            ShowStatus("账号、权限或数据范围已变化，正在保留原账号的本机草稿。");
            lifetime.Cancel(); UpdateActions();
            if (!submitting) _ = PreserveAndCloseAsync();
        }
        private async Task PreserveAndCloseAsync()
        {
            if (ended || preservingClose || submitting) return;
            preservingClose = true; debounce.Stop(); UpdateActions();
            try
            {
                await FlushDraftAsync();
                allowedClose = true; Close();
            }
            catch (Exception)
            {
                ShowStatus("草稿未能保存，原输入仍保留。请恢复本机存储后再次点击“保存草稿并关闭”。", true);
            }
            finally { preservingClose = false; if (!ended) UpdateActions(); }
        }
        protected override void OnClosing(CancelEventArgs args)
        {
            if (!allowedClose && !ended)
            {
                args.Cancel = true;
                if (submitting) ShowStatus("正在确认提交结果，请稍候再关闭。");
                else Dispatcher.BeginInvoke(new Action(() => { if (!ended) _ = PreserveAndCloseAsync(); }));
            }
            base.OnClosing(args);
        }
        protected override void OnClosed(EventArgs args)
        {
            ended = true; debounce.Stop(); lifetime.Cancel();
            session.SessionChanged -= OnOwnerChanged; session.ReadScopeChanged -= OnOwnerChanged;
            lifetime.Dispose();
            // A pending local flush owns its semaphore until it returns; never dispose it underneath I/O.
            base.OnClosed(args);
        }
    }
}
