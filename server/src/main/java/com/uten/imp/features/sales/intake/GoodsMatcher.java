package com.uten.imp.features.sales.intake;

import com.uten.imp.application.port.MasterIntakeLookupPort.AliasKind;
import com.uten.imp.application.port.MasterIntakeLookupPort.AliasRow;
import com.uten.imp.application.port.MasterIntakeLookupPort.AliasScope;
import com.uten.imp.application.port.MasterIntakeLookupPort.ClientGoodsHistory;
import com.uten.imp.application.port.MasterIntakeLookupPort.GoodsRow;
import com.uten.imp.common.text.IntakeTextNormalizer;

import java.math.BigDecimal;
import java.time.LocalDate;
import java.util.ArrayList;
import java.util.Collection;
import java.util.Comparator;
import java.util.EnumSet;
import java.util.HashMap;
import java.util.HashSet;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.Set;
import java.util.UUID;

/**
 * 货品匹配打分(SPEC §5.5; 移植参考实现 {@code .local-tmp/ai-intake/reference/sim2.py} 的加法证据模型)。
 *
 * <p>纯计算(只用 int/double, 不做任何金额舍入), 输入是已经召回的候选货品池。每个候选先取最强的一项基础分
 * (对照 99/92/90、型号一致 80、去前缀后一致 76、同系列只差一个字符 70、名称一致 85、去括号后一致 78、名称结尾一致 80、
 * 名称相似 40+45×相似度、英文名一致 88/80、英文名相似 40+40×相似度), 再累加调整
 * (系列 +10/+2/−20、颜色 +8/−25、面框 −10、型号与名称都对上 +10、买过 +6(+3)、本客户专用 +4 / 他人专用 −10、
 * 单价等于标价 +4、折扣异常 −10、品名对照 +6、短中文名只作 +5 佐证)。
 * 自动对应(MATCHED)必须同时满足: 最高 ≥ 90、比第二名高 ≥ 8、有型号/对照/唯一名称这类确切证据、没有系列颜色冲突、
 * 没有同名兄弟货品、不是组合件、对照不含糊; 无系列且同型号同颜色跨多个系列时, 只有近 24 个月客户只买过其中一个才自动对应。
 */
final class GoodsMatcher {

    /** 货品名称前常见的系列前缀(比较名称前剥掉; 数据里量最大的几个系列)。 */
    static final Set<String> COMMON_SERIES_TOKENS = Set.of("Q120", "V5", "V7", "Z9", "6M");
    static final int TOP_K = 8;
    static final int SHORT_CJK_CHARS = 6;
    private static final int BIGRAM_TOP = 12;
    private static final int NAME_EN_TOP = 12;
    private static final double BIGRAM_MIN = 0.5;
    private static final double NAME_EN_MIN = 0.4;
    static final double MATCH_MIN = 90;
    static final double MATCH_MARGIN = 8;
    static final double REVIEW_MIN = 60;
    static final double ALIAS_AUTHORITATIVE_SCORE = 99;
    static final double NON_ALIAS_CAP_WHEN_AUTHORITATIVE = 89;
    static final int REPORT_CAP_ALIAS = 99;
    static final int REPORT_CAP_OTHER = 95;
    static final int RECENT_MONTHS_FOR_SERIES = 24;

    private GoodsMatcher() {
    }

    /** 证据与调整项(结果里翻成中文理由)。 */
    enum Evidence {
        ALIAS_AUTHORITATIVE, ALIAS, ALIAS_GLOBAL, MODEL, MODEL_VARIANT, MODEL_ONE_EDIT, CODE, NAME_EXACT, NAME_APPROX,
        NAME_SUFFIX, NAME_BIGRAM, NAME_EN_EXACT, NAME_EN_SIMILAR, SERIES_MATCH, SERIES_NEAR, SERIES_CONFLICT, COLOR_MATCH,
        COLOR_CONFLICT, FRAME_CONFLICT, MODEL_AND_NAME, NAME_SHORT_AGREES, DESCRIPTION_ALIAS, BOUGHT_BEFORE, OWN_PREFIX,
        OTHER_CUSTOMER, PRICE_MATCH, DISCOUNT_ODD, ASSEMBLED_PART, BUNDLE, AI_PICK
    }

