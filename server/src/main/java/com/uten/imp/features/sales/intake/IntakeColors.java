package com.uten.imp.features.sales.intake;

import com.uten.imp.common.text.IntakeTextNormalizer;

import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.Set;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

/**
 * 客户文件里的颜色解析(SPEC §5.4 颜色、§5.5 颜色调整; 移植自参考实现 sim2 parse_color)。
 *
 * <p>结果用中文颜色词表示, 与货品资料的颜色名称做「包含」比较(「响臻白」含「白」)。
 * 规则: 中文颜色列优先; 英文「主色 + 边框色 BORDER/FRAME」拆成主色与面框色(面框色和货品规格里的「…面框」比较);
 * 英文里认出不止一种主色时不给颜色加减分并要求核对; 都没有时从中文描述括号里的「(杏色)」取。
 */
final class IntakeColors {

    /** 中文颜色词(先长后短; 「香槟」「咖啡」「透明」是多字词)。 */
    static final List<String> CN_COLOR_WORDS = List.of("香槟", "咖啡", "透明", "白", "黑", "灰", "金", "银", "红", "蓝", "绿",
            "黄", "粉", "紫", "杏", "米", "棕");

    /** 英文颜色 → 中文候选(任一包含即算一致)。多词在前, 先匹配先移除, 避免 OFF WHITE 又认成 WHITE。 */
    private static final Map<String, List<String>> EN_TO_CN = new LinkedHashMap<>();

    static {
        EN_TO_CN.put("OFF WHITE", List.of("杏", "米"));
        EN_TO_CN.put("OFF WIHTE", List.of("杏", "米"));
        EN_TO_CN.put("OFF-WHITE", List.of("杏", "米"));
        EN_TO_CN.put("WHITE", List.of("白"));
        EN_TO_CN.put("BLACK", List.of("黑"));
        EN_TO_CN.put("GRAY", List.of("灰"));
        EN_TO_CN.put("GREY", List.of("灰"));
        EN_TO_CN.put("GOLDEN", List.of("金"));
        EN_TO_CN.put("GOLD", List.of("金"));
        EN_TO_CN.put("SILVER", List.of("银"));
        EN_TO_CN.put("CHAMPAGNE", List.of("香槟"));
        EN_TO_CN.put("BROWN", List.of("咖啡", "棕"));
        EN_TO_CN.put("COFFEE", List.of("咖啡", "棕"));
        EN_TO_CN.put("RED", List.of("红"));
        EN_TO_CN.put("BLUE", List.of("蓝"));
        EN_TO_CN.put("GREEN", List.of("绿"));
        EN_TO_CN.put("YELLOW", List.of("黄"));
        EN_TO_CN.put("PINK", List.of("粉"));
        EN_TO_CN.put("PURPLE", List.of("紫"));
        EN_TO_CN.put("IVORY", List.of("杏", "米"));
        EN_TO_CN.put("BEIGE", List.of("杏", "米"));
        EN_TO_CN.put("CREAM", List.of("杏", "米"));
        EN_TO_CN.put("TRANSPARENT", List.of("透明"));
        EN_TO_CN.put("CLEAR", List.of("透明"));
    }

    private static final Pattern COMPOUND = Pattern.compile(
            "^\\s*([A-Z][A-Z \\-]*?)\\s*(?:\\+|/|\\bWITH\\b)\\s*([A-Z][A-Z \\-]*?)\\s*(?:BORDER|FRAME)S?\\s*$");
    private static final Pattern CN_BRACKET_COLOR = Pattern.compile("[\uFF08(]\\s*([\\u4e00-\\u9fff]{1,3}色)\\s*[)\uFF09]");
    private static final Pattern CN_FRAME = Pattern.compile("([\\u4e00-\\u9fff]{1,3})面框");

    private IntakeColors() {
    }

    /**
     * 解析结果。
     *
     * @param main          主色: 每个元素是一组中文候选(一组内任一包含即一致); 为空表示不知道颜色
     * @param frame         面框色中文候选
     * @param ambiguous     英文里认出多种主色(不加减分, 要核对)
     * @param colorAltFound 从中文描述括号里取到的颜色文字(没有颜色列时回填 colorAlt), 可为 null
     */
    record ColorSpec(List<List<String>> main, List<String> frame, boolean ambiguous, String colorAltFound) {

        static final ColorSpec NONE = new ColorSpec(List.of(), List.of(), false, null);

        boolean known() {
            return !main.isEmpty() && !ambiguous;
        }

        /** 结果里的 mainColor: 各组第一个候选用 / 连接; 不知道为 null。 */
        String mainLabel() {
            if (main.isEmpty()) {
                return null;
            }
            List<String> parts = new ArrayList<>();
            for (List<String> group : main) {
                parts.add(group.getFirst());
            }
            return String.join("/", parts);
        }

