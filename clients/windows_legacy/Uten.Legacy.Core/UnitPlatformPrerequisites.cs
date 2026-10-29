using System;
using System.Collections.Generic;
using System.Linq;
using System.Threading;
using System.Threading.Tasks;

namespace Uten.Legacy.Core
{
    public sealed partial class SessionCoordinator
    {
        private async Task ValidateUnitPlatformPrerequisitesAsync(MutationRequest request, CancellationToken ct)
        {
            lock (gate) RequireMutationOwnerLocked(request.Owner);
            try
            {
                if (request.Action == MutationAction.UnitColumnLayoutSave)
                {
                    var json = await GetAsync("auth/me", ct).ConfigureAwait(false);
                    var profile = await Task.Run(() => MutationJsonTree.Parse(json, 2097152, true, 65536, true, true).Object, ct).ConfigureAwait(false);
                    if (MutationJsonTree.Text(MutationJsonTree.Required(profile, "id"), true) != request.Owner.UserId)
                        throw new FormatException();
                    MutationJsonNode session;
                    if (!profile.TryGetValue("session", out session) || session.Value == null || !session.Object.ContainsKey("preferences")
                        || !(session.Object["preferences"].Value is Dictionary<string, MutationJsonNode>))
                        throw new ApiException("PREFERENCES_UNCONFIRMED", "尚未读取当前账号完整偏好快照，不能覆盖未知远端表头。");
                    var body = ValidateUnitPlatformBody(request.Action, request.BodyJson, false);
                    await CheckUnitDefinitionsAsync(body["added"].Array.Select(value => MutationJsonTree.Uuid(value.Object["id"])).ToArray(), false, ct).ConfigureAwait(false);
                }
                else if (request.Action == MutationAction.UnitPlatformValuesWrite)
                {
                    var body = ValidateUnitPlatformBody(request.Action, request.BodyJson, false);
                    var incoming = body["cells"].Array.ToDictionary(value => MutationJsonTree.Uuid(value.Object["columnId"]), value => value.Object["value"], StringComparer.Ordinal);
                    var json = await ReadUnitPlatformValuesAsync(new[] { request.ResourceId }, incoming.Keys.ToArray(), ct).ConfigureAwait(false);
                    var rows = await Task.Run(() => MutationJsonTree.Parse(json, 2097152, true, 65536).Array, ct).ConfigureAwait(false);
                    if (rows.Count != 1) throw new FormatException();
                    var current = UnitPlatformResponse.ReadRow(rows[0].Object);
                    if (current.Id != request.ResourceId) throw new FormatException();
                    if (!current.CanWrite) throw new ApiException("FORBIDDEN", "当前单位的扩展字段只能查看，请重新读取权限。", 403);
                    if (current.Version != (long)body["expectedVersion"].Value)
                        throw new ApiException("PLATFORM_ROW_CHANGED", "整行扩展字段已变化，本次未发送；请重新读取完整字段后核对原输入。", 409);
                    if (current.Cells.Values.Any(value => value.Persisted && value.Masked))
                        throw new ApiException("PLATFORM_HIDDEN_FIELDS_UNVERIFIED", "此行有未完整读取的受保护字段，不能安全保全整行；本次未发送。", 403);
                    if (current.Cells.Values.Any(value => value.Persisted && !incoming.ContainsKey(value.Id)))
                        throw new ApiException("PLATFORM_FIELDS_NOT_PRESERVED", "原行仍有未包含的已保存字段，本次未发送，未丢弃任何隐藏字段。", 409);
                    foreach (var value in incoming)
                    {
                        UnitPlatformCellState actual;
                        if (!current.Cells.TryGetValue(value.Key, out actual)) throw new FormatException();
                        if (actual.Masked || actual.Type == "RELATED" || actual.Type == "CALCULATED" && value.Value.Value != null
                            || actual.Type != "CALCULATED" && actual.Error != null)
                            throw new ApiException("PLATFORM_FIELD_NOT_WRITABLE", "所选字段未被完整核实、只读或属于计算展示，本次未发送。", 403);
                    }
                }
                else
                {
                    if (request.Action == MutationAction.UnitPlatformDefinitionCreate)
                    {
                        var scopes = await GetAsync("platform-columns/scopes", ct).ConfigureAwait(false);
                        var values = MutationJsonTree.Parse(scopes, 2097152, true, 16384).Array;
                        var unit = values.Select(value => value.Object).Where(value => value.ContainsKey("scope") && value["scope"].Value as string == "master_unit").ToList();
                        if (unit.Count != 1 || !unit[0].ContainsKey("canDefine") || !(unit[0]["canDefine"].Value is bool) || !(bool)unit[0]["canDefine"].Value)
                            throw new ApiException("PLATFORM_CAPABILITY_UNCONFIRMED", "当前服务器未确认单位自设列的定义权限，本次未发送。", 403);
                        var body = ValidateUnitPlatformBody(request.Action, request.BodyJson, false);
                        var refs = DefinitionReferences(body).ToArray();
                        var definitions = await CheckUnitDefinitionsAsync(refs, false, ct).ConfigureAwait(false);
                        if (definitions.Values.Any(value => value.Type != "NUMBER" && value.Type != "CALCULATED"))
                            throw new ApiException("PLATFORM_FORMULA_REFERENCE_INVALID", "计算公式只能引用当前范围内已验读的数字列。", 409);
                        MutationJsonNode protectedInput, priceVisible;
                        if ((body.TryGetValue("priceProtected", out protectedInput) && protectedInput.Value is bool && (bool)protectedInput.Value
                            || definitions.Values.Any(value => value.PriceProtected))
                            && (!unit[0].TryGetValue("priceVisible", out priceVisible) || !(priceVisible.Value is bool) || !(bool)priceVisible.Value))
                            throw new ApiException("FORBIDDEN", "当前价格查看权限未被确认，不能定义敏感计算列。", 403);
                    }
                    else
                    {
                        var values = await CheckUnitDefinitionsAsync(new[] { request.ResourceId }, true, ct).ConfigureAwait(false);
                        if (request.Action == MutationAction.UnitPlatformDefinitionDelete && !values[request.ResourceId].CanDelete)
                            throw new ApiException("PLATFORM_DEFINITION_NOT_DELETABLE", "服务器未确认可删除此列；只能删除当前账号有权删除的原定义。", 403);
                    }
                }
            }
            catch (Exception invalid) when (invalid is FormatException || invalid is ArgumentException || invalid is InvalidOperationException)
            { throw new ApiException("PLATFORM_PREREQUISITE_INVALID", "单位字段或偏好前置读取不完整，未发送写入；请保留原输入后重新读取。"); }
            lock (gate) RequireMutationOwnerLocked(request.Owner);
        }
        private async Task<Dictionary<string, UnitPlatformDefinitionState>> CheckUnitDefinitionsAsync(string[] ids, bool availableOnly, CancellationToken ct)
        {
            var result = new Dictionary<string, UnitPlatformDefinitionState>(StringComparer.Ordinal);
            if (ids.Length == 0) return result;
            var json = await GetAsync("platform-columns/master_unit/definitions?ids=" + Uri.EscapeDataString(String.Join(",", ids))
                + (availableOnly ? "&availableOnly=true" : ""), ct).ConfigureAwait(false);
            var values = await Task.Run(() => MutationJsonTree.Parse(json, 2097152, true, 131072).Array, ct).ConfigureAwait(false);
            if (values.Count > 8192) throw new FormatException();
            foreach (var value in values)
            {
                var definition = UnitPlatformResponse.ReadDefinition(value.Object);
                if (result.ContainsKey(definition.Id)) throw new FormatException(); result.Add(definition.Id, definition);
            }
            if (ids.Any(id => !result.ContainsKey(id))) throw new FormatException();
            return result.Where(value => ids.Contains(value.Key, StringComparer.Ordinal)).ToDictionary(value => value.Key, value => value.Value, StringComparer.Ordinal);
        }
        private static IEnumerable<string> DefinitionReferences(Dictionary<string, MutationJsonNode> body)
        {
            MutationJsonNode formula; if (!body.TryGetValue("formula", out formula) || formula.Value == null) return new string[0];
            var operands = new List<MutationJsonNode> { formula.Object["base"] };
            operands.AddRange(formula.Object["steps"].Array.Select(value => value.Object["operand"]));
            return operands.Select(value => value.Object).Where(value => value.ContainsKey("columnId") && value["columnId"].Value != null)
                .Select(value => MutationJsonTree.Uuid(value["columnId"])).Distinct(StringComparer.Ordinal);
        }
    }
    internal sealed class UnitPlatformDefinitionState
    {
        internal string Id, Type;
        internal bool CanDelete, PriceProtected;
    }
    internal sealed class UnitPlatformCellState
    {
        internal string Id, Type, Error;
        internal bool Persisted, Masked;
    }
    internal sealed class UnitPlatformRowState
    {
        internal string Id;
        internal long Version;
        internal bool CanWrite;
        internal Dictionary<string, UnitPlatformCellState> Cells;
    }
    internal static class UnitPlatformResponse
    {
        internal static UnitPlatformDefinitionState ReadDefinition(Dictionary<string, MutationJsonNode> value)
        {
            MutationJsonTree.Keys(value, "id", "scope", "name", "type", "priceProtected", "formula", "usageCount", "personalUsageCount", "relationKey", "canDelete");
            var id = MutationJsonTree.Uuid(MutationJsonTree.Required(value, "id"));
            if (MutationJsonTree.Text(MutationJsonTree.Required(value, "scope"), true) != "master_unit") throw new FormatException();
            MutationJsonTree.Text(MutationJsonTree.Required(value, "name"), true, 80);
            var type = MutationJsonTree.Text(MutationJsonTree.Required(value, "type"), true, 16);
            if (type != "TEXT" && type != "NUMBER" && type != "CALCULATED" && type != "RELATED") throw new FormatException();
            var price = MutationJsonTree.Required(value, "priceProtected"); if (!(price.Value is bool)) throw new FormatException();
            MutationJsonNode node;
            if (value.TryGetValue("formula", out node) && node.Value != null) SessionCoordinator.ValidateFormula(node.Object, false);
            if (value.TryGetValue("relationKey", out node)) MutationJsonTree.Text(node, false, 120);
            foreach (var key in new[] { "usageCount", "personalUsageCount" }) if (value.TryGetValue(key, out node)) MutationJsonTree.Integer(node, 0, Int64.MaxValue);
            var canDelete = value.TryGetValue("canDelete", out node) && node.Value is bool && (bool)node.Value;
            if (value.ContainsKey("canDelete") && !(value["canDelete"].Value is bool)) throw new FormatException();
            return new UnitPlatformDefinitionState { Id = id, Type = type, CanDelete = canDelete, PriceProtected = (bool)price.Value };
        }
        internal static UnitPlatformRowState ReadRow(Dictionary<string, MutationJsonNode> value)
        {
            MutationJsonTree.Keys(value, "recordId", "version", "canWrite", "cells");
            var result = new UnitPlatformRowState { Id = MutationJsonTree.Uuid(MutationJsonTree.Required(value, "recordId")),
                Version = MutationJsonTree.Integer(MutationJsonTree.Required(value, "version"), 0, Int64.MaxValue), Cells = new Dictionary<string, UnitPlatformCellState>(StringComparer.Ordinal) };
            var canWrite = MutationJsonTree.Required(value, "canWrite"); if (!(canWrite.Value is bool)) throw new FormatException(); result.CanWrite = (bool)canWrite.Value;
            var cells = MutationJsonTree.Required(value, "cells").Array; if (cells.Count > 64) throw new FormatException();
            foreach (var item in cells)
            {
                var cell = item.Object; MutationJsonTree.Keys(cell, "columnId", "value", "definition", "masked", "persisted", "error");
                var id = MutationJsonTree.Uuid(MutationJsonTree.Required(cell, "columnId"));
                var definition = ReadDefinition(MutationJsonTree.Required(cell, "definition").Object);
                if (definition.Id != id || result.Cells.ContainsKey(id)) throw new FormatException();
                MutationJsonTree.Text(MutationJsonTree.Required(cell, "value"), false, 2097152);
                var masked = MutationJsonTree.Required(cell, "masked"); var persisted = MutationJsonTree.Required(cell, "persisted");
                if (!(masked.Value is bool) || !(persisted.Value is bool)) throw new FormatException();
                MutationJsonNode error; var message = cell.TryGetValue("error", out error) ? MutationJsonTree.Text(error, false, 16384) : null;
                result.Cells.Add(id, new UnitPlatformCellState { Id = id, Type = definition.Type, Masked = (bool)masked.Value, Persisted = (bool)persisted.Value, Error = message });
            }
            return result;
        }
    }
}
