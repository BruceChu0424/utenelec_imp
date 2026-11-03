using System;
using System.Collections.Generic;
using System.Globalization;
using System.Text.RegularExpressions;
using System.Windows;
using System.Windows.Data;
using System.Windows.Media;

namespace Uten.Legacy.Desktop.Shared
{
    /// <summary>Readable currency master data and stable category roles. Numeric legacy codes
    /// remain identity/history; they never imply a currency or an amount conversion.</summary>
    public static class CurrencyDisplay
    {
        private static readonly IDictionary<string, string> KnownNames = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase)
        {
            ["CNY"] = "人民币", ["RMB"] = "人民币", ["USD"] = "美金", ["HKD"] = "港币",
            ["EUR"] = "欧元", ["JPY"] = "日元", ["GBP"] = "英镑", ["SGD"] = "新加坡元",
            ["AUD"] = "澳元", ["CAD"] = "加元", ["KRW"] = "韩元", ["RUB"] = "卢布", ["CHF"] = "瑞士法郎",
            ["CHINESE YUAN"] = "人民币", ["RENMINBI"] = "人民币", ["US DOLLAR"] = "美金",
            ["UNITED STATES DOLLAR"] = "美金", ["HONG KONG DOLLAR"] = "港币", ["EURO"] = "欧元",
            ["JAPANESE YEN"] = "日元", ["POUND STERLING"] = "英镑", ["BRITISH POUND"] = "英镑",
            ["SINGAPORE DOLLAR"] = "新加坡元", ["AUSTRALIAN DOLLAR"] = "澳元", ["CANADIAN DOLLAR"] = "加元",
            ["SOUTH KOREAN WON"] = "韩元", ["RUSSIAN RUBLE"] = "卢布", ["SWISS FRANC"] = "瑞士法郎"
        };
        private static string Readable(string value)
        {
            value = value?.Trim();
            return string.IsNullOrEmpty(value) || value == "—" || Regex.IsMatch(value, @"^\d+$") ? null : value;
        }
        public static string Label(string name, string code)
        {
            string masterName = Readable(name), currencyCode = Readable(code), known;
            if (masterName != null && Regex.IsMatch(masterName, @"[\u3400-\u9fff]")) return masterName;
            if (masterName != null && KnownNames.TryGetValue(masterName, out known)) return known;
            if (currencyCode != null && KnownNames.TryGetValue(currencyCode, out known)) return known;
            return masterName ?? currencyCode;
        }
        public static string ColorRole(string name, string code)
        {
            switch (Label(name, code))
            {
                case "人民币": return "Cny";
                case "美金": case "美元": return "Usd";
                case "港币": case "港元": return "Hkd";
                case "欧元": return "Eur";
                case "日元": case "日圆": return "Jpy";
                case "英镑": return "Gbp";
                case "新加坡元": case "新币": return "Sgd";
                case "澳元": case "澳币": return "Aud";
                case "加元": case "加拿大元": return "Cad";
                case "韩元": case "韩币": return "Krw";
                case "卢布": return "Rub";
                case "瑞士法郎": return "Chf";
                default: return "Other";
            }
        }
    }

    internal sealed class CurrencyBrushConverter : IValueConverter
    {
        public object Convert(object value, Type targetType, object parameter, CultureInfo culture)
        {
            return Application.Current.FindResource("Uten.Currency." + (value as string ?? "Other")) as Brush;
        }
        public object ConvertBack(object value, Type targetType, object parameter, CultureInfo culture)
        { throw new NotSupportedException(); }
    }
}
