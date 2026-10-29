using System;
using System.Collections.Generic;
using System.Linq;
using System.Net.Http;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;
using System.Threading.Tasks;

namespace Uten.Legacy.Core
{
    public sealed partial class SessionCoordinator
    {
        private readonly object mutationIdentity = new object();
        private readonly Dictionary<string, MutationRequest> mutationIntents = new Dictionary<string, MutationRequest>(StringComparer.Ordinal);
        private StepUpGrant stepUpGrant;
        private const int MaximumRetainedMutationIntents = 512;

        /// <summary>W7-CORE-011 is an in-process safety foundation. Durable encrypted drafts,
        /// a crash-safe submit journal and receipt/manual reconciliation UI are separate work.</summary>
        public bool DurableMutationJournalAvailable { get { return false; } }

        public MutationOwnerSnapshot CaptureMutationOwner()
        {
            lock (gate)
            {
                RequireAuthenticated();
                if (String.IsNullOrEmpty(credentials.User.BusinessDatasetId))
                    throw new ApiException("MUTATION_DATASET_UNCONFIRMED", "服务器尚未提供可确认的业务数据集身份，本次客户端不会开放业务写入。");
                return new MutationOwnerSnapshot(mutationIdentity, generation, readScopes.Revision, endpoint.ApiBaseUrl, credentials.User);
            }
        }

        public MutationRequest PrepareMutation(MutationAction action, string requestId, string bodyJson,
            MutationOwnerSnapshot owner, string resourceId = null, string observedStatus = null)
        {
            var id = CanonicalCommandId(requestId);
            Dictionary<string, FlatJsonField> fields;
            try { fields = MutationFlatJson.Parse(bodyJson); }
            catch (Exception error) when (error is FormatException || error is ArgumentException || error is InvalidOperationException)
            { throw new ApiException("MUTATION_BODY_INVALID", "提交内容必须符合已审核的单位接口字段；请保留原始输入后修正。"); }
            string method;
            string path;
            var permissions = new List<string>();
            var strategy = MutationVersionStrategy.NotSupported;
            if (action == MutationAction.UnitCreate || action == MutationAction.UnitUpdate)
            {
                RequireFields(fields, "name", "code", "status", "measurementDimension", "massUnitCode");
                RequireText(fields, "name", true);
                foreach (var key in new[] { "code", "measurementDimension", "massUnitCode" }) RequireText(fields, key, false);
                if (action == MutationAction.UnitUpdate) RequireStatus(fields, true);
                else RequireStatus(fields, false);
                if (action == MutationAction.UnitCreate)
                {
                    if (resourceId != null || observedStatus != null) throw InvalidAction();
                    method = "POST"; path = "master/units"; permissions.Add("unit:create");
                    FlatJsonField status;
                    if (fields.TryGetValue("status", out status) && status.Value != null && (string)status.Value != "使用") permissions.Add("unit:status");
                }
                else
                {
                    resourceId = CanonicalCommandId(resourceId);
                    if (observedStatus != null && observedStatus != "使用" && observedStatus != "禁用") throw InvalidAction();
                    method = "PUT"; path = "master/units/" + resourceId; permissions.Add("unit:edit");
                    // The server rechecks the live row. A UI observation is not a concurrency token.
                    if (observedStatus == null || (string)fields["status"].Value != observedStatus) permissions.Add("unit:status");
                }
            }
            else if (action == MutationAction.UnitStatus)
            {
                RequireFields(fields, "status", "version"); RequireStatus(fields, true);
                FlatJsonField version;
                if (fields.TryGetValue("version", out version) && version.Value != null && !(version.Value is long)) throw InvalidAction();
                if (observedStatus != null) throw InvalidAction();
                resourceId = CanonicalCommandId(resourceId);
                method = "PATCH"; path = "master/units/" + resourceId + "/status"; permissions.Add("unit:status");
                // MasterStatusChangeRequest accepts version, but UnitService uses its row lock and ignores it.
                strategy = MutationVersionStrategy.AcceptedButIgnored;
            }
            else throw InvalidAction();
            lock (gate)
            {
                RequireMutationOwnerLocked(owner);
                RequireMutationPermissionsLocked(permissions);
                MutationRequest existing;
                if (mutationIntents.TryGetValue(id, out existing))
                {
                    if (existing.Action != action || existing.ResourceId != resourceId || existing.BodyJson != bodyJson
                        || existing.ObservedStatus != observedStatus || !SameMutationOwner(existing.Owner, owner))
                        throw new ApiException("MUTATION_INTENT_CHANGED", "同一个提交编号不能更换内容、操作或账号。请保留原请求并为新的编辑意图生成新编号。");
                    return existing;
                }
                if (mutationIntents.Count >= MaximumRetainedMutationIntents)
                    throw new ApiException("MUTATION_JOURNAL_FULL", "本次进程保留的提交记录已到上限；请先核对待确认操作并保存记录，不能丢弃记录后继续自动提交。");
                var result = new MutationRequest(action, id, method, path, resourceId, bodyJson, owner, permissions, strategy, fields, observedStatus);
                mutationIntents.Add(id, result);
                return result;
            }
        }

