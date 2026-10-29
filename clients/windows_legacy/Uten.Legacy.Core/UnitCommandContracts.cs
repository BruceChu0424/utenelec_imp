using System;
using System.Collections.Generic;
using System.Linq;

namespace Uten.Legacy.Core
{
    public sealed partial class SessionCoordinator
    {
        internal static bool IsSupplementalUnitAction(MutationAction action)
        { return action == MutationAction.UnitInlineEdit || action == MutationAction.UnitBatchStatus || action == MutationAction.UnitBatchDelete; }

        internal static bool PendingUnitCommandConflicts(MutationRequest request, MutationJournalRecord before)
        {
            if (!before.MayNeedManualReconciliation) return false;
            // A personal replay/version restore can touch multiple rows. Its public DTO does
            // not expose snapshots, so no client-side row-equality receipt is invented.
            if (IsUnitHistoryMutation(request.Action) && IsUnitHistoryMutation(before.Action)) return true;
            if (request.Action == MutationAction.UnitColumnLayoutSave && before.Action == request.Action) return true;
            if (request.Action == MutationAction.UnitPlatformDefinitionCreate && before.Action == request.Action) return request.BodySha256 == before.BodySha256;
            if ((request.Action == MutationAction.UnitPlatformDefinitionDelete || request.Action == MutationAction.UnitPlatformDefinitionUse)
                && (before.Action == MutationAction.UnitPlatformDefinitionDelete || before.Action == MutationAction.UnitPlatformDefinitionUse)) return request.ResourceId == before.ResourceId;
            if (request.Action == MutationAction.UnitCreate && before.Action == MutationAction.UnitCreate)
                return request.BodySha256 == before.BodySha256;
            var current = UnitTargets(request.Action, request.ResourceId, request.BatchResourceIds);
            var prior = UnitTargets(before.Action, before.ResourceId, before.BatchResourceIds);
            return current.Intersect(prior, StringComparer.Ordinal).Any();
        }
        private static IEnumerable<string> UnitTargets(MutationAction action, string resourceId, IEnumerable<string> batchIds)
        {
            if (action == MutationAction.UnitBatchStatus || action == MutationAction.UnitBatchDelete) return batchIds;
            if (action == MutationAction.UnitUpdate || action == MutationAction.UnitStatus || action == MutationAction.UnitInlineEdit || action == MutationAction.UnitPlatformValuesWrite)
                return resourceId == null ? new string[0] : new[] { resourceId };
            return new string[0];
        }

        private static MutationRequest BuildUnitSupplementalRequest(MutationAction action, string requestId, string body,
            MutationOwnerSnapshot owner, string resourceId, string observedStatus)
        {
            CanonicalCommandId(requestId);
            if (observedStatus != null) throw InvalidAction();
            Dictionary<string, MutationJsonNode> fields;
            try { fields = ValidateSupplementalBody(action, body, false); }
            catch (Exception error) when (error is FormatException || error is ArgumentException || error is InvalidOperationException)
            { throw new ApiException("MUTATION_BODY_INVALID", "单位行内或批量提交不符合审核合同；请核对原值、字段及完整目标集合。"); }
            var flat = fields.ToDictionary(value => value.Key, value => new FlatJsonField(value.Value.Raw, value.Value.Value), StringComparer.Ordinal);
            if (action == MutationAction.UnitInlineEdit)
            {
                resourceId = CanonicalCommandId(resourceId);
                var permissions = new List<string> { "unit:view", "unit:edit" };
                var expected = fields["expected"].Object; var changes = fields["changes"].Object;
                MutationJsonNode changedStatus;
                if (changes.TryGetValue("status", out changedStatus)
                    && !Object.Equals(expected["status"].Value, changedStatus.Value)) permissions.Add("unit:status");
                return new MutationRequest(action, requestId, "PATCH", "master/inline-edit/units/" + resourceId, resourceId,
                    body, owner, permissions, MutationVersionStrategy.ExpectedFieldValues, flat, null);
            }
            if (resourceId != null) throw InvalidAction();
            var ids = fields["items"].Array.Select(value => MutationJsonTree.Uuid(value.Object["id"])).ToList();
            return new MutationRequest(action, requestId, "POST", action == MutationAction.UnitBatchStatus ? "master/units/batch-status" : "master/units/batch-delete",
                null, body, owner, new[] { action == MutationAction.UnitBatchStatus ? "unit:status" : "unit:delete" },
                MutationVersionStrategy.AcceptedButIgnored, flat, null)
            { ResponseKind = MutationResponseKind.BatchResult, BatchResourceIds = ids.AsReadOnly() };
        }