    private static final Set<Evidence> EXACT_EVIDENCE = EnumSet.of(Evidence.ALIAS_AUTHORITATIVE, Evidence.ALIAS,
            Evidence.ALIAS_GLOBAL, Evidence.MODEL, Evidence.MODEL_VARIANT, Evidence.CODE, Evidence.NAME_EXACT,
            Evidence.NAME_EN_EXACT);
    private static final Set<Evidence> ALIAS_EVIDENCE = EnumSet.of(Evidence.ALIAS_AUTHORITATIVE, Evidence.ALIAS,
            Evidence.ALIAS_GLOBAL);

    /** 匹配用的一行输入。 */
    record LineInput(String key, String partNo, String firstPartNorm, String fullPartNorm, String seriesNorm,
                     IntakeColors.ColorSpec colors, String cjkText, String latinNorm, String descriptionNorm,
                     String descriptionAltNorm, String contextNorm, double customerPrice, boolean bundle,
                     boolean assembled) {

        static LineInput of(ExtractedLine line) {
            String cjk = line.matchDescription();
            if (cjk == null && line.description() != null && IntakeTextNormalizer.hasCjk(line.description())) {
                cjk = line.description();
            }
            String latin = line.description() == null ? "" : IntakeTextNormalizer.normalizeDescription(line.description());
            String altNorm = line.descriptionAlt() == null ? "" : IntakeTextNormalizer.normalizeDescription(line.descriptionAlt());
            BigDecimal price = line.customerUnitPrice();
            return new LineInput(line.key(), line.partNo() == null ? "" : line.partNo().strip(), line.firstPartNorm(),
                    line.partNorm(), line.seriesNorm(), line.colors(), cjk, latin, latin, altNorm, line.contextNorm(),
                    price == null || price.signum() <= 0 ? Double.NaN : price.doubleValue(), line.bundle(),
                    line.assembled());
        }
    }

    /**
     * 客户上下文; 不知道客户(先不看客户的第一轮)用 {@link #NONE}。
     *
     * @param history     近若干年该客户买过的货品(订单数、最近日期)
     * @param recentSince 「近 24 个月」起始日(同型号多系列判定用)
     */
    record ClientContext(UUID clientId, String name, String placeId, Map<UUID, ClientGoodsHistory> history,
                         LocalDate recentSince) {

        static final ClientContext NONE = new ClientContext(null, "", "", Map.of(), null);

        ClientContext {
            name = name == null ? "" : name;
            placeId = placeId == null ? "" : placeId;
            history = history == null ? Map.of() : history;
        }

        int orderCount(UUID goodsId) {
            ClientGoodsHistory h = goodsId == null ? null : history.get(goodsId);
            return h == null ? 0 : h.orderCount();
        }

        boolean boughtRecently(UUID goodsId) {
            ClientGoodsHistory h = goodsId == null ? null : history.get(goodsId);
            if (h == null) {
                return false;
            }
            return recentSince == null || h.lastOrderDate() == null || !h.lastOrderDate().isBefore(recentSince);
        }
    }

    /**
     * 单价证据用的汇率: 文件币种是外币且财务维护了参考汇率时同时试 1 和汇率。
     */
    record PriceContext(boolean foreign, double rate) {

        static final PriceContext BASE = new PriceContext(false, 0);

        double[] rates() {
            return foreign && rate > 0 ? new double[]{1, rate} : new double[]{1};
        }
    }

    /** 一个候选及其得分。 */
    static final class Scored {
        final GoodsRow goods;
        double base = Double.NEGATIVE_INFINITY;
        double raw;
        final EnumSet<Evidence> evidence = EnumSet.noneOf(Evidence.class);
        int historyCount;
        double bigram;