        /// <summary>One descriptor gets at most one invocation. No 401, reauthentication, timeout,
        /// cancellation or server error automatically replays a business write. After a definite
        /// rejection, a new explicit user decision must create a new local command ID.</summary>
        public async Task<MutationResult> MutateAsync(MutationRequest request, CancellationToken cancellationToken)
        {
            if (request == null) throw new ArgumentNullException(nameof(request));
            Scope scope = null;
            CancellationToken readLifetime = CancellationToken.None;
            var permit = new MutationWirePermit(request, usesManagedTlsTransport, () =>
            {
                cancellationToken.ThrowIfCancellationRequested();
                lock (gate)
                {
                    RequireMutationOwnerLocked(request.Owner);
                    RequireMutationPermissionsLocked(request.RequiredPermissions);
                }
            });
            try
            {
                lock (gate)
                {
                    MutationRequest registered;
                    if (!mutationIntents.TryGetValue(request.RequestId, out registered) || !Object.ReferenceEquals(registered, request)
                        || !Object.ReferenceEquals(request.Owner.CoordinatorIdentity, mutationIdentity)) throw InvalidAction();
                    if (request.Started) throw new ApiException("MUTATION_ALREADY_ATTEMPTED", "此提交已经处理或正在处理；请先查看原结果，不会重复发送。");
                    request.Started = true;
                    RequireMutationOwnerLocked(request.Owner);
                    RequireMutationPermissionsLocked(request.RequiredPermissions);
                    cancellationToken.ThrowIfCancellationRequested();
                    scope = CaptureLocked(); readLifetime = readCancellation.Token;
                }
                // Refresh is shared and may rotate access credentials. It may not change this
                // frozen command's logical owner, grants, dataset or read revision.
                var owned = await EnsureAccessAsync(scope, false, null, cancellationToken).ConfigureAwait(false);
                permit.ValidateBeforeDispatch();
                Reply response;
                using (var wait = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken, readLifetime))
                    response = await SendAsync(scope, new HttpMethod(request.Method), request.RelativePath,
                        null, owned.AccessToken, wait.Token, request.BodyJson, permit).ConfigureAwait(false);
                lock (gate) RequireMutationOwnerLocked(request.Owner);
                var error = ErrorFrom(response, true);
                if (error != null)
                {
                    // No generated receipt exists for these unit endpoints. Any 5xx or
                    // unstructured response after dispatch therefore stays uncertain.
                    var rejected = response.Status >= 400 && response.Status < 500 && error.HasResponseCode;
                    if (rejected && error.StatusCode == 403 && error.Code == "READ_SCOPE_CHANGED")
                        RetireReader(scope, new ReadRequest(request.Owner.ReadScopeRevision, 0, readLifetime));
                    if (rejected && (error.Code == "ACCOUNT_DISABLED" || error.Code == "ACCOUNT_LOCKED"
                        || error.Code == "SESSION_REPLACED")) RejectCurrent(scope, owned);
                    return CompleteMutation(request, rejected ? MutationOutcome.Rejected : MutationOutcome.Unknown, error);
                }
                // The verified routes return UnitDetail, not an asynchronous 202 acknowledgement.
                if (response.Status != 200 || !ValidUnitReply(response.Text, request.ResourceId))
                    return CompleteMutation(request, MutationOutcome.Unknown,
                        new ApiException("MUTATION_RESPONSE_UNCONFIRMED", "服务器回复不能确认为本次单位操作结果，请先人工核对。", response.Status, true));
                lock (gate)
                {
                    RequireMutationOwnerLocked(request.Owner);
                    return CompleteMutation(request, MutationOutcome.Confirmed, null, response.Text);
                }
            }
            catch (Exception error) when (error is ApiException || error is OperationCanceledException || error is ObjectDisposedException)
            {
                // Concurrent duplicate invocations must not overwrite the original running/result state.
                var api = error as ApiException;
                if (api?.Code == "MUTATION_ALREADY_ATTEMPTED") throw;
                var sent = permit.MayHaveBeenSubmitted;
                if (sent)
                    api = new ApiException("SUBMISSION_UNKNOWN", "操作可能已发送，结果尚未确认。请核对原提交，不能直接重复提交。",
                        api?.StatusCode, true, api?.HasResponseCode ?? false);
                else if (api == null) api = error is OperationCanceledException
                    ? new ApiException("MUTATION_CANCELLED_NOT_SENT", "已取消，本次业务提交尚未发送。")
                    : new ApiException("MUTATION_CONTEXT_CLOSED", "客户端会话已关闭，本次业务提交尚未发送。");
                else if (api.IsSubmissionUnknown) api = new ApiException("MUTATION_NOT_SENT", "会话准备未完成，本次单位操作尚未发送；请先核对会话状态。");
                return CompleteMutation(request, sent ? MutationOutcome.Unknown : MutationOutcome.NotSent, api);
            }
        }

