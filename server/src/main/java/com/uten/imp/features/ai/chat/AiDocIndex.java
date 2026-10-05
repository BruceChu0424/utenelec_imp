package com.uten.imp.features.ai.chat;

import java.text.Normalizer;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.HashSet;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.Set;
import java.util.function.IntPredicate;
import java.util.regex.Pattern;

/**
 * ADR-153 in-memory BM25 index over knowledge chunks. Chinese text is indexed as character bigrams,
 * English words and numbers as whole tokens; the chunk's document title and section path count three
 * times (a title match is a strong signal). Queries drop question words, expand a small table of
 * everyday synonyms (重量/单重/均重, 盘点/实盘, 入库/到货, 不良品/不良仓 ...) at a lower weight, and never
 * use bare numbers (the user's example values are not search terms).
 */
final class AiDocIndex {
    private static final double K1 = 1.2;
    private static final double B = 0.5;
    private static final int TITLE_WEIGHT = 3;
    private static final double SYNONYM_WEIGHT = 0.7;

    /** Everyday words and the words the documents use for the same thing. */
    static final List<List<String>> SYNONYMS = List.of(
            List.of("重量", "单重", "均重", "称重", "实称", "净重", "毛重", "公斤", "千克"),
            List.of("每个多重", "每个重", "单重", "单件重量", "均重"),
            List.of("没填", "未填", "没称", "未称", "空着", "留空", "不填"),
            List.of("计算", "估算", "推算", "换算", "折算"),
            List.of("差异", "差额", "偏差", "不一致"),
            List.of("盘点", "实盘", "盘盈", "盘亏", "账面"),
            List.of("入库", "到货", "收货", "入仓", "点收"),
            List.of("出库", "发料", "领料", "出仓"),
            List.of("不良品", "不良仓", "不良品仓", "次品", "不合格"),
            List.of("库存", "余额", "结存", "可用量", "在库"),
            List.of("委外", "外协", "外发"),
            List.of("质检", "检验", "品质"),
            List.of("报工", "日报", "完工"),
            List.of("审核", "审批", "批准"),
            List.of("谁来审核", "谁审核", "谁审批", "谁来审", "审核归属", "审核入口", "审核人"),
            List.of("谁负责", "谁来处理", "谁来办", "负责人", "归属"),
            List.of("订货单", "订单"),
            List.of("产品", "货品"),
            List.of("红框", "必填"),
            List.of("黄框", "预填", "待核对"),
            List.of("徽章", "红点", "角标", "计数"),
            List.of("草稿", "暂存"),
            List.of("单价", "价格"));

    /** Question and filler words removed from a query before it is split into terms. */
    private static final Pattern QUERY_FILLER = Pattern.compile("是什么意思|什么意思|意思|含义|区别|作用|这个|那个|这些|那些|这里|那里|怎么样|怎么|怎样|如何|什么|为什么|为啥"
            + "|多少|哪些|哪个|哪里|一下|一个|我们|你们|他们|请问|比如|例如|假如|如果|然后|最终|最后|可以|能不能|是不是|有没有"
            + "|会不会|应该|需要|系统|平台|erp|帮我|告诉我|谁来|谁去|谁能|谁可以|谁负责|时候"
            + "|\\b(?:how|what|why|when|where|which|who|does|do|is|are|the|a|an|of|to|in|on|for|and|or|this|that|it|i|you|my|me|please)\\b");
    /**
     * Single characters that carry no topic. They are never cut out of the question (that would split real words:
     * 在途, 让料, 对账, 供给, 有效期); a bigram is only dropped when it holds a particle (的, 了, 吗 ...) or consists of
     * such characters alone ("是我").
     */
    private static final String PARTICLES = "的了吗呢吧啊呀么嘛哦哈";
    private static final String FILLER_CHARACTERS = PARTICLES + "请是有在和与及或被把给让对将我你他她它这那些又谁就都也还";
    /** Weight of the earlier question's words when a follow-up is searched in the context of the conversation. */
    static final double CONTEXT_WEIGHT = 0.5;

    private final int size;
    private final int[] lengths;
    private final double averageLength;
    private final Map<String, int[]> postings;
    private final double[] priors;
    /** Sections that state rules (decisions, rules, counting conventions, calculations) rank a little higher. */
    private static final Pattern RULE_SECTION = Pattern.compile("决策|决定|规则|口径|算法|公式|计算|怎么算");
    private static final double RULE_PRIOR = 1.2;
    /**
     * Sections about who may do what, menus, layout and screen mechanics rank lower unless the question is about
     * them: "3.5 权限" must not push "3.3 单重自学习" out of a weight question.
     */
    private static final Pattern MECHANICS_SECTION = Pattern.compile("权限|菜单|入口|布局|样式|按钮|图标|字号|快捷键|分页|刷新|加载|响应式|交互");
    private static final double MECHANICS_PRIOR = 0.8;
    private static final Pattern MECHANICS_QUESTION = Pattern.compile("权限|谁能|谁可以|能不能看|看得到|看不到|看得见|授权|菜单|入口|在哪|哪里"
            + "|按钮|布局|permission|access|where|menu|button|권한|어디");
    private final boolean[] mechanics;