        Scored(GoodsRow goods) {
            this.goods = goods;
        }

        void add(double baseScore, Evidence why) {
            if (baseScore > base) {
                base = baseScore;
            }
            evidence.add(why);
        }

        boolean isAlias() {
            return evidence.stream().anyMatch(ALIAS_EVIDENCE::contains);
        }

        boolean hasExactEvidence() {
            return evidence.stream().anyMatch(EXACT_EVIDENCE::contains);
        }

        boolean hasConflict() {
            return evidence.contains(Evidence.SERIES_CONFLICT) || evidence.contains(Evidence.COLOR_CONFLICT)
                    || evidence.contains(Evidence.FRAME_CONFLICT);
        }

        boolean hasModelEvidence() {
            return evidence.contains(Evidence.MODEL) || evidence.contains(Evidence.MODEL_VARIANT)
                    || evidence.contains(Evidence.MODEL_ONE_EDIT);
        }

        /** 界面显示的分数(0-99): 对照最高 99, 其他最高 95。 */
        int reportedScore() {
            int cap = isAlias() ? REPORT_CAP_ALIAS : REPORT_CAP_OTHER;
            return (int) Math.max(0, Math.min(cap, Math.round(raw)));
        }
    }

    /** 一行的对照命中汇总。 */
    record AliasHits(boolean exactContextAmbiguous, boolean globalConflict) {
    }

    /**
     * 一行的打分结果。
     *
     * @param ranked         全部候选(分数从高到低)
     * @param aliasAmbiguous 同一叫法的对照指向多个货品(要核对)
     */
    record Scoring(List<Scored> ranked, boolean aliasAmbiguous) {
    }