        public async Task<StepUpGrant> StepUpAsync(string password, CancellationToken cancellationToken)
        {
            cancellationToken.ThrowIfCancellationRequested();
            if (String.IsNullOrWhiteSpace(password) || password.Length > 4096)
                throw new ApiException("PASSWORD_INPUT_INVALID", "请填写当前账号密码。");
            MutationOwnerSnapshot owner;
            Scope scope;
            lock (gate) { owner = CaptureMutationOwner(); scope = CaptureLocked(); }
            var owned = await EnsureAccessAsync(scope, false, null, cancellationToken).ConfigureAwait(false);
            lock (gate) RequireMutationOwnerLocked(owner, false);
            var response = await SendAsync(scope, HttpMethod.Post, "auth/step-up",
                new Dictionary<string, object> { { "password", password } }, owned.AccessToken, cancellationToken).ConfigureAwait(false);
            lock (gate) RequireMutationOwnerLocked(owner, false);
            var failure = ErrorFrom(response, true);
            if (failure != null)
            {
                if (failure.Code == "REAUTH_LOCKED" || failure.Code == "ACCOUNT_DISABLED" || failure.Code == "SESSION_REPLACED")
                    RejectCurrent(scope, owned);
                throw failure;
            }
            try
            {
                var body = JsonValue.ParseObject(response.Text);
                var token = JsonValue.RequiredString(body, "stepUpToken", 200);
                if (!Regex.IsMatch(token, "^[A-Za-z0-9_-]{32,200}$")) throw new FormatException();
                var seconds = JsonValue.Integer(body, "expiresInSeconds", 0, 1, 300);
                lock (gate)
                {
                    RequireMutationOwnerLocked(owner, false);
                    stepUpGrant = new StepUpGrant(token, seconds, owner);
                    return stepUpGrant;
                }
            }
            catch (Exception error) when (error is FormatException || error is ArgumentException || error is InvalidOperationException)
            { throw new ApiException("INVALID_STEP_UP_RESPONSE", "再认证结果无法确认，请重新验证后自行继续原操作。"); }
        }

        public StepUpGrant CurrentStepUpGrant
        {
            get
            {
                lock (gate)
                {
                    if (stepUpGrant == null || stepUpGrant.IsExpired) return null;
                    try { RequireMutationOwnerLocked(stepUpGrant.Owner, false); return stepUpGrant; }
                    catch (ApiException) { return null; }
                }
            }
        }

