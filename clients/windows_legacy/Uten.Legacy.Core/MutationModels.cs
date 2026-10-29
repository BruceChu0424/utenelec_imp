using System;
using System.Collections.Generic;
using System.Collections.ObjectModel;
using System.Globalization;
using System.Linq;
using System.Security.Cryptography;
using System.Text;
using System.Web.Script.Serialization;

namespace Uten.Legacy.Core
{
    public enum MutationAction { Unknown = 0, UnitCreate = 1, UnitUpdate = 2, UnitStatus = 3,
        UnitInlineEdit = 4, UnitBatchStatus = 5, UnitBatchDelete = 6, UnitUndo = 7, UnitRedo = 8, UnitRecordRestore = 9,
        UnitExportSubmit = 10, UnitExportCancel = 11,
        UnitColumnLayoutSave = 12, UnitPlatformDefinitionCreate = 13, UnitPlatformDefinitionDelete = 14,
        UnitPlatformDefinitionUse = 15, UnitPlatformValuesWrite = 16 }
    public enum MutationOutcome { NotSent, Confirmed, Rejected, Unknown }
    public enum MutationVersionStrategy { NotSupported, AcceptedButIgnored, ExpectedFieldValues, OperationVersion, OpaqueHistoryHead, PlatformRowVersion }
    public enum MutationReceiptStrategy { NoReceiptManualReconciliation, ExportJobCreation, ExportJobStateQuery }
    public enum MutationResponseKind { UnitDetail, BatchResult, OperationHistory, Empty, ExportJob, PlatformDefinition, PlatformRow }

    /// <summary>A page captures this before reading/editing. An ordinary token refresh is allowed;
    /// a different account, issuer, permissions, dataset or read scope requires a new edit intent.</summary>
    public sealed class MutationOwnerSnapshot
    {
        internal readonly object CoordinatorIdentity;
        public long AuthGeneration { get; private set; }
        public long ReadScopeRevision { get; private set; }
        public string IssuerApiBaseUrl { get; private set; }
        public string UserId { get; private set; }
        public string BusinessDatasetId { get; private set; }
        public long BusinessResetGeneration { get; private set; }
        internal MutationOwnerSnapshot(object identity, long generation, long revision, string issuer, UserProfile user)
        {
            CoordinatorIdentity = identity; AuthGeneration = generation; ReadScopeRevision = revision;
            IssuerApiBaseUrl = issuer; UserId = user.Id; BusinessDatasetId = user.BusinessDatasetId;
            BusinessResetGeneration = user.BusinessResetGeneration;
        }
    }

    /// <summary>A frozen, allowlisted command. RequestId is LOCAL correlation, never a server receipt.
    /// BodyJson is kept verbatim: missing fields, explicit null and integer precision are not rewritten.</summary>
    public sealed class MutationRequest
    {
        public MutationAction Action { get; private set; }
        public int ContractVersion { get { return ContractVersionFor(Action); } }
        internal static int ContractVersionFor(MutationAction action)
        { return (int)action >= 12 && (int)action <= 16 ? 4 : action == MutationAction.UnitExportSubmit || action == MutationAction.UnitExportCancel ? 3 : (int)action >= 4 ? 2 : 1; }
        public string RequestId { get; private set; }
        public string Method { get; private set; }
        public string RelativePath { get; private set; }
        public string ResourceId { get; private set; }
        public string BodyJson { get; private set; }
        public string BodySha256 { get; private set; }
        public MutationOwnerSnapshot Owner { get; private set; }
        public ReadOnlyCollection<string> RequiredPermissions { get; private set; }
        public MutationVersionStrategy VersionStrategy { get; private set; }
        public MutationReceiptStrategy ReceiptStrategy { get { return Action == MutationAction.UnitExportSubmit ? MutationReceiptStrategy.ExportJobCreation
            : Action == MutationAction.UnitExportCancel ? MutationReceiptStrategy.ExportJobStateQuery : MutationReceiptStrategy.NoReceiptManualReconciliation; } }
        public bool EnforcesExpectedVersion { get { return VersionStrategy == MutationVersionStrategy.OperationVersion || VersionStrategy == MutationVersionStrategy.PlatformRowVersion; } }
        public bool EnforcesExpectedValues { get { return VersionStrategy == MutationVersionStrategy.ExpectedFieldValues; } }
        public bool EnforcesExpectedHead { get { return VersionStrategy == MutationVersionStrategy.OpaqueHistoryHead; } }
        public bool ServerIdempotencyAvailable { get { return Action == MutationAction.UnitExportSubmit; } }
        public string ServerIdempotencyKey { get { return ServerIdempotencyAvailable ? ResourceId : null; } }
        public string ServerIdempotencyBodyField { get { return ServerIdempotencyAvailable ? "id" : null; } }
        public string ReceiptPath { get { return Action == MutationAction.UnitExportSubmit || Action == MutationAction.UnitExportCancel ? "report-export-jobs/" + ResourceId : null; } }
        public bool RequiresStepUp { get { return false; } }
        public string RequestIdHeader { get { return null; } }
        public string RequestIdBodyField { get { return null; } }
        public string ExpectedVersionJson { get; private set; }
        public bool HasMeasurementDimension { get; private set; }
        public bool HasMassUnitCode { get; private set; }
        public MutationResponseKind ResponseKind { get; internal set; }
        public ReadOnlyCollection<string> BatchResourceIds { get; internal set; } = new List<string>().AsReadOnly();
        public int MaximumBodyBytes { get { return Action == MutationAction.UnitPlatformValuesWrite ? 524288 : Action == MutationAction.UnitBatchStatus || Action == MutationAction.UnitBatchDelete
            || Action == MutationAction.UnitExportSubmit ? 65536 : 16384; } }
        public string ExpectedHead { get; internal set; }
        public string OriginDraftId { get; private set; }
        public long? OriginDraftRevision { get; private set; }
        internal string ObservedStatus;
        internal bool Started;
        internal MutationResult Result;

