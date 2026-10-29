using System;
using System.Collections.Generic;
using System.Collections.ObjectModel;
using System.ComponentModel;
using System.Linq;
using System.Threading;
using System.Threading.Tasks;
using System.Web.Script.Serialization;
using Uten.Legacy.Core;

namespace Uten.Legacy.Desktop.Features.Units
{
    public sealed class UnitInlineRow : INotifyPropertyChanged
    {
        private readonly UnitInlineWorkspaceModel workspace;
        private readonly HashSet<string> edited = new HashSet<string>(StringComparer.Ordinal);
        private string code, name, status, message, retiredCompositionBody;
        private bool retiredCompositionDirty;
        private readonly string restoredBody;
        private readonly Dictionary<string, object> restoredExpected, restoredChanges;
        internal readonly UnitRecord Baseline;
        internal readonly DraftWriteLease Lease;
        internal long Revision;
        internal string PersistedBody;
        internal bool AttemptFrozen, composing, ReconciliationRequired;
        internal MutationResult Result;
        internal UnitInlineRow(UnitInlineWorkspaceModel workspace, UnitRecord baseline, DraftWriteLease lease, BusinessDraft restored = null)
        {
            this.workspace = workspace; Baseline = baseline; Lease = lease;
            code = baseline?.Code ?? ""; name = baseline?.Name ?? ""; status = baseline == null ? "使用" : baseline.Status;
            if (restored != null)
            {
                restoredBody = restored.BodyJson; Revision = restored.Revision; PersistedBody = restored.BodyJson;
                var body = UnitJson.Object(UnitJson.Parse(restored.BodyJson)); object raw;
                restoredExpected = body.TryGetValue("expected", out raw) ? UnitJson.Object(raw) : new Dictionary<string, object>();
                restoredChanges = body.TryGetValue("changes", out raw) ? UnitJson.Object(raw) : new Dictionary<string, object>();
                if (restoredChanges.TryGetValue("name", out raw)) name = raw as string ?? "";
                if (restoredChanges.TryGetValue("status", out raw)) status = raw as string;
                foreach (string key in restoredChanges.Keys)
                    if (key != "name" && key != "status") { AttemptFrozen = true; ReconciliationRequired = true; message = "原草稿含本页未迁移字段，请保留并核对原始草稿。"; }
            }
        }
        public event PropertyChangedEventHandler PropertyChanged;
        public string Code { get { return code; } set { if (!IsNew) throw new InvalidOperationException("既有单位编号不能行内修改。"); Change("code", ref code, value); } }
        public string Name { get { return name; } set { Change("name", ref name, value); } }
        public string Status { get { return status; } set { Change("status", ref status, value); } }
        public string Id { get { return Baseline?.Id; } }
        public bool IsNew { get { return Baseline == null; } }
        public bool SupportsEditing { get { return Lease != null; } }
        public bool CodeReadOnly { get { return !IsNew || !CanEdit; } }
        public bool CanEdit { get { return Lease != null && !AttemptFrozen && !workspace.IsBusy && !workspace.IsRetired && workspace.RestoredJournalVerified; } }
        public bool CanEditStatus { get { return CanEdit && workspace.CanChangeStatus; } }
        public bool IsComposing { get { return composing; } }
        public bool IsBlank { get { return IsNew && edited.Count == 0; } }
        public bool HasChanges { get { return retiredCompositionBody != null ? retiredCompositionDirty
            : Result?.Outcome != MutationOutcome.Confirmed && (restoredBody != null ? restoredChanges.Count != 0 || edited.Count != 0
                : IsNew ? edited.Count != 0 : ChangedFields().Count != 0); } }
        public bool IsUnresolved { get { return ReconciliationRequired || Result != null && (Result.NeedsManualReconciliation || Result.Outcome == MutationOutcome.Confirmed && !Result.IsDurablyRecorded); } }
        public string Message { get { return message ?? (IsBlank ? "新增空行" : HasChanges ? "未保存" : ""); } }
        public string DraftId { get { return Lease?.DraftId; } }
        public string RequestId { get { return Result?.Request.RequestId; } }
        public MutationOutcome? Outcome { get { return Result?.Outcome; } }
        private void Change(string key, ref string field, string value)
        {
            value = value ?? "";
            if (field == value) return;
            if (workspace.IsFinished) return;
            if (retiredCompositionBody != null) return; // Hiding an IME editor may emit a cancellation/reversion.
            if (Lease == null || AttemptFrozen) throw new InvalidOperationException("这一行不能继续修改。");
            if (key == "status" && !workspace.CanChangeStatus && !workspace.IsRetired)
                throw new ApiException("FORBIDDEN", "当前账号没有单位状态权限。", 403);
            // An already issued lease may accept the final IME/binding value
            // during retirement for LOCAL preservation in its original owner.
            field = value; edited.Add(key); message = null;
            Notify(key == "code" ? nameof(Code) : key == "name" ? nameof(Name) : nameof(Status));
            workspace.InputChanged(this);
        }
        internal Dictionary<string, UnitOptionalText> ChangedFields()
        {
            var values = new Dictionary<string, UnitOptionalText>();
            if (Baseline == null) return values;
            if (edited.Contains("name") && name != Baseline.Name) values["name"] = UnitOptionalText.Of(name);
            if (edited.Contains("status") && status != Baseline.Status) values["status"] = UnitOptionalText.Of(status);
            return values;
        }
        internal string Body()
        {
            if (retiredCompositionBody != null) return retiredCompositionBody;
            if (restoredBody != null)
            {
                if (edited.Count == 0) return restoredBody;
                var before = new Dictionary<string, object>(restoredExpected, StringComparer.Ordinal);
                var after = new Dictionary<string, object>(restoredChanges, StringComparer.Ordinal);
                foreach (string key in edited)
                {
                    if (!before.ContainsKey(key)) before[key] = key == "name" ? Baseline.Name : Baseline.Status;
                    after[key] = key == "name" ? name : status;
                }
                return new JavaScriptSerializer().Serialize(new Dictionary<string, object> { ["expected"] = before, ["changes"] = after });
            }
            if (IsNew) return UnitSaveInput.Daily(name, code, status).ToJson();
            var changes = ChangedFields();
            if (changes.Count == 0) return "{\"expected\":{},\"changes\":{}}";
            var expected = new Dictionary<string, UnitOptionalText>();
            foreach (string key in changes.Keys)
            {
                string original = key == "name" ? Baseline.Name : Baseline.Status;
                expected[key] = original == null ? UnitOptionalText.Null : UnitOptionalText.Of(original);
            }
            return new UnitInlinePatch(Id, expected, changes).ToJson();
        }
        internal void CaptureRetiringComposition()
        {
            if (!composing || Lease == null || AttemptFrozen || retiredCompositionBody != null) return;
            retiredCompositionDirty = HasChanges; retiredCompositionBody = Body();
        }
        internal bool Valid()
        {
            if (restoredBody != null)
            {
                var body = UnitJson.Object(UnitJson.Parse(Body()));
                var restoredValues = UnitJson.Object(body["changes"]);
                return restoredValues.Count != 0 && (!restoredValues.ContainsKey("name") || !String.IsNullOrWhiteSpace(restoredValues["name"] as string))
                    && (!restoredValues.ContainsKey("status") || restoredValues["status"] as string == "使用" || restoredValues["status"] as string == "禁用");
            }
            var changes = ChangedFields();
            return (IsNew ? !String.IsNullOrWhiteSpace(name) : changes.Count != 0
                    && (!changes.ContainsKey("name") || !String.IsNullOrWhiteSpace(name)))
                && (status == "使用" || status == "禁用" || !IsNew && !changes.ContainsKey("status"));
        }
        internal void SetComposing(bool value) { composing = value; workspace.NotifyState(); }
        internal void SetMessage(string text) { message = text; Notify(nameof(Message)); }
        internal void Refresh()
        {
            foreach (string key in new[] { nameof(CanEdit), nameof(CanEditStatus), nameof(CodeReadOnly), nameof(HasChanges), nameof(Outcome), nameof(RequestId), nameof(Message) }) Notify(key);
        }
        private void Notify(string key) { PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(key)); }
    }

    /// <summary>Only UI intent and preservation coordination; Core owns every durable draft/journal and HTTP attempt.</summary>
    public sealed class UnitInlineWorkspaceModel
    {
        public const int DefaultBlankRows = 3; // master_inline_create.dart defaults; not a total batch limit.
        private readonly SessionCoordinator session;
        private readonly UnitReadOwner readOwner;
        private readonly MutationOwnerSnapshot owner;
        private readonly UnitService service;
        private readonly SemaphoreSlim draftLock = new SemaphoreSlim(1, 1);
        private readonly ObservableCollection<UnitInlineRow> rows = new ObservableCollection<UnitInlineRow>();
        private readonly List<UnitInlineRow> editOrder = new List<UnitInlineRow>();
        private readonly CancellationTokenSource submission = new CancellationTokenSource();
        private readonly BusinessDraft restoredDraft;
        private readonly UnitInlineRow restoredRow;
        private bool restoredJournalVerified, reviewAcknowledged;
        private bool ended;
        public ReadOnlyObservableCollection<UnitInlineRow> Rows { get; private set; }
        public event EventHandler StateChanged;
        public event EventHandler InputEdited;
        public bool IsBusy { get; private set; }
        public bool IsRetired { get; private set; }
        public bool BusinessChanged { get; private set; }
        public bool IsFinished { get { return ended; } }
        public bool IsOwnerCurrent { get { return !IsRetired && readOwner.IsCurrent(session) && readOwner.Matches(owner); } }
        public bool CanChangeStatus { get { return session.CurrentUser?.HasPermission("unit:status") == true; } }
        public int PendingRows { get { return rows.Count(row => row.HasChanges && !row.AttemptFrozen); } }
        public bool HasComposition { get { return rows.Any(row => row.IsComposing); } }
        public bool HasUnresolved { get { return rows.Any(row => row.IsUnresolved); } }
        public bool HasRestoredDraft { get { return restoredDraft != null; } }
        public bool RestoredJournalVerified { get { return restoredDraft == null || restoredJournalVerified; } }
        public bool RequiresRestoredReview { get { return restoredDraft != null && !reviewAcknowledged; } }
        public string RestoredReviewSummary { get; private set; }
        public bool CanSave { get { return !ended && !IsBusy && IsOwnerCurrent && RestoredJournalVerified && !RequiresRestoredReview
            && !HasComposition && !HasUnresolved && PendingRows != 0; } }
        public string Status { get; private set; }

        public UnitInlineWorkspaceModel(SessionCoordinator session, IReadOnlyList<UnitRecord> currentRows, UnitReadOwner readOwner, BusinessDraft restoredDraft = null)
        {
            this.session = session ?? throw new ArgumentNullException(nameof(session));
            this.readOwner = readOwner ?? throw new ArgumentNullException(nameof(readOwner));
            if (currentRows == null) throw new ArgumentNullException(nameof(currentRows));
            if (!readOwner.IsCurrent(session) || session.CurrentUser?.HasPermission("unit:view") != true)
                throw new ApiException("READ_SCOPE_CHANGED", "单位资料已经过期，请重新读取。");
            owner = session.CaptureMutationOwner();
            if (!readOwner.Matches(owner)) throw new ApiException("READ_SCOPE_CHANGED", "单位行不属于当前读取范围。");
            service = new UnitService(session);
            this.restoredDraft = restoredDraft;
            if (restoredDraft != null && (restoredDraft.Action != MutationAction.UnitInlineEdit
                || restoredDraft.IssuerApiBaseUrl != owner.IssuerApiBaseUrl || restoredDraft.UserId != owner.UserId
                || restoredDraft.BusinessDatasetId != owner.BusinessDatasetId || restoredDraft.BusinessResetGeneration != owner.BusinessResetGeneration
                || !currentRows.Any(row => row.Id == restoredDraft.ResourceId)))
                throw new ApiException("DRAFT_OWNER_CHANGED", "原行内草稿不属于当前单位、账号或业务数据范围。");
            if (restoredDraft != null && session.CurrentUser?.HasPermission("unit:edit") != true)
                throw new ApiException("FORBIDDEN", "当前账号不能恢复单位行内编辑。", 403);
            var ids = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            foreach (var record in currentRows)
            {
                if (record == null || !ids.Add(record.Id)) throw new ArgumentException("单位行不能缺失或重复。");
                bool restoredTarget = restoredDraft?.ResourceId == record.Id;
                var row = CreateRow(record, session.CurrentUser.HasPermission("unit:edit") && (restoredDraft == null || restoredTarget),
                    restoredTarget ? restoredDraft : null);
                rows.Add(row);
                if (restoredTarget) { restoredRow = row; editOrder.Add(row); }
            }
            Rows = new ReadOnlyObservableCollection<UnitInlineRow>(rows);
            ReplenishBlankRows();
            if (restoredRow != null) RestoredReviewSummary = BuildReviewSummary();
        }
        private UnitInlineRow CreateRow(UnitRecord baseline, bool editable, BusinessDraft restored = null)
        {
            var lease = editable ? session.CreateDraftLease(baseline == null ? MutationAction.UnitCreate : MutationAction.UnitInlineEdit,
                restored?.DraftId ?? Guid.NewGuid().ToString("D"), owner, baseline?.Id) : null;
            return new UnitInlineRow(this, baseline, lease, restored);
        }
        private string BuildReviewSummary()
        {
            var body = UnitJson.Object(UnitJson.Parse(restoredDraft.BodyJson)); object raw;
            var before = body.TryGetValue("expected", out raw) ? UnitJson.Object(raw) : new Dictionary<string, object>();
            var after = body.TryGetValue("changes", out raw) ? UnitJson.Object(raw) : new Dictionary<string, object>();
            if (after.Keys.Any(key => key != "name" && key != "status"))
                return "原草稿包含本页尚未迁移字段。原始预期及修改完整保留，不能在本页重新提交。请在草稿详情核对。";
            var lines = new List<string>();
            foreach (var entry in after)
            {
                object original; bool present = before.TryGetValue(entry.Key, out original);
                string current = entry.Key == "name" ? restoredRow.Baseline.Name : entry.Key == "status" ? restoredRow.Baseline.Status : null;
                string label = entry.Key == "name" ? "单位名称" : entry.Key == "status" ? "状态" : entry.Key;
                lines.Add(label + "：原预期 " + Display(present, original) + "；本次读取 " + Display(true, current) + "；原修改 " + Display(true, entry.Value));
            }
            return "请核对原草稿和本次读取。确认后仍保留原预期值；不会自动覆盖新资料。" + Environment.NewLine + String.Join(Environment.NewLine, lines);
        }
        private static string Display(bool present, object value)
        { return !present ? "（未提供）" : value == null ? "（空值）" : value.ToString() == "" ? "（空文本）" : value.ToString(); }
        public async Task VerifyRestoredDraftAsync()
        {
            if (restoredDraft == null || restoredJournalVerified || ended) return;
            if (!IsOwnerCurrent) throw new ApiException("READ_SCOPE_CHANGED", "恢复草稿的读取范围已经变化。");
            var journal = await session.ListMutationJournalAsync(owner, CancellationToken.None);
            if (!IsOwnerCurrent) return;
            bool linked = journal.Any(entry => entry.OriginDraftId == restoredDraft.DraftId
                && (entry.MayNeedManualReconciliation || entry.State == MutationJournalState.Confirmed && entry.OriginDraftRevision == restoredDraft.Revision));
            restoredJournalVerified = true;
            if (linked)
            {
                restoredRow.AttemptFrozen = true; restoredRow.ReconciliationRequired = true;
                restoredRow.SetMessage("原草稿已有待核对或已确认的提交，不能重新发送。");
                Status = "请核对原提交记录；原内容保持不变。";
            }
            NotifyState();
        }
        public void AcknowledgeRestoredReview()
        {
            if (!IsOwnerCurrent || !RestoredJournalVerified || HasUnresolved || ended)
                throw new ApiException("DRAFT_REVIEW_REQUIRED", "请先核对原提交记录，不能重复发送未决草稿。");
            reviewAcknowledged = true; Status = "已明确核对原值；提交仍使用原草稿的预期值。"; NotifyState();
        }
        private void ReplenishBlankRows()
        {
            if (!IsOwnerCurrent || session.CurrentUser?.HasPermission("unit:create") != true) return;
            while (rows.Count(row => row.IsBlank) < DefaultBlankRows) rows.Add(CreateRow(null, true));
        }
        public UnitInlineRow FirstBlankRow()
        {
            if (ended || IsBusy || !IsOwnerCurrent) return null;
            ReplenishBlankRows(); return rows.FirstOrDefault(row => row.IsBlank);
        }
        internal void InputChanged(UnitInlineRow row)
        {
            if (ended) return;
            if (!row.IsNew)
            {
                if (row.HasChanges && !editOrder.Contains(row)) editOrder.Add(row);
                else if (!row.HasChanges) editOrder.Remove(row);
            }
            if (!IsRetired) ReplenishBlankRows();
            NotifyState(); InputEdited?.Invoke(this, EventArgs.Empty);
        }
        internal void NotifyState()
        {
            foreach (var row in rows) row.Refresh();
            StateChanged?.Invoke(this, EventArgs.Empty);
        }
        public async Task FlushDraftsAsync()
        {
            await draftLock.WaitAsync();
            try
            {
                foreach (var row in rows.ToArray())
                {
                    if (row.Lease == null || row.AttemptFrozen || !row.HasChanges && row.Revision == 0) continue;
                    // Read each body only after acquiring the writer gate. A final
                    // IME value delivered during earlier I/O is preserved as well.
                    while (true)
                    {
                        string body = row.Body();
                        if (body == row.PersistedBody) break;
                        var saved = await session.SaveDraftAsync(row.Lease, row.Revision, body, CancellationToken.None);
                        row.Revision = saved.Revision; row.PersistedBody = saved.BodyJson;
                    }
                }
            }
            finally { draftLock.Release(); }
        }
        public async Task<bool> SaveAllAsync()
        {
            if (!CanSave) return false;
            // Flutter's existing-row patch map follows first-edit insertion
            // order, then creation follows its stable appended-row order.
            var pending = editOrder.Where(row => row.HasChanges && !row.AttemptFrozen)
                .Concat(rows.Where(row => row.IsNew && row.HasChanges && !row.AttemptFrozen)).ToArray();
            IsBusy = true; Status = "正在保存资料…"; NotifyState();
            try
            {
                // Preserve EVERY unsent row before the first network attempt.
                await FlushDraftsAsync();
                var invalid = pending.FirstOrDefault(row => !row.Valid());
                if (invalid != null)
                { invalid.SetMessage("请填写单位名称，并核对状态。"); Status = "请先补全资料，原输入和草稿仍保留。"; return false; }
                foreach (var row in pending)
                {
                    if (!IsOwnerCurrent || submission.IsCancellationRequested) return false;
                    await FlushDraftsAsync();
                    if (!IsOwnerCurrent) return false;
                    row.AttemptFrozen = true; row.Result = null; row.SetMessage("正在保存"); NotifyState();
                    bool invoked = false;
                    try
                    {
                        var request = await session.PrepareMutationFromDraftAsync(Guid.NewGuid().ToString("D"), row.Lease.DraftId, row.Revision,
                            owner, submission.Token);
                        invoked = true;
                        row.Result = await service.SendAsync(request, submission.Token);
                        if (row.Result.Outcome == MutationOutcome.Confirmed)
                        {
                            BusinessChanged = true; row.SetMessage("已保存");
                            if (!row.Result.IsDurablyRecorded)
                            { row.SetMessage("服务器已确认，本机记录待核对；请勿重提。"); Status = "已停止剩余提交，请保存草稿并核对原提交。"; return false; }
                            try { await session.DeleteDraftAsync(row.Lease.DraftId, row.Revision, owner, CancellationToken.None); }
                            catch (Exception)
                            {
                                row.ReconciliationRequired = true;
                                row.SetMessage("已保存，本机草稿待清理；请勿重提。");
                                Status = "已停止剩余提交，请保留草稿并核对本机记录。"; return false;
                            }
                            continue; // Never submit a confirmed row again.
                        }
                        if (row.Result.NeedsManualReconciliation)
                        { row.SetMessage("结果待核对，请勿重提。"); Status = "已停止剩余提交，原内容和提交记录已保留。"; return false; }
                        row.AttemptFrozen = false;
                        row.SetMessage(row.Result.Error?.UserMessage ?? "本次未保存，原输入已保留。");
                        Status = "部分资料尚未保存，请核对该行；其余输入已保留。";
                        return false;
                    }
                    catch (Exception error)
                    {
                        // A dispatch exception cannot authorize a new request. If
                        // Core returned no result after invocation, keep this row
                        // frozen and let its durable Sending entry recover Unknown.
                        var apiError = error as ApiException;
                        bool unresolved = invoked || apiError?.IsSubmissionUnknown == true
                            || apiError?.Code == "DRAFT_PENDING_SUBMISSION" || apiError?.Code == "MUTATION_PENDING_RECONCILIATION";
                        row.ReconciliationRequired = unresolved;
                        row.AttemptFrozen = unresolved;
                        row.SetMessage(error is ApiException api ? api.UserMessage : invoked ? "提交记录待核对，请勿重提。" : "本次未发送，原输入已保留。");
                        Status = invoked ? "已停止剩余提交，请先核对本机提交记录。" : "暂未完成保存，全部原输入仍保留。";
                        return false;
                    }
                }
                Status = "修改已保存。"; return true;
            }
            catch (Exception error)
            { Status = error is ApiException api ? api.UserMessage : "本机草稿尚未保存，未继续发送资料；原输入仍保留。"; return false; }
            finally { IsBusy = false; NotifyState(); }
        }
        public void RetireOwner()
        {
            if (ended || IsRetired) return;
            foreach (var row in rows) row.CaptureRetiringComposition();
            IsRetired = true; submission.Cancel();
            Status = "账号、权限或读取范围已变化，正在保全原账号的草稿。"; NotifyState();
        }
        public void RequestStop() { submission.Cancel(); }
        public async Task PreserveAndFinishAsync()
        {
            if (ended) return;
            if (IsBusy) throw new InvalidOperationException("正在完成原提交记录，请稍候保全。");
            await FlushDraftsAsync();
            ended = true; submission.Cancel(); NotifyState();
        }
        public async Task DiscardUnsentAndFinishAsync()
        {
            if (ended || IsBusy || !IsOwnerCurrent) return;
            await draftLock.WaitAsync();
            try
            {
                foreach (var row in rows.Where(row => row.Lease != null && !row.AttemptFrozen && row.Revision != 0))
                {
                    await session.DeleteDraftAsync(row.Lease.DraftId, row.Revision, owner, CancellationToken.None);
                    row.Revision = 0; row.PersistedBody = null;
                }
                ended = true; submission.Cancel();
            }
            finally { draftLock.Release(); NotifyState(); }
        }
    }
}