        internal static Dictionary<string, MutationJsonNode> ValidateSupplementalBody(MutationAction action, string body, bool draft)
        {
            var fields = MutationJsonTree.Parse(body, draft || action != MutationAction.UnitInlineEdit ? 65536 : 16384, draft).Object;
            if (action == MutationAction.UnitInlineEdit)
            {
                MutationJsonTree.Keys(fields, "expected", "changes");
                Dictionary<string, MutationJsonNode> expected = null, changes = null;
                MutationJsonNode node;
                if (fields.TryGetValue("expected", out node)) expected = node.Object;
                if (fields.TryGetValue("changes", out node)) changes = node.Object;
                foreach (var map in new[] { expected, changes }.Where(value => value != null))
                {
                    MutationJsonTree.Keys(map, "name", "status", "measurementDimension", "massUnitCode");
                    foreach (var value in map.Values) MutationJsonTree.Text(value);
                }
                if (!draft)
                {
                    if (expected == null || changes == null || changes.Count == 0 || changes.Count != expected.Count
                        || changes.Keys.Any(key => !expected.ContainsKey(key))) throw new FormatException();
                    if (changes.TryGetValue("name", out node)) MutationJsonTree.Text(node, true);
                    if (changes.TryGetValue("status", out node) && node.Value as string != "使用" && node.Value as string != "禁用") throw new FormatException();
                }
                return fields;
            }
            if (action != MutationAction.UnitBatchStatus && action != MutationAction.UnitBatchDelete) throw new FormatException();
            if (action == MutationAction.UnitBatchStatus) MutationJsonTree.Keys(fields, "status", "items");
            else MutationJsonTree.Keys(fields, "items");
            MutationJsonNode status;
            if (fields.TryGetValue("status", out status)) MutationJsonTree.Text(status);
            if (!draft && action == MutationAction.UnitBatchStatus
                && (!fields.TryGetValue("status", out status) || status.Value as string != "使用" && status.Value as string != "禁用")) throw new FormatException();
            MutationJsonNode items;
            if (!fields.TryGetValue("items", out items)) { if (draft) return fields; throw new FormatException(); }
            if (items.Array.Count > 500 || (!draft && items.Array.Count == 0)) throw new FormatException();
            var seen = new HashSet<string>(StringComparer.Ordinal);
            foreach (var item in items.Array)
            {
                var row = item.Object; MutationJsonTree.Keys(row, "id", "version");
                var id = MutationJsonTree.Uuid(MutationJsonTree.Required(row, "id"));
                if (!seen.Add(id)) throw new FormatException();
                MutationJsonNode version;
                if (row.TryGetValue("version", out version) && version.Value != null) MutationJsonTree.Integer(version, 0, Int64.MaxValue);
            }
            return fields;
        }
    }

