using System;
using System.Collections.Generic;
using System.Collections.ObjectModel;
using System.Threading;
using System.Threading.Tasks;
using System.Web.Script.Serialization;
using Uten.Legacy.Core;

namespace Uten.Legacy.Desktop.Features.Units
{
    public static class UnitReadContract
    {
        public static UnitPageResult ParsePage(string json)
        {
            var value = UnitJson.Object(UnitJson.Parse(json));
            object rows;
            if (!value.TryGetValue("items", out rows)) throw new FormatException("单位分页响应缺少资料行。");
            return new UnitPageResult { Items = UnitJson.Records(rows),
                Page = (int)UnitJson.Integer(value, "page", 1, Int32.MaxValue),
                Size = (int)UnitJson.Integer(value, "size", 1, 100),
                TotalElements = UnitJson.Integer(value, "total", 0, Int64.MaxValue),
                TotalPages = (int)UnitJson.Integer(value, "totalPages", 0, Int32.MaxValue) };
        }
        public static IReadOnlyList<UnitRecord> ParseDictionary(string json) { return UnitJson.Records(UnitJson.Parse(json)); }
        public static UnitFacetSet ParseFacets(string json)
        {
            var value = UnitJson.Object(UnitJson.Parse(json));
            var fields = new Dictionary<string, IReadOnlyList<UnitFacetBucket>>();
            var counts = new Dictionary<string, long?>();
            object rawCounts;
            Dictionary<string, object> nulls = value.TryGetValue("nullCounts", out rawCounts) && rawCounts != null ? UnitJson.Object(rawCounts) : null;
            foreach (string key in new[] { "code", "name", "status", "dimension" })
            {
                var buckets = new List<UnitFacetBucket>();
                object raw;
                if (value.TryGetValue(key, out raw) && raw != null)
                {
                    var entries = raw as object[];
                    if (entries == null) throw new FormatException("单位筛选桶格式无效。");
                    foreach (object entry in entries)
                    {
                        var bucket = UnitJson.Object(entry);
                        string text = UnitJson.Text(bucket, "value");
                        if (text == null) throw new FormatException("单位筛选桶缺少值。");
                        buckets.Add(new UnitFacetBucket { Value = text,
                            Count = bucket.ContainsKey("count") && bucket["count"] != null ? (long?)UnitJson.Integer(bucket, "count", 0, Int64.MaxValue) : null });
                    }
                }
                fields.Add(key, new ReadOnlyCollection<UnitFacetBucket>(buckets));
                counts.Add(key, nulls != null && nulls.ContainsKey(key) && nulls[key] != null ? (long?)UnitJson.Integer(nulls, key, 0, Int64.MaxValue) : null);
            }
            return new UnitFacetSet { Fields = new ReadOnlyDictionary<string, IReadOnlyList<UnitFacetBucket>>(fields),
                NullCounts = new ReadOnlyDictionary<string, long?>(counts) };
        }
        public static string DetailPath(string id)
        {
            Guid parsed;
            if (!Guid.TryParseExact(id, "D", out parsed)) throw new ArgumentException("单位必须以 UUID 查询。", nameof(id));
            return "/master/units/" + Uri.EscapeDataString(id);
        }
    }

    /// <summary>Unit-specific contracts over the single Core transport and mutation coordinator.</summary>
    public sealed class UnitService
    {
        private readonly SessionCoordinator session;
        public UnitService(SessionCoordinator session) { this.session = session ?? throw new ArgumentNullException(nameof(session)); }
        public Task<UnitReadSnapshot<UnitPageResult>> ListAsync(UnitQuery query, CancellationToken cancellationToken)
        {
            if (query == null) throw new ArgumentNullException(nameof(query));
            return ReadAsync(query.ToRelativePath(), UnitReadContract.ParsePage, cancellationToken);
        }
        public Task<UnitReadSnapshot<UnitFacetSet>> FacetsAsync(CancellationToken cancellationToken)
        {
            return ReadAsync("/master/units/facets", UnitReadContract.ParseFacets, cancellationToken);
        }
        public Task<UnitReadSnapshot<UnitRecord>> DetailAsync(string id, CancellationToken cancellationToken)
        {
            return ReadAsync(UnitReadContract.DetailPath(id), UnitRecord.Parse, cancellationToken);
        }
        public Task<UnitReadSnapshot<IReadOnlyList<UnitRecord>>> DictAsync(CancellationToken cancellationToken)
        {
            return ReadAsync("/master/units/dict", UnitReadContract.ParseDictionary, cancellationToken);
        }
        private async Task<UnitReadSnapshot<T>> ReadAsync<T>(string path, Func<string, T> parse, CancellationToken cancellationToken)
        {
            var user = session.CurrentUser;
            if (user == null || !user.HasPermission("unit:view")) throw new ApiException("FORBIDDEN", "当前账号没有单位资料查看权限。", 403);
            var owner = new UnitReadOwner(session);
            cancellationToken.ThrowIfCancellationRequested();
            string json = await session.GetAsync(path, cancellationToken).ConfigureAwait(false);
            RequireCurrent(owner);
            T result = await Task.Run(() => parse(json), cancellationToken).ConfigureAwait(false);
            RequireCurrent(owner); cancellationToken.ThrowIfCancellationRequested();
            return new UnitReadSnapshot<T>(result, owner, path);
        }
        private void RequireCurrent(UnitReadOwner owner)
        {
            if (owner == null || !owner.IsCurrent(session))
                throw new ApiException("READ_SCOPE_CHANGED", "账号、权限或读取范围已变化，请重新读取单位资料。", 403);
        }
        public MutationOwnerSnapshot CaptureWriteOwner() { return session.CaptureMutationOwner(); }

