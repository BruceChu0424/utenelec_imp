using System;
using System.Collections.Generic;
using System.Collections.ObjectModel;
using System.Globalization;
using System.Web.Script.Serialization;
using Uten.Legacy.Core;

namespace Uten.Legacy.Desktop.Features.Units
{
    /// <summary>Missing, explicit null and text are distinct wire intents.</summary>
    public sealed class UnitOptionalText
    {
        public static readonly UnitOptionalText Omitted = new UnitOptionalText(false, null);
        public static readonly UnitOptionalText Null = new UnitOptionalText(true, null);
        public bool IsPresent { get; private set; }
        public bool IsNull { get { return IsPresent && Value == null; } }
        public string Value { get; private set; }
        private UnitOptionalText(bool present, string value) { IsPresent = present; Value = value; }
        public static UnitOptionalText Of(string value)
        {
            if (value == null) throw new ArgumentNullException(nameof(value));
            return new UnitOptionalText(true, value);
        }
    }

    public sealed class UnitSaveInput
    {
        public UnitOptionalText Name { get; set; } = UnitOptionalText.Omitted;
        public UnitOptionalText Code { get; set; } = UnitOptionalText.Omitted;
        public UnitOptionalText Status { get; set; } = UnitOptionalText.Omitted;
        public UnitOptionalText MeasurementDimension { get; set; } = UnitOptionalText.Omitted;
        public UnitOptionalText MassUnitCode { get; set; } = UnitOptionalText.Omitted;

        public static UnitSaveInput Daily(string name, string code, string status)
        {
            // Preserve input text. The source server owns trimming/code allocation
            // and weight-name learning. Daily forms never fill hidden rules with null.
            return new UnitSaveInput { Name = Field(name), Code = Field(code), Status = Field(status) };
        }
        private static UnitOptionalText Field(string value) { return value == null ? UnitOptionalText.Null : UnitOptionalText.Of(value); }
        public string ToJson()
        {
            var fields = new Dictionary<string, object>();
            Add(fields, "name", Name); Add(fields, "code", Code); Add(fields, "status", Status);
            Add(fields, "measurementDimension", MeasurementDimension); Add(fields, "massUnitCode", MassUnitCode);
            return new JavaScriptSerializer { MaxJsonLength = 65536 }.Serialize(fields);
        }
        private static void Add(IDictionary<string, object> values, string key, UnitOptionalText value)
        {
            if (value != null && value.IsPresent) values.Add(key, value.Value);
        }
    }

    public sealed class UnitRecord
    {
        public string Id { get; private set; }
        public string Code { get; private set; }
        public string Name { get; private set; }
        public string Status { get; private set; }
        public string LegacyIdText { get; private set; }
        public bool HasMeasurementDimension { get; private set; }
        public bool HasMassUnitCode { get; private set; }
        public string MeasurementDimension { get; private set; }
        public string MassUnitCode { get; private set; }
        public bool SupportsExpectedVersion { get { return false; } }

        internal static UnitRecord Read(Dictionary<string, object> value)
        {
            string id = UnitJson.Text(value, "id");
            Guid parsed;
            if (!Guid.TryParseExact(id, "D", out parsed)) throw new FormatException("单位关系必须使用真实 UUID。");
            object legacy;
            string legacyText = null;
            if (value.TryGetValue("legacyId", out legacy) && legacy != null)
            {
                // The schema is INT, never a business quantity or relationship key.
                // Reject floating-point values rather than round/truncate them.
                if (!(legacy is int || legacy is long)) throw new FormatException("单位历史编号必须是整数。");
                legacyText = Convert.ToInt64(legacy, CultureInfo.InvariantCulture).ToString(CultureInfo.InvariantCulture);
            }
            return new UnitRecord { Id = id, Code = UnitJson.Text(value, "code"), Name = UnitJson.Text(value, "name"),
                Status = UnitJson.Text(value, "status"), LegacyIdText = legacyText,
                HasMeasurementDimension = value.ContainsKey("measurementDimension"), HasMassUnitCode = value.ContainsKey("massUnitCode"),
                MeasurementDimension = UnitJson.Text(value, "measurementDimension"), MassUnitCode = UnitJson.Text(value, "massUnitCode") };
        }
        public static UnitRecord Parse(string json) { return Read(UnitJson.Object(UnitJson.Parse(json))); }
    }

    public sealed class UnitPageResult
    {
        public IReadOnlyList<UnitRecord> Items { get; internal set; }
        public int Page { get; internal set; }
        public int Size { get; internal set; }
        public long TotalElements { get; internal set; }
        public int TotalPages { get; internal set; }
    }