    internal static partial class MutationResponseContract
    {
        internal sealed class Assessment
        {
            internal MutationBatchResult Batch;
            internal MutationExportJob ExportJob;
        }
        internal static Assessment Assess(MutationRequest request, string json)
        { return request.ResponseKind == MutationResponseKind.ExportJob ? new Assessment { ExportJob = UnitExportMutationContract.ReadJob(request, json) }
            : new Assessment { Batch = Validate(request, json) }; }
        internal static MutationBatchResult Validate(MutationRequest request, string json)
        {
            if (request.ResponseKind == MutationResponseKind.ExportJob) { UnitExportMutationContract.ReadJob(request, json); return null; }
            if (request.ResponseKind == MutationResponseKind.PlatformDefinition)
            {
                var definition = UnitPlatformResponse.ReadDefinition(MutationJsonTree.Parse(json, 2097152, true, 16384).Object);
                var expected = SessionCoordinator.ValidateUnitPlatformBody(request.Action, request.BodyJson, false);
                if (definition.Type != expected["type"].Value as string) throw new FormatException();
                return null;
            }
            if (request.ResponseKind == MutationResponseKind.PlatformRow)
            {
                var row = UnitPlatformResponse.ReadRow(MutationJsonTree.Parse(json, 2097152, true, 65536).Object);
                var body = SessionCoordinator.ValidateUnitPlatformBody(request.Action, request.BodyJson, false);
                var expectedVersion = (long)body["expectedVersion"].Value;
                var ids = new HashSet<string>(body["cells"].Array.Select(field => MutationJsonTree.Uuid(field.Object["columnId"])), StringComparer.Ordinal);
                if (row.Id != request.ResourceId || expectedVersion == Int64.MaxValue || row.Version != expectedVersion + 1
                    || !ids.SetEquals(row.Cells.Keys) || row.Cells.Values.Any(cell => !cell.Persisted)) throw new FormatException();
                return null;
            }
            if (request.ResponseKind == MutationResponseKind.Empty)
            { if (!String.IsNullOrWhiteSpace(json)) throw new FormatException(); return null; }
            if (request.ResponseKind == MutationResponseKind.OperationHistory)
            { ValidateOperationHistory(request, json); return null; }
            if (request.ResponseKind == MutationResponseKind.UnitDetail)
            {
                var root = MutationJsonTree.Parse(json, 2097152, true, 16384, true).Object;
                var id = MutationJsonTree.Uuid(MutationJsonTree.Required(root, "id"));
                MutationJsonTree.Text(MutationJsonTree.Required(root, "name"), true);
                if (request.ResourceId != null && id != request.ResourceId) throw new FormatException();
                return null;
            }
            if (request.ResponseKind != MutationResponseKind.BatchResult) throw new FormatException();
            var value = MutationJsonTree.Parse(json, 2097152, true, 16384).Object;
            MutationJsonTree.Keys(value, "succeeded", "failed", "results");
            var succeeded = (int)MutationJsonTree.Integer(MutationJsonTree.Required(value, "succeeded"), 0, 500);
            var failed = (int)MutationJsonTree.Integer(MutationJsonTree.Required(value, "failed"), 0, 500);
            var items = MutationJsonTree.Required(value, "results").Array;
            if (items.Count != request.BatchResourceIds.Count || succeeded + failed != items.Count) throw new FormatException();
            var requested = new HashSet<string>(request.BatchResourceIds, StringComparer.Ordinal);
            var seen = new HashSet<string>(StringComparer.Ordinal);
            var results = new List<MutationBatchItemResult>();
            foreach (var item in items)
            {
                var row = item.Object; MutationJsonTree.Keys(row, "id", "label", "ok", "reason");
                var id = MutationJsonTree.Uuid(MutationJsonTree.Required(row, "id"));
                var ok = MutationJsonTree.Required(row, "ok");
                if (!(ok.Value is bool) || !requested.Contains(id) || !seen.Add(id)) throw new FormatException();
                MutationJsonNode label, reason;
                var labelText = row.TryGetValue("label", out label) ? MutationJsonTree.Text(label, false, 16384) : null;
                var reasonText = row.TryGetValue("reason", out reason) ? MutationJsonTree.Text(reason, false, 16384) : null;
                if (!(bool)ok.Value && String.IsNullOrWhiteSpace(reasonText)) throw new FormatException();
                results.Add(new MutationBatchItemResult(id, labelText, (bool)ok.Value, reasonText));
            }
            if (results.Count(row => row.Ok) != succeeded) throw new FormatException();
            return new MutationBatchResult(succeeded, failed, results);
        }
    }
}