        public MutationRequest PrepareCreate(string requestId, UnitSaveInput input, MutationOwnerSnapshot owner)
        {
            if (input == null) throw new ArgumentNullException(nameof(input));
            return PrepareCreateJson(requestId, input.ToJson(), owner);
        }
        public MutationRequest PrepareCreateJson(string requestId, string frozenBodyJson, MutationOwnerSnapshot owner)
        {
            return session.PrepareMutation(MutationAction.UnitCreate, requestId, frozenBodyJson, owner);
        }
        public MutationRequest PrepareUpdate(string requestId, UnitReadSnapshot<UnitRecord> baseline,
            UnitSaveInput input, MutationOwnerSnapshot owner)
        {
            if (input == null) throw new ArgumentNullException(nameof(input));
            return PrepareUpdateJson(requestId, baseline, input.ToJson(), owner);
        }
        public MutationRequest PrepareUpdateJson(string requestId, UnitReadSnapshot<UnitRecord> baseline,
            string frozenBodyJson, MutationOwnerSnapshot owner)
        {
            if (baseline == null || baseline.Value == null) throw new ArgumentNullException(nameof(baseline));
            RequireCurrent(baseline.Owner);
            if (!baseline.Owner.Matches(owner)) throw new ApiException("MUTATION_OWNER_CHANGED", "编辑详情不属于当前提交身份，请重新打开详情。");
            return session.PrepareMutation(MutationAction.UnitUpdate, requestId, frozenBodyJson, owner,
                baseline.Value.Id, baseline.Value.Status);
        }
        public MutationRequest PrepareStatus(string requestId, string unitId, string status,
            MutationOwnerSnapshot owner, long? ignoredVersion = null)
        {
            var body = new Dictionary<string, object> { ["status"] = status };
            if (ignoredVersion.HasValue) body["version"] = ignoredVersion.Value;
            string json = new JavaScriptSerializer().Serialize(body);
            return session.PrepareMutation(MutationAction.UnitStatus, requestId, json, owner, unitId);
        }
        public Task<MutationResult> SendAsync(MutationRequest request, CancellationToken cancellationToken)
        {
            if (request == null || (request.Action != MutationAction.UnitCreate && request.Action != MutationAction.UnitUpdate && request.Action != MutationAction.UnitStatus))
                throw new ArgumentException("单位服务只发送已注册的真实单位动作。", nameof(request));
            // Core owns durable pre-send gating and outcome recording. This service
            // never retries, changes an outcome, fabricates receipts, or writes its own journal.
            return session.MutateAsync(request, cancellationToken);
        }
        public bool TryReadConfirmedUnit(MutationResult result, out UnitRecord record)
        {
            record = null;
            if (result == null || result.Outcome != MutationOutcome.Confirmed || String.IsNullOrEmpty(result.ResponseJson)) return false;
            var current = session.CurrentUser;
            var owner = result.Request.Owner;
            if (!session.IsAuthenticated || current == null || session.Generation != owner.AuthGeneration
                || session.ReadScopeRevision != owner.ReadScopeRevision || session.CurrentEndpoint?.ApiBaseUrl != owner.IssuerApiBaseUrl
                || current.Id != owner.UserId || current.BusinessDatasetId != owner.BusinessDatasetId || current.BusinessResetGeneration != owner.BusinessResetGeneration) return false;
            try { record = UnitRecord.Parse(result.ResponseJson); return true; }
            catch (FormatException) { return false; }
            catch (ArgumentException) { return false; }
            catch (InvalidOperationException) { return false; }
            // False means a confirmed result needs a fresh read/UI projection.
            // It never authorizes resubmitting the original command.
        }
    }
}
