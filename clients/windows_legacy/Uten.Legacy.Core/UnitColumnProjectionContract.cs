using System;
using System.Collections.Generic;
using System.Globalization;

namespace Uten.Legacy.Core
{
    internal static class UnitColumnProjectionContract
    {
        internal static void Validate(MutationJsonNode projection)
        {
            if (projection == null || projection.Value == null) return;
            var root = projection.Object; MutationJsonTree.Keys(root, "tableKey", "scope", "columns");
            if (MutationJsonTree.Text(MutationJsonTree.Required(root, "tableKey"), true) != "master.unit"
                || MutationJsonTree.Text(MutationJsonTree.Required(root, "scope"), true) != "master_unit") throw new FormatException();
            var columns = MutationJsonTree.Required(root, "columns").Array;
            if (columns.Count < 3 || columns.Count > 35) throw new FormatException();
            var seen = new HashSet<string>(StringComparer.Ordinal); var required = new[] { "code", "name", "status" };
            for (var index = 0; index < columns.Count; index++)
            {
                var column = columns[index].Object; MutationJsonTree.Keys(column, "key", "label", "width", "type", "definition");
                var key = MutationJsonTree.Text(MutationJsonTree.Required(column, "key"), true, 128);
                if (!seen.Add(key) || (index < 3 && key != required[index])) throw new FormatException();
                if (index >= 3 && !PlatformKey(key)) throw new FormatException();
                MutationJsonTree.Text(MutationJsonTree.Required(column, "label"), true, 200);
                var type = MutationJsonTree.Text(MutationJsonTree.Required(column, "type"), true, 20);
                if (type != "text" && type != "number") throw new FormatException();
                MutationJsonNode width;
                if (column.TryGetValue("width", out width) && width.Value != null) PixelWidth(width, 1);
                MutationJsonNode definition;
                // Native sends descriptive keys only. Authority remains in fresh server definitions.
                if (column.TryGetValue("definition", out definition) && definition.Value != null) throw new FormatException();
            }
        }
        internal static bool Equivalent(MutationJsonNode left, MutationJsonNode right)
        {
            if (left == null || left.Value == null) return right == null || right.Value == null;
            if (right == null || right.Value == null) return false;
            Validate(left); Validate(right);
            var a = left.Object["columns"].Array; var b = right.Object["columns"].Array;
            if (a.Count != b.Count) return false;
            for (var index = 0; index < a.Count; index++)
            {
                var ac = a[index].Object; var bc = b[index].Object;
                foreach (var key in new[] { "key", "label", "type" }) if (!Object.Equals(ac[key].Value, bc[key].Value)) return false;
                MutationJsonNode aw, bw; ac.TryGetValue("width", out aw); bc.TryGetValue("width", out bw);
                if (aw == null || aw.Value == null) { if (bw != null && bw.Value != null) return false; }
                else if (bw == null || bw.Value == null || PixelWidth(aw, 1) != PixelWidth(bw, 1)) return false;
            }
            return true;
        }
        internal static bool PlatformKey(string value)
        {
            Guid id;
            return value != null && value.StartsWith("platform:", StringComparison.Ordinal) && Guid.TryParseExact(value.Substring(9), "D", out id)
                && id != Guid.Empty && value == "platform:" + id.ToString("D");
        }
        internal static double PixelWidth(MutationJsonNode value, double minimum)
        {
            // This conversion is restricted to visual pixel widths. Business numbers and
            // formula/cell values never call this method and remain original string lexemes.
            double pixels;
            if (!(value.Value is long) && !(value.Value is MutationJsonNumber)) throw new FormatException();
            if (!Double.TryParse(value.Raw, NumberStyles.Float, CultureInfo.InvariantCulture, out pixels)
                || Double.IsNaN(pixels) || Double.IsInfinity(pixels) || pixels < minimum || pixels > 2000) throw new FormatException();
            return pixels;
        }
    }
}