    /** The question asks about permissions, menus or where something is on screen. */
    static boolean mechanicsAsked(String question) {
        return question != null && MECHANICS_QUESTION.matcher(normalize(question)).find();
    }
    /** Each of the question's own words in the document title (up to three) adds this share to the score. */
    private static final double TITLE_BONUS = 0.15;
    private final List<Set<String>> documentTitles;

    /** One scored chunk. */
    record Hit(int chunk, double score, int matched) {}

    /**
     * @param documentTitles per chunk: its document's title (a document about the question's subject ranks first)
     * @param titles         per chunk: document title and section path
     * @param bodies         per chunk: the text
     */
    AiDocIndex(List<String> documentTitles, List<String> titles, List<String> bodies) {
        size = bodies.size();
        lengths = new int[size];
        priors = new double[size];
        mechanics = new boolean[size];
        Map<String, Set<String>> titleTerms = new HashMap<>();
        List<Set<String>> perChunk = new ArrayList<>(size);
        for (String title : documentTitles) perChunk.add(titleTerms.computeIfAbsent(title, key -> Set.copyOf(terms(key))));
        this.documentTitles = List.copyOf(perChunk);
        Map<String, List<int[]>> building = new HashMap<>();
        long total = 0;
        for (int chunk = 0; chunk < size; chunk++) {
            Map<String, Integer> tf = new HashMap<>();
            List<String> body = terms(bodies.get(chunk));
            List<String> title = terms(titles.get(chunk));
            for (String term : body) tf.merge(term, 1, Integer::sum);
            for (String term : title) tf.merge(term, TITLE_WEIGHT, Integer::sum);
            lengths[chunk] = body.size() + title.size() * TITLE_WEIGHT;
            priors[chunk] = RULE_SECTION.matcher(titles.get(chunk)).find() ? RULE_PRIOR : 1.0;
            String sections = titles.get(chunk).startsWith(documentTitles.get(chunk))
                    ? titles.get(chunk).substring(documentTitles.get(chunk).length()) : titles.get(chunk);
            mechanics[chunk] = MECHANICS_SECTION.matcher(sections).find();
            total += lengths[chunk];
            for (var entry : tf.entrySet()) {
                building.computeIfAbsent(entry.getKey(), key -> new ArrayList<>()).add(new int[] {chunk, entry.getValue()});
            }
        }
        averageLength = size == 0 ? 1 : Math.max(1, (double) total / size);
        postings = new HashMap<>(building.size() * 2);
        building.forEach((term, list) -> {
            int[] packed = new int[list.size() * 2];
            for (int i = 0; i < list.size(); i++) {
                packed[2 * i] = list.get(i)[0];
                packed[2 * i + 1] = list.get(i)[1];
            }
            postings.put(term, packed);
        });
    }

    int termCount() { return postings.size(); }

    long postingCount() { return postings.values().stream().mapToLong(values -> values.length / 2).sum(); }

    /** Rough heap estimate of the index structures (for the startup log). */
    long approximateBytes() {
        long bytes = (long) size * 4;
        for (var entry : postings.entrySet()) bytes += 64 + entry.getKey().length() * 2L + 16 + entry.getValue().length * 4L;
        return bytes;
    }

    /**
     * Chunks ordered by score, only those the reader may see; each hit records how many distinct query
     * terms it matched.
     */
    List<Hit> search(Map<String, Double> query, IntPredicate visible, int limit) {
        return search(query, visible, limit, true);
    }

