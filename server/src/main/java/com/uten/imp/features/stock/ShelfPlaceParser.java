package com.uten.imp.features.stock;

import java.util.regex.Matcher;
import java.util.regex.Pattern;

/**
 * 库位号「库行-层-位」三段解析（货架目视化清单，2026-09-10）。
 *
 * <p>规则（Java 与 SQL 同一口径，{@link #SQL_PATTERN} 与 {@link #PATTERN} 必须等价）：
 * <ul>
 *   <li>先 BTRIM；形如 {@code [字母]*数字-数字-数字}（如 {@code A31-3-1}、{@code 30-1-2}）才算已分层；</li>
 *   <li>库行 = 第一段原样（字母+数字，不改大小写）；层/位 = 第二、三段十进制整数，各 1~6 位
 *       （防 {@code ::int} 溢出，实物货架不可能超过 6 位）；</li>
 *   <li>其余任何值（老库残值 {@code '19'}/{@code 'Y12'}、两段式 {@code 'A30-1'}、四段式、超长数字）
 *       一律 {@code parsed=false}，库行为空串、层/位为 null，前端归入「未分层」桶。</li>
 * </ul>
 */
public final class ShelfPlaceParser {

    /** PostgreSQL {@code ~} 正则（不含长度上限；长度上限在 SQL 里用 length() 另加，避免 {} 进 JDBC）。 */
    public static final String SQL_PATTERN = "^[A-Za-z]*[0-9]+-[0-9]+-[0-9]+$";

    /** 层/位段最大位数（SQL 侧同样用 length(split_part(...)) <= 6 守）。 */
    public static final int MAX_DIGITS = 6;

    private static final Pattern PATTERN =
            Pattern.compile("^([A-Za-z]*[0-9]+)-([0-9]{1," + MAX_DIGITS + "})-([0-9]{1," + MAX_DIGITS + "})$");

    private ShelfPlaceParser() {
    }

    /** 解析结果：parsed=false 时 rack 为空串、level/slot 为 null。 */
    public record ShelfPlace(String rack, Integer level, Integer slot, boolean parsed) {
        static final ShelfPlace UNPARSED = new ShelfPlace("", null, null, false);
    }

    public static ShelfPlace parse(String place) {
        if (place == null) {
            return ShelfPlace.UNPARSED;
        }
        String trimmed = place.trim();
        if (trimmed.isEmpty()) {
            return ShelfPlace.UNPARSED;
        }
        Matcher m = PATTERN.matcher(trimmed);
        if (!m.matches()) {
            return ShelfPlace.UNPARSED;
        }
        return new ShelfPlace(m.group(1), Integer.valueOf(m.group(2)), Integer.valueOf(m.group(3)), true);
    }
}
