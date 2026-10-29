using System;
using System.Collections.Generic;
using System.Globalization;
using System.Linq;

namespace Uten.Legacy.Core
{
    public sealed partial class SessionCoordinator
    {
        internal static bool IsUnitHistoryMutation(MutationAction action)
        { return action == MutationAction.UnitUndo || action == MutationAction.UnitRedo || action == MutationAction.UnitRecordRestore; }

        private static MutationRequest BuildUnitHistoryRequest(MutationAction action, string requestId, string body,
            MutationOwnerSnapshot owner, string resourceId, string observedStatus)
        {
            CanonicalCommandId(requestId);
            if (observedStatus != null) throw InvalidAction();
            Dictionary<string, MutationJsonNode> values;
            try
            {
                values = MutationJsonTree.Parse(body, 16384).Object;
                if (action == MutationAction.UnitRecordRestore)
                {
                    MutationJsonTree.Keys(values, "expectedHead", "before");
                    MutationJsonTree.Text(MutationJsonTree.Required(values, "expectedHead"), true, 128);
                    if (!(MutationJsonTree.Required(values, "before").Value is bool)) throw new FormatException();
                }
                else
                {
                    MutationJsonTree.Keys(values, "expectedVersion");
                    MutationJsonTree.Integer(MutationJsonTree.Required(values, "expectedVersion"), 0, Int64.MaxValue);
                }
            }
            catch (Exception invalid) when (invalid is FormatException || invalid is ArgumentException || invalid is InvalidOperationException)
            { throw new ApiException("MUTATION_BODY_INVALID", "单位历史操作须使用原操作版本，或原始历史头与明确恢复方向；不会推测版本或自动重复提交。"); }
            var fields = values.ToDictionary(value => value.Key, value => new FlatJsonField(value.Value.Raw, value.Value.Value), StringComparer.Ordinal);
            if (action == MutationAction.UnitRecordRestore)
            {
                long historyId;
                if (String.IsNullOrEmpty(resourceId) || !System.Text.RegularExpressions.Regex.IsMatch(resourceId, "^[1-9][0-9]{0,18}$")
                    || !Int64.TryParse(resourceId, NumberStyles.None, CultureInfo.InvariantCulture, out historyId) || historyId <= 0)
                    throw new ApiException("MUTATION_HISTORY_ID_INVALID", "请选择使用正整数 Int64 标识的真实历史版本，不能以名称或任意路径代替。");
                return new MutationRequest(action, requestId, "POST", "master/record-history/" + resourceId + "/restore?entityType=units", resourceId,
                    body, owner, new[] { "unit:view", "unit:edit" }, MutationVersionStrategy.OpaqueHistoryHead, fields, null)
                { ResponseKind = MutationResponseKind.Empty, ExpectedHead = (string)values["expectedHead"].Value };
            }
            resourceId = CanonicalCommandId(resourceId);
            // The server derives create/edit/status/delete grants from the immutable original
            // operation and current targets. An unconditional edit grant would reject a valid
            // status-only/create-only personal undo, so no invented edit requirement is added.
            return new MutationRequest(action, requestId, "POST", "master/operation-history/" + resourceId
                + (action == MutationAction.UnitUndo ? "/undo" : "/redo") + "?entityType=units", resourceId,
                body, owner, new[] { "unit:view" }, MutationVersionStrategy.OperationVersion, fields, null)
            { ResponseKind = MutationResponseKind.OperationHistory };
        }
    }

    internal static partial class MutationResponseContract
    {
        internal static void ValidateOperationHistory(MutationRequest request, string json)
        {
            var root = MutationJsonTree.Parse(json, 2097152, true, 16384).Object;
            MutationJsonTree.Keys(root, "entries", "events");
            var entries = MutationJsonTree.Required(root, "entries").Array;
            var events = MutationJsonTree.Required(root, "events").Array;
            if (entries.Count > 10 || events.Count > 30) throw new FormatException();
            var seen = new HashSet<string>(StringComparer.Ordinal);
            Dictionary<string, MutationJsonNode> target = null;
            foreach (var entry in entries)
            {
                var value = entry.Object;
                MutationJsonTree.Keys(value, "id", "operationType", "label", "summary", "createdAt", "state", "version", "affectedCount", "canUndo", "canRedo", "blockedReason");
                var id = MutationJsonTree.Uuid(MutationJsonTree.Required(value, "id"));
                if (!seen.Add(id)) throw new FormatException();
                OperationType(MutationJsonTree.Required(value, "operationType"));
                MutationJsonTree.Text(MutationJsonTree.Required(value, "label"), true);
                MutationJsonTree.Text(MutationJsonTree.Required(value, "summary"));
                MutationJsonTree.Text(MutationJsonTree.Required(value, "createdAt"), true, 128);
                var state = MutationJsonTree.Text(MutationJsonTree.Required(value, "state"), true, 16);
                if (state != "APPLIED" && state != "UNDONE") throw new FormatException();
                MutationJsonTree.Integer(MutationJsonTree.Required(value, "version"), 0, Int64.MaxValue);
                MutationJsonTree.Integer(MutationJsonTree.Required(value, "affectedCount"), 0, Int32.MaxValue);
                var canUndo = MutationJsonTree.Required(value, "canUndo"); var canRedo = MutationJsonTree.Required(value, "canRedo");
                if (!(canUndo.Value is bool) || !(canRedo.Value is bool) || (state == "APPLIED" && (bool)canRedo.Value)
                    || (state == "UNDONE" && (bool)canUndo.Value)) throw new FormatException();
                MutationJsonNode blocked;
                if (value.TryGetValue("blockedReason", out blocked)) MutationJsonTree.Text(blocked);
                if (id == request.ResourceId) target = value;
            }
            if (target == null) throw new FormatException();
            var expected = Int64.Parse(request.ExpectedVersionJson, CultureInfo.InvariantCulture);
            if (expected == Int64.MaxValue || (long)target["version"].Value != expected + 1
                || (string)target["state"].Value != (request.Action == MutationAction.UnitUndo ? "UNDONE" : "APPLIED")) throw new FormatException();
            var eventIds = new HashSet<string>(StringComparer.Ordinal);
            foreach (var item in events)
            {
                var value = item.Object;
                MutationJsonTree.Keys(value, "id", "operationId", "action", "label", "createdAt", "operationType");
                var id = MutationJsonTree.Text(MutationJsonTree.Required(value, "id"), true, 128);
                if (!eventIds.Add(id)) throw new FormatException();
                MutationJsonTree.Uuid(MutationJsonTree.Required(value, "operationId"));
                var action = MutationJsonTree.Text(MutationJsonTree.Required(value, "action"), true, 16);
                if (action != "UNDO" && action != "REDO") throw new FormatException();
                MutationJsonTree.Text(MutationJsonTree.Required(value, "label"), true);
                MutationJsonTree.Text(MutationJsonTree.Required(value, "createdAt"), true, 128);
                OperationType(MutationJsonTree.Required(value, "operationType"));
            }
        }
        private static void OperationType(MutationJsonNode value)
        {
            var name = MutationJsonTree.Text(value, true, 16);
            if (name != "CREATE" && name != "EDIT" && name != "STATUS" && name != "DELETE") throw new FormatException();
        }
    }
}