    /**
     * @param mechanicsAsked the question is about permissions, menus or screen mechanics; otherwise such sections
     *                       rank lower than the rules
     */
    List<Hit> search(Map<String, Double> query, IntPredicate visible, int limit, boolean mechanicsAsked) {
        if (size == 0 || query.isEmpty()) return List.of();
        double[] scores = new double[size];
        int[] matched = new int[size];
        for (var term : query.entrySet()) {
            int[] list = postings.get(term.getKey());
            if (list == null) continue;
            int df = list.length / 2;
            double idf = Math.log(1 + (size - df + 0.5) / (df + 0.5));
            for (int i = 0; i < list.length; i += 2) {
                int chunk = list[i];
                double tf = list[i + 1];
                double norm = tf * (K1 + 1) / (tf + K1 * (1 - B + B * lengths[chunk] / averageLength));
                scores[chunk] += term.getValue() * idf * norm;
                if (term.getValue() >= 1.0) matched[chunk]++;
            }
        }
        List<String> own = query.entrySet().stream().filter(term -> term.getValue() >= 1.0).map(Map.Entry::getKey).toList();
        List<Hit> hits = new ArrayList<>();
        for (int chunk = 0; chunk < size; chunk++) {
            if (scores[chunk] <= 0 || !visible.test(chunk)) continue;
            Set<String> title = documentTitles.get(chunk);
            long inTitle = own.stream().filter(title::contains).limit(3).count();
            double prior = priors[chunk] * (mechanics[chunk] && !mechanicsAsked ? MECHANICS_PRIOR : 1.0);
            hits.add(new Hit(chunk, scores[chunk] * prior * (1 + TITLE_BONUS * inTitle), matched[chunk]));
        }
        hits.sort((a, b) -> Double.compare(b.score(), a.score()));
        return hits.size() > limit ? List.copyOf(hits.subList(0, limit)) : List.copyOf(hits);
    }

    /** Index terms of a text: Chinese bigrams (a lone character stays itself), English words and numbers. */
    static List<String> terms(String text) {
        List<String> terms = new ArrayList<>();
        if (text == null || text.isEmpty()) return terms;
        String value = normalize(text);
        int i = 0;
        int n = value.length();
        while (i < n) {
            char c = value.charAt(i);
            if (Character.UnicodeScript.of(c) == Character.UnicodeScript.HAN) {
                int start = i;
                while (i < n && Character.UnicodeScript.of(value.charAt(i)) == Character.UnicodeScript.HAN) i++;
                if (i - start == 1) {
                    terms.add(value.substring(start, i));
                } else {
                    for (int j = start; j + 1 < i; j++) terms.add(value.substring(j, j + 2));
                }
            } else if (Character.isLetterOrDigit(c)) {
                int start = i;
                while (i < n && Character.isLetterOrDigit(value.charAt(i))
                        && Character.UnicodeScript.of(value.charAt(i)) != Character.UnicodeScript.HAN) i++;
                terms.add(value.substring(start, i));
            } else {
                i++;
            }
        }
        return terms;
    }

    /**
     * Weighted query terms: the question's own words (weight 1, English and Korean business words translated to
     * the documents' words by {@link AiDocLexicon}) and synonyms of the words it uses (weight {@value #SYNONYM_WEIGHT}).
     * Question words, particles and bare numbers are left out.
     */
    static Map<String, Double> queryTerms(String question) {
        return queryTerms(question, "");
    }

    /**
     * Query terms of a follow-up searched in the context of the conversation: the earlier question's words count
     * at {@value #CONTEXT_WEIGHT} (they keep the topic, the current words decide), never as the question's own.
     */
    static Map<String, Double> queryTerms(String question, String context) {
        Map<String, Double> weighted = new LinkedHashMap<>();
        if (question == null || question.isBlank()) return weighted;
        String value = normalize(question + " " + AiDocLexicon.translate(question));
        for (String term : keyTerms(value)) weighted.put(term, 1.0);
        addSynonyms(value, weighted, SYNONYM_WEIGHT);
        if (context != null && !context.isBlank()) {
            String earlier = normalize(context + " " + AiDocLexicon.translate(context));
            for (String term : keyTerms(earlier)) weighted.putIfAbsent(term, CONTEXT_WEIGHT);
            addSynonyms(earlier, weighted, CONTEXT_WEIGHT * SYNONYM_WEIGHT);
        }
        return weighted;
    }

    private static void addSynonyms(String value, Map<String, Double> weighted, double weight) {
        for (List<String> group : SYNONYMS) {
            if (group.stream().noneMatch(value::contains)) continue;
            for (String word : group) {
                for (String term : terms(word)) weighted.putIfAbsent(term, weight);
            }
        }
    }

    /**
     * The question's content terms: whole filler words removed ("怎么", "什么意思"), then terms; numbers, single
     * letters or characters, and bigrams holding a particle or made of filler characters only are left out.
     */
    static List<String> keyTerms(String question) {
        String value = QUERY_FILLER.matcher(normalize(question)).replaceAll(" ");
        List<String> result = new ArrayList<>();
        Set<String> seen = new HashSet<>();
        for (String term : terms(value)) {
            if (term.chars().allMatch(Character::isDigit)) continue;
            // A lone letter or a lone Chinese character says nothing about the topic.
            if (term.length() == 1) continue;
            if (term.length() == 2 && Character.UnicodeScript.of(term.charAt(0)) == Character.UnicodeScript.HAN
                    && (PARTICLES.indexOf(term.charAt(0)) >= 0 || PARTICLES.indexOf(term.charAt(1)) >= 0
                    || (FILLER_CHARACTERS.indexOf(term.charAt(0)) >= 0 && FILLER_CHARACTERS.indexOf(term.charAt(1)) >= 0))) {
                continue;
            }
            if (seen.add(term)) result.add(term);
        }
        return result;
    }

