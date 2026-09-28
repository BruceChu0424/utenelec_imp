package com.uten.imp.features.sales.intake;

import com.uten.imp.common.files.document.DocumentGrid;
import com.uten.imp.common.files.document.DocumentGrid.Cell;
import com.uten.imp.common.files.document.DocumentGrid.Row;
import com.uten.imp.common.files.document.DocumentGrid.Sheet;
import com.uten.imp.common.text.IntakeTextNormalizer;

import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.security.NoSuchAlgorithmException;
import java.util.ArrayList;
import java.util.EnumMap;
import java.util.HexFormat;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.Set;
import java.util.TreeMap;
import java.util.regex.Pattern;

/**
 * 用固定规则找明细表的表头与各列含义(SPEC §5.2 第 2 步)。纯函数, 不访问数据库。
 *
 * <p>关键词表: 英文不分大小写、按整词匹配; 中文按子串匹配; 表头单元格先整体匹配, 再按换行与「/」拆开逐段匹配,
 * 取最长的那个关键词。表头行 = 前 150 行里认出的不同角色最多(≥ 3)且含数量列、含型号或品名列的那一行。
 * 同一角色出现两列时(品名/颜色常见中英各一列), 按数据是英文为主还是中文为主分成主列与中文列。
 */
final class IntakeLayoutDetector {

    static final int SCAN_ROWS = 150;
    static final int MIN_HEADER_SCORE = 3;
    private static final int DATA_PROBE_ROWS = 30;

    /** 关键词 → 角色(英文小写)。 */
    private static final Map<String, ColumnRole> KEYWORDS = new LinkedHashMap<>();

    static {
        put(ColumnRole.LINE_NO, "s/n", "sl. no", "sl.no", "sl no", "s. no", "s.no", "sr. no", "sr no", "no.", "no", "item#",
                "item #", "#", "序号", "项次");
        put(ColumnRole.PART_NO, "item no", "item no.", "item code", "part no", "part no.", "part number", "model", "model no",
                "model no.", "model number", "art no", "art. no", "article no", "article number", "ref", "ref.", "code",
                "product code", "型号", "货号", "零配件编号", "产品编号", "编号", "规格型号", "产品型号");
        put(ColumnRole.DESCRIPTION, "description", "descriptions", "part description", "item description",
                "product description", "goods description", "item", "product", "product name", "goods", "name",
                "commodity", "品名", "描述", "名称", "产品名称", "零件名称", "货品名称", "商品名称", "品名规格");
        put(ColumnRole.SERIES, "series", "系列");
        put(ColumnRole.COLOR, "color", "colour", "colors", "colours", "颜色", "顏色");
        put(ColumnRole.QTY, "qty", "qty.", "q'ty", "quantity", "order qty", "qty(pcs)", "total qty", "pcs", "数量",
                "订货数量", "订单数量");
        put(ColumnRole.UNIT, "unit", "units", "uom", "单位");
        put(ColumnRole.UNIT_PRICE, "price", "unit price", "u/price", "u. price", "exw price", "exw-work price",
                "ex-work price", "exw work price", "fob price", "cif price", "cfr price", "单价", "价格", "含税单价");
        put(ColumnRole.AMOUNT, "amount", "total amount", "total", "total price", "total value", "value", "sub total",
                "subtotal", "金额", "总价", "总金额", "合计金额");
        put(ColumnRole.PCS_PER_CTN, "pcs/ctn", "qty/ctn", "pcs/carton", "pcs per carton", "装箱数", "每箱数量");
        put(ColumnRole.CTN, "ctn", "ctns", "carton", "cartons", "箱数", "件数");
        put(ColumnRole.REMARK, "remark", "remarks", "note", "notes", "备注");
        put(ColumnRole.IGNORED, "packing", "package", "g.w.", "n.w.", "t.g.w.", "t.n.w.", "g.w", "n.w", "gw", "nw",
                "gross weight", "net weight", "cbm", "volume", "size", "measurement", "meas", "picture", "photo", "image",
                "pic", "图片", "零件图", "产品图", "毛重", "净重", "体积", "尺寸", "包装", "外箱尺寸");
    }

    private static final Pattern HAS_LETTER_OR_CJK = Pattern.compile("[A-Za-z\\u4e00-\\u9fff]");
    private static final Pattern WHITESPACE = Pattern.compile("\\s+");

    private IntakeLayoutDetector() {
    }

    private static void put(ColumnRole role, String... words) {
        for (String w : words) {
            KEYWORDS.put(w, role);
        }
    }

