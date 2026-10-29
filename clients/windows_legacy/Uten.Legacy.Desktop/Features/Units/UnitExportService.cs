using System;
using System.Collections.Generic;
using System.Linq;
using System.Threading;
using System.Threading.Tasks;
using System.Web.Script.Serialization;
using Uten.Legacy.Core;
using Uten.Legacy.Desktop.Features.Columns;

namespace Uten.Legacy.Desktop.Features.Units
{
    public sealed class UnitExportService
    {
        private readonly SessionCoordinator session;
        public UnitExportService(SessionCoordinator session) { this.session = session ?? throw new ArgumentNullException(nameof(session)); }
        public async Task<UnitReadSnapshot<bool>> AvailableAsync(CancellationToken token)
        {
            Demand(); var owner = new UnitReadOwner(session);
            try
            {
                string json = await session.GetAsync("/report-export-jobs/capabilities", token).ConfigureAwait(false);
                Require(owner); var body = UnitJson.Object(UnitJson.Parse(json)); object available;
                if (!body.TryGetValue("available", out available) || !(available is bool)) throw new FormatException("导出任务能力格式无效。");
                return new UnitReadSnapshot<bool>((bool)available, owner, "/report-export-jobs/capabilities");
            }
            catch (ApiException error) when (error.StatusCode == 404 || error.StatusCode == 501)
            { Require(owner); return new UnitReadSnapshot<bool>(false, owner, "/report-export-jobs/capabilities"); }
        }
        public async Task<UnitReadSnapshot<IReadOnlyList<MutationExportJob>>> RecentAsync(CancellationToken token)
        {
            Demand(); var owner = new UnitReadOwner(session);
            string json = await session.GetAsync("/report-export-jobs", token).ConfigureAwait(false); Require(owner);
            var jobs = SessionCoordinator.ParseRecentUnitExportJobs(json); Require(owner);
            return new UnitReadSnapshot<IReadOnlyList<MutationExportJob>>(jobs, owner, "/report-export-jobs");
        }
        public async Task<UnitReadSnapshot<MutationExportJob>> GetAsync(string id, CancellationToken token)
        {
            id = Id(id); Demand(); var owner = new UnitReadOwner(session);
            string json = await session.GetAsync("/report-export-jobs/" + id, token).ConfigureAwait(false); Require(owner);
            var job = SessionCoordinator.ParseUnitExportJob(json, id); Require(owner);
            return new UnitReadSnapshot<MutationExportJob>(job, owner, "/report-export-jobs/" + id);
        }
        public async Task AuthorizeDownloadAsync(string id, UnitReadOwner sourceOwner, CancellationToken token)
        {
            Demand(); Require(sourceOwner); id = Id(id);
            string json = await session.GetAsync("/report-export-jobs/" + id + "/download-authorization", token).ConfigureAwait(false);
            Require(sourceOwner); object authorized;
            if (!UnitJson.Object(UnitJson.Parse(json)).TryGetValue("authorized", out authorized) || !(authorized is bool) || !(bool)authorized)
                throw new ApiException("EXPORT_DOWNLOAD_UNAUTHORIZED", "当前任务尚未获得下载授权。");
        }
        public MutationRequest PrepareSubmit(string localId, string frozenBody, UnitReadOwner owner)
        {
            Demand(); Require(owner); var mutationOwner = session.CaptureMutationOwner();
            if (!owner.Matches(mutationOwner)) throw new ApiException("READ_SCOPE_CHANGED", "原导出条件的读取范围已变化，请重新打开导出。");
            return session.PrepareMutation(MutationAction.UnitExportSubmit, localId, frozenBody, mutationOwner);
        }
        public MutationRequest PrepareCancel(string localId, string jobId, UnitReadOwner owner)
        {
            Demand(); Require(owner); var mutationOwner = session.CaptureMutationOwner();
            if (!owner.Matches(mutationOwner)) throw new ApiException("READ_SCOPE_CHANGED", "原导出任务的读取范围已变化。");
            return session.PrepareMutation(MutationAction.UnitExportCancel, localId, null, mutationOwner, Id(jobId));
        }
        public static string CreateBody(string jobId, UnitQuery query, UnitColumnProjection projection)
        {
            if (query == null) throw new ArgumentNullException(nameof(query)); jobId = Id(jobId);
            var filter = new Dictionary<string, object>();
            if (!String.IsNullOrWhiteSpace(query.Keyword)) filter.Add("keyword", query.Keyword.Trim());
            var nulls = new List<string>();
            foreach (var pair in query.Filters)
            {
                if (pair.Value.IsNull) nulls.Add(pair.Key);
                else filter.Add(pair.Key, pair.Value.Value);
            }
            if (nulls.Count != 0) filter.Add("nullFields", nulls.OrderBy(value => value, StringComparer.Ordinal).ToArray());
            var json = new JavaScriptSerializer { MaxJsonLength = 65536 };
            return json.Serialize(new Dictionary<string, object> {
                ["id"] = jobId, ["domain"] = "master", ["report"] = "unit", ["format"] = "xlsx",
                ["parameters"] = new Dictionary<string, string> { ["filter"] = json.Serialize(filter) },
                ["sort"] = null, ["order"] = null,
                ["columnProjection"] = projection == null ? null : json.DeserializeObject(projection.ToJson()) });
        }
        public static IDictionary<string, string> LegacyParameters(UnitQuery query)
        {
            var values = new Dictionary<string, string>(StringComparer.Ordinal);
            if (!String.IsNullOrWhiteSpace(query.Keyword)) values.Add("keyword", query.Keyword.Trim());
            var nulls = new List<string>();
            foreach (var item in query.Filters) { if (item.Value.IsNull) nulls.Add(item.Key); else values.Add(item.Key, item.Value.Value); }
            if (nulls.Count != 0) values.Add("nullFields", String.Join(",", nulls.OrderBy(value => value, StringComparer.Ordinal)));
            return values;
        }
        private void Demand() { if (session.CurrentUser?.HasPermission("unit:export") != true) throw new ApiException("FORBIDDEN", "当前账号没有单位导出权限。", 403); }
        private void Require(UnitReadOwner owner)
        { Demand(); if (owner == null || !owner.IsCurrent(session)) throw new ApiException("READ_SCOPE_CHANGED", "导出的账号、权限或数据范围已变化。"); }
        private static string Id(string value)
        {
            Guid id;
            if (!Guid.TryParseExact(value, "D", out id) || id == Guid.Empty || id.ToString("D") != value) throw new ArgumentException("需要真实标准任务UUID。");
            return value;
        }
    }
}
