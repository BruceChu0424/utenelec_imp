package com.uten.imp.features.sales.intake;

import com.uten.imp.application.port.MasterIntakeLookupPort;
import com.uten.imp.application.port.MasterIntakeLookupPort.AliasRow;
import com.uten.imp.application.port.MasterIntakeLookupPort.ClientGoodsHistory;
import com.uten.imp.application.port.MasterIntakeLookupPort.GoodsRow;
import com.uten.imp.common.text.IntakeTextNormalizer;

import java.util.ArrayList;
import java.util.Collection;
import java.util.Comparator;
import java.util.HashSet;
import java.util.LinkedHashMap;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.UUID;
import java.util.function.Function;

/**
 * 按行召回候选货品(SPEC §5.5 候选来源), 全部经 {@link MasterIntakeLookupPort}(按当前用户的数据范围):
 * 型号精确及前缀变体、同系列只差一个字符的型号、编号、中文名称(精确/包含)、英文名称、客户对照与全局对照,
 * 知道客户后再加上该客户买过的货品(最多 500 个)。打分在 {@link GoodsMatcher} 里做。
 */
final class GoodsCandidateRetriever {

    static final int HISTORY_MONTHS = 120;
    static final int HISTORY_POOL_MAX = 500;
    static final int NAME_LIMIT_PER_LINE = 150;
    static final int NAME_EN_LIMIT_PER_LINE = 40;
    static final int MAX_ONE_EDIT_VARIANTS = 6000;
    private static final int CHUNK = 200;
    private static final String ONE_EDIT_ALPHABET = "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-/.";
    private static final String USABLE_STATUS = "使用";

    private final MasterIntakeLookupPort lookup;

    GoodsCandidateRetriever(MasterIntakeLookupPort lookup) {
        this.lookup = lookup;
    }

    /** 召回结果: 全部货品行(去重) + 相关对照。 */
    record Retrieval(Map<UUID, GoodsRow> rows, List<AliasRow> aliases) {
    }

    /** 客户买过的货品池。 */
    record HistoryPool(Map<UUID, ClientGoodsHistory> history, List<GoodsRow> rows) {
        static final HistoryPool EMPTY = new HistoryPool(Map.of(), List.of());
    }

    /** 按文字召回(不看客户的历史); {@code clientIdOrNull} 只影响对照(客户对照 + 全局对照)。 */
    Retrieval retrieve(List<ExtractedLine> lines, UUID clientIdOrNull) {
        Map<UUID, GoodsRow> rows = new LinkedHashMap<>();
        // 型号: 原值、剥前缀、加前缀(货品型号本身带前缀的情况)
        Set<String> modelNorms = new LinkedHashSet<>();
        for (ExtractedLine line : lines) {
            modelNorms.addAll(modelQueries(line.firstPartNorm()));
        }
        addAll(rows, chunked(modelNorms, lookup::goodsByModelNorm));
        // 同系列只差一个字符: 只对该系列里一个型号都没对上的行生成候选型号
        Set<String> oneEdit = new LinkedHashSet<>();
        for (ExtractedLine line : lines) {
            String full = line.partNorm();
            String series = line.seriesNorm();
            if (series.isEmpty() || full.length() < 6 || full.contains("+")) {
                continue;
            }
            boolean seriesHit = rows.values().stream().anyMatch(g -> series.equals(GoodsMatcher.seriesNorm(g.series()))
                    && g.model() != null && IntakeTextNormalizer.partVariants(IntakeTextNormalizer.normalizePart(g.model()))
                    .keySet().stream().anyMatch(v -> IntakeTextNormalizer.partVariants(line.firstPartNorm()).containsKey(v)));
            if (seriesHit) {
                continue;
            }
            Set<String> variants = oneEditVariants(full);
            if (oneEdit.size() + variants.size() > MAX_ONE_EDIT_VARIANTS) {
                break;
            }
            oneEdit.addAll(variants);
        }
        if (!oneEdit.isEmpty()) {
            addAll(rows, chunked(oneEdit, lookup::goodsByModelNorm));
        }
        // 编号
        Set<String> codes = new LinkedHashSet<>();
        for (ExtractedLine line : lines) {
            if (line.partNo() != null) {
                String code = line.partNo().strip();
                if (code.length() >= 3 && code.length() <= 40 && !code.contains("+")) {
                    codes.add(code);
                }
            }
        }
        if (!codes.isEmpty()) {
            addAll(rows, chunked(codes, lookup::goodsByCode));
        }
        // 中文名称(精确/包含)与英文名称: 整份文件一次召回(每行各自限额), 不按行逐次查库。
        List<List<String>> cnGroups = new ArrayList<>();
        Set<String> enTexts = new LinkedHashSet<>();
        for (ExtractedLine line : lines) {
            List<String> cn = nameQueries(line);
            if (!cn.isEmpty()) {
                cnGroups.add(cn);
            }
            if (line.description() != null && line.description().strip().length() >= 3) {
                enTexts.add(line.description().strip());
            }
        }
        if (!cnGroups.isEmpty()) {
            addAll(rows, lookup.goodsByNameCandidatesEach(cnGroups, NAME_LIMIT_PER_LINE));
        }
        if (!enTexts.isEmpty()) {
            // 每段文字的相似候选在查询里已各自限量, 整批上限 = 段数 × 每行上限, 不会挤掉后面的行。
            addAll(rows, chunked(enTexts, chunk -> lookup.goodsByNameEn(chunk, chunk.size() * NAME_EN_LIMIT_PER_LINE)));
        }
        return withAliases(new Retrieval(rows, List.of()), lines, clientIdOrNull);
    }