    /** 一个表头单元格识别结果。 */
    record RoleHit(ColumnRole role, int length) {
    }

    /** 表头单元格 → 角色(取最长关键词); 不认识返回 null。 */
    static RoleHit classify(String cellText) {
        if (cellText == null || cellText.isBlank()) {
            return null;
        }
        String full = normalizeHeader(cellText);
        RoleHit best = matchLongest(full);
        for (String part : full.split("[\\n/]")) {
            String p = part.strip();
            if (p.isEmpty() || p.equals(full)) {
                continue;
            }
            RoleHit hit = matchLongest(p);
            if (hit != null && (best == null || hit.length() > best.length())) {
                best = hit;
            }
        }
        return best;
    }

    private static RoleHit matchLongest(String text) {
        RoleHit best = null;
        for (Map.Entry<String, ColumnRole> e : KEYWORDS.entrySet()) {
            String k = e.getKey();
            if (k.length() <= (best == null ? 0 : best.length())) {
                continue;
            }
            if (containsKeyword(text, k)) {
                best = new RoleHit(e.getValue(), k.length());
            }
        }
        return best;
    }

    /** 英文按整词(前后不是字母数字)包含; 中文按子串包含。 */
    static boolean containsKeyword(String text, String keyword) {
        if (IntakeTextNormalizer.hasCjk(keyword)) {
            return text.contains(keyword);
        }
        int from = 0;
        while (true) {
            int i = text.indexOf(keyword, from);
            if (i < 0) {
                return false;
            }
            int end = i + keyword.length();
            boolean startOk = i == 0 || !Character.isLetterOrDigit(text.charAt(i - 1))
                    || !Character.isLetterOrDigit(keyword.charAt(0));
            boolean endOk = end >= text.length() || !Character.isLetter(text.charAt(end))
                    || !Character.isLetterOrDigit(keyword.charAt(keyword.length() - 1));
            if (startOk && endOk) {
                return true;
            }
            from = i + 1;
        }
    }

    /** 表头文字规范化: NFKC、小写、行内空白合并(保留换行)、去掉结尾冒号。 */
    static String normalizeHeader(String text) {
        String t = IntakeTextNormalizer.nfkc(text).toLowerCase(Locale.ROOT).replace('\r', '\n');
        StringBuilder sb = new StringBuilder();
        for (String line : t.split("\n")) {
            String l = WHITESPACE.matcher(line).replaceAll(" ").strip();
            if (l.endsWith(":")) {
                l = l.substring(0, l.length() - 1).strip();
            }
            if (!l.isEmpty()) {
                if (!sb.isEmpty()) {
                    sb.append('\n');
                }
                sb.append(l);
            }
        }
        return sb.toString();
    }

    /** 一行的角色识别(列号 → 命中)。 */
    static Map<Integer, RoleHit> classifyRow(Row row) {
        Map<Integer, RoleHit> out = new TreeMap<>();
        for (Cell cell : row.cells()) {
            if (cell.kind() != DocumentGrid.CellKind.TEXT || !HAS_LETTER_OR_CJK.matcher(cell.text()).find()) {
                continue;
            }
            if (cell.text().length() > 60) {
                continue;
            }
            RoleHit hit = classify(cell.text());
            if (hit != null) {
                out.put(cell.col0(), hit);
            }
        }
        return out;
    }

    private static int score(Map<Integer, RoleHit> hits) {
        return (int) hits.values().stream().map(RoleHit::role).filter(r -> r != ColumnRole.IGNORED).distinct().count();
    }

    private static boolean qualifies(Map<Integer, RoleHit> hits) {
        boolean qty = false;
        boolean partOrDesc = false;
        for (RoleHit h : hits.values()) {
            qty |= h.role() == ColumnRole.QTY;
            partOrDesc |= h.role() == ColumnRole.PART_NO || h.role() == ColumnRole.DESCRIPTION;
        }
        return qty && partOrDesc && score(hits) >= MIN_HEADER_SCORE;
    }