    /**
     * 给一行打分, 返回全部候选(按分数从高到低)。
     *
     * @param pool    候选货品池(本任务召回的所有货品 + 客户买过的货品)
     * @param aliases 这一行相关的对照(按型号/品名规范化后查出)
     */
    static Scoring score(LineInput line, Collection<GoodsRow> pool, ClientContext client, List<AliasRow> aliases,
                         PriceContext price) {
        Map<UUID, Scored> cands = new LinkedHashMap<>();
        Map<UUID, GoodsRow> poolById = new LinkedHashMap<>();
        for (GoodsRow g : pool) {
            poolById.putIfAbsent(g.id(), g);
        }
        // 型号一致 / 去前缀后一致(两边都试剥前缀)
        if (!line.firstPartNorm().isEmpty()) {
            Map<String, Integer> lineVariants = IntakeTextNormalizer.partVariants(line.firstPartNorm());
            for (GoodsRow g : poolById.values()) {
                if (g.model() == null || g.model().isBlank()) {
                    continue;
                }
                Map<String, Integer> goodsVariants = IntakeTextNormalizer.partVariants(IntakeTextNormalizer.normalizePart(g.model()));
                for (Map.Entry<String, Integer> v : lineVariants.entrySet()) {
                    Integer pen2 = goodsVariants.get(v.getKey());
                    if (pen2 != null) {
                        int pen = v.getValue() + pen2;
                        cand(cands, g).add(80 + pen, pen == 0 ? Evidence.MODEL : Evidence.MODEL_VARIANT);
                    }
                }
            }
        }
        // 同系列只差一个字符的型号(只能进待核对)
        String full = line.fullPartNorm();
        if (!line.seriesNorm().isEmpty() && full.length() >= 6) {
            for (GoodsRow g : poolById.values()) {
                if (g.model() == null || g.model().isBlank() || !line.seriesNorm().equals(seriesNorm(g.series()))) {
                    continue;
                }
                String m = IntakeTextNormalizer.normalizePart(g.model());
                if (!m.equals(full) && Math.abs(m.length() - full.length()) <= 1 && oneEdit(m, full)) {
                    cand(cands, g).add(70, Evidence.MODEL_ONE_EDIT);
                }
            }
        }
        Set<String> seriesTokens = new HashSet<>(COMMON_SERIES_TOKENS);
        for (Scored s : cands.values()) {
            if (s.goods.series() != null && !s.goods.series().isBlank()) {
                seriesTokens.add(s.goods.series());
            }
        }
        if (!line.seriesNorm().isEmpty()) {
            seriesTokens.add(line.seriesNorm());
        }
        // 编号一致
        if (!line.partNo().isEmpty()) {
            for (GoodsRow g : poolById.values()) {
                if (g.code() != null && g.code().equalsIgnoreCase(line.partNo())) {
                    cand(cands, g).add(80, Evidence.CODE);
                }
            }
        }
        // 对照
        AliasHits aliasHits = applyAliases(line, aliases, poolById, cands);
        // 中文名称
        Map<UUID, Boolean> shortAgrees = new HashMap<>();
        String dn = "";
        if (line.cjkText() != null && !line.cjkText().isBlank()) {
            dn = IntakeTextNormalizer.normalizeCn(line.cjkText(), seriesTokens);
            if (!dn.isEmpty()) {
                boolean shortText = dn.codePointCount(0, dn.length()) < SHORT_CJK_CHARS;
                String dnQual = IntakeTextNormalizer.stripBracketQualifiers(dn);
                for (GoodsRow g : poolById.values()) {
                    String gn = IntakeTextNormalizer.normalizeCn(g.name(), seriesTokens);
                    Evidence rel = null;
                    double base = 0;
                    if (gn.equals(dn)) {
                        rel = Evidence.NAME_EXACT;
                        base = 85;
                    } else if (IntakeTextNormalizer.stripBracketQualifiers(gn).equals(dnQual)) {
                        rel = Evidence.NAME_APPROX;
                        base = 78;
                    } else if (dn.length() >= 4 && gn.endsWith(dn)) {
                        rel = Evidence.NAME_SUFFIX;
                        base = 80;
                    }
                    if (rel == null) {
                        continue;
                    }
                    if (shortText) {
                        shortAgrees.put(g.id(), true);
                    } else {
                        cand(cands, g).add(base, rel);
                    }
                }
                if (!shortText) {
                    List<Scored> byDice = new ArrayList<>();
                    for (GoodsRow g : poolById.values()) {
                        double d = IntakeTextNormalizer.bigramDice(line.cjkText(), g.name());
                        if (d > 0) {
                            Scored tmp = new Scored(g);
                            tmp.bigram = d;
                            byDice.add(tmp);
                        }
                    }
                    byDice.sort(Comparator.comparingDouble((Scored s) -> -s.bigram));
                    for (int i = 0; i < Math.min(BIGRAM_TOP, byDice.size()); i++) {
                        Scored d = byDice.get(i);
                        if (d.bigram >= BIGRAM_MIN) {
                            Scored c = cand(cands, d.goods);
                            c.bigram = Math.max(c.bigram, d.bigram);
                            c.add(40 + 45 * d.bigram, Evidence.NAME_BIGRAM);
                        }
                    }
                }
            }
        }
        // 英文名称
        if (line.latinNorm().length() >= 3) {
            List<Scored> byEn = new ArrayList<>();
            for (GoodsRow g : poolById.values()) {
                if (g.nameEn() == null || g.nameEn().isBlank()) {
                    continue;
                }
                String en = IntakeTextNormalizer.normalizeDescription(g.nameEn());
                if (en.equals(line.latinNorm())) {
                    cand(cands, g).add("MANUAL".equals(g.nameEnSource()) ? 88 : 80, Evidence.NAME_EN_EXACT);
                } else {
                    double sim = trigramSimilarity(en, line.latinNorm());
                    if (sim >= NAME_EN_MIN) {
                        Scored tmp = new Scored(g);
                        tmp.bigram = sim;
                        byEn.add(tmp);
                    }
                }
            }
            byEn.sort(Comparator.comparingDouble((Scored s) -> -s.bigram));
            for (int i = 0; i < Math.min(NAME_EN_TOP, byEn.size()); i++) {
                Scored d = byEn.get(i);
                cand(cands, d.goods).add(40 + 40 * d.bigram, Evidence.NAME_EN_SIMILAR);
            }
        }
        // 品名对照佐证(同上下文)
        Set<UUID> descAliasGoods = new HashSet<>();
        for (AliasRow a : aliases) {
            if (a.kind() != AliasKind.DESCRIPTION || !a.context().equals(line.contextNorm())) {
                continue;
            }
            if (a.scope() == AliasScope.GLOBAL && a.confirmCount() < 2) {
                continue;
            }
            if (a.norm().equals(line.descriptionNorm()) || a.norm().equals(line.descriptionAltNorm())) {
                descAliasGoods.add(a.goodsId());
            }
        }
        // 调整
        boolean anyAuthoritative = false;
        for (Scored s : cands.values()) {
            adjust(s, line, client, price, shortAgrees, descAliasGoods);
            anyAuthoritative |= s.evidence.contains(Evidence.ALIAS_AUTHORITATIVE);
        }
        if (anyAuthoritative) {
            for (Scored s : cands.values()) {
                if (s.evidence.contains(Evidence.ALIAS_AUTHORITATIVE)) {
                    s.raw = ALIAS_AUTHORITATIVE_SCORE;
                } else {
                    s.raw = Math.min(s.raw, NON_ALIAS_CAP_WHEN_AUTHORITATIVE);
                }
            }
        }
        List<Scored> ranked = new ArrayList<>(cands.values());
        ranked.sort(RANKING);
        return new Scoring(ranked, aliasHits.exactContextAmbiguous() || aliasHits.globalConflict());
    }

