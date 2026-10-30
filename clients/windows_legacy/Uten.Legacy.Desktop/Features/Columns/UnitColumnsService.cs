using System;
using System.Collections.Generic;
using System.Collections.ObjectModel;
using System.Linq;
using System.Threading;
using System.Threading.Tasks;
using Uten.Legacy.Core;
using Uten.Legacy.Desktop.Features.Units;

namespace Uten.Legacy.Desktop.Features.Columns
{
    /// <summary>Unit composition over the shared platform-column protocol. No formulas are evaluated locally.</summary>
    public sealed class UnitColumnsService
    {
        private readonly SessionCoordinator session;
        public UnitColumnsService(SessionCoordinator session) { this.session = session ?? throw new ArgumentNullException(nameof(session)); }
        public async Task<UnitColumnsSnapshot> LoadAsync(IReadOnlyList<string> recordIds, CancellationToken ct, UnitColumnsSnapshot previous = null)
        {
            DemandRead(); var owner = new UnitReadOwner(session); var ids = RecordIds(recordIds);
            if (previous != null) Require(previous.Owner);
            var scopeRead = session.GetAsync("/platform-columns/scopes", ct);
            var preferencesRead = session.GetAsync("/auth/me", ct);
            await Task.WhenAll(scopeRead, preferencesRead).ConfigureAwait(false); Require(owner);
            var capabilities = ColumnReadContract.UnitCapabilities(await scopeRead.ConfigureAwait(false));
            bool preferenceConfirmed;
            var serverLayout = ColumnReadContract.Preference(await preferencesRead.ConfigureAwait(false), owner.UserId, out preferenceConfirmed);
            var layout = previous?.Layout ?? serverLayout;
            var observed = new HashSet<string>(previous?.ObservedDefinitionIds ?? new string[0], StringComparer.OrdinalIgnoreCase);
            // Only the previously visible budget is re-verified through current permissions;
            // retained overflow columns refresh through their own authoritative cells below,
            // so legacy data with more than 32 persisted columns cannot fail the page closed.
            var previousVisible = previous == null ? new string[0]
                : previous.Projection.Columns.Select(column => column.PlatformId).Where(id => id != null).ToArray();
            var verifyRoots = layout.AddedIds.Concat(previousVisible).Distinct(StringComparer.OrdinalIgnoreCase).ToArray();
            var definitions = await ReadDefinitionsAsync(verifyRoots, true, owner, ct).ConfigureAwait(false);
            var unavailable = verifyRoots.Where(id => !definitions.ContainsKey(id)).ToList();
            var availableIds = layout.AddedIds.Where(definitions.ContainsKey).ToArray();
            layout = new UnitColumnLayout(layout.Order, layout.Hidden, layout.Pinned, layout.Widths.ToDictionary(pair => pair.Key, pair => pair.Value), availableIds);
            observed.RemoveWhere(id => verifyRoots.Contains(id) && !definitions.ContainsKey(id));
            var beforeRows = layout.ProjectBounded(definitions, observed);
            var selected = beforeRows.Projection.Columns.Where(column => column.PlatformId != null).Select(column => column.PlatformId).ToArray();
            var rows = await ReadRowsAsync(ids, selected, owner, ct).ConfigureAwait(false); Require(owner);
            foreach (var row in rows.Values)
                foreach (var cell in row.Cells.Values)
                {
                    PlatformColumnDefinition old;
                    if (definitions.TryGetValue(cell.ColumnId, out old) && old.Fingerprint != cell.Definition.Fingerprint)
                        throw new ApiException("COLUMN_DEFINITION_CHANGED", "扩展列定义或查看权限在读取时变化，请刷新表头后重试。", 409);
                    definitions[cell.ColumnId] = cell.Definition;
                    if (cell.Persisted) observed.Add(cell.ColumnId);
                }
            var maskedRoots = new HashSet<string>(rows.Values.SelectMany(row => row.Cells.Values).Where(cell => cell.Masked).Select(cell => cell.ColumnId), StringComparer.OrdinalIgnoreCase);
            var closureRoots = layout.AddedIds.Concat(beforeRows.Projection.Columns.Select(column => column.PlatformId)
                .Where(id => id != null && !maskedRoots.Contains(id))).Distinct(StringComparer.OrdinalIgnoreCase);
            var closure = await ReadDefinitionsAsync(closureRoots, false, owner, ct).ConfigureAwait(false);
            foreach (var pair in closure)
            {
                PlatformColumnDefinition prior;
                if (definitions.TryGetValue(pair.Key, out prior) && prior.Fingerprint != pair.Value.Fingerprint)
                    throw new ApiException("COLUMN_DEFINITION_CHANGED", "自设列在依赖验读时发生变化，请重新读取。", 409);
                definitions[pair.Key] = pair.Value;
            }
            // Cell definitions from a complete authorized batch are real server evidence too.
            var outcome = layout.ProjectBounded(definitions, observed); Require(owner); ct.ThrowIfCancellationRequested();
            return Snapshot(owner, layout, outcome.Projection, capabilities, definitions, rows, unavailable, observed, preferenceConfirmed, outcome.OverflowedDefinitionIds);
        }
        /// <summary>For all-result print/export snapshots: preserve exactly the frozen header and its authoritative definitions.</summary>
        public async Task<UnitColumnsSnapshot> LoadRowsAsync(IReadOnlyList<string> recordIds, UnitColumnsSnapshot frozen, CancellationToken ct)
        {
            if (frozen == null) throw new ArgumentNullException(nameof(frozen)); Require(frozen.Owner); var ids = RecordIds(recordIds);
            string[] selected = frozen.Projection.Columns.Where(column => column.PlatformId != null).Select(column => column.PlatformId).ToArray();
            var checkedDefinitions = await ReadDefinitionsAsync(selected, false, frozen.Owner, ct).ConfigureAwait(false);
            foreach (var pair in checkedDefinitions)
            {
                PlatformColumnDefinition original;
                if (!frozen.Definitions.TryGetValue(pair.Key, out original) || original.Fingerprint != pair.Value.Fingerprint)
                    throw new ApiException("COLUMN_DEFINITION_CHANGED", "完整结果读取期间表头定义发生变化，已停止交付，请重新预览。", 409);
            }
            foreach (string id in selected) if (!checkedDefinitions.ContainsKey(id)) throw new FormatException("所选自设列未被权威定义完整覆盖。");
            var rows = await ReadRowsAsync(ids, selected, frozen.Owner, ct).ConfigureAwait(false); Require(frozen.Owner);
            foreach (var row in rows.Values)
                foreach (string id in selected)
                {
                    PlatformColumnCell cell;
                    if (!row.Cells.TryGetValue("platform:" + id, out cell) || cell.Masked || cell.Error != null
                        || cell.Definition.Fingerprint != frozen.Definitions[id].Fingerprint)
                        throw new ApiException("COLUMN_VALUES_UNAVAILABLE", "所选扩展列存在缺失、掩码、读取错误或定义变化，已停止完整结果交付。", 409);
                }
            return Snapshot(frozen.Owner, frozen.Layout, frozen.Projection, frozen.Capabilities,
                frozen.Definitions.ToDictionary(pair => pair.Key, pair => pair.Value, StringComparer.OrdinalIgnoreCase), rows,
                frozen.UnavailableDefinitionIds, frozen.ObservedDefinitionIds, frozen.PreferencesConfirmed, frozen.OverflowedDefinitionIds);
        }
        public async Task<UnitReadSnapshot<IReadOnlyDictionary<string, PlatformColumnDefinition>>> SearchAsync(string query, CancellationToken ct)
        {
            DemandRead(); var owner = new UnitReadOwner(session);
            string json = await session.GetAsync("/platform-columns/master_unit/definitions?q=" + Uri.EscapeDataString(query ?? ""), ct).ConfigureAwait(false);
            Require(owner); var result = ColumnReadContract.Definitions(json); Require(owner);
            return new UnitReadSnapshot<IReadOnlyDictionary<string, PlatformColumnDefinition>>(result, owner, "platform-columns/master_unit/definitions");
        }
        public async Task<UnitReadSnapshot<PlatformColumnDefinition>> DefinitionAsync(string id, CancellationToken ct)
        {
            DemandRead(); var owner = new UnitReadOwner(session); id = ColumnJson.Uuid(id);
            var definitions = await ReadDefinitionsAsync(new[] { id }, false, owner, ct).ConfigureAwait(false); Require(owner);
            PlatformColumnDefinition value;
            if (!definitions.TryGetValue(id, out value)) throw new FormatException("所选自设列未被权威定义覆盖。");
            return new UnitReadSnapshot<PlatformColumnDefinition>(value, owner, "platform-columns/master_unit/definitions?ids=" + id);
        }
        public UnitColumnsSnapshot WithCatalog(UnitColumnsSnapshot current, UnitReadSnapshot<IReadOnlyDictionary<string, PlatformColumnDefinition>> catalog)
        {
            if (current == null || catalog == null) throw new ArgumentNullException(current == null ? nameof(current) : nameof(catalog));
            Require(current.Owner); Require(catalog.Owner);
            var definitions = current.Definitions.ToDictionary(pair => pair.Key, pair => pair.Value, StringComparer.OrdinalIgnoreCase);
            foreach (var pair in catalog.Value)
            {
                PlatformColumnDefinition previous;
                if (definitions.TryGetValue(pair.Key, out previous) && previous.Fingerprint != pair.Value.Fingerprint)
                    throw new ApiException("COLUMN_DEFINITION_CHANGED", "列目录和当前表头证据不一致，请重新读取表头。", 409);
                definitions[pair.Key] = pair.Value;
            }
            return Snapshot(current.Owner, current.Layout, current.Projection, current.Capabilities, definitions, current.Rows,
                current.UnavailableDefinitionIds, current.ObservedDefinitionIds, current.PreferencesConfirmed, current.OverflowedDefinitionIds);
        }
        public async Task<UnitReadSnapshot<PlatformColumnRow>> ReadRowAsync(string recordId, IReadOnlyList<string> columnIds, CancellationToken ct)
        {
            DemandRead(); var owner = new UnitReadOwner(session); recordId = ColumnJson.Uuid(recordId);
            var selected = (columnIds ?? new string[0]).Select(ColumnJson.Uuid).Distinct(StringComparer.OrdinalIgnoreCase).ToArray();
            if (selected.Length > 32) throw new ArgumentException("最多选择32个字段。");
            await ReadDefinitionsAsync(selected, false, owner, ct).ConfigureAwait(false);
            var rows = await ReadRowsAsync(new[] { recordId }, selected, owner, ct).ConfigureAwait(false); Require(owner);
            return new UnitReadSnapshot<PlatformColumnRow>(rows[recordId], owner, "platform-columns/master_unit/values:batch");
        }
        public Task<UnitColumnsSnapshot> PreviewLayoutAsync(UnitColumnLayout layout, UnitColumnsSnapshot current, CancellationToken ct)
        {
            if (layout == null || current == null) throw new ArgumentNullException(layout == null ? nameof(layout) : nameof(current)); Require(current.Owner);
            var staged = Snapshot(current.Owner, layout, current.Projection, current.Capabilities,
                current.Definitions.ToDictionary(pair => pair.Key, pair => pair.Value, StringComparer.OrdinalIgnoreCase), current.Rows,
                current.UnavailableDefinitionIds, current.ObservedDefinitionIds, current.PreferencesConfirmed, current.OverflowedDefinitionIds);
            return LoadAsync(current.Rows.Keys.ToArray(), ct, staged);
        }
        public MutationOwnerSnapshot CaptureWriteOwner(UnitColumnsSnapshot current)
        {
            if (current == null) throw new ArgumentNullException(nameof(current)); Require(current.Owner);
            var owner = session.CaptureMutationOwner();
            if (!current.Owner.Matches(owner)) throw new ApiException("MUTATION_OWNER_CHANGED", "表头与当前提交身份不一致，请重新读取。", 409);
            return owner;
        }
        public MutationRequest PrepareLayout(string requestId, UnitColumnsSnapshot source, UnitColumnLayout layout)
        {
            var owner = CaptureWriteOwner(source);
            if (!source.PreferencesConfirmed) throw new ApiException("PREFERENCES_UNCONFIRMED", "当前尚未读到账号的完整偏好快照，不能覆盖未知表头。请刷新后重试。");
            return session.PrepareMutation(MutationAction.UnitColumnLayoutSave, requestId, layout.ToPreferenceJson(source.Definitions), owner);
        }
        public MutationRequest PrepareDefinitionCreate(string requestId, UnitColumnsSnapshot source, PlatformColumnCreateInput input)
        {
            var owner = CaptureWriteOwner(source);
            if (input == null) throw new ArgumentNullException(nameof(input));
            if (!source.Capabilities.CanDefine || session.CurrentUser?.HasPermission("unit:edit") != true)
                throw new ApiException("FORBIDDEN", "当前没有单位自设列的定义权限。", 403);
            if (input.PriceProtected && !source.Capabilities.PriceVisible) throw new ApiException("FORBIDDEN", "当前没有敏感列的查看权限。", 403);
            if (input.Formula != null)
            {
                var operands = new[] { input.Formula.Base }.Concat(input.Formula.Steps.Select(step => step.Operand));
                foreach (var operand in operands.Where(operand => operand.ColumnId != null))
                {
                    PlatformColumnDefinition definition;
                    if (!source.Definitions.TryGetValue(operand.ColumnId, out definition) || !definition.Numeric)
                        throw new ApiException("COLUMN_DEPENDENCY_UNCONFIRMED", "公式只能使用已经权威验读的同范围数字列和计算列。");
                }
            }
            return session.PrepareMutation(MutationAction.UnitPlatformDefinitionCreate, requestId, input.ToJson(), owner);
        }
        public MutationRequest PrepareDefinitionDelete(string requestId, UnitReadSnapshot<PlatformColumnDefinition> fresh)
        {
            if (fresh == null) throw new ArgumentNullException(nameof(fresh)); Require(fresh.Owner);
            if (!fresh.Value.CanDelete) throw new ApiException("FORBIDDEN", "当前不能删除此自设列；只能删除自己创建且获准修改的列。", 403);
            var owner = session.CaptureMutationOwner(); if (!fresh.Owner.Matches(owner)) throw new ApiException("MUTATION_OWNER_CHANGED", "列定义的提交身份已经变化。");
            return session.PrepareMutation(MutationAction.UnitPlatformDefinitionDelete, requestId, null, owner, fresh.Value.Id);
        }
        public MutationRequest PrepareDefinitionUse(string requestId, UnitReadSnapshot<PlatformColumnDefinition> fresh)
        {
            if (fresh == null) throw new ArgumentNullException(nameof(fresh)); Require(fresh.Owner);
            var owner = session.CaptureMutationOwner(); if (!fresh.Owner.Matches(owner)) throw new ApiException("MUTATION_OWNER_CHANGED", "列定义的使用身份已经变化。");
            return session.PrepareMutation(MutationAction.UnitPlatformDefinitionUse, requestId, null, owner, fresh.Value.Id);
        }
        public MutationRequest PrepareValue(string requestId, UnitColumnsSnapshot source, string recordId, string columnId, string value)
        {
            var owner = CaptureWriteOwner(source); PlatformColumnRow row;
            if (!source.Capabilities.CanWrite || session.CurrentUser?.HasPermission("unit:edit") != true || !source.Rows.TryGetValue(ColumnJson.Uuid(recordId), out row))
                throw new ApiException("FORBIDDEN", "当前不能修改此单位的扩展字段。", 403);
            return session.PrepareMutation(MutationAction.UnitPlatformValuesWrite, requestId, PlatformValueWriteContract.ToJson(row, columnId, value), owner, row.RecordId);
        }
        public Task<MutationResult> SendAsync(MutationRequest request, CancellationToken ct)
        {
            if (request == null || !IsColumnAction(request.Action)) throw new ArgumentException("只能发送已审核的单位列设置和扩展字段操作。", nameof(request));
            return session.MutateAsync(request, ct);
        }
        public static bool IsColumnAction(MutationAction action)
        { return action == MutationAction.UnitColumnLayoutSave || action == MutationAction.UnitPlatformDefinitionCreate || action == MutationAction.UnitPlatformDefinitionDelete
            || action == MutationAction.UnitPlatformDefinitionUse || action == MutationAction.UnitPlatformValuesWrite; }
        private async Task<Dictionary<string, PlatformColumnDefinition>> ReadDefinitionsAsync(IEnumerable<string> requested, bool availableOnly, UnitReadOwner owner, CancellationToken ct)
        {
            var result = new Dictionary<string, PlatformColumnDefinition>(StringComparer.OrdinalIgnoreCase);
            var ids = requested.Select(ColumnJson.Uuid).Distinct(StringComparer.OrdinalIgnoreCase).ToArray();
            if (ids.Length > 160) throw new ArgumentException("当前表头来源超出范围，请先减少自设列。");
            for (int start = 0; start < ids.Length; start += 32)
            {
                Require(owner);
                string path = "/platform-columns/master_unit/definitions?ids=" + String.Join(",", ids.Skip(start).Take(32)) + (availableOnly ? "&availableOnly=true" : "");
                string json = await session.GetAsync(path, ct).ConfigureAwait(false); Require(owner);
                foreach (var pair in ColumnReadContract.Definitions(json))
                {
                    PlatformColumnDefinition previous;
                    if (result.TryGetValue(pair.Key, out previous) && previous.Fingerprint != pair.Value.Fingerprint) throw new FormatException("扩展列依赖在分批读取时变化。");
                    result[pair.Key] = pair.Value;
                }
            }
            return result;
        }
        private async Task<IReadOnlyDictionary<string, PlatformColumnRow>> ReadRowsAsync(string[] ids, string[] selected, UnitReadOwner owner, CancellationToken ct)
        {
            var rows = new Dictionary<string, PlatformColumnRow>(StringComparer.OrdinalIgnoreCase);
            for (int start = 0; start < ids.Length; start += 200)
            {
                var requested = ids.Skip(start).Take(200).ToArray(); Require(owner);
                foreach (var pair in await ReadBatchAsync(requested, selected, owner, ct).ConfigureAwait(false))
                {
                    rows.Add(pair.Key, pair.Value);
                }
            }
            return new ReadOnlyDictionary<string, PlatformColumnRow>(rows);
        }
        private async Task<IReadOnlyDictionary<string, PlatformColumnRow>> ReadBatchAsync(string[] requested, string[] selected, UnitReadOwner owner, CancellationToken ct)
        {
            try
            {
                string json = await session.ReadUnitPlatformValuesAsync(requested, selected, ct).ConfigureAwait(false); Require(owner);
                var rows = ColumnReadContract.Rows(json, requested);
                foreach (var row in rows.Values)
                    foreach (string id in selected) if (!row.Cells.ContainsKey("platform:" + id)) throw new FormatException("所选字段未被完整返回，未发布不完整快照。");
                return rows;
            }
            catch (ApiException error) when (error.Code == "RESPONSE_TOO_LARGE" && requested.Length > 1)
            {
                // The approved POST is a pure read. Reduce the record batch, never weaken the shared byte bound.
                Require(owner); ct.ThrowIfCancellationRequested(); int middle = requested.Length / 2;
                var first = await ReadBatchAsync(requested.Take(middle).ToArray(), selected, owner, ct).ConfigureAwait(false);
                var second = await ReadBatchAsync(requested.Skip(middle).ToArray(), selected, owner, ct).ConfigureAwait(false);
                Require(owner); var complete = first.ToDictionary(pair => pair.Key, pair => pair.Value, StringComparer.OrdinalIgnoreCase);
                foreach (var pair in second) complete.Add(pair.Key, pair.Value);
                return new ReadOnlyDictionary<string, PlatformColumnRow>(complete);
            }
        }
        private static UnitColumnsSnapshot Snapshot(UnitReadOwner owner, UnitColumnLayout layout, UnitColumnProjection projection,
            PlatformColumnCapabilities capabilities, Dictionary<string, PlatformColumnDefinition> definitions, IReadOnlyDictionary<string, PlatformColumnRow> rows,
            IEnumerable<string> unavailable, IEnumerable<string> observed, bool preferencesConfirmed, IEnumerable<string> overflowed = null)
        {
            return new UnitColumnsSnapshot { Owner = owner, Layout = layout, Projection = projection, Capabilities = capabilities,
                Definitions = new ReadOnlyDictionary<string, PlatformColumnDefinition>(definitions), Rows = rows,
                DefinitionFingerprint = ColumnJson.Hash(String.Join("\n", definitions.OrderBy(pair => pair.Key, StringComparer.Ordinal).Select(pair => pair.Key + ":" + pair.Value.Fingerprint))),
                UnavailableDefinitionIds = unavailable.ToList().AsReadOnly(), ObservedDefinitionIds = observed.OrderBy(id => id, StringComparer.Ordinal).ToList().AsReadOnly(),
                OverflowedDefinitionIds = (overflowed ?? Enumerable.Empty<string>()).OrderBy(id => id, StringComparer.Ordinal).ToList().AsReadOnly(),
                PreferencesConfirmed = preferencesConfirmed };
        }
        private static string[] RecordIds(IReadOnlyList<string> recordIds)
        {
            if (recordIds == null) throw new ArgumentNullException(nameof(recordIds));
            var ids = recordIds.Select(ColumnJson.Uuid).ToArray();
            if (ids.Distinct(StringComparer.OrdinalIgnoreCase).Count() != ids.Length) throw new ArgumentException("记录UUID重复。");
            return ids;
        }
        private void DemandRead() { if (session.CurrentUser?.HasPermission("unit:view") != true) throw new ApiException("FORBIDDEN", "当前没有单位列设置的查看权限。", 403); }
        private void Require(UnitReadOwner owner)
        { DemandRead(); if (owner == null || !owner.IsCurrent(session)) throw new ApiException("READ_SCOPE_CHANGED", "列设置的账号、权限或数据范围已变化，请重新打开。", 403); }
    }
}
