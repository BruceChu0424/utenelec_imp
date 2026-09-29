package com.uten.imp.common.text;

import java.text.Normalizer;
import java.util.HashSet;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.Set;
import java.util.regex.Pattern;

/**
 * 客户文件识别与客户货品对照学习共用的文本归一(ADR-134, SPEC §5.4)。
 *
 * <p>纯函数, 无状态; 识别(features/sales/intake)与主档学习(features/master/learning)都只用这里,
 * 迁移 V742 里客户型号种子的 SQL 表达式与 {@link #normalizePart} 逐字等价(有一致性测试)。
 */
public final class IntakeTextNormalizer {

    /** 货品名称前缀里常见的客户/国别标记(后跟可选序号), 比较名称前剥掉。 */
    public static final List<String> OWNER_PREFIXES = List.of(
            "尼日利亚", "伊拉克", "马来西亚", "沙特", "俄罗斯", "乌兹别克", "越南", "哈萨克", "巴林", "孟加拉", "巴基",
            "土耳其", "埃及", "约旦", "智利", "西班牙", "乌克兰", "亚美尼", "夏威夷", "叙利亚", "墨西哥", "吴昊", "宝迪",
            "业电", "群富", "德力西", "通士达", "西顿", "慕朵", "西力", "汉的", "立维腾", "三雄", "品上", "华泰", "亮迪",
            "外贸");

    /** 客户型号常见的前缀变体(剥掉后作次一级候选, 不剥 -0N 后缀)。 */
    public static final List<String> PART_PREFIXES = List.of("Q120-", "F-", "V6", "G-");

    private static final Pattern WHITESPACE = Pattern.compile("\\s+");
    /**
     * 型号归一去掉的空白: Java 的 {@code \s} 再加上 PostgreSQL(glibc)正则 {@code \s} 也算空白、NFKC 又不会换成空格的
     * U+1680/U+2028/U+2029(U+0085 两边都不算), 与迁移 V742 种子表达式逐字一致(一致性测试覆盖)。
     */
    private static final Pattern PART_WHITESPACE = Pattern.compile("[\\s\\u1680\\u2028\\u2029]+");
    /** 只在整个字符串的最末尾({@code \z}); {@code $} 还会匹配结尾换行符之前, 与 SQL 不一致。 */
    private static final Pattern TRAILING_DOT = Pattern.compile("\\.\\z");
    private static final Pattern DESCRIPTION_PUNCT = Pattern.compile("[^\\p{L}\\p{N}\\s+/\\-]");
    /** 前缀后的中文序号(「沙特二」「伊拉克三」); 不剥数字, 否则会吃掉「6M」这类系列号。 */
    private static final Pattern ORDINAL_AFTER_PREFIX = Pattern.compile("^[一二三四五六七八九十]");
    private static final Pattern MODEL_TYPE_PREFIX = Pattern.compile("^\\d{2,3}型");
    private static final Pattern BRACKET_QUALIFIER = Pattern.compile("[（(][^）)]*[）)]");
    private static final Pattern BIGRAM_NOISE = Pattern.compile("[\\s()（）\\[\\]【】,，.。:：;；\\-_/]+");
    private static final Pattern CJK = Pattern.compile("[\\u4e00-\\u9fff]");
    private static final Pattern LATIN = Pattern.compile("[A-Za-z]");

    private IntakeTextNormalizer() {
    }

    /** Unicode NFKC(全角转半角等); null 视为空串。 */
    public static String nfkc(String s) {
        return s == null ? "" : Normalizer.normalize(s, Normalizer.Form.NFKC);
    }

    /**
     * 型号/料号归一: NFKC → 大写 → 去掉全部空白 → 斜杠/连字符统一 → 去掉一个结尾句点。
     * 与 V742 种子 SQL {@code upper(regexp_replace(translate(normalize(x, NFKC), '／－—–', '/---'), '\s+', '', 'g'))} 再去结尾句点等价。
     */
    public static String normalizePart(String s) {
        String out = nfkc(s)
                .replace('／', '/')
                .replace('－', '-')
                .replace('—', '-')
                .replace('–', '-');
        // 逐码点大写, 与 PostgreSQL upper() 一致(不做 ß→SS 这类一变多的特殊映射)。
        out = out.codePoints().map(Character::toUpperCase)
                .collect(StringBuilder::new, StringBuilder::appendCodePoint, StringBuilder::append).toString();
        out = PART_WHITESPACE.matcher(out).replaceAll("");
        return TRAILING_DOT.matcher(out).replaceFirst("");
    }

    /** 英文等描述归一: NFKC → 小写 → 去掉除 + / - 外的标点 → 空白折叠。 */
    public static String normalizeDescription(String s) {
        String out = nfkc(s).toLowerCase(Locale.ROOT);
        out = DESCRIPTION_PUNCT.matcher(out).replaceAll(" ");
        return WHITESPACE.matcher(out).replaceAll(" ").trim();
    }