    /** 规则找表头; 找不到返回 null。 */
    static IntakeLayout detect(Sheet sheet) {
        Row bestRow = null;
        Map<Integer, RoleHit> bestHits = null;
        int bestScore = -1;
        int limit = firstRowIndex(sheet) + SCAN_ROWS;
        for (Row row : sheet.rows()) {
            if (row.index0() > limit) {
                break;
            }
            Map<Integer, RoleHit> hits = classifyRow(row);
            if (!qualifies(hits)) {
                continue;
            }
            int s = score(hits);
            if (s > bestScore) {
                bestScore = s;
                bestRow = row;
                bestHits = hits;
            }
        }
        if (bestRow == null) {
            return null;
        }
        Map<Integer, RoleHit> merged = new TreeMap<>(bestHits);
        int span = 1;
        Row next = sheet.row(bestRow.index0() + 1);
        if (next != null) {
            Map<Integer, RoleHit> nextHits = classifyRow(next);
            if (nextHits.size() >= 2 && !looksLikeData(next, bestHits)) {
                span = 2;
                for (Map.Entry<Integer, RoleHit> e : nextHits.entrySet()) {
                    merged.putIfAbsent(e.getKey(), e.getValue());
                }
            }
        }
        Map<Integer, ColumnRole> roles = new TreeMap<>();
        for (Map.Entry<Integer, RoleHit> e : merged.entrySet()) {
            roles.put(e.getKey(), e.getValue().role());
        }
        int headerRow0 = bestRow.index0();
        roles = resolveDuplicates(sheet, headerRow0 + span, roles);
        String headerTexts = headerTexts(sheet, headerRow0, span);
        return new IntakeLayout(headerRow0, span, roles, headerTexts, fingerprint(headerTexts), IntakeLayout.SOURCE_RULES,
                currencyOf(sheet, headerRow0, span, roles), headerUnit(sheet, headerRow0, span, roles), score(merged));
    }

    /** 用已知的列角色(学习到的或 AI 给的)组装版式。 */
    static IntakeLayout withRoles(Sheet sheet, int headerRow0, int span, Map<Integer, ColumnRole> roles, String source) {
        String headerTexts = headerTexts(sheet, headerRow0, span);
        Map<Integer, ColumnRole> resolved = resolveDuplicates(sheet, headerRow0 + span, roles);
        int s = (int) resolved.values().stream().filter(r -> r != ColumnRole.IGNORED).distinct().count();
        return new IntakeLayout(headerRow0, span, resolved, headerTexts, fingerprint(headerTexts), source,
                currencyOf(sheet, headerRow0, span, resolved), headerUnit(sheet, headerRow0, span, resolved), s);
    }

    /** 版式是否可用: 有数量列, 且有型号或品名列。 */
    static boolean usable(Map<Integer, ColumnRole> roles) {
        boolean qty = roles.containsValue(ColumnRole.QTY);
        boolean partOrDesc = roles.containsValue(ColumnRole.PART_NO) || roles.containsValue(ColumnRole.DESCRIPTION)
                || roles.containsValue(ColumnRole.DESCRIPTION_ALT);
        return qty && partOrDesc;
    }

    private static int firstRowIndex(Sheet sheet) {
        return sheet.rows().isEmpty() ? 0 : sheet.rows().getFirst().index0();
    }

    private static boolean looksLikeData(Row row, Map<Integer, RoleHit> headerHits) {
        for (Map.Entry<Integer, RoleHit> e : headerHits.entrySet()) {
            if (e.getValue().role() == ColumnRole.QTY) {
                Cell c = row.cell(e.getKey());
                if (c != null && IntakeNumbers.positive(IntakeNumbers.of(c))) {
                    return true;
                }
            }
        }
        return false;
    }

    /**
     * 同一角色多列: 品名/颜色按数据文字分成主列(英文为主)与中文列; 其他角色保留最左一列(数量优先表头写了 pcs 的列),
     * 其余标 IGNORED。
     */
    static Map<Integer, ColumnRole> resolveDuplicates(Sheet sheet, int firstDataRow0, Map<Integer, ColumnRole> roles) {
        Map<ColumnRole, List<Integer>> byRole = new EnumMap<>(ColumnRole.class);
        for (Map.Entry<Integer, ColumnRole> e : roles.entrySet()) {
            byRole.computeIfAbsent(e.getValue(), k -> new ArrayList<>()).add(e.getKey());
        }
        Map<Integer, ColumnRole> out = new TreeMap<>(roles);
        splitByScript(sheet, firstDataRow0, byRole, out, ColumnRole.DESCRIPTION, ColumnRole.DESCRIPTION_ALT);
        splitByScript(sheet, firstDataRow0, byRole, out, ColumnRole.COLOR, ColumnRole.COLOR_ALT);
        for (Map.Entry<ColumnRole, List<Integer>> e : byRole.entrySet()) {
            ColumnRole role = e.getKey();
            List<Integer> cols = e.getValue();
            if (cols.size() < 2 || role == ColumnRole.IGNORED || role == ColumnRole.DESCRIPTION
                    || role == ColumnRole.COLOR || role == ColumnRole.DESCRIPTION_ALT || role == ColumnRole.COLOR_ALT) {
                continue;
            }
            int keep = cols.getFirst();
            for (int c : cols) {
                if (!out.containsKey(c) || out.get(c) != role) {
                    continue;
                }
                if (numericShare(sheet, firstDataRow0, c) > numericShare(sheet, firstDataRow0, keep)
                        && (role == ColumnRole.QTY || role == ColumnRole.UNIT_PRICE || role == ColumnRole.AMOUNT)) {
                    keep = c;
                }
            }
            for (int c : cols) {
                if (c != keep && out.get(c) == role) {
                    out.put(c, ColumnRole.IGNORED);
                }
            }
        }
        return out;
    }