    /** 排序: 分数高在前; 同分时有确切证据、买过次数多、编号小的在前(结果稳定)。 */
    static final Comparator<Scored> RANKING = Comparator
            .comparingDouble((Scored s) -> -s.raw)
            .thenComparing((Scored s) -> s.hasExactEvidence() ? 0 : 1)
            .thenComparingInt((Scored s) -> -s.historyCount)
            .thenComparing((Scored s) -> s.goods.code() == null ? "" : s.goods.code());

    private static AliasHits applyAliases(LineInput line, List<AliasRow> aliases, Map<UUID, GoodsRow> poolById,
                                          Map<UUID, Scored> cands) {
        Set<UUID> exactContextGoods = new HashSet<>();
        Map<String, Set<UUID>> globalByNorm = new HashMap<>();
        for (AliasRow a : aliases) {
            if (a.kind() != AliasKind.PART_NO || line.fullPartNorm().isEmpty() || !a.norm().equals(line.fullPartNorm())) {
                continue;
            }
            GoodsRow g = poolById.get(a.goodsId());
            if (g == null) {
                continue;
            }
            if (a.scope() == AliasScope.CLIENT) {
                boolean exactContext = a.context().equals(line.contextNorm());
                if (exactContext) {
                    exactContextGoods.add(a.goodsId());
                }
                boolean authoritative = exactContext && (a.explicitCount() >= 1 || a.confirmCount() >= 2);
                cand(cands, g).add(authoritative ? ALIAS_AUTHORITATIVE_SCORE : 92,
                        authoritative ? Evidence.ALIAS_AUTHORITATIVE : Evidence.ALIAS);
            } else if (a.confirmCount() >= 2) {
                globalByNorm.computeIfAbsent(a.norm(), k -> new HashSet<>()).add(a.goodsId());
            }
        }
        boolean globalConflict = false;
        for (Set<UUID> goodsIds : globalByNorm.values()) {
            if (goodsIds.size() == 1) {
                GoodsRow g = poolById.get(goodsIds.iterator().next());
                cand(cands, g).add(90, Evidence.ALIAS_GLOBAL);
            } else {
                globalConflict = true;
            }
        }
        boolean ambiguous = exactContextGoods.size() > 1;
        if (ambiguous) {
            // 同一叫法同一上下文指向多个货品: 不再当权威对照。
            for (UUID id : exactContextGoods) {
                Scored s = cands.get(id);
                if (s != null && s.evidence.remove(Evidence.ALIAS_AUTHORITATIVE)) {
                    s.evidence.add(Evidence.ALIAS);
                    s.base = Math.min(s.base, 92);
                }
            }
        }
        return new AliasHits(ambiguous, globalConflict);
    }

