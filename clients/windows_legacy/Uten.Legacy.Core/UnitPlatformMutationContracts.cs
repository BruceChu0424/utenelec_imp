using System;
using System.Collections.Generic;
using System.Linq;

namespace Uten.Legacy.Core
{
    public sealed partial class SessionCoordinator
    {
        internal const string UnitLayoutPreferenceKey = "platform.table.19e439ed14e5af7509dbe9fd5a998194";
        internal static bool IsUnitPlatformMutation(MutationAction action)
        { return (int)action >= 12 && (int)action <= 16; }
        internal static int UnitDraftBudget(MutationAction action)
        { return action == MutationAction.UnitPlatformValuesWrite ? 524288 : action == MutationAction.UnitColumnLayoutSave ? 16384 : 65536; }
        private static MutationRequest BuildUnitPlatformRequest(MutationAction action, string requestId, string body,
            MutationOwnerSnapshot owner, string resourceId, string observedStatus)
        {
            CanonicalCommandId(requestId); if (observedStatus != null) throw InvalidAction();
            Dictionary<string, MutationJsonNode> fields;
            try { fields = ValidateUnitPlatformBody(action, body, false); }
            catch (Exception invalid) when (invalid is FormatException || invalid is ArgumentException || invalid is InvalidOperationException)
            { throw new ApiException("MUTATION_BODY_INVALID", "单位表头或扩展字段不符合审核合同；请保留原输入并核对完整字段、原版本和公式。"); }
            string method, path; var response = MutationResponseKind.Empty; var strategy = MutationVersionStrategy.NotSupported;
            if (action == MutationAction.UnitColumnLayoutSave)
            { if (resourceId != null) throw InvalidAction(); method = "PUT"; path = "user/preferences/" + UnitLayoutPreferenceKey; }
            else if (action == MutationAction.UnitPlatformDefinitionCreate)
            { if (resourceId != null) throw InvalidAction(); method = "POST"; path = "platform-columns/master_unit/definitions"; response = MutationResponseKind.PlatformDefinition; }
            else
            {
                resourceId = CanonicalCommandId(resourceId);
                if (action == MutationAction.UnitPlatformDefinitionDelete) { method = "DELETE"; path = "platform-columns/master_unit/definitions/" + resourceId; }
                else if (action == MutationAction.UnitPlatformDefinitionUse) { method = "POST"; path = "platform-columns/master_unit/definitions/" + resourceId + "/use"; }
                else { method = "PUT"; path = "platform-columns/master_unit/values/" + resourceId; response = MutationResponseKind.PlatformRow; strategy = MutationVersionStrategy.PlatformRowVersion; }
            }
            return new MutationRequest(action, requestId, method, path, resourceId, body, owner, UnitPlatformPermissions(action), strategy, FlatNodes(fields), null)
            { ResponseKind = response };
        }
        private static string[] UnitPlatformPermissions(MutationAction action)
        { return action == MutationAction.UnitColumnLayoutSave || action == MutationAction.UnitPlatformDefinitionUse
            ? new[] { "unit:view" } : new[] { "unit:view", "unit:edit" }; }

