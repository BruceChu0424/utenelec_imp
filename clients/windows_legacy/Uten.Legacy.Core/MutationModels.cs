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
    public enum MutationAction { Unknown = 0, UnitCreate = 1, UnitUpdate = 2, UnitStatus = 3 }
    public enum MutationOutcome { NotSent, Confirmed, Rejected, Unknown }
    public enum MutationVersionStrategy { NotSupported, AcceptedButIgnored }
    public enum MutationReceiptStrategy { NoReceiptManualReconciliation }

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
        public int ContractVersion { get { return 1; } }
        public string RequestId { get; private set; }
        public string Method { get; private set; }
        public string RelativePath { get; private set; }
        public string ResourceId { get; private set; }
        public string BodyJson { get; private set; }
        public string BodySha256 { get; private set; }
        public MutationOwnerSnapshot Owner { get; private set; }
        public ReadOnlyCollection<string> RequiredPermissions { get; private set; }
        public MutationVersionStrategy VersionStrategy { get; private set; }
        public MutationReceiptStrategy ReceiptStrategy { get { return MutationReceiptStrategy.NoReceiptManualReconciliation; } }
        public bool EnforcesExpectedVersion { get { return false; } }
        public bool ServerIdempotencyAvailable { get { return false; } }
        public bool RequiresStepUp { get { return false; } }
        public string RequestIdHeader { get { return null; } }
        public string RequestIdBodyField { get { return null; } }
        public string ExpectedVersionJson { get; private set; }
        public bool HasMeasurementDimension { get; private set; }
        public bool HasMassUnitCode { get; private set; }
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
            BodyJson = body; BodySha256 = Hash(new UTF8Encoding(false, true).GetBytes(body)); Owner = owner;
            RequiredPermissions = permissions.Distinct(StringComparer.Ordinal).ToList().AsReadOnly();
            VersionStrategy = versionStrategy; ObservedStatus = observedStatus;
            FlatJsonField version;
            ExpectedVersionJson = fields.TryGetValue("version", out version) ? version.Raw : null;
            HasMeasurementDimension = fields.ContainsKey("measurementDimension");
            HasMassUnitCode = fields.ContainsKey("massUnitCode");
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
        public bool NeedsManualReconciliation { get { return Outcome == MutationOutcome.Unknown; } }
        public bool IsDurablyRecorded { get; private set; }
        public ApiException PersistenceError { get; private set; }
        public string ReconciliationHint { get; private set; }
        internal MutationResult(MutationOutcome outcome, MutationRequest request, ApiException error, string response = null)
        {
            Outcome = outcome; Request = request; Error = error; ResponseJson = response;
            ReconciliationHint = outcome == MutationOutcome.Unknown
                ? "请在原服务器、原账号和原业务数据集中人工核对单位详情及操作历史。此接口没有请求回执或强幂等键，不能凭同名记录认领结果，也不要直接再次提交。保留原请求编号和原始内容，并核对本机提交台账的保存状态。"
                : null;
        }
        internal void RecordPersistence(bool saved, ApiException error) { IsDurablyRecorded = saved; PersistenceError = error; }
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
            if (json == null || new UTF8Encoding(false, true).GetByteCount(json) > maximumBytes) throw new FormatException();
            var fields = new Dictionary<string, FlatJsonField>(StringComparer.Ordinal);
            var position = 0;
            White(json, ref position); Take(json, ref position, '{'); White(json, ref position);
            if (position < json.Length && json[position] == '}') position++;
            else while (true)
            {
                White(json, ref position);
                var key = String(json, ref position, false);
                White(json, ref position); Take(json, ref position, ':'); White(json, ref position);
                var start = position;
                object value;
                if (position < json.Length && json[position] == '"') value = String(json, ref position, preserveValueControls);
                else
                {
                    while (position < json.Length && json[position] != ',' && json[position] != '}') position++;
                    var token = json.Substring(start, position - start).Trim();
                    long integer;
                    if (token == "null") value = null;
                    else if (System.Text.RegularExpressions.Regex.IsMatch(token, "^(0|[1-9][0-9]*)$")
                        && Int64.TryParse(token, NumberStyles.None, CultureInfo.InvariantCulture, out integer)) value = integer;
                    else throw new FormatException();
                }
                if (fields.ContainsKey(key)) throw new FormatException();
                fields.Add(key, new FlatJsonField(json.Substring(start, position - start).Trim(), value));
                White(json, ref position);
                if (position < json.Length && json[position] == ',') { position++; continue; }
                Take(json, ref position, '}'); break;
            }
            White(json, ref position);
            if (position != json.Length) throw new FormatException();
            return fields;
        }
        private static string String(string json, ref int position, bool preserveControls)
        {
            var start = position;
            Take(json, ref position, '"');
            while (position < json.Length)
            {
                var value = json[position++];
                if (value == '\\') { if (position >= json.Length) throw new FormatException(); position++; continue; }
                if (value != '"') continue;
                var result = new JavaScriptSerializer().DeserializeObject(json.Substring(start, position - start)) as string;
                if (result == null || (!preserveControls && result.Any(Char.IsControl))) throw new FormatException();
                // Reject unpaired UTF-16 surrogates instead of silently replacing source bytes.
                new UTF8Encoding(false, true).GetByteCount(result);
                return result;
            }
            throw new FormatException();
        }
        private static void White(string text, ref int p) { while (p < text.Length && (text[p] == ' ' || text[p] == '\t' || text[p] == '\r' || text[p] == '\n')) p++; }
        private static void Take(string text, ref int p, char ch) { if (p >= text.Length || text[p++] != ch) throw new FormatException(); }
    }
}