    private static void adjust(Scored s, LineInput line, ClientContext client, PriceContext price,
                               Map<UUID, Boolean> shortAgrees, Set<UUID> descAliasGoods) {
        GoodsRow g = s.goods;
        double v = s.base;
        String gs = seriesNorm(g.series());
        if (!line.seriesNorm().isEmpty()) {
            if (gs.equals(line.seriesNorm())) {
                v += 10;
                s.evidence.add(Evidence.SERIES_MATCH);
            } else if (gs.contains(line.seriesNorm())) {
                v += 2;
                s.evidence.add(Evidence.SERIES_NEAR);
            } else {
                v -= 20;
                s.evidence.add(Evidence.SERIES_CONFLICT);
            }
        }
        IntakeColors.ColorSpec colors = line.colors();
        if (colors.known() && g.colorName() != null && !g.colorName().isBlank()) {
            if (colors.matchesMain(g.colorName())) {
                v += 8;
                s.evidence.add(Evidence.COLOR_MATCH);
            } else {
                v -= 25;
                s.evidence.add(Evidence.COLOR_CONFLICT);
            }
        }
        if (colors.frameConflicts(g.spec())) {
            v -= 10;
            s.evidence.add(Evidence.FRAME_CONFLICT);
        }
        boolean model = s.evidence.contains(Evidence.MODEL) || s.evidence.contains(Evidence.MODEL_VARIANT)
                || s.evidence.contains(Evidence.MODEL_ONE_EDIT);
        if (s.evidence.contains(Evidence.NAME_EXACT) && model) {
            v += 10;
            s.evidence.add(Evidence.MODEL_AND_NAME);
        }
        if (shortAgrees.containsKey(g.id())) {
            v += 5;
            s.evidence.add(Evidence.NAME_SHORT_AGREES);
        }
        if (descAliasGoods.contains(g.id())) {
            v += 6;
            s.evidence.add(Evidence.DESCRIPTION_ALIAS);
        }
        int count = client.orderCount(g.id());
        if (count > 0) {
            v += 6 + (count >= 3 ? 3 : 0);
            s.historyCount = count;
            s.evidence.add(Evidence.BOUGHT_BEFORE);
        }
        String prefix = IntakeTextNormalizer.ownerPrefix(g.name());
        if (prefix != null) {
            if (client.placeId().contains(prefix) || client.name().contains(prefix)) {
                v += 4;
                s.evidence.add(Evidence.OWN_PREFIX);
            } else {
                v -= 10;
                s.evidence.add(Evidence.OTHER_CUSTOMER);
            }
        }
        double list = g.price() == null ? 0 : g.price().doubleValue();
        if (!Double.isNaN(line.customerPrice()) && list > 0) {
            boolean equal = false;
            boolean plausible = false;
            for (double rate : price.rates()) {
                double converted = line.customerPrice() * rate;
                if (Math.abs(converted - list) <= 0.005 * list) {
                    equal = true;
                }
                double ratio = converted / list;
                if (ratio > 0.3 && ratio <= 1.0 + 1e-9) {
                    plausible = true;
                }
            }
            if (equal) {
                v += 4;
                s.evidence.add(Evidence.PRICE_MATCH);
            }
            if (!plausible) {
                v -= 10;
                s.evidence.add(Evidence.DISCOUNT_ODD);
            }
        }
        if (line.assembled() && g.name() != null && g.name().contains("功能件")) {
            // 文件写明「组装成功能件」: 名称是功能件的货品略加分(只作同分时的取舍)。
            v += 3;
            s.evidence.add(Evidence.ASSEMBLED_PART);
        }
        if (line.bundle()) {
            s.evidence.add(Evidence.BUNDLE);
        }
        s.raw = v;
    }