    /**
     * 中文品名归一: NFKC → 去掉全部空白 → 剥掉客户/国别前缀(及紧跟的序号) → 剥掉给定系列前缀 →
     * 剥掉「86型」之类规格前缀 → 小写。seriesTokens 可为空。
     */
    public static String normalizeCn(String s, Set<String> seriesTokens) {
        String n = WHITESPACE.matcher(nfkc(s)).replaceAll("");
        for (String prefix : OWNER_PREFIXES) {
            if (n.startsWith(prefix)) {
                n = ORDINAL_AFTER_PREFIX.matcher(n.substring(prefix.length())).replaceFirst("");
                break;
            }
        }
        if (seriesTokens != null && !seriesTokens.isEmpty()) {
            String upper = n.toUpperCase(Locale.ROOT);
            String best = null;
            for (String token : seriesTokens) {
                if (token == null || token.isBlank()) continue;
                String t = token.toUpperCase(Locale.ROOT);
                if (upper.startsWith(t) && (best == null || t.length() > best.length())) best = t;
            }
            if (best != null) n = n.substring(best.length());
        }
        n = MODEL_TYPE_PREFIX.matcher(n).replaceFirst("");
        return n.toLowerCase(Locale.ROOT);
    }

    /** 去掉括号里的限定语(例如「(不锈钢)」「（杏色）」)。 */
    public static String stripBracketQualifiers(String s) {
        return BRACKET_QUALIFIER.matcher(s == null ? "" : s).replaceAll("");
    }

    /** 名称开头的客户/国别前缀; 没有则 null。 */
    public static String ownerPrefix(String name) {
        String n = WHITESPACE.matcher(nfkc(name)).replaceAll("");
        for (String prefix : OWNER_PREFIXES) {
            if (!"外贸".equals(prefix) && n.startsWith(prefix)) return prefix;
        }
        return null;
    }

    /**
     * 型号变体: 原值罚分 0; 剥掉 {@link #PART_PREFIXES} 之一罚 -4。入参应已 {@link #normalizePart}。
     * 返回按插入顺序的「变体 → 罚分」。
     */
    public static Map<String, Integer> partVariants(String normalizedPart) {
        Map<String, Integer> out = new LinkedHashMap<>();
        if (normalizedPart == null || normalizedPart.isEmpty()) return out;
        out.put(normalizedPart, 0);
        for (String prefix : PART_PREFIXES) {
            if (normalizedPart.startsWith(prefix) && normalizedPart.length() > prefix.length() + 1) {
                out.putIfAbsent(normalizedPart.substring(prefix.length()), -4);
            }
        }
        return out;
    }

    /** 是否含中日韩汉字。 */
    public static boolean hasCjk(String s) {
        return s != null && CJK.matcher(s).find();
    }

    /** 拉丁字母占字母总数的比例 ≥ 0.7(用于判断一行文字是英文为主)。 */
    public static boolean isLatinDominant(String s) {
        if (s == null) return false;
        int latin = 0;
        int cjk = 0;
        for (int i = 0; i < s.length(); i++) {
            char c = s.charAt(i);
            if ((c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z')) latin++;
            else if (c >= '一' && c <= '鿿') cjk++;
        }
        return latin > 0 && latin >= 0.7 * (latin + cjk);
    }

    /**
     * 一个单元格里中英混排时按行、按文字拆开: 英文为主的行进 latin, 含汉字的行进 cjk。
     * 例如 "Pressure plate\nQ120德式插座压板" → latin="Pressure plate", cjk="Q120德式插座压板"。
     */
    public static ScriptSplit splitByScript(String cell) {
        StringBuilder latin = new StringBuilder();
        StringBuilder cjk = new StringBuilder();
        if (cell != null) {
            for (String raw : cell.split("\\r?\\n")) {
                String line = raw.strip();
                if (line.isEmpty()) continue;
                if (hasCjk(line)) {
                    if (!cjk.isEmpty()) cjk.append(' ');
                    cjk.append(line);
                } else if (LATIN.matcher(line).find()) {
                    if (!latin.isEmpty()) latin.append(' ');
                    latin.append(line);
                }
            }
        }
        return new ScriptSplit(latin.toString(), cjk.toString());
    }

    /** 字符二元组(先去空白与常见标点, 小写)。 */
    public static Set<String> bigrams(String s) {
        String t = BIGRAM_NOISE.matcher(nfkc(s).toLowerCase(Locale.ROOT)).replaceAll("");
        Set<String> out = new HashSet<>();
        for (int i = 0; i + 1 < t.length(); i++) out.add(t.substring(i, i + 2));
        return out;
    }

    /** 二元组 Dice 相似度 0..1(中文名称比较用, 不用 pg_trgm)。任一边少于 1 个二元组返回 0。 */
    public static double bigramDice(String a, String b) {
        Set<String> x = bigrams(a);
        Set<String> y = bigrams(b);
        if (x.isEmpty() || y.isEmpty()) return 0;
        int common = 0;
        for (String g : x) if (y.contains(g)) common++;
        return 2.0 * common / (x.size() + y.size());
    }

    /** {@link #splitByScript} 的结果。 */
    public record ScriptSplit(String latin, String cjk) {
    }
}
