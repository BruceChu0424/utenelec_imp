using System;
using System.Collections.Generic;
using System.Linq;
using System.Net.Http;
using System.Threading;
using System.Threading.Tasks;

namespace Uten.Legacy.Core
{
    public sealed partial class SessionCoordinator
    {
        /// <summary>The owning endpoint is @Transactional(readOnly=true). POST carries only
        /// bounded UUID arrays; it is not a business mutation or a write-journal operation.</summary>
        public Task<string> ReadUnitPlatformValuesAsync(IReadOnlyList<string> recordIds, IReadOnlyList<string> columnIds, CancellationToken ct)
        {
            var records = UnitReadIds(recordIds, 200, false);
            var columns = UnitReadIds(columnIds, 32, true);
            var body = new Dictionary<string, object> { { "recordIds", records }, { "columnIds", columns } };
            return ReadJsonAsync(HttpMethod.Post, "platform-columns/master_unit/values:batch", body, ct, "unit:view");
        }
        private static string[] UnitReadIds(IReadOnlyList<string> values, int maximum, bool nullable)
        {
            if (values == null)
            { if (nullable) return null; throw new ApiException("UNIT_COLUMN_READ_INVALID", "请提供真实单位记录编号列表。"); }
            if (values.Count > maximum) throw new ApiException("UNIT_COLUMN_READ_INVALID", "一次读取的单位或列数量超出审核上限。");
            var result = values.ToArray(); var seen = new HashSet<string>(StringComparer.Ordinal);
            foreach (var value in result)
            {
                Guid id;
                if (value == null || !Guid.TryParseExact(value, "D", out id) || id == Guid.Empty || id.ToString("D") != value || !seen.Add(value))
                    throw new ApiException("UNIT_COLUMN_READ_INVALID", "单位和列必须使用不重复的真实 UUID，不能使用名称或任意路径。");
            }
            return result;
        }
    }
}