        internal MutationRequest(MutationAction action, string id, string method, string path, string resource,
            string body, MutationOwnerSnapshot owner, IEnumerable<string> permissions,
            MutationVersionStrategy versionStrategy, IDictionary<string, FlatJsonField> fields, string observedStatus)
        {
            Action = action; RequestId = id; Method = method; RelativePath = path; ResourceId = resource;
            BodyJson = body; BodySha256 = Hash(body == null ? new byte[0] : new UTF8Encoding(false, true).GetBytes(body)); Owner = owner;
            RequiredPermissions = permissions.Distinct(StringComparer.Ordinal).ToList().AsReadOnly();
            VersionStrategy = versionStrategy; ObservedStatus = observedStatus;
            FlatJsonField version;
            ExpectedVersionJson = fields.TryGetValue("version", out version) || fields.TryGetValue("expectedVersion", out version) ? version.Raw : null;
            HasMeasurementDimension = fields.ContainsKey("measurementDimension");
            HasMassUnitCode = fields.ContainsKey("massUnitCode");
            FlatJsonField changed;
            if (action == MutationAction.UnitInlineEdit && fields.TryGetValue("changes", out changed))
            {
                var changeFields = changed.Value as Dictionary<string, MutationJsonNode>;
                HasMeasurementDimension = changeFields?.ContainsKey("measurementDimension") == true;
                HasMassUnitCode = changeFields?.ContainsKey("massUnitCode") == true;
            }
        }
        internal static string Hash(byte[] bytes)
        { using (var sha = SHA256.Create()) return BitConverter.ToString(sha.ComputeHash(bytes)).Replace("-", "").ToLowerInvariant(); }
        internal void LinkDraft(string draftId, long revision)
        {
            if (OriginDraftId != null || revision < 1) throw new InvalidOperationException("Draft linkage cannot be replaced.");
            OriginDraftId = draftId; OriginDraftRevision = revision;
        }
    }

