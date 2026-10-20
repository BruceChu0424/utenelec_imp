package com.uten.imp.common.finance;

import com.uten.imp.common.sql.SqlCatalogLiteral;
import java.util.Map;
import java.util.Locale;

/** Human-readable currency names; legacy numeric identifiers never imply a currency. */
public final class CurrencyDisplayLabel {
    private CurrencyDisplayLabel() {}

    private static final Map<String, String> NAMES = Map.ofEntries(
            Map.entry("CNY", "人民币"), Map.entry("RMB", "人民币"),
            Map.entry("USD", "美金"), Map.entry("HKD", "港币"),
            Map.entry("EUR", "欧元"), Map.entry("JPY", "日元"),
            Map.entry("GBP", "英镑"), Map.entry("SGD", "新加坡元"),
            Map.entry("AUD", "澳元"), Map.entry("CAD", "加元"),
            Map.entry("KRW", "韩元"), Map.entry("RUB", "卢布"), Map.entry("CHF", "瑞士法郎"),
            Map.entry("CHINESE YUAN", "人民币"), Map.entry("RENMINBI", "人民币"),
            Map.entry("US DOLLAR", "美金"), Map.entry("UNITED STATES DOLLAR", "美金"),
            Map.entry("HONG KONG DOLLAR", "港币"), Map.entry("EURO", "欧元"),
            Map.entry("JAPANESE YEN", "日元"), Map.entry("POUND STERLING", "英镑"),
            Map.entry("BRITISH POUND", "英镑"), Map.entry("SINGAPORE DOLLAR", "新加坡元"),
            Map.entry("AUSTRALIAN DOLLAR", "澳元"), Map.entry("CANADIAN DOLLAR", "加元"),
            Map.entry("SOUTH KOREAN WON", "韩元"), Map.entry("RUSSIAN RUBLE", "卢布"),
            Map.entry("SWISS FRANC", "瑞士法郎"));

    public static String of(String name, String code) {
        String readableName = readable(name), readableCode = readable(code);
        if (readableName != null && readableName.codePoints().anyMatch(c -> c >= 0x3400 && c <= 0x9fff)) {
            return readableName;
        }
        for (String value : new String[] {readableName, readableCode}) {
            if (value != null && NAMES.containsKey(value.toUpperCase(Locale.ROOT))) {
                return NAMES.get(value.toUpperCase(Locale.ROOT));
            }
        }
        return readableName == null ? readableCode : readableName;
    }

    /** Compile-time SQL expression, keeping SQL grouping identical to displayed names. */
    public static String sql(String alias) {
        if (!alias.matches("[a-zA-Z_][a-zA-Z_0-9]*")) throw new IllegalArgumentException("currency alias");
        String name = readableSql(alias + ".name"), code = readableSql(alias + ".code");
        return " CASE WHEN (" + name + ") ~ '[㐀-鿿]' THEN " + name + " ELSE COALESCE("
                + knownSql(name) + ", " + knownSql(code) + ", " + name + ", " + code + ") END ";
    }

    private static String knownSql(String value) {
        StringBuilder sql = new StringBuilder("CASE UPPER(" + value + ")");
        NAMES.entrySet().stream().sorted(Map.Entry.comparingByKey()).forEach(entry ->
                sql.append(" WHEN ").append(SqlCatalogLiteral.text(entry.getKey())).append(" THEN ")
                        .append(SqlCatalogLiteral.text(entry.getValue())));
        return sql.append(" ELSE NULL END").toString();
    }

    private static String readable(String value) {
        if (value == null || value.isBlank()) return null;
        value = value.strip();
        return value.equals("—") || value.matches("[0-9]+") ? null : value;
    }

    private static String readableSql(String column) {
        return "CASE WHEN BTRIM(" + column + ") !~ '^[0-9]+$' AND BTRIM(" + column
                + ") <> '—' THEN NULLIF(BTRIM(" + column + "), '') END";
    }
}