    private static Scored cand(Map<UUID, Scored> cands, GoodsRow g) {
        return cands.computeIfAbsent(g.id(), id -> new Scored(g));
    }

    static String seriesNorm(String series) {
        if (series == null) {
            return "";
        }
        return IntakeTextNormalizer.nfkc(series).strip().toUpperCase(Locale.ROOT).replaceAll("\\s+", "");
    }

    /** a 与 b 编辑距离恰好为 1(替换、插入或删除一个字符)。 */
    static boolean oneEdit(String a, String b) {
        if (a.equals(b)) {
            return false;
        }
        if (a.length() == b.length()) {
            int diff = 0;
            for (int i = 0; i < a.length(); i++) {
                if (a.charAt(i) != b.charAt(i) && ++diff > 1) {
                    return false;
                }
            }
            return diff == 1;
        }
        String shorter = a.length() < b.length() ? a : b;
        String longer = a.length() < b.length() ? b : a;
        if (longer.length() - shorter.length() != 1) {
            return false;
        }
        int i = 0;
        int j = 0;
        boolean skipped = false;
        while (i < shorter.length() && j < longer.length()) {
            if (shorter.charAt(i) == longer.charAt(j)) {
                i++;
                j++;
            } else {
                if (skipped) {
                    return false;
                }
                skipped = true;
                j++;
            }
        }
        return true;
    }

    /** 与 pg_trgm similarity 同口径的三元组相似度(词首补两个空格、词尾补一个空格)。 */
    static double trigramSimilarity(String a, String b) {
        Set<String> x = trigrams(a);
        Set<String> y = trigrams(b);
        if (x.isEmpty() || y.isEmpty()) {
            return 0;
        }
        int common = 0;
        for (String t : x) {
            if (y.contains(t)) {
                common++;
            }
        }
        return (double) common / (x.size() + y.size() - common);
    }

    private static Set<String> trigrams(String s) {
        Set<String> out = new HashSet<>();
        for (String word : s.toLowerCase(Locale.ROOT).split("[^\\p{L}\\p{N}]+")) {
            if (word.isEmpty()) {
                continue;
            }
            String padded = "  " + word + " ";
            for (int i = 0; i + 3 <= padded.length(); i++) {
                out.add(padded.substring(i, i + 3));
            }
        }
        return out;
    }

    // ------------------------------------------------------------------ decision

    /** 判定结论。 */
    enum Status { MATCHED, REVIEW, UNMATCHED }

    /** 待核对/没找到的原因(按优先级, 结果里翻成大白话)。 */
    enum Reason {
        NONE, NOT_FOUND, BUNDLE, ALIAS_AMBIGUOUS, SERIES_CONFLICT, COLOR_CONFLICT, FRAME_CONFLICT, COLOR_AMBIGUOUS,
        DISCOUNT_ODD, SAME_NAME_SIBLINGS, MULTI_SERIES, FUZZY_ONLY, CLOSE_CANDIDATES, LOW_SCORE,
        /** 只有按推测(未确认)的客户的历史/对照才够得上自动对应。 */
        CLIENT_UNCONFIRMED
    }

    /** 判定。 */
    record Decision(Status status, Reason reason, Scored top) {
    }