    public sealed class UnitFacetBucket
    {
        public string Value { get; internal set; }
        public long? Count { get; internal set; }
    }
    public sealed class UnitFacetSet
    {
        public IReadOnlyDictionary<string, IReadOnlyList<UnitFacetBucket>> Fields { get; internal set; }
        public IReadOnlyDictionary<string, long?> NullCounts { get; internal set; }
    }

    public sealed class UnitReadOwner
    {
        private readonly SessionCoordinator coordinator;
        public long AuthGeneration { get; private set; }
        public long ReadScopeRevision { get; private set; }
        public string IssuerApiBaseUrl { get; private set; }
        public string UserId { get; private set; }
        public string BusinessDatasetId { get; private set; }
        public long BusinessResetGeneration { get; private set; }
        internal UnitReadOwner(SessionCoordinator session)
        {
            var user = session.CurrentUser;
            if (!session.IsAuthenticated || user == null || session.CurrentEndpoint == null)
                throw new ApiException("UNAUTHORIZED", "请先登录后读取单位资料。", 401);
            coordinator = session; AuthGeneration = session.Generation; ReadScopeRevision = session.ReadScopeRevision;
            IssuerApiBaseUrl = session.CurrentEndpoint.ApiBaseUrl; UserId = user.Id;
            BusinessDatasetId = user.BusinessDatasetId; BusinessResetGeneration = user.BusinessResetGeneration;
        }
        public bool IsCurrent(SessionCoordinator session)
        {
            var user = session.CurrentUser;
            return ReferenceEquals(coordinator, session) && session.IsAuthenticated && user != null
                && session.Generation == AuthGeneration && session.ReadScopeRevision == ReadScopeRevision
                && session.CurrentEndpoint?.ApiBaseUrl == IssuerApiBaseUrl && user.Id == UserId
                && user.BusinessDatasetId == BusinessDatasetId && user.BusinessResetGeneration == BusinessResetGeneration;
        }
        internal bool Matches(MutationOwnerSnapshot owner)
        {
            return owner != null && owner.AuthGeneration == AuthGeneration && owner.ReadScopeRevision == ReadScopeRevision
                && owner.IssuerApiBaseUrl == IssuerApiBaseUrl && owner.UserId == UserId
                && owner.BusinessDatasetId == BusinessDatasetId && owner.BusinessResetGeneration == BusinessResetGeneration;
        }
    }
    public sealed class UnitReadSnapshot<T>
    {
        public T Value { get; private set; }
        public UnitReadOwner Owner { get; private set; }
        public string RequestPath { get; private set; }
        internal UnitReadSnapshot(T value, UnitReadOwner owner, string path) { Value = value; Owner = owner; RequestPath = path; }
        public bool IsCurrent(SessionCoordinator session) { return Owner.IsCurrent(session); }
    }

    internal static class UnitJson
    {
        internal static object Parse(string json)
        {
            return new JavaScriptSerializer { MaxJsonLength = 8388608, RecursionLimit = 64 }.DeserializeObject(json);
        }
        internal static Dictionary<string, object> Object(object value)
        {
            var result = value as Dictionary<string, object>;
            if (result == null) throw new FormatException("单位资料响应格式无效。");
            return result;
        }
        internal static string Text(Dictionary<string, object> value, string key)
        {
            object raw;
            if (!value.TryGetValue(key, out raw) || raw == null) return null;
            if (!(raw is string)) throw new FormatException("单位文字字段类型无效：" + key);
            return (string)raw;
        }
        internal static long Integer(Dictionary<string, object> value, string key, long minimum, long maximum)
        {
            object raw;
            if (!value.TryGetValue(key, out raw) || !(raw is int || raw is long)) throw new FormatException("单位分页/计数字段不是整数：" + key);
            long result = Convert.ToInt64(raw, CultureInfo.InvariantCulture);
            if (result < minimum || result > maximum) throw new FormatException("单位分页/计数字段超出范围：" + key);
            return result;
        }
        internal static IReadOnlyList<UnitRecord> Records(object raw)
        {
            var array = raw as object[];
            if (array == null) throw new FormatException("单位资料行不是数组。");
            var records = new List<UnitRecord>();
            var ids = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            foreach (object entry in array)
            {
                var record = UnitRecord.Read(Object(entry));
                if (!ids.Add(record.Id)) throw new FormatException("单位资料响应包含重复 UUID。");
                records.Add(record);
            }
            return new ReadOnlyCollection<UnitRecord>(records);
        }
    }
}