    private static void splitByScript(Sheet sheet, int firstDataRow0, Map<ColumnRole, List<Integer>> byRole,
                                      Map<Integer, ColumnRole> out, ColumnRole main, ColumnRole alt) {
        List<Integer> cols = new ArrayList<>();
        cols.addAll(byRole.getOrDefault(main, List.of()));
        cols.addAll(byRole.getOrDefault(alt, List.of()));
        if (cols.size() < 2) {
            return;
        }
        cols.sort(Integer::compare);
        Integer latinCol = null;
        Integer cjkCol = null;
        for (int c : cols) {
            double latin = latinShare(sheet, firstDataRow0, c);
            if (latin >= 0.5 && latinCol == null) {
                latinCol = c;
            } else if (latin < 0.5 && cjkCol == null) {
                cjkCol = c;
            }
        }
        for (int c : cols) {
            if (latinCol != null && c == latinCol) {
                out.put(c, main);
            } else if (cjkCol != null && c == cjkCol) {
                out.put(c, latinCol == null ? main : alt);
            } else {
                out.put(c, ColumnRole.IGNORED);
            }
        }
        if (latinCol == null && cjkCol != null) {
            // 两列都是中文: 第一列当主列, 第二列当中文列。
            final int mainCol = cjkCol;
            int second = cols.stream().filter(c -> c != mainCol).findFirst().orElse(-1);
            if (second >= 0) {
                out.put(second, alt);
            }
        }
    }

    /** 数据行里该列文字以英文为主的比例(没有文字返回 0)。 */
    static double latinShare(Sheet sheet, int firstDataRow0, int col) {
        int latin = 0;
        int total = 0;
        for (Row row : sheet.rows()) {
            if (row.index0() < firstDataRow0) {
                continue;
            }
            if (row.index0() >= firstDataRow0 + DATA_PROBE_ROWS) {
                break;
            }
            Cell c = row.cell(col);
            if (c == null || c.text().isBlank()) {
                continue;
            }
            total++;
            if (!IntakeTextNormalizer.hasCjk(c.text()) || IntakeTextNormalizer.isLatinDominant(c.text())) {
                latin++;
            }
        }
        return total == 0 ? 0 : (double) latin / total;
    }

    private static double numericShare(Sheet sheet, int firstDataRow0, int col) {
        int numeric = 0;
        int total = 0;
        for (Row row : sheet.rows()) {
            if (row.index0() < firstDataRow0) {
                continue;
            }
            if (row.index0() >= firstDataRow0 + DATA_PROBE_ROWS) {
                break;
            }
            Cell c = row.cell(col);
            if (c == null || c.text().isBlank()) {
                continue;
            }
            total++;
            if (IntakeNumbers.of(c) != null) {
                numeric++;
            }
        }
        return total == 0 ? 0 : (double) numeric / total;
    }

    /** 指纹原文: 每个表头行一行, 行内「列字母=规范化文字」用 | 连接。 */
    static String headerTexts(Sheet sheet, int headerRow0, int span) {
        StringBuilder sb = new StringBuilder();
        for (int r = headerRow0; r < headerRow0 + span; r++) {
            if (r > headerRow0) {
                sb.append('\n');
            }
            Row row = sheet.row(r);
            if (row == null) {
                continue;
            }
            List<String> parts = new ArrayList<>();
            for (Cell cell : row.cells()) {
                String t = normalizeHeader(cell.text()).replace('\n', ' ');
                if (!t.isEmpty()) {
                    parts.add(DocumentGrid.columnLetter(cell.col0()) + "=" + t);
                }
            }
            sb.append(String.join("|", parts));
        }
        return sb.toString();
    }

    /** SHA-256 小写十六进制。 */
    static String fingerprint(String headerTexts) {
        try {
            MessageDigest md = MessageDigest.getInstance("SHA-256");
            return HexFormat.of().formatHex(md.digest(headerTexts.getBytes(StandardCharsets.UTF_8)));
        } catch (NoSuchAlgorithmException e) {
            throw new IllegalStateException(e);
        }
    }