    /**
     * 在已有召回结果上换成某客户的对照(客户对照 + 全局对照), 并补齐对照指向但还没召回的货品。
     * 找到客户后用它, 不必把文字召回再做一遍。
     */
    Retrieval withAliases(Retrieval base, List<ExtractedLine> lines, UUID clientIdOrNull) {
        Map<UUID, GoodsRow> rows = new LinkedHashMap<>(base.rows());
        Set<String> partNorms = new LinkedHashSet<>();
        Set<String> descNorms = new LinkedHashSet<>();
        for (ExtractedLine line : lines) {
            if (!line.partNorm().isEmpty()) {
                partNorms.add(line.partNorm());
            }
            if (line.description() != null) {
                descNorms.add(IntakeTextNormalizer.normalizeDescription(line.description()));
            }
            if (line.descriptionAlt() != null) {
                descNorms.add(IntakeTextNormalizer.normalizeDescription(line.descriptionAlt()));
            }
        }
        descNorms.remove("");
        List<AliasRow> aliases = partNorms.isEmpty() && descNorms.isEmpty() ? List.of()
                : lookup.aliases(clientIdOrNull, partNorms, descNorms);
        if (aliases == null) {
            aliases = List.of();
        }
        Set<UUID> missing = new LinkedHashSet<>();
        for (AliasRow a : aliases) {
            if (!rows.containsKey(a.goodsId())) {
                missing.add(a.goodsId());
            }
        }
        if (!missing.isEmpty()) {
            addAll(rows, chunked(missing, lookup::goodsByIds));
        }
        return new Retrieval(rows, List.copyOf(aliases));
    }

    /** 客户买过的货品(近 10 年, 最多 500 个, 订单数多、最近买过的优先)。 */
    HistoryPool history(UUID clientId) {
        if (clientId == null) {
            return HistoryPool.EMPTY;
        }
        Map<UUID, ClientGoodsHistory> history = lookup.clientHistory(clientId, HISTORY_MONTHS);
        if (history == null || history.isEmpty()) {
            return HistoryPool.EMPTY;
        }
        List<ClientGoodsHistory> ordered = new ArrayList<>(history.values());
        ordered.sort(Comparator.comparingInt((ClientGoodsHistory h) -> -h.orderCount())
                .thenComparing(h -> h.lastOrderDate() == null ? java.time.LocalDate.MIN : h.lastOrderDate(),
                        Comparator.reverseOrder()));
        Map<UUID, ClientGoodsHistory> kept = new LinkedHashMap<>();
        for (ClientGoodsHistory h : ordered) {
            if (kept.size() >= HISTORY_POOL_MAX) {
                break;
            }
            if (h.goodsId() != null) {
                kept.put(h.goodsId(), h);
            }
        }
        Map<UUID, GoodsRow> rows = new LinkedHashMap<>();
        addAll(rows, chunked(kept.keySet(), lookup::goodsByIds));
        return new HistoryPool(kept, List.copyOf(rows.values()));
    }

