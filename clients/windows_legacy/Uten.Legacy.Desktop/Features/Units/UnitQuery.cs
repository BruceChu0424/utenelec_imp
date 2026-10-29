using System;
using System.Collections.Generic;
using System.Collections.ObjectModel;
using System.Globalization;
using System.Text;

namespace Uten.Legacy.Desktop.Features.Units
{
    public sealed class UnitFilter
    {
        public static readonly UnitFilter Null = new UnitFilter(true, null);
        public bool IsNull { get; private set; }
        public string Value { get; private set; }
        private UnitFilter(bool isNull, string value) { IsNull = isNull; Value = value; }
        public static UnitFilter Exact(string value)
        {
            if (value == null) throw new ArgumentNullException(nameof(value));
            return new UnitFilter(false, value);
        }
    }
    public sealed class UnitQuery
    {
        private static readonly string[] AllowedFields = { "code", "name", "status", "dimension" };
        public int Page { get; private set; }
        public int Size { get; private set; }
        public string Keyword { get; private set; }
        public IReadOnlyDictionary<string, UnitFilter> Filters { get; private set; }
        public UnitQuery(int page = 1, int size = 20, string keyword = null, IDictionary<string, UnitFilter> filters = null)
        {
            if (page < 1) throw new ArgumentOutOfRangeException(nameof(page));
            if (size < 1 || size > 100) throw new ArgumentOutOfRangeException(nameof(size));
            Page = page; Size = size; Keyword = keyword;
            var copy = new Dictionary<string, UnitFilter>(StringComparer.Ordinal);
            foreach (var entry in filters ?? new Dictionary<string, UnitFilter>())
            {
                if (Array.IndexOf(AllowedFields, entry.Key) < 0 || entry.Value == null)
                    throw new ArgumentException("单位筛选只允许编号、名称、状态和计量维度。", nameof(filters));
                copy.Add(entry.Key, entry.Value);
            }
            Filters = new ReadOnlyDictionary<string, UnitFilter>(copy);
        }
        public string ToRelativePath()
        {
            var path = new StringBuilder("/master/units?page=").Append(Page.ToString(CultureInfo.InvariantCulture))
                .Append("&size=").Append(Size.ToString(CultureInfo.InvariantCulture));
            if (!String.IsNullOrWhiteSpace(Keyword)) path.Append("&keyword=").Append(Uri.EscapeDataString(Keyword.Trim()));
            foreach (string field in AllowedFields)
            {
                UnitFilter filter;
                if (!Filters.TryGetValue(field, out filter)) continue;
                if (filter.IsNull) path.Append("&nullFields=").Append(field);
                else path.Append('&').Append(field).Append('=').Append(Uri.EscapeDataString(filter.Value));
            }
            return path.ToString();
        }
    }
}
