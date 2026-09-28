package com.uten.imp.features.master.learning;

import com.uten.imp.common.text.IntakeTextNormalizer;
import jakarta.persistence.EntityManager;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Component;

import java.time.Clock;
import java.time.Duration;
import java.time.Instant;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.Collection;
import java.util.Comparator;
import java.util.HashMap;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.UUID;
import java.util.regex.Pattern;

/**
 * 按中文品名召回货品候选的内存索引(ADR-134, 供 {@link MasterIntakeLookupAdapter#goodsByNameCandidates})。
 *
 * <p>为什么不用数据库三元组索引: 中文品名在 pg_trgm 里是一整个「词」, 正确名称的相似度只有 0.1 左右;
 * 货品名里还夹着空格、全角括号与客户/国别前缀。这里把所有「使用中、未删除、非占位」货品的名称按
 * 识别侧同一口径(NFKC、小写、去全部空白)规范化后放在内存里, 召回三类候选:
 * <ol>
 *   <li>名称以文件品名结尾(含去掉括号限定语后结尾)——覆盖「完全一致」「去前缀后一致」「后缀一致」;</li>
 *   <li>字二元组 Dice 相似度最高的若干个(与识别参考实现 sim2 的 dice_top 同一算法, 这里精确计算);</li>
 *   <li>名称包含文件品名的其余货品(较短的优先)。</li>
 * </ol>
 * 只返回货品 id; 可见范围、状态等由调用方再按 id 回表过滤(索引过期也不会越权或返回停用货品)。
 * 索引按货品表的轻量签名(行数、版本和、最后修改时间)失效重建, 另有 10 分钟兜底过期。
 */
@Component
@RequiredArgsConstructor
class GoodsNameCatalog {

    /** 每段文件品名最多取的「名称结尾一致」候选(同一品名在很多系列都有, 系列由调用方打分区分)。 */
    static final int SUFFIX_PER_TEXT = 200;
    /** 每段文件品名最多取的二元组相似候选(sim2 取 12)。 */
    static final int BIGRAM_PER_TEXT = 12;
    /** 二元组相似的召回下限(调用方按 0.5 打分, 这里略放宽, 防两边规范化细节差异漏召回)。 */
    static final double BIGRAM_MIN_DICE = 0.4;
    /** 每段文件品名最多取的「名称包含」候选。 */
    static final int CONTAINS_PER_TEXT = 20;

    private static final Duration MAX_AGE = Duration.ofMinutes(10);
    private static final Pattern WHITESPACE = Pattern.compile("(?U)\\s+");

    private final EntityManager em;
    private final Clock clock = Clock.systemUTC();
    private final Object rebuildLock = new Object();
    private volatile Snapshot snapshot;

    /** 按优先级(结尾一致 → 二元组相似 → 包含)返回候选货品 id, 去重, 最多 {@code limit} 个。 */
    List<UUID> search(Collection<String> texts, int limit) {
        if (texts == null || texts.isEmpty() || limit <= 0) return List.of();
        Snapshot index = current();
        List<List<Integer>> suffix = new ArrayList<>();
        List<List<Integer>> bigram = new ArrayList<>();
        List<List<Integer>> contains = new ArrayList<>();
        for (String text : new LinkedHashSet<>(texts)) {
            if (text == null || text.isBlank()) continue;
            String key = containsKey(text);
            String keyNoBracket = containsKey(IntakeTextNormalizer.stripBracketQualifiers(key));
            List<Integer> suffixHits = new ArrayList<>();
            List<Integer> containsHits = new ArrayList<>();
            if (key.length() >= 2) {
                for (int i = 0; i < index.size(); i++) {
                    String name = index.names[i];
                    String nameNoBracket = index.namesNoBracket[i];
                    if (name.endsWith(key) || (keyNoBracket.length() >= 2 && nameNoBracket.endsWith(keyNoBracket))) {
                        suffixHits.add(i);
                    } else if (name.contains(key) || (keyNoBracket.length() >= 2 && nameNoBracket.contains(keyNoBracket))) {
                        containsHits.add(i);
                    }
                }
            }
            Comparator<Integer> shortestFirst = Comparator.comparingInt((Integer i) -> index.names[i].length())
                    .thenComparing(i -> index.ids[i].toString());
            suffixHits.sort(shortestFirst);
            containsHits.sort(shortestFirst);
            suffix.add(suffixHits.subList(0, Math.min(SUFFIX_PER_TEXT, suffixHits.size())));
            contains.add(containsHits.subList(0, Math.min(CONTAINS_PER_TEXT, containsHits.size())));
            bigram.add(index.topDice(text));
        }
        Set<UUID> out = new LinkedHashSet<>();
        for (List<List<Integer>> tier : List.of(suffix, bigram, contains)) {
            for (List<Integer> hits : tier) {
                for (int i : hits) {
                    if (out.size() >= limit) return List.copyOf(out);
                    out.add(index.ids[i]);
                }
            }
        }
        return List.copyOf(out);
    }