    /** 可能是表头的行(前 150 行里至少 2 个文字格)与其单行、两行指纹, 用于查学习到的版式。 */
    static List<FingerprintProbe> fingerprintProbes(Sheet sheet) {
        List<FingerprintProbe> out = new ArrayList<>();
        int limit = firstRowIndex(sheet) + SCAN_ROWS;
        for (Row row : sheet.rows()) {
            if (row.index0() > limit) {
                break;
            }
            long textCells = row.cells().stream()
                    .filter(c -> c.kind() == DocumentGrid.CellKind.TEXT && HAS_LETTER_OR_CJK.matcher(c.text()).find())
                    .count();
            if (textCells < 2) {
                continue;
            }
            for (int span = 1; span <= 2; span++) {
                String texts = headerTexts(sheet, row.index0(), span);
                out.add(new FingerprintProbe(row.index0(), span, fingerprint(texts)));
            }
        }
        return out;
    }

    /** 学习版式查询探针。 */
    record FingerprintProbe(int headerRow0, int span, String fingerprint) {
    }

    /** 单价/金额列表头里写明的币种。 */
    static String currencyOf(Sheet sheet, int headerRow0, int span, Map<Integer, ColumnRole> roles) {
        for (Map.Entry<Integer, ColumnRole> e : roles.entrySet()) {
            if (e.getValue() != ColumnRole.UNIT_PRICE && e.getValue() != ColumnRole.AMOUNT) {
                continue;
            }
            for (int r = headerRow0; r < headerRow0 + span; r++) {
                String c = currencyOf(sheet.text(r, e.getKey()));
                if (c != null) {
                    return c;
                }
            }
        }
        return null;
    }

    /** 文字里的币种标记 → CNY/USD/EUR/HKD; 没有返回 null。 */
    static String currencyOf(String text) {
        if (text == null || text.isBlank()) {
            return null;
        }
        String t = IntakeTextNormalizer.nfkc(text).toUpperCase(Locale.ROOT);
        if (t.contains("HKD") || t.contains("HK$") || t.contains("港币") || t.contains("港元")) {
            return "HKD";
        }
        if (t.contains("USD") || t.contains("US$") || t.contains("美元") || t.contains("美金") || t.contains("$")) {
            return "USD";
        }
        if (t.contains("EUR") || t.contains("€") || t.contains("欧元")) {
            return "EUR";
        }
        if (t.contains("RMB") || t.contains("CNY") || t.contains("¥") || t.contains("人民币")
                || Pattern.compile("(^|[^A-Z])元").matcher(t).find()) {
            return "CNY";
        }
        return null;
    }

    private static final Pattern UNIT_IN_PARENS = Pattern.compile("\\(\\s*(pcs|pc|piece|pieces|ctn|ctns|carton|cartons|set|sets|"
            + "box|boxes|pair|pairs|个|只|件|箱|套|盒)\\s*\\)");

    /** 数量列表头括号里的单位(order qty(pcs) → pcs)。 */
    static String headerUnit(Sheet sheet, int headerRow0, int span, Map<Integer, ColumnRole> roles) {
        for (Map.Entry<Integer, ColumnRole> e : roles.entrySet()) {
            if (e.getValue() != ColumnRole.QTY) {
                continue;
            }
            for (int r = headerRow0; r < headerRow0 + span; r++) {
                var m = UNIT_IN_PARENS.matcher(normalizeHeader(sheet.text(r, e.getKey())));
                if (m.find()) {
                    return m.group(1);
                }
            }
        }
        return null;
    }

    /** 学习/AI 给出的「列字母 → 角色名」转列号映射; 非法项忽略。 */
    static Map<Integer, ColumnRole> rolesFromLetters(Map<String, ?> byLetter) {
        Map<Integer, ColumnRole> out = new TreeMap<>();
        if (byLetter == null) {
            return out;
        }
        for (Map.Entry<String, ?> e : byLetter.entrySet()) {
            int col = DocumentGrid.columnIndex(e.getKey() == null ? null : e.getKey().strip());
            ColumnRole role = e.getValue() == null ? null : ColumnRole.parse(e.getValue().toString());
            if (col >= 0 && role != null) {
                out.put(col, role);
            }
        }
        return out;
    }

    /** 角色名集合(结果与测试用)。 */
    static Set<String> roleNames(Map<Integer, ColumnRole> roles) {
        Set<String> out = new java.util.TreeSet<>();
        roles.values().forEach(r -> out.add(r.name()));
        return out;
    }
}
