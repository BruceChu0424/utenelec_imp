using System;
using System.Collections;
using System.Collections.Generic;
using System.Collections.ObjectModel;
using System.Globalization;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;
using System.Threading.Tasks;
using System.Web.Script.Serialization;
using Uten.Legacy.Core;

namespace Uten.Legacy.Desktop.Features.Goods
{
    // A read-only adapter for the existing GoodsController and MaterialCategoryController.
    // UUIDs remain relationship keys. Legacy IDs, source values and numeric text are retained.
    public sealed class GoodsReadService
    {
        public const string GoodsViewPermission = "goods:view";
        public const string CategoryViewPermission = "material_category:view";
        private readonly SessionCoordinator session;

        public GoodsReadService(SessionCoordinator session)
        {
            this.session = session ?? throw new ArgumentNullException(nameof(session));
        }

        private void Demand(string permission)
        {
            if (session.CurrentUser == null || !session.CurrentUser.HasPermission(permission))
                throw new UnauthorizedAccessException("当前账号没有此资料的查看权限。");
        }

        public async Task<IReadOnlyList<GoodsCategory>> CategoriesAsync(CancellationToken cancellationToken)
        {
            Demand(CategoryViewPermission);
            string json = await session.GetAsync("/master/material-categories/tree", cancellationToken).ConfigureAwait(false);
            cancellationToken.ThrowIfCancellationRequested();
            return await Task.Run(() => GoodsReadContract.ParseCategories(json), cancellationToken).ConfigureAwait(false);
        }

        public async Task<GoodsPage> ListAsync(string categoryId, string keyword, int page, int size,
            CancellationToken cancellationToken)
        {
            Demand(GoodsViewPermission);
            string json = await session.GetAsync(GoodsReadContract.ListPath(categoryId, keyword, page, size),
                cancellationToken).ConfigureAwait(false);
            cancellationToken.ThrowIfCancellationRequested();
            return await Task.Run(() => GoodsReadContract.ParsePage(json), cancellationToken).ConfigureAwait(false);
        }

        public async Task<GoodsRecord> DetailAsync(string id, CancellationToken cancellationToken)
        {
            Demand(GoodsViewPermission);
            string json = await session.GetAsync(GoodsReadContract.DetailPath(id), cancellationToken).ConfigureAwait(false);
            cancellationToken.ThrowIfCancellationRequested();
            return await Task.Run(() => GoodsReadContract.ParseDetail(json), cancellationToken).ConfigureAwait(false);
        }
    }

    public sealed class GoodsCategory
    {
        public string Id { get; internal set; }
        public string ParentId { get; internal set; }
        public string Code { get; internal set; }
        public string Name { get; internal set; }
        public string LegacyId { get; internal set; }
        public IReadOnlyList<GoodsCategory> Children { get; internal set; }
        public override string ToString() { return string.IsNullOrEmpty(Code) ? Name : Code + "  " + Name; }
    }

    public sealed class GoodsRecord
    {
        private readonly IDictionary<string, object> values;
        internal GoodsRecord(IDictionary<string, object> values)
        {
            this.values = values;
            Id = GoodsReadContract.RequiredId(values, "id");
        }
        public string Id { get; private set; }
        public string Code { get { return Text("code"); } }
        public string Name { get { return Text("name"); } }
        public string Spec { get { return Text("spec"); } }
        public string ColorName { get { return Text("colorName"); } }
        public string UnitName { get { return Text("unitName"); } }
        // The unit relationship key is the authoritative UUID; unitName is the server's
        // resolved display. A missing UUID with a unit name is the read-only legacy
        // snapshot fallback, never promoted to a live reference or a fake key.
        public string UnitId { get { return OptionalUuid("unitId"); } }
        public string UnitLegacyId { get { return OptionalUuid("unitLegacyId"); } }
        public string UnitRelationship
        { get { return UnitId != null ? "UUID 引用" : OptionalText("unitName") != null ? "历史快照回落" : "—"; } }
        public string SourceType { get { return Text("sourceType"); } }
        public string StockQuantity { get { return Text("stockQtyDisplayText", "stockQty"); } }
        public string Price { get { return Flag("priceMasked") ? "—" : Text("priceDisplayText", "price"); } }
        public string Discount { get { return Flag("discountMasked") ? "—" : Text("discountDisplayText", "discount"); } }
        public string LegacyId { get { return Text("legacyId"); } }
        public bool Flag(string name)
        {
            object value;
            return values.TryGetValue(name, out value) && value is bool && (bool)value;
        }
        public string Text(string name, string fallback = null)
        {
            string value = GoodsReadContract.OptionalText(values, name);
            if (value == null && fallback != null) value = GoodsReadContract.OptionalText(values, fallback);
            return value ?? "—";
        }
        private string OptionalUuid(string name)
        {
            object value;
            if (!values.TryGetValue(name, out value) || value == null) return null;
            if (!(value is string)) throw new FormatException("服务端货品单位关系字段类型无效：" + name);
            Guid parsed;
            if (!Guid.TryParse((string)value, out parsed)) throw new FormatException("服务端货品单位关系不是 UUID：" + name);
            return (string)value;
        }
        private string OptionalText(string name) { return GoodsReadContract.OptionalText(values, name); }
    }

