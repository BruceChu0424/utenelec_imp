using System;
using System.ComponentModel;
using System.Linq;
using System.Threading;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Threading;
using Uten.Legacy.Core;

namespace Uten.Legacy.Desktop.Controls
{
    /// <summary>Single editable-dialog lifecycle. Business fields, presence and raw-body restoration belong to the derived editor.</summary>
    public abstract class DurableDraftDialog : UtenDialogWindow
    {
        protected readonly SessionCoordinator Session;
        protected readonly BusinessDraft RestoredDraft;
        protected readonly MutationOwnerSnapshot DraftOwner;
        protected readonly DraftWriteLease DraftLease;
        private readonly string observedStatus;
        private readonly CancellationTokenSource lifetime = new CancellationTokenSource();
        private readonly SemaphoreSlim draftLock = new SemaphoreSlim(1, 1);
        private readonly DispatcherTimer debounce = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(500) };
        private Button submit, keepDraft;
        private string initialBody, persistedBody;
        private long draftRevision;
        private bool initialized, ended, retired, submitting, preservingClose, allowedClose, unresolved, closeRequested;
        private int auxiliaryOperations;
        private bool recoveryJournalConfirmed;
        private MutationResult result;
        public bool BusinessChanged { get; private set; }
        public MutationResult Result { get { return IsDraftOwnerCurrent ? result : null; } }
        protected long DraftRevision { get { return draftRevision; } }
        protected Button SubmitButton { get { return submit; } }
        protected Button KeepDraftButton { get { return keepDraft; } }
        protected CancellationToken LifetimeToken { get { return lifetime.Token; } }
        protected bool IsSubmitting { get { return submitting; } }
        protected bool IsRetired { get { return retired; } }
        protected bool HasUnresolvedOutcome { get { return unresolved; } }
        protected bool IsEnded { get { return ended; } }
        protected virtual string SubmitObservedStatus { get { return observedStatus; } }
        protected abstract string BuildCurrentBody();
        protected abstract bool CanSubmitBody { get; }
        protected virtual void SetEditorEnabled(bool enabled) { Body.IsEnabled = enabled; }
        protected virtual void RetireSensitiveContent() { Body.Visibility = Visibility.Collapsed; }
        protected virtual Task BeforeSubmitAsync(CancellationToken ct) { return Task.CompletedTask; }
        protected virtual Task OnConfirmedAsync(MutationResult response) { return Task.CompletedTask; }