    public sealed class MutationResult
    {
        public MutationOutcome Outcome { get; private set; }
        public MutationRequest Request { get; private set; }
        public ApiException Error { get; private set; }
        public string ResponseJson { get; private set; }
        public MutationResponseKind ResponseKind { get { return Request.ResponseKind; } }
        public MutationBatchResult BatchResult { get; internal set; }
        public MutationExportJob ExportJob { get; internal set; }
        public bool ConfirmedByReceiptQuery { get; internal set; }
        public bool NeedsReceiptQuery { get { return Outcome == MutationOutcome.Unknown && Request.ReceiptPath != null; } }
        public bool NeedsManualReconciliation { get { return Outcome == MutationOutcome.Unknown
            || Error?.Code == "MUTATION_PENDING_RECONCILIATION" || Error?.Code == "DRAFT_PENDING_SUBMISSION"; } }
        public bool IsDurablyRecorded { get; private set; }
        public ApiException PersistenceError { get; private set; }
        public string ReconciliationHint { get; private set; }
        internal MutationResult(MutationOutcome outcome, MutationRequest request, ApiException error, string response = null)
        {
            Outcome = outcome; Request = request; Error = error; ResponseJson = response;
            ReconciliationHint = outcome != MutationOutcome.Unknown ? null : request.ReceiptStrategy == MutationReceiptStrategy.ExportJobStateQuery
                ? "请按原任务编号检查取消标记和任务状态。核对期间保留原记录，后续操作须由用户明确决定。"
                : request.ReceiptPath != null
                ? "请按原任务编号查询导出任务。创建任务只有服务器返回完整原请求并与冻结内容一致，才可据此确认；旧服务缺少该证据时仍保留待核对。不能换任务编号盲重试，也不能在原编号下更改条件。"
                : "请在原服务器、原账号和原业务数据集中人工核对单位详情及操作历史。此接口没有请求回执或强幂等键，不能凭同名记录认领结果，也不要直接再次提交。保留原请求编号和原始内容，并核对本机提交台账的保存状态。";
        }
        internal void RecordPersistence(bool saved, ApiException error) { IsDurablyRecorded = saved; PersistenceError = error; }
    }

    /// <summary>Confirmed means the full per-item response is known, not that every item succeeded.</summary>
    public sealed class MutationBatchResult
    {
        public int Succeeded { get; private set; }
        public int Failed { get; private set; }
        public ReadOnlyCollection<MutationBatchItemResult> Items { get; private set; }
        public bool AllSucceeded { get { return Failed == 0; } }
        public bool HasAnyFailure { get { return Failed != 0; } }
        public bool HasPartialFailure { get { return Succeeded != 0 && Failed != 0; } }
        internal MutationBatchResult(int succeeded, int failed, IEnumerable<MutationBatchItemResult> items)
        { Succeeded = succeeded; Failed = failed; Items = items.ToList().AsReadOnly(); }
    }
    public sealed class MutationBatchItemResult
    {
        public string Id { get; private set; }
        public string Label { get; private set; }
        public bool Ok { get; private set; }
        public string Reason { get; private set; }
        internal MutationBatchItemResult(string id, string label, bool ok, string reason)
        { Id = id; Label = label; Ok = ok; Reason = reason; }
    }

    /// <summary>Memory-only grant. The server binds it to the auth session; idle five minutes,
    /// renewed by explicit authorized activity. Units do not require or transmit this grant.</summary>
    public sealed class StepUpGrant
    {
        public const string HeaderName = "X-Uten-Step-Up";
        internal readonly string Token;
        /// <summary>Credential for X-Uten-Step-Up only; never persist or log it. The controlled
        /// business dispatcher will attach it only when an audited action requires step-up.</summary>
        public string StepUpToken { get { return Token; } }
        internal readonly long IssuedAt;
        public MutationOwnerSnapshot Owner { get; private set; }
        public long ExpiresInSeconds { get; private set; }
        internal StepUpGrant(string token, long seconds, MutationOwnerSnapshot owner)
        { Token = token; ExpiresInSeconds = seconds; Owner = owner; IssuedAt = System.Diagnostics.Stopwatch.GetTimestamp(); }
        public bool IsExpired { get { return (System.Diagnostics.Stopwatch.GetTimestamp() - IssuedAt)
            / (double)System.Diagnostics.Stopwatch.Frequency >= ExpiresInSeconds; } }
    }

    internal sealed class FlatJsonField
    {
        internal readonly string Raw;
        internal readonly object Value;
        internal FlatJsonField(string raw, object value) { Raw = raw; Value = value; }
    }

    /// <summary>Only the flat string/null/Int64 unit DTO shape, not a general business JSON codec.
    /// Decode strings with the framework parser; never parse numeric tokens through Double.</summary>
    internal static class MutationFlatJson
    {
        internal static Dictionary<string, FlatJsonField> Parse(string json, int maximumBytes = 16384, bool preserveValueControls = false)
        {
            var root = MutationJsonTree.Parse(json, maximumBytes, preserveValueControls).Object;
            var result = new Dictionary<string, FlatJsonField>(StringComparer.Ordinal);
            foreach (var field in root)
            {
                if (field.Value.Value != null && !(field.Value.Value is string) && !(field.Value.Value is long)) throw new FormatException();
                result.Add(field.Key, new FlatJsonField(field.Value.Raw, field.Value.Value));
            }
            return result;
        }
    }
}