        String frameLabel() {
            return frame.isEmpty() ? null : String.join("/", frame);
        }

        /** 货品颜色名称是否与主色一致(任一组任一候选被包含)。 */
        boolean matchesMain(String goodsColor) {
            if (goodsColor == null || goodsColor.isBlank()) {
                return false;
            }
            for (List<String> group : main) {
                for (String cn : group) {
                    if (goodsColor.contains(cn)) {
                        return true;
                    }
                }
            }
            return false;
        }

        /** 规格里有「…面框」且与面框色不一致。 */
        boolean frameConflicts(String spec) {
            if (frame.isEmpty() || spec == null || !spec.contains("面框")) {
                return false;
            }
            for (String cn : frame) {
                if (spec.contains(cn)) {
                    return false;
                }
            }
            return true;
        }
    }

    /**
     * @param color         颜色列(英文为主)文字, 可为空
     * @param colorAlt      中文颜色列文字, 可为空
     * @param descriptionAlt 中文描述(没有颜色列时从括号里取颜色), 可为空
     * @param description   英文描述(没有颜色列时从里面认颜色词), 可为空
     * @param hasColorColumn 表格有颜色列(有则不从描述里取)
     */
    static ColorSpec parse(String color, String colorAlt, String descriptionAlt, String description, boolean hasColorColumn) {
        List<List<String>> main = new ArrayList<>();
        List<String> frame = new ArrayList<>();
        boolean ambiguous = false;
        String colorAltFound = null;

        String cnColumn = colorAlt;
        if ((cnColumn == null || cnColumn.isBlank()) && color != null && IntakeTextNormalizer.hasCjk(color)) {
            cnColumn = color;
            color = null;
        }
        if (cnColumn != null && !cnColumn.isBlank()) {
            String cn = IntakeTextNormalizer.nfkc(cnColumn);
            Matcher f = CN_FRAME.matcher(cn);
            if (f.find()) {
                frame.addAll(cnWords(f.group(1)));
                cn = cn.substring(0, f.start()) + cn.substring(f.end());
            }
            for (String word : cnWords(cn)) {
                main.add(List.of(word));
            }
        }
        String en = color == null ? "" : IntakeTextNormalizer.nfkc(color).toUpperCase(Locale.ROOT).strip();
        if (!en.isEmpty()) {
            Matcher m = COMPOUND.matcher(en);
            if (m.matches()) {
                for (List<String> group : enColors(m.group(2))) {
                    for (String cn : group) {
                        if (!frame.contains(cn)) {
                            frame.add(cn);
                        }
                    }
                }
                en = m.group(1);
            }
            if (main.isEmpty()) {
                List<List<String>> groups = enColors(en);
                main.addAll(groups);
                ambiguous = groups.size() > 1;
            }
        }
        if (main.isEmpty() && !hasColorColumn) {
            if (descriptionAlt != null) {
                Matcher b = CN_BRACKET_COLOR.matcher(IntakeTextNormalizer.nfkc(descriptionAlt));
                while (b.find()) {
                    for (String word : cnWords(b.group(1))) {
                        if (main.stream().noneMatch(g -> g.contains(word))) {
                            main.add(List.of(word));
                        }
                    }
                    if (colorAltFound == null) {
                        colorAltFound = b.group(1);
                    }
                }
            }
            if (main.isEmpty() && description != null && !description.isBlank()) {
                List<List<String>> groups = enColors(IntakeTextNormalizer.nfkc(description).toUpperCase(Locale.ROOT));
                main.addAll(groups);
                ambiguous = groups.size() > 1;
            }
        }
        if (main.isEmpty() && frame.isEmpty()) {
            return ColorSpec.NONE;
        }
        return new ColorSpec(List.copyOf(main), List.copyOf(frame), ambiguous, colorAltFound);
    }

    /** 文字里出现的中文颜色词(按词表顺序, 长词优先, 已匹配部分不再参与)。 */
    static List<String> cnWords(String text) {
        Set<String> out = new LinkedHashSet<>();
        String rest = text == null ? "" : text;
        for (String word : CN_COLOR_WORDS) {
            if (rest.contains(word)) {
                out.add(word);
                rest = rest.replace(word, " ");
            }
        }
        return new ArrayList<>(out);
    }

    /** 英文里的颜色词 → 各自的中文候选组(整词匹配, 多词先匹配并移除)。 */
    static List<List<String>> enColors(String upper) {
        List<List<String>> groups = new ArrayList<>();
        String rest = " " + upper.replaceAll("[^A-Z]+", " ") + " ";
        for (Map.Entry<String, List<String>> e : EN_TO_CN.entrySet()) {
            String key = " " + e.getKey().replace('-', ' ') + " ";
            if (rest.contains(key)) {
                if (!groups.contains(e.getValue())) {
                    groups.add(e.getValue());
                }
                rest = rest.replace(key, " ");
            }
        }
        return groups;
    }
}