        protected DurableDraftDialog(Window parent, SessionCoordinator session, string title, MutationAction action,
            string resourceId = null, string observedStatus = null, BusinessDraft restoredDraft = null, double width = 560)
            : base(parent, title, width)
        {
            Session = session ?? throw new ArgumentNullException(nameof(session)); this.observedStatus = observedStatus;
            DraftOwner = session.CaptureMutationOwner(); RestoredDraft = restoredDraft;
            if (restoredDraft != null && (restoredDraft.Action != action || restoredDraft.ResourceId != resourceId
                || restoredDraft.IssuerApiBaseUrl != DraftOwner.IssuerApiBaseUrl || restoredDraft.UserId != DraftOwner.UserId
                || restoredDraft.BusinessDatasetId != DraftOwner.BusinessDatasetId || restoredDraft.BusinessResetGeneration != DraftOwner.BusinessResetGeneration))
                throw new ApiException("DRAFT_OWNER_CHANGED", "原草稿不属于当前操作、账号或业务数据范围，不能带入当前页面。");
            DraftLease = session.CreateDraftLease(action, restoredDraft?.DraftId ?? Guid.NewGuid().ToString("D"), DraftOwner, resourceId, observedStatus);
            draftRevision = restoredDraft?.Revision ?? 0;
            recoveryJournalConfirmed = restoredDraft == null;
        }
        /// <summary>Call exactly once, after all controls and the derived raw-body restoration are ready.</summary>
        protected void InitializeDraftUi(string submitLabel, string originalInitialBody)
        {
            if (initialized) throw new InvalidOperationException("Draft UI was already initialized.");
            initialBody = originalInitialBody ?? throw new ArgumentNullException(nameof(originalInitialBody));
            persistedBody = RestoredDraft?.BodyJson ?? initialBody;
            keepDraft = ActionButton("保存草稿并关闭", () => Close());
            submit = ActionButton(submitLabel, () => { _ = SubmitAsync(); }, primary: true); submit.IsDefault = true;
            debounce.Tick += async (sender, args) =>
            {
                debounce.Stop();
                try { await FlushDraftAsync(); }
                catch (Exception) { if (!ended) ShowStatus("本机草稿暂未保存，请检查存储空间后重试；原输入仍保留。", true); }
            };
            initialized = true; RefreshDraftActions();
            if (RestoredDraft != null) Loaded += async (sender, args) => await ProbeRestoredJournalAsync();
            // Derived validation and control creation have all completed before subscriptions/global guards exist.
            (Owner as IPendingEditHost)?.TrackPendingEditor(this);
            Session.SessionChanged += OnOwnerChanged; Session.ReadScopeChanged += OnOwnerChanged;
            if (!IsDraftOwnerCurrent) RetireOwner();
        }
        private async Task ProbeRestoredJournalAsync()
        {
            if (ended || retired || recoveryJournalConfirmed) return;
            try
            {
                var journal = await Session.ListMutationJournalAsync(DraftOwner, lifetime.Token);
                if (ended || !IsDraftOwnerCurrent) return;
                unresolved = journal.Any(entry => entry.OriginDraftId == DraftLease.DraftId
                    && (entry.MayNeedManualReconciliation || entry.State == MutationJournalState.Confirmed && entry.OriginDraftRevision == draftRevision));
                recoveryJournalConfirmed = true;
                if (unresolved) ShowStatus("这份草稿已有待核对或已确认的原提交，只能保留和核对，不能恢复后再次发送。", true);
            }
            catch (OperationCanceledException) { }
            catch (ApiException error) { if (!ended && IsDraftOwnerCurrent) ShowStatus(error.UserMessage + " 原草稿仍保留，暂不能重新提交。", true); }
            finally { if (!ended) RefreshDraftActions(); }
        }
        protected bool IsDraftOwnerCurrent
        {
            get
            {
                var user = Session.CurrentUser;
                return Session.IsAuthenticated && user != null && Session.Generation == DraftOwner.AuthGeneration
                    && Session.ReadScopeRevision == DraftOwner.ReadScopeRevision && Session.CurrentEndpoint?.ApiBaseUrl == DraftOwner.IssuerApiBaseUrl
                    && user.Id == DraftOwner.UserId && user.BusinessDatasetId == DraftOwner.BusinessDatasetId
                    && user.BusinessResetGeneration == DraftOwner.BusinessResetGeneration;
            }
        }
        protected void MarkDraftChanged()
        {
            if (!initialized || ended || retired || unresolved) return;
            debounce.Stop(); debounce.Start(); RefreshDraftActions();
        }
        protected void RefreshDraftActions()
        {
            if (!initialized || ended) return;
            bool busy = submitting || preservingClose || auxiliaryOperations != 0;
            bool valid = false; string body = null;
            try { valid = CanSubmitBody; body = BuildCurrentBody(); }
            catch (Exception error) when (error is FormatException || error is ArgumentException || error is InvalidOperationException) { }
            submit.IsEnabled = !busy && !retired && !unresolved && recoveryJournalConfirmed && IsDraftOwnerCurrent && valid && body != null && body != initialBody;
            SetEditorEnabled(!busy && !retired && !unresolved && recoveryJournalConfirmed);
            CloseButton.IsEnabled = keepDraft.IsEnabled = !busy;
            keepDraft.Content = unresolved ? "关闭并保留原记录" : "保存草稿并关闭";
        }
        protected IDisposable BeginEditorOperation()
        {
            if (ended || retired || submitting || preservingClose) throw new InvalidOperationException("The draft editor is unavailable.");
            if (!IsDraftOwnerCurrent)
            { RetireOwner(); throw new ApiException("READ_SCOPE_CHANGED", "编辑来源的账号、权限或数据范围已经变化，未开始辅助读取。", 403); }
            auxiliaryOperations++; RefreshDraftActions();
            return new OperationLease(this);
        }
        private sealed class OperationLease : IDisposable
        {
            private DurableDraftDialog dialog;
            internal OperationLease(DurableDraftDialog dialog) { this.dialog = dialog; }
            public void Dispose()
            {
                var owned = dialog; dialog = null; if (owned == null) return;
                owned.auxiliaryOperations--; owned.RefreshDraftActions();
                if (!owned.ended && owned.auxiliaryOperations == 0 && (owned.retired || owned.closeRequested)) _ = owned.PreserveAndCloseAsync();
            }
        }
        private async Task FlushDraftAsync()
        {
            await draftLock.WaitAsync();
            try
            {
                string body = BuildCurrentBody();
                if (body == persistedBody || unresolved) return;
                // Issued lease preserves only the original namespace even after authentication retirement.
                var saved = await Session.SaveDraftAsync(DraftLease, draftRevision, body, CancellationToken.None);
                draftRevision = saved.Revision; persistedBody = saved.BodyJson;
                if (!ended && !retired && !submitting) ShowStatus("草稿已保存在本机。");
            }
            finally { draftLock.Release(); }
        }
        private async Task SubmitAsync()
        {
            if (ended || !submit.IsEnabled) return;
            submitting = true; debounce.Stop(); RefreshDraftActions(); bool dispatchInvoked = false;
            try
            {
                if (!IsDraftOwnerCurrent) { RetireOwner(); return; }
                await BeforeSubmitAsync(lifetime.Token);
                if (!IsDraftOwnerCurrent) { RetireOwner(); return; }
                await FlushDraftAsync();
                if (!IsDraftOwnerCurrent) { RetireOwner(); return; }
                var request = await Session.PrepareMutationFromDraftAsync(Guid.NewGuid().ToString("D"), DraftLease.DraftId, draftRevision,
                    DraftOwner, lifetime.Token, SubmitObservedStatus);
                dispatchInvoked = true;
                var response = await Session.MutateAsync(request, lifetime.Token);
                result = response;
                if (response.Outcome == MutationOutcome.Confirmed)
                {
                    BusinessChanged = true;
                    if (!response.IsDurablyRecorded)
                    { unresolved = true; ShowStatus("服务器已确认保存，本机提交记录尚未保存完整。请保留原记录，不要再次提交。", true); return; }
                    try { await Session.DeleteDraftAsync(DraftLease.DraftId, draftRevision, DraftOwner, CancellationToken.None); }
                    catch (Exception)
                    { unresolved = true; ShowStatus("服务器已确认保存，本机草稿尚未清理。重新打开时请先核对原提交记录，不要再次提交。", true); return; }
                    if (IsDraftOwnerCurrent)
                    {
                        try { await OnConfirmedAsync(response); }
                        catch (Exception) { unresolved = true; ShowStatus("服务器已确认保存，但页面结果暂未完整读取。请刷新核对；不要重复提交原操作。", true); return; }
                    }
                    allowedClose = true; Close();
                }
                else if (response.Outcome == MutationOutcome.Unknown || response.NeedsManualReconciliation)
                {
                    unresolved = true;
                    if (IsDraftOwnerCurrent) ShowStatus("提交结果待核对，原内容和编号已保留：" + response.Request.RequestId
                        + "。请在原服务器核对资料和操作历史，不要重复提交。", true);
                }
                else if (IsDraftOwnerCurrent) ShowStatus(response.Error?.UserMessage ?? "本次没有确认保存，原输入与草稿已保留。", true);
            }
            catch (OperationCanceledException) { if (dispatchInvoked) unresolved = true; if (!ended) ShowStatus("操作已停止，请先核对本机提交记录；原草稿仍保留。", true); }
            catch (ApiException error) { if (dispatchInvoked && error.IsSubmissionUnknown) unresolved = true; if (!ended) ShowStatus(error.UserMessage, true); }
            catch (Exception) { if (dispatchInvoked) unresolved = true; if (!ended) ShowStatus("暂时无法完成操作，请先核对本机提交记录；不会自动重试。", true); }
            finally
            {
                submitting = false;
                if (!ended) { RefreshDraftActions(); if (retired || closeRequested) _ = PreserveAndCloseAsync(); }
            }
        }
        private void OnOwnerChanged(object sender, EventArgs args)
        { if (!ended) Dispatcher.BeginInvoke(new Action(() => { if (!ended && !IsDraftOwnerCurrent) RetireOwner(); })); }
        public void RetireOwner()
        {
            if (ended || retired) return;
            retired = true; debounce.Stop(); RetireSensitiveContent(); lifetime.Cancel();
            ShowStatus("账号、权限或数据范围已变化，正在保留原账号的本机草稿。"); RefreshDraftActions();
            if (!submitting && auxiliaryOperations == 0) _ = PreserveAndCloseAsync();
        }
        private async Task PreserveAndCloseAsync()
        {
            if (ended || preservingClose || submitting || auxiliaryOperations != 0) return;
            preservingClose = true; debounce.Stop(); RefreshDraftActions();
            try { await FlushDraftAsync(); allowedClose = true; Close(); }
            catch (Exception) { ShowStatus("草稿未能保存，原输入仍保留。请恢复本机存储后再次点击“保存草稿并关闭”。", true); }
            finally { preservingClose = false; if (!ended) RefreshDraftActions(); }
        }
        protected override void OnClosing(CancelEventArgs args)
        {
            // An owned editor may still return a new selection. Wait for descendants before freezing our final body.
            base.OnClosing(args);
            if (args.Cancel || ended || allowedClose) return;
            args.Cancel = true;
            if (submitting || auxiliaryOperations != 0)
            { closeRequested = true; ShowStatus("正在完成当前操作和本机记录保全，请稍候再关闭。"); }
            else Dispatcher.BeginInvoke(new Action(() => { if (!ended) _ = PreserveAndCloseAsync(); }));
        }
        protected override void OnClosed(EventArgs args)
        {
            ended = true; debounce.Stop(); lifetime.Cancel();
            Session.SessionChanged -= OnOwnerChanged; Session.ReadScopeChanged -= OnOwnerChanged; lifetime.Dispose();
            // An already-running local flush owns its semaphore until return; never dispose it under I/O.
            base.OnClosed(args);
        }
    }
}