        internal static Dictionary<string, MutationJsonNode> ValidateUnitPlatformBody(MutationAction action, string body, bool draft)
        {
            if (action == MutationAction.UnitPlatformDefinitionDelete || action == MutationAction.UnitPlatformDefinitionUse)
            { if (draft || body != null) throw new FormatException(); return new Dictionary<string, MutationJsonNode>(); }
            var budget = action == MutationAction.UnitPlatformValuesWrite ? 524288 : draft ? UnitDraftBudget(action) : 16384;
            var fields = MutationJsonTree.Parse(body, budget, draft || action == MutationAction.UnitPlatformValuesWrite, 4096, false,
                action == MutationAction.UnitColumnLayoutSave).Object;
            if (action == MutationAction.UnitColumnLayoutSave) ValidateLayout(fields, draft);
            else if (action == MutationAction.UnitPlatformDefinitionCreate) ValidateDefinitionInput(fields, draft);
            else if (action == MutationAction.UnitPlatformValuesWrite)
            {
                MutationJsonTree.Keys(fields, "expectedVersion", "cells");
                MutationJsonNode version;
                if (fields.TryGetValue("expectedVersion", out version)) MutationJsonTree.Integer(version, 0, Int64.MaxValue);
                else if (!draft) throw new FormatException();
                MutationJsonNode cells;
                if (!fields.TryGetValue("cells", out cells)) { if (draft) return fields; throw new FormatException(); }
                if (cells.Array.Count > 32) throw new FormatException();
                var seen = new HashSet<string>(StringComparer.Ordinal);
                foreach (var cell in cells.Array)
                {
                    var value = cell.Object; MutationJsonTree.Keys(value, "columnId", "value");
                    var id = MutationJsonTree.Uuid(MutationJsonTree.Required(value, "columnId")); if (!seen.Add(id)) throw new FormatException();
                    var original = MutationJsonTree.Required(value, "value");
                    var text = MutationJsonTree.Text(original, false, draft ? 524288 : 2000);
                    if (!draft && text?.IndexOf('\0') >= 0) throw new FormatException();
                }
            }
            else throw new FormatException();
            return fields;
        }
        private static void ValidateLayout(Dictionary<string, MutationJsonNode> fields, bool draft)
        {
            MutationJsonTree.Keys(fields, "order", "hidden", "pinned", "widths", "added", "sortColumn", "sortAscending", "hasQueryPreferences");
            foreach (var key in new[] { "order", "hidden", "pinned" })
            {
                MutationJsonNode values;
                if (!fields.TryGetValue(key, out values)) { if (draft) continue; throw new FormatException(); }
                if (values.Array.Count > 160) throw new FormatException(); var seen = new HashSet<string>(StringComparer.Ordinal);
                foreach (var item in values.Array)
                {
                    var name = MutationJsonTree.Text(item, true, 128);
                    if (!LayoutKey(name) || !seen.Add(name) || key == "hidden" && (name == "code" || name == "name" || name == "status")) throw new FormatException();
                }
                if (!draft && key == "pinned" && !new[] { "code", "name", "status" }.All(seen.Contains)) throw new FormatException();
            }
            MutationJsonNode widths;
            if (fields.TryGetValue("widths", out widths))
            {
                if (widths.Object.Count > 160) throw new FormatException();
                foreach (var item in widths.Object)
                {
                    if (!LayoutKey(item.Key)) throw new FormatException();
                    if (draft && item.Value.Value is string) { MutationJsonTree.Text(item.Value, false, 120); continue; }
                    if (draft && (item.Value.Value is long || item.Value.Value is MutationJsonNumber)) continue;
                    UnitColumnProjectionContract.PixelWidth(item.Value, 48);
                }
            }
            else if (!draft) throw new FormatException();
            MutationJsonNode added;
            if (fields.TryGetValue("added", out added))
            {
                if (added.Array.Count > 32) throw new FormatException(); var seen = new HashSet<string>(StringComparer.Ordinal);
                foreach (var item in added.Array)
                {
                    var value = item.Object; MutationJsonTree.Keys(value, "id", "scope", "name", "type", "priceProtected", "relationKey");
                    var id = MutationJsonTree.Uuid(MutationJsonTree.Required(value, "id")); if (!seen.Add(id)) throw new FormatException();
                    if (MutationJsonTree.Text(MutationJsonTree.Required(value, "scope"), true) != "master_unit") throw new FormatException();
                    MutationJsonTree.Text(MutationJsonTree.Required(value, "name"), !draft, 80);
                    var type = MutationJsonTree.Text(MutationJsonTree.Required(value, "type"), true, 16); if (type != "TEXT" && type != "NUMBER" && type != "CALCULATED") throw new FormatException();
                    if (!(MutationJsonTree.Required(value, "priceProtected").Value is bool)) throw new FormatException();
                    MutationJsonNode relation; if (value.TryGetValue("relationKey", out relation) && relation.Value != null) throw new FormatException();
                }
            }
            else if (!draft) throw new FormatException();
            MutationJsonNode option;
            if (fields.TryGetValue("sortColumn", out option) && option.Value != null) throw new FormatException();
            if (fields.TryGetValue("sortAscending", out option) && (!(option.Value is bool) || !(bool)option.Value)) throw new FormatException();
            if (fields.TryGetValue("hasQueryPreferences", out option) && (!(option.Value is bool) || (bool)option.Value)) throw new FormatException();
        }
        private static bool LayoutKey(string key) { return key == "code" || key == "name" || key == "status" || UnitColumnProjectionContract.PlatformKey(key); }
        private static void ValidateDefinitionInput(Dictionary<string, MutationJsonNode> fields, bool draft)
        {
            MutationJsonTree.Keys(fields, "name", "type", "priceProtected", "formula", "relationKey");
            MutationJsonNode name, type, protectedPrice, formula, relation;
            if (fields.TryGetValue("name", out name)) MutationJsonTree.Text(name, !draft, draft ? 65536 : 80); else if (!draft) throw new FormatException();
            string kind = null;
            if (fields.TryGetValue("type", out type)) kind = MutationJsonTree.Text(type, !draft, 16); else if (!draft) throw new FormatException();
            if (!draft && kind != "TEXT" && kind != "NUMBER" && kind != "CALCULATED") throw new FormatException();
            if (fields.TryGetValue("priceProtected", out protectedPrice) && protectedPrice.Value != null && !(protectedPrice.Value is bool)) throw new FormatException();
            if (fields.TryGetValue("relationKey", out relation) && relation.Value != null) throw new FormatException();
            var hasFormula = fields.TryGetValue("formula", out formula) && formula.Value != null;
            if (!draft && (kind == "CALCULATED") != hasFormula) throw new FormatException();
            if (hasFormula) ValidateFormula(formula.Object, draft);
        }
        internal static void ValidateFormula(Dictionary<string, MutationJsonNode> value, bool draft)
        {
            MutationJsonTree.Keys(value, "base", "steps"); MutationJsonNode initial, steps;
            if (value.TryGetValue("base", out initial) && initial.Value != null) ValidateOperand(initial.Object, draft); else if (!draft) throw new FormatException();
            if (!value.TryGetValue("steps", out steps) || steps.Value == null) { if (draft) return; throw new FormatException(); }
            if (steps.Array.Count > 16) throw new FormatException();
            foreach (var item in steps.Array)
            {
                var step = item.Object; MutationJsonTree.Keys(step, "operation", "operand");
                var operation = MutationJsonTree.Text(MutationJsonTree.Required(step, "operation"), !draft, 16);
                if (!draft && operation != "ADD" && operation != "SUBTRACT" && operation != "MULTIPLY" && operation != "DIVIDE") throw new FormatException();
                MutationJsonNode operand; if (step.TryGetValue("operand", out operand) && operand.Value != null) ValidateOperand(operand.Object, draft); else if (!draft) throw new FormatException();
            }
        }
        private static void ValidateOperand(Dictionary<string, MutationJsonNode> value, bool draft)
        {
            MutationJsonTree.Keys(value, "columnId", "fact", "constant"); var count = 0;
            foreach (var item in value)
            {
                if (item.Value.Value == null) continue; count++;
                if (item.Key == "columnId") MutationJsonTree.Uuid(item.Value);
                else { MutationJsonTree.Text(item.Value, !draft, 120); if (!draft && item.Key == "fact") throw new FormatException(); }
            }
            if (!draft && count != 1) throw new FormatException();
        }
    }
}
