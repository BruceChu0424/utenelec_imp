using System;
using System.Collections.Generic;
using System.Linq;

namespace Uten.Legacy.Core
{
    public sealed class MutationExportJob
    {
        public string Id { get; internal set; }
        public string Domain { get; internal set; }
        public string Report { get; internal set; }
        public string Format { get; internal set; }
        public string Status { get; internal set; }
        public bool CancelRequested { get; internal set; }
        public int Rows { get; internal set; }
        public long Bytes { get; internal set; }
        public string SnapshotAt { get; internal set; }
        public string Error { get; internal set; }
        public string CreatedAt { get; internal set; }
        public string FinishedAt { get; internal set; }
        public bool HasCreationRequestProof { get; internal set; }
    }

    public sealed partial class SessionCoordinator
    {
        /// <summary>Pure metadata read. Presence of View.request alone never proves a command.</summary>
        public static MutationExportJob ParseUnitExportJob(string json, string expectedJobId)
        {
            Guid id;
            if (!Guid.TryParseExact(expectedJobId, "D", out id) || id == Guid.Empty) throw new FormatException();
            return UnitExportMutationContract.ReadMetadata(MutationJsonTree.Parse(json, 2097152, true, 16384, false, true).Object, id.ToString("D"));
        }
        public static IReadOnlyList<MutationExportJob> ParseRecentUnitExportJobs(string json)
        {
            var items = MutationJsonTree.Parse(json, 2097152, true, 16384, false, true).Array;
            if (items.Count > 50) throw new FormatException();
            var result = new List<MutationExportJob>(); var seen = new HashSet<string>(StringComparer.Ordinal);
            foreach (var item in items)
            {
                var value = item.Object;
                var domain = MutationJsonTree.Text(MutationJsonTree.Required(value, "domain"), true);
                var report = MutationJsonTree.Text(MutationJsonTree.Required(value, "report"), true);
                if (domain != "master" || report != "unit") continue;
                var id = MutationJsonTree.Uuid(MutationJsonTree.Required(value, "id"));
                if (!seen.Add(id)) throw new FormatException();
                result.Add(UnitExportMutationContract.ReadMetadata(value, id));
            }
            return result.AsReadOnly();
        }
        internal static bool IsUnitExportMutation(MutationAction action)
        { return action == MutationAction.UnitExportSubmit || action == MutationAction.UnitExportCancel; }
        private static MutationRequest BuildUnitExportRequest(MutationAction action, string requestId, string body,
            MutationOwnerSnapshot owner, string resourceId, string observedStatus)
        {
            CanonicalCommandId(requestId); if (observedStatus != null) throw InvalidAction();
            try
            {
                if (action == MutationAction.UnitExportSubmit)
                {
                    var values = UnitExportMutationContract.SubmitObject(MutationJsonTree.Parse(body, 65536, false, 4096, false, true).Object);
                    var jobId = MutationJsonTree.Uuid(values["id"]);
                    if (resourceId != null && resourceId != jobId) throw new FormatException();
                    return new MutationRequest(action, requestId, "POST", "report-export-jobs", jobId, body, owner, new[] { "unit:export" },
                        MutationVersionStrategy.NotSupported, FlatNodes(values), null) { ResponseKind = MutationResponseKind.ExportJob };
                }
                resourceId = CanonicalCommandId(resourceId);
                if ((body != null && new System.Text.UTF8Encoding(false, true).GetByteCount(body) > 16384)
                    || (!String.IsNullOrWhiteSpace(body) && MutationJsonTree.Parse(body, 16384).Object.Count != 0)) throw new FormatException();
                return new MutationRequest(action, requestId, "POST", "report-export-jobs/" + resourceId + "/cancel", resourceId, body,
                    owner, new[] { "unit:export" }, MutationVersionStrategy.NotSupported, new Dictionary<string, FlatJsonField>(), null)
                { ResponseKind = MutationResponseKind.ExportJob };
            }
            catch (Exception invalid) when (invalid is FormatException || invalid is ArgumentException || invalid is InvalidOperationException)
            { throw new ApiException("MUTATION_BODY_INVALID", "单位导出须使用固定任务编号、原始单位筛选与 Excel 格式；不能携带密码或修改原任务条件。"); }
        }
        private static Dictionary<string, FlatJsonField> FlatNodes(Dictionary<string, MutationJsonNode> values)
        { return values.ToDictionary(value => value.Key, value => new FlatJsonField(value.Value.Raw, value.Value.Value), StringComparer.Ordinal); }
    }