        private void RequireMutationOwnerLocked(MutationOwnerSnapshot owner, bool includeReadScope = true)
        {
            RequireAuthenticated();
            if (owner == null || !Object.ReferenceEquals(owner.CoordinatorIdentity, mutationIdentity)
                || owner.AuthGeneration != generation || owner.IssuerApiBaseUrl != endpoint.ApiBaseUrl
                || owner.UserId != credentials.User.Id || owner.BusinessDatasetId != credentials.User.BusinessDatasetId
                || owner.BusinessResetGeneration != credentials.User.BusinessResetGeneration
                || (includeReadScope && owner.ReadScopeRevision != readScopes.Revision))
                throw new ApiException("MUTATION_OWNER_CHANGED", "账号、服务器、权限或数据范围已变化，请重新读取详情并核对原编辑内容。");
            if (credentials.User.MustChangePassword)
                throw new ApiException("PASSWORD_CHANGE_REQUIRED", "请先修改初始密码，再重新打开业务页面。");
        }
        private void RequireMutationPermissionsLocked(IEnumerable<string> permissions)
        {
            if (permissions.Any(value => !credentials.User.HasPermission(value)))
                throw new ApiException("FORBIDDEN", "当前账号没有执行此单位操作所需的权限。", 403);
        }
        private static bool SameMutationOwner(MutationOwnerSnapshot a, MutationOwnerSnapshot b)
        {
            return a != null && b != null && Object.ReferenceEquals(a.CoordinatorIdentity, b.CoordinatorIdentity)
                && a.AuthGeneration == b.AuthGeneration && a.ReadScopeRevision == b.ReadScopeRevision
                && a.IssuerApiBaseUrl == b.IssuerApiBaseUrl && a.UserId == b.UserId
                && a.BusinessDatasetId == b.BusinessDatasetId && a.BusinessResetGeneration == b.BusinessResetGeneration;
        }
        private MutationResult CompleteMutation(MutationRequest request, MutationOutcome outcome, ApiException error, string response = null)
        {
            lock (gate)
            {
                if (outcome == MutationOutcome.Unknown && (error == null || !error.IsSubmissionUnknown))
                    error = new ApiException(error?.Code ?? "SUBMISSION_UNKNOWN",
                        error?.UserMessage ?? "提交结果尚未确认，请先核对原请求。", error?.StatusCode, true, error?.HasResponseCode ?? false);
                var result = new MutationResult(outcome, request, error, response);
                request.Result = result;
                return result;
            }
        }
        private static bool ValidUnitReply(string json, string expectedId)
        {
            try
            {
                var body = JsonValue.ParseObject(json);
                var id = JsonValue.RequiredString(body, "id", 36);
                CanonicalCommandId(id);
                JsonValue.RequiredString(body, "name", 16384);
                return expectedId == null || id == expectedId;
            }
            catch (Exception error) when (error is ApiException || error is FormatException || error is ArgumentException || error is InvalidOperationException)
            { return false; }
        }
        private static void RequireFields(IDictionary<string, FlatJsonField> fields, params string[] allowed)
        { if (fields.Keys.Any(key => !allowed.Contains(key, StringComparer.Ordinal))) throw InvalidAction(); }
        private static void RequireText(IDictionary<string, FlatJsonField> fields, string name, bool required)
        {
            FlatJsonField field;
            if (!fields.TryGetValue(name, out field)) { if (required) throw InvalidAction(); return; }
            if (field.Value != null && !(field.Value is string)) throw InvalidAction();
            if (required && String.IsNullOrWhiteSpace(field.Value as string)) throw InvalidAction();
        }
        private static void RequireStatus(IDictionary<string, FlatJsonField> fields, bool required)
        {
            FlatJsonField value;
            if (!fields.TryGetValue("status", out value) || value.Value == null)
            { if (required) throw InvalidAction(); return; }
            if (!(value.Value is string) || ((string)value.Value != "使用" && (string)value.Value != "禁用")) throw InvalidAction();
        }
        private static string CanonicalCommandId(string value)
        {
            Guid id;
            if (value == null || !Guid.TryParseExact(value, "D", out id) || id == Guid.Empty || id.ToString("D") != value)
                throw new ApiException("MUTATION_ID_INVALID", "请为本次提交或目标记录提供标准 UUID；不能使用名称、旧库编号或任意路径代替。");
            return value;
        }
        private static ApiException InvalidAction()
        { return new ApiException("MUTATION_ACTION_NOT_APPROVED", "操作或字段不符合已审核的单位写入合同，未发送请求。"); }
    }
}