    /**
     * 按分数与证据判定一行。{@code scoring} 是 {@link #score} 的结果。
     */
    static Decision decide(LineInput line, Scoring scoring, ClientContext client) {
        List<Scored> ranked = scoring.ranked();
        if (ranked.isEmpty()) {
            return new Decision(Status.UNMATCHED, Reason.NOT_FOUND, null);
        }
        Scored top = ranked.getFirst();
        double second = ranked.size() > 1 ? ranked.get(1).raw : -99;
        Status weak = top.raw >= REVIEW_MIN ? Status.REVIEW : Status.UNMATCHED;
        if (line.bundle()) {
            return new Decision(weak, Reason.BUNDLE, top);
        }
        if (scoring.aliasAmbiguous()) {
            return new Decision(weak, Reason.ALIAS_AMBIGUOUS, top);
        }
        if (top.evidence.contains(Evidence.SERIES_CONFLICT)) {
            return new Decision(weak, Reason.SERIES_CONFLICT, top);
        }
        if (top.evidence.contains(Evidence.COLOR_CONFLICT)) {
            return new Decision(weak, Reason.COLOR_CONFLICT, top);
        }
        if (top.evidence.contains(Evidence.FRAME_CONFLICT)) {
            return new Decision(weak, Reason.FRAME_CONFLICT, top);
        }
        if (line.colors().ambiguous()) {
            return new Decision(weak, Reason.COLOR_AMBIGUOUS, top);
        }
        if (top.evidence.contains(Evidence.DISCOUNT_ODD)) {
            return new Decision(weak, Reason.DISCOUNT_ODD, top);
        }
        if (!top.hasExactEvidence()) {
            return new Decision(weak, top.raw >= REVIEW_MIN ? Reason.FUZZY_ONLY : Reason.LOW_SCORE, top);
        }
        if (top.evidence.contains(Evidence.NAME_EXACT) && !top.evidence.contains(Evidence.MODEL) && !top.isAlias()
                && !top.evidence.contains(Evidence.CODE)) {
            int limit = Math.min(TOP_K, ranked.size());
            for (int i = 1; i < limit; i++) {
                Scored other = ranked.get(i);
                if (other.evidence.contains(Evidence.NAME_EXACT) || other.evidence.contains(Evidence.NAME_APPROX)) {
                    return new Decision(weak, Reason.SAME_NAME_SIBLINGS, top);
                }
            }
        }
        if (top.raw < MATCH_MIN) {
            return new Decision(weak, Reason.LOW_SCORE, top);
        }
        if (top.raw - second < MATCH_MARGIN) {
            return new Decision(weak, Reason.CLOSE_CANDIDATES, top);
        }
        if (line.seriesNorm().isEmpty() && top.hasModelEvidence() && !top.isAlias()) {
            String topModel = top.goods.model() == null ? "" : IntakeTextNormalizer.normalizePart(top.goods.model());
            Set<String> seriesSeen = new HashSet<>();
            List<Scored> sameModel = new ArrayList<>();
            for (Scored s : ranked) {
                String m = s.goods.model() == null ? "" : IntakeTextNormalizer.normalizePart(s.goods.model());
                if (!topModel.isEmpty() && m.equals(topModel) && !s.evidence.contains(Evidence.COLOR_CONFLICT)) {
                    sameModel.add(s);
                    seriesSeen.add(seriesNorm(s.goods.series()));
                }
            }
            if (seriesSeen.size() >= 2) {
                List<Scored> bought = sameModel.stream().filter(s -> client.boughtRecently(s.goods.id())).toList();
                if (bought.size() != 1 || bought.getFirst() != top) {
                    return new Decision(Status.REVIEW, Reason.MULTI_SERIES, top);
                }
            }
        }
        return new Decision(Status.MATCHED, Reason.NONE, top);
    }

    /** 前 N 个候选。 */
    static List<Scored> top(List<Scored> ranked, int n) {
        return ranked.subList(0, Math.min(n, ranked.size()));
    }

    /** 找某货品的候选(没有返回 null)。 */
    static Scored find(List<Scored> ranked, UUID goodsId) {
        for (Scored s : ranked) {
            if (s.goods.id().equals(goodsId)) {
                return s;
            }
        }
        return null;
    }
}