    internal static class UnitExportMutationContract
    {
        internal static Dictionary<string, MutationJsonNode> SubmitObject(Dictionary<string, MutationJsonNode> values)
        {
            MutationJsonTree.Keys(values, "id", "domain", "report", "format", "parameters", "sort", "order", "columnProjection");
            MutationJsonTree.Uuid(MutationJsonTree.Required(values, "id"));
            if (MutationJsonTree.Text(MutationJsonTree.Required(values, "domain"), true) != "master"
                || MutationJsonTree.Text(MutationJsonTree.Required(values, "report"), true) != "unit") throw new FormatException();
            MutationJsonNode format;
            if (values.TryGetValue("format", out format) && format.Value != null && MutationJsonTree.Text(format) != "xlsx") throw new FormatException();
            foreach (var key in new[] { "sort", "order" })
            { MutationJsonNode value; if (values.TryGetValue(key, out value) && value.Value != null) throw new FormatException(); }
            MutationJsonNode projection; values.TryGetValue("columnProjection", out projection); UnitColumnProjectionContract.Validate(projection);
            var parameters = MutationJsonTree.Required(values, "parameters").Object;
            MutationJsonTree.Keys(parameters, "filter");
            var filterText = MutationJsonTree.Text(MutationJsonTree.Required(parameters, "filter"), true, 60000);
            var filter = MutationJsonTree.Parse(filterText, 65536).Object;
            MutationJsonTree.Keys(filter, "keyword", "nullFields", "code", "name", "status", "dimension");
            var query = new Dictionary<string, string>(StringComparer.Ordinal);
            foreach (var item in filter)
            {
                if (item.Value.Value == null) continue;
                if (item.Key != "nullFields") query.Add(item.Key, MutationJsonTree.Text(item.Value, false, 2000));
                else
                {
                    if (item.Value.Array.Count > 4) throw new FormatException();
                    var names = item.Value.Array.Select(value => MutationJsonTree.Text(value, true, 16)).ToArray();
                    if (names.Length != 0) query.Add(item.Key, String.Join(",", names));
                }
            }
            try { SessionCoordinator.UnitExportQuery(query); }
            catch (ApiException) { throw new FormatException(); }
            // Only validation/encoding; never rewrite the original filter string.
            return values;
        }
        internal static bool SameSubmit(Dictionary<string, MutationJsonNode> left, Dictionary<string, MutationJsonNode> right)
        {
            SubmitObject(left); SubmitObject(right);
            MutationJsonNode a, b; left.TryGetValue("columnProjection", out a); right.TryGetValue("columnProjection", out b);
            return MutationJsonTree.Uuid(left["id"]) == MutationJsonTree.Uuid(right["id"])
                && (string)left["parameters"].Object["filter"].Value == (string)right["parameters"].Object["filter"].Value
                && UnitColumnProjectionContract.Equivalent(a, b);
        }
        internal static MutationExportJob ReadJob(MutationRequest request, string json)
        {
            var values = MutationJsonTree.Parse(json, 2097152, true, 16384, false, true).Object;
            var result = ReadMetadata(values, request.ResourceId);
            MutationJsonNode proof;
            if (request.Action == MutationAction.UnitExportSubmit && values.TryGetValue("request", out proof) && proof.Value != null)
            {
                if (!SameSubmit(SubmitObject(MutationJsonTree.Parse(request.BodyJson, 65536, false, 4096, false, true).Object), proof.Object)) throw new FormatException();
                result.HasCreationRequestProof = true;
            }
            return result;
        }
        internal static MutationExportJob ReadMetadata(Dictionary<string, MutationJsonNode> values, string expectedJobId)
        {
            MutationJsonTree.Keys(values, "id", "domain", "report", "format", "status", "cancelRequested", "rows", "bytes", "snapshotAt", "error", "createdAt", "finishedAt", "request");
            var id = MutationJsonTree.Uuid(MutationJsonTree.Required(values, "id"));
            if (id != expectedJobId || MutationJsonTree.Text(MutationJsonTree.Required(values, "domain"), true) != "master"
                || MutationJsonTree.Text(MutationJsonTree.Required(values, "report"), true) != "unit"
                || MutationJsonTree.Text(MutationJsonTree.Required(values, "format"), true) != "xlsx") throw new FormatException();
            var status = MutationJsonTree.Text(MutationJsonTree.Required(values, "status"), true, 32);
            if (!new[] { "PENDING", "RUNNING", "SUCCEEDED", "FAILED", "CANCELLED", "EXPIRED" }.Contains(status, StringComparer.Ordinal)) throw new FormatException();
            var cancel = MutationJsonTree.Required(values, "cancelRequested"); if (!(cancel.Value is bool)) throw new FormatException();
            var result = new MutationExportJob { Id = id, Domain = "master", Report = "unit", Format = "xlsx", Status = status,
                CancelRequested = (bool)cancel.Value, Rows = (int)MutationJsonTree.Integer(MutationJsonTree.Required(values, "rows"), 0, Int32.MaxValue),
                Bytes = MutationJsonTree.Integer(MutationJsonTree.Required(values, "bytes"), 0, Int64.MaxValue),
                SnapshotAt = Optional(values, "snapshotAt", 128), Error = Optional(values, "error", 16384),
                CreatedAt = MutationJsonTree.Text(MutationJsonTree.Required(values, "createdAt"), true, 128), FinishedAt = Optional(values, "finishedAt", 128) };
            MutationJsonNode proof;
            if (values.TryGetValue("request", out proof) && proof.Value != null && !(proof.Value is Dictionary<string, MutationJsonNode>)) throw new FormatException();
            return result;
        }
        internal static void RequireCreationProof(MutationRequest request, string json)
        {
            if (request.Action != MutationAction.UnitExportSubmit || !ReadJob(request, json).HasCreationRequestProof) throw new FormatException();
        }
        private static string Optional(Dictionary<string, MutationJsonNode> values, string key, int maximum)
        { MutationJsonNode value; return values.TryGetValue(key, out value) ? MutationJsonTree.Text(value, false, maximum) : null; }
    }
}