    /** 与识别侧 normalizeCn 的比较口径一致: NFKC、去全部空白、小写(不剥前缀——剥前缀后仍是原名的结尾)。 */
    static String containsKey(String text) {
        return WHITESPACE.matcher(IntakeTextNormalizer.nfkc(text)).replaceAll("").toLowerCase(java.util.Locale.ROOT);
    }

    private Snapshot current() {
        String signature = signature();
        Snapshot existing = snapshot;
        Instant now = clock.instant();
        if (existing != null && existing.signature.equals(signature)
                && existing.builtAt.plus(MAX_AGE).isAfter(now)) {
            return existing;
        }
        synchronized (rebuildLock) {
            existing = snapshot;
            if (existing != null && existing.signature.equals(signature)
                    && existing.builtAt.plus(MAX_AGE).isAfter(now)) {
                return existing;
            }
            Snapshot rebuilt = load(signature, now);
            snapshot = rebuilt;
            return rebuilt;
        }
    }

    private String signature() {
        Object[] row = (Object[]) em.createNativeQuery("""
                        SELECT count(*), coalesce(sum(version), 0), coalesce(CAST(max(updated_at) AS text), '')
                        FROM goods
                        WHERE NOT is_deleted AND status = '使用' AND NOT auto_created
                        """)
                .getSingleResult();
        return row[0] + "|" + row[1] + "|" + row[2];
    }

    @SuppressWarnings("unchecked")
    private Snapshot load(String signature, Instant builtAt) {
        List<Object[]> rows = em.createNativeQuery("""
                        SELECT id, name
                        FROM goods
                        WHERE NOT is_deleted AND status = '使用' AND NOT auto_created
                          AND name IS NOT NULL AND btrim(name) <> ''
                        ORDER BY id
                        """)
                .getResultList();
        int size = rows.size();
        UUID[] ids = new UUID[size];
        String[] names = new String[size];
        String[] namesNoBracket = new String[size];
        int[][] bigrams = new int[size][];
        Map<Integer, List<Integer>> postingLists = new HashMap<>();
        for (int i = 0; i < size; i++) {
            Object[] row = rows.get(i);
            ids[i] = (UUID) row[0];
            String raw = (String) row[1];
            names[i] = containsKey(raw);
            String noBracket = containsKey(IntakeTextNormalizer.stripBracketQualifiers(names[i]));
            namesNoBracket[i] = noBracket.equals(names[i]) ? names[i] : noBracket;
            bigrams[i] = pack(IntakeTextNormalizer.bigrams(raw));
            for (int gram : bigrams[i]) {
                postingLists.computeIfAbsent(gram, ignored -> new ArrayList<>()).add(i);
            }
        }
        Map<Integer, int[]> postings = new HashMap<>(postingLists.size() * 2);
        for (Map.Entry<Integer, List<Integer>> entry : postingLists.entrySet()) {
            postings.put(entry.getKey(), entry.getValue().stream().mapToInt(Integer::intValue).toArray());
        }
        return new Snapshot(signature, builtAt, ids, names, namesNoBracket, bigrams, postings);
    }

    /** 二元组打包成 int(两个 UTF-16 码元), 排序去重。 */
    static int[] pack(Set<String> grams) {
        int[] out = new int[grams.size()];
        int n = 0;
        for (String gram : grams) {
            if (gram.length() != 2) continue;
            out[n++] = (gram.charAt(0) << 16) | gram.charAt(1);
        }
        int[] trimmed = Arrays.copyOf(out, n);
        Arrays.sort(trimmed);
        return trimmed;
    }

    /** 不可变索引快照。 */
    private record Snapshot(String signature, Instant builtAt, UUID[] ids, String[] names, String[] namesNoBracket,
                            int[][] bigrams, Map<Integer, int[]> postings) {

        int size() {
            return ids.length;
        }

        /** 与 sim2 dice_top 同一口径: 文本二元组少于 2 个不召回; 取 Dice 最高的若干个。 */
        List<Integer> topDice(String text) {
            int[] query = pack(IntakeTextNormalizer.bigrams(text));
            if (query.length < 2) return List.of();
            Map<Integer, Integer> shared = new HashMap<>();
            for (int gram : query) {
                int[] posting = postings.get(gram);
                if (posting == null) continue;
                for (int i : posting) shared.merge(i, 1, Integer::sum);
            }
            List<double[]> scored = new ArrayList<>();
            for (Map.Entry<Integer, Integer> entry : shared.entrySet()) {
                int i = entry.getKey();
                double dice = 2.0 * entry.getValue() / (query.length + bigrams[i].length);
                if (dice >= BIGRAM_MIN_DICE) scored.add(new double[]{dice, i});
            }
            scored.sort((a, b) -> {
                int byDice = Double.compare(b[0], a[0]);
                return byDice != 0 ? byDice : ids[(int) a[1]].toString().compareTo(ids[(int) b[1]].toString());
            });
            List<Integer> out = new ArrayList<>();
            for (int k = 0; k < Math.min(BIGRAM_PER_TEXT, scored.size()); k++) out.add((int) scored.get(k)[1]);
            return out;
        }
    }
}