    public sealed class GoodsPage
    {
        public IReadOnlyList<GoodsRecord> Items { get; internal set; }
        public int Page { get; internal set; }
        public int Size { get; internal set; }
        public long Total { get; internal set; }
        public int TotalPages { get; internal set; }
        public string ReadScopeVersion { get; internal set; }
    }

    public static class GoodsReadContract
    {
        public static string ListPath(string categoryId, string keyword, int page, int size)
        {
            if (page < 1) throw new ArgumentOutOfRangeException(nameof(page));
            if (size < 1 || size > 100) throw new ArgumentOutOfRangeException(nameof(size));
            var path = new StringBuilder("/master/goods?page=");
            path.Append(page.ToString(CultureInfo.InvariantCulture)).Append("&size=")
                .Append(size.ToString(CultureInfo.InvariantCulture));
            if (!string.IsNullOrWhiteSpace(categoryId))
            {
                Guid parsed;
                if (!Guid.TryParse(categoryId, out parsed)) throw new ArgumentException("分类关系必须是 UUID。", nameof(categoryId));
                path.Append("&categoryId=").Append(Uri.EscapeDataString(categoryId));
            }
            if (!string.IsNullOrWhiteSpace(keyword))
                path.Append("&keyword=").Append(Uri.EscapeDataString(keyword.Trim()));
            // No hidden exclude/status/source/scope filter and no client-side recomputation.
            return path.ToString();
        }

        public static string DetailPath(string id)
        {
            Guid parsed;
            if (!Guid.TryParse(id, out parsed)) throw new ArgumentException("货品关系必须是 UUID。", nameof(id));
            return "/master/goods/" + Uri.EscapeDataString(id);
        }

        public static GoodsPage ParsePage(string json)
        {
            var root = Object(Parse(json));
            var rows = Array(root, "items", true);
            var items = new List<GoodsRecord>();
            foreach (object row in rows) items.Add(new GoodsRecord(Object(row)));
            int page = PositiveInt(root, "page", false);
            int size = PositiveInt(root, "size", false);
            int pages = PositiveInt(root, "totalPages", true);
            long total;
            if (!long.TryParse(OptionalText(root, "total"), NumberStyles.None,
                CultureInfo.InvariantCulture, out total) || total < 0)
                throw new FormatException("货品分页总数无效。");
            return new GoodsPage { Items = new ReadOnlyCollection<GoodsRecord>(items), Page = page,
                Size = size, Total = total, TotalPages = pages, ReadScopeVersion = OptionalText(root, "readScopeVersion") };
        }

        public static GoodsRecord ParseDetail(string json) { return new GoodsRecord(Object(Parse(json))); }

        public static IReadOnlyList<GoodsCategory> ParseCategories(string json)
        {
            var rows = Parse(json) as object[];
            if (rows == null) throw new FormatException("分类树响应不是数组。");
            var seen = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            var result = new List<GoodsCategory>();
            foreach (object item in rows) result.Add(Category(Object(item), seen, 0));
            return new ReadOnlyCollection<GoodsCategory>(result);
        }