    /**
     * Share of the question's content terms that the reply uses (0..1), and how many terms there were.
     * A reply about something else shares almost none of them.
     */
    static double overlap(String question, String reply) {
        // Compared in the documents' words as well, so an English or Korean answer to an English or Korean question
        // (whose particles and word forms never repeat exactly) is measured by the business words both use.
        String asked = question + " " + AiDocLexicon.translate(question);
        String answered = reply + " " + AiDocLexicon.translate(reply);
        List<String> key = keyTerms(asked).stream().filter(term -> !term.matches("\\d.*|[a-z]{1,2}")).toList();
        if (key.isEmpty()) return 1;
        Set<String> said = new HashSet<>(terms(answered));
        // A synonym in the reply counts ("日报" answered with "报工", "点收" with "入库").
        String replyText = normalize(answered);
        for (List<String> group : SYNONYMS) {
            if (group.stream().anyMatch(replyText::contains)) {
                for (String word : group) said.addAll(terms(word));
            }
        }
        long used = key.stream().filter(said::contains).count();
        return (double) used / key.size();
    }

    /**
     * The sentences of {@code text} that share the most content words with the question, in their original
     * order, at most {@code maxChars} characters (a deterministic, focused excerpt). Only readable sentences are
     * used: a sentence left broken by the removal of internal names (unbalanced brackets, a dangling word, too short)
     * is skipped; empty when nothing readable is left.
     */
    static String focusedExcerpt(String question, String text, int maxChars) {
        Set<String> key = new HashSet<>(queryTerms(question).keySet());
        List<String> sentences = new ArrayList<>();
        for (String line : text.split("\n")) {
            for (String sentence : line.split("(?<=[。；！？])")) {
                String value = sentence.strip().replaceFirst("^[-*•]\\s*", "");
                if (readable(value)) sentences.add(value);
            }
        }
        record Scored(int index, long score) {}
        List<Scored> scored = new ArrayList<>();
        for (int i = 0; i < sentences.size(); i++) {
            long score = terms(sentences.get(i)).stream().distinct().filter(key::contains).count();
            if (score > 0) scored.add(new Scored(i, score));
        }
        scored.sort((a, b) -> b.score() != a.score() ? Long.compare(b.score(), a.score()) : Integer.compare(a.index(), b.index()));
        java.util.TreeSet<Integer> picked = new java.util.TreeSet<>();
        int length = 0;
        for (Scored item : scored) {
            int size = sentences.get(item.index()).length() + 1;
            if (length + size > maxChars) continue;
            picked.add(item.index());
            length += size;
        }
        StringBuilder out = new StringBuilder();
        for (int index : picked) {
            if (out.length() > 0) out.append('\n');
            out.append(sentences.get(index));
        }
        return out.length() < 20 ? "" : out.toString();
    }

    /** A whole, readable sentence: long enough, balanced brackets, no dangling particle, no table or code remains. */
    static boolean readable(String sentence) {
        if (sentence == null || sentence.length() < 10) return false;
        long open = sentence.chars().filter(c -> c == '(' || c == '\uFF08').count();
        long close = sentence.chars().filter(c -> c == ')' || c == '\uFF09').count();
        if (open != close) return false;
        if (sentence.contains("...") || sentence.contains("|") || sentence.matches(".*[(\uFF08]\\s*[)\uFF09].*")
                || sentence.matches(".*[(\uFF08]\\s*[,\uFF0C\u3001;\uFF1B].*|.*[,\uFF0C\u3001]\\s*[)\uFF09].*")) return false;
        if (sentence.matches(".*[把被将对给与和及或的从向在为以由]\\s*$")) return false;
        return sentence.codePoints().filter(Character::isIdeographic).count() >= 5 || sentence.matches(".*[a-zA-Z]{3,}.*\\s.*");
    }

    static int keyTermCount(String question) {
        return (int) keyTerms(question).stream().filter(term -> !term.matches("\\d.*|[a-z]{1,2}")).count();
    }

    static String normalize(String text) {
        return Normalizer.normalize(text, Normalizer.Form.NFKC).toLowerCase(Locale.ROOT);
    }

    @Override public String toString() {
        return "AiDocIndex[chunks=" + size + ", terms=" + postings.size() + "]";
    }
}