    /** 型号查询值: 原值、剥前缀变体, 以及加上常见前缀(货品型号带前缀、文件不带)。 */
    static Set<String> modelQueries(String firstPartNorm) {
        Set<String> out = new LinkedHashSet<>();
        if (firstPartNorm == null || firstPartNorm.isEmpty()) {
            return out;
        }
        Map<String, Integer> variants = IntakeTextNormalizer.partVariants(firstPartNorm);
        out.addAll(variants.keySet());
        for (String v : variants.keySet()) {
            for (String prefix : IntakeTextNormalizer.PART_PREFIXES) {
                out.add(prefix + v);
            }
        }
        return out;
    }

    /** 中文名称查询值: 整段(去空白)、去掉前缀与系列后的核心、再去括号说明。 */
    static List<String> nameQueries(ExtractedLine line) {
        String cjk = line.matchDescription();
        if (cjk == null || cjk.isBlank()) {
            return List.of();
        }
        Set<String> tokens = new HashSet<>(GoodsMatcher.COMMON_SERIES_TOKENS);
        if (!line.seriesNorm().isEmpty()) {
            tokens.add(line.seriesNorm());
        }
        Set<String> out = new LinkedHashSet<>();
        String whole = IntakeTextNormalizer.nfkc(cjk).replaceAll("\\s+", "");
        String core = IntakeTextNormalizer.normalizeCn(cjk, tokens);
        String qual = IntakeTextNormalizer.stripBracketQualifiers(core);
        for (String t : List.of(whole, core, qual)) {
            if (t.codePointCount(0, t.length()) >= 2) {
                out.add(t);
            }
        }
        return List.copyOf(out);
    }

    /** 编辑距离为 1 的全部写法(删除、替换、插入一个字符)。 */
    static Set<String> oneEditVariants(String s) {
        Set<String> out = new LinkedHashSet<>();
        for (int i = 0; i < s.length(); i++) {
            out.add(s.substring(0, i) + s.substring(i + 1));
        }
        for (int i = 0; i < s.length(); i++) {
            for (int k = 0; k < ONE_EDIT_ALPHABET.length(); k++) {
                char c = ONE_EDIT_ALPHABET.charAt(k);
                if (c != s.charAt(i)) {
                    out.add(s.substring(0, i) + c + s.substring(i + 1));
                }
            }
        }
        for (int i = 0; i <= s.length(); i++) {
            for (int k = 0; k < ONE_EDIT_ALPHABET.length(); k++) {
                out.add(s.substring(0, i) + ONE_EDIT_ALPHABET.charAt(k) + s.substring(i));
            }
        }
        out.remove(s);
        return out;
    }

    private static <T> List<GoodsRow> chunked(Collection<T> values, Function<List<T>, List<GoodsRow>> query) {
        List<GoodsRow> out = new ArrayList<>();
        List<T> all = new ArrayList<>(values);
        for (int i = 0; i < all.size(); i += CHUNK) {
            List<GoodsRow> part = query.apply(List.copyOf(all.subList(i, Math.min(all.size(), i + CHUNK))));
            if (part != null) {
                out.addAll(part);
            }
        }
        return out;
    }

    private static void addAll(Map<UUID, GoodsRow> rows, Collection<GoodsRow> found) {
        if (found == null) {
            return;
        }
        for (GoodsRow g : found) {
            if (g != null && (g.status() == null || USABLE_STATUS.equals(g.status()))) {
                rows.putIfAbsent(g.id(), g);
            }
        }
    }
}