        private static GoodsCategory Category(IDictionary<string, object> values, HashSet<string> seen, int depth)
        {
            if (depth > 100) throw new FormatException("分类树层级无效。");
            string id = RequiredId(values, "id");
            if (!seen.Add(id)) throw new FormatException("分类树包含重复关系。");
            var children = new List<GoodsCategory>();
            foreach (object item in Array(values, "children", false)) children.Add(Category(Object(item), seen, depth + 1));
            return new GoodsCategory { Id = id, ParentId = OptionalText(values, "parentId"),
                Code = OptionalText(values, "code") ?? "", Name = OptionalText(values, "name") ?? "",
                LegacyId = OptionalText(values, "legacyId"), Children = new ReadOnlyCollection<GoodsCategory>(children) };
        }

        internal static string RequiredId(IDictionary<string, object> values, string name)
        {
            string id = OptionalText(values, name);
            Guid parsed;
            if (!Guid.TryParse(id, out parsed)) throw new FormatException("服务端返回的货品或分类关系不是 UUID。");
            return id;
        }
        internal static string OptionalText(IDictionary<string, object> values, string name)
        {
            object value;
            if (!values.TryGetValue(name, out value) || value == null) return null;
            if (!(value is string)) throw new FormatException("服务端资料字段类型无效：" + name);
            return (string)value;
        }
        private static IDictionary<string, object> Object(object value)
        {
            var result = value as IDictionary<string, object>;
            if (result == null) throw new FormatException("服务端资料响应不是对象。");
            return result;
        }
        private static object[] Array(IDictionary<string, object> value, string name, bool required)
        {
            object raw;
            if (!value.TryGetValue(name, out raw) || raw == null)
            {
                if (required) throw new FormatException("服务端分页缺少资料行。");
                return new object[0];
            }
            var rows = raw as object[];
            if (rows == null) throw new FormatException("服务端资料行类型无效。");
            return rows;
        }
        private static int PositiveInt(IDictionary<string, object> values, string name, bool allowZero)
        {
            int result;
            if (!int.TryParse(OptionalText(values, name), NumberStyles.None, CultureInfo.InvariantCulture, out result)
                || result < (allowZero ? 0 : 1)) throw new FormatException("服务端分页参数无效：" + name);
            return result;
        }

        private static object Parse(string json)
        {
            if (json == null) throw new ArgumentNullException(nameof(json));
            // Quote number tokens before JavaScriptSerializer sees them: financial/quantity
            // lexemes stay exact strings, including trailing zeroes and numbers beyond double.
            // Only pagination metadata is subsequently parsed as integer; no business arithmetic.
            var text = new StringBuilder(json.Length);
            bool inString = false, escaped = false;
            for (int i = 0; i < json.Length; i++)
            {
                char current = json[i];
                if (inString)
                {
                    text.Append(current);
                    if (escaped) escaped = false;
                    else if (current == '\\') escaped = true;
                    else if (current == '"') inString = false;
                    continue;
                }
                if (current == '"') { inString = true; text.Append(current); continue; }
                if (current == '-' || current >= '0' && current <= '9')
                {
                    int end = i + 1;
                    while (end < json.Length && (json[end] == '-' || json[end] == '+' || json[end] == '.'
                        || json[end] == 'e' || json[end] == 'E' || json[end] >= '0' && json[end] <= '9')) end++;
                    string number = json.Substring(i, end - i);
                    if (!Regex.IsMatch(number, @"\A-?(?:0|[1-9][0-9]*)(?:\.[0-9]+)?(?:[eE][+-]?[0-9]+)?\z", RegexOptions.CultureInvariant))
                        throw new FormatException("服务端数值字段不是有效 JSON 数字。");
                    text.Append('"').Append(number).Append('"');
                    i = end - 1;
                }
                else text.Append(current);
            }
            var serializer = new JavaScriptSerializer { MaxJsonLength = 16 * 1024 * 1024, RecursionLimit = 200 };
            return serializer.DeserializeObject(text.ToString());
        }
    }
}
