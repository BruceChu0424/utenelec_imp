package com.uten.imp.features.ai.chat;

import java.text.Normalizer;
import java.util.ArrayList;
import java.util.Collection;
import java.util.HashMap;
import java.util.HashSet;
import java.util.LinkedHashMap;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.Set;
import java.util.function.IntPredicate;
import java.util.regex.Pattern;

/**
 * ADR-153 in-memory BM25 index over knowledge chunks. Chinese text is indexed as character bigrams,
 * English words and numbers as whole tokens; the chunk's document title and section path count three
 * times (a title match is a strong signal). Queries drop question and filler words, read the question with a
 * {@link Vocabulary} of whole business words (a bigram that straddles two words is not searched, an everyday phrase
 * is searched in the documents' words), expand a small table of everyday synonyms (重量/单重/均重, 盘点/实盘,
 * 入库/到货 ...) at a lower weight, and never use bare numbers (the user's example values are not search terms).
 */
final class AiDocIndex {
    private static final double K1 = 1.2;
    private static final double B = 0.5;
    private static final int TITLE_WEIGHT = 3;
    private static final double SYNONYM_WEIGHT = 0.7;
    /**
     * Weight of the glossary term of an everyday word the question uses ("线边仓" -> 车间内料仓): a little above a synonym,
     * and a chunk holding it counts it as one of the question's words (the user's everyday word is rarely in a rule).
     */
    static final double ALIAS_WEIGHT = 0.75;

    /** Everyday words and the words the documents use for the same thing (either one finds the others). */
    static final List<List<String>> SYNONYMS = List.of(
            List.of("重量", "单重", "均重", "称重", "实称", "净重", "毛重", "公斤", "千克"),
            List.of("每个多重", "每个重", "单重", "单件重量", "均重"),
            List.of("没填", "未填", "没称", "未称", "空着", "留空", "不填"),
            List.of("计算", "估算", "推算", "换算", "折算"),
            List.of("差异", "差额", "偏差", "不一致"),
            List.of("盘点", "实盘", "盘盈", "盘亏", "账面"),
            List.of("入库", "到货", "收货", "入仓", "点收"),
            List.of("出库", "发料", "领料", "出仓", "出入库"),
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
            List.of("单价", "价格"),
            List.of("票据", "发票", "凭证"),
            List.of("撤回", "撤销"),
            List.of("缺货", "稀缺", "缺货仲裁"),
            List.of("驳回", "退回修改"));

    /**
     * P0-4 everyday phrases (qa-eval 6 #1a) and the documents' words for them. The phrase is read as one word: its own
     * characters are not searched (they match quoted user wording in unrelated documents), the documents' words are
     * searched as the question's own words.
     */
    static final List<Map.Entry<List<String>, List<String>>> COLLOQUIAL = List.of(
            colloquial("货不够|货不足|不够发|没货发", "缺货"),
            colloquial("先给哪个|先给谁|先发谁|谁先发|先发哪个|先给哪家", "仲裁 优先"),
            colloquial("被退回|退回来了|打回来|被打回|给退回", "驳回"),
            colloquial("多送|多交了|送多了|来多了|多到了|多收了", "超收"),
            colloquial("做多了|多做了|生产多了|做超了", "超产"),
            colloquial("下不了|点不了|勾不了|选不了|按钮灰|按钮是灰", "锁住 解锁"),
            colloquial("报过什么价|报过价|报过的价|以前报价|以前的报价|历史报价|上次报价|上次报的价", "报价历史 报价记录"),
            colloquial("字太小|看不清|字大一点|放大字|字体大|调大字|调大一点", "字号 缩放"),
            colloquial("领去用|拿去用|先领", "领料 可用量"),
            colloquial("东西到了|货到了|送来了|送到了", "到货"),
            colloquial("料不够|没料了|缺料", "缺料 齐套"),
            colloquial("少了几|少货|少给|少发了", "短交"),
            colloquial("这次做的|这次做了|这次报", "本次"),
            colloquial("开权限|开通权限|没权限|没有权限", "权限"),
            colloquial("下采购单|开采购单|做采购单|采购下单", "采购订货单"),
            colloquial("下委外单|开委外单|做委外单", "委外订货单"),
            colloquial("收进去|收进来|收进仓", "入库"),
            colloquial("客户预付|客户先付|预付的钱|先付的钱|定金", "预收"),
            colloquial("改密码|换密码|改个密码|改登录密码", "修改密码"));

    /**
     * Whole business words used to read a question (besides the synonym table, the everyday phrases and, at index
     * build, the glossary terms and the documents' aliases): a bigram across two of them ("后仓" in 以后仓库) is noise.
     */
    static final List<String> CORE_WORDS = List.of(
            "销售", "报价", "客户", "出货", "发货", "应收", "收款", "退货", "预留", "仲裁", "零星发货", "样品",
            "采购", "供应商", "应付", "超收", "仓库", "主仓", "分仓", "货架", "库位", "料仓", "内料仓", "待检", "调拨",
            "生产", "车间", "排产", "待排产", "物料", "物料分析", "产量", "产成品", "成品", "流水线", "计划", "工序", "直送",
            "备料", "超产", "补产", "追加", "自制", "调度", "让料", "齐套", "缺料", "缺口", "在途", "短交", "损耗",
            "退料", "余料", "放行", "认领", "路线", "工单", "子计划", "委外单", "委外申请", "结案",
            "财务", "钱流", "成本", "资金", "付款", "汇率", "币种", "资产", "待摊", "金额", "账户", "核价", "过账", "往来",
            "预付", "手续费", "银行", "结账",
            "人事", "员工", "工号", "入职", "离职", "工资", "工资条", "转正", "试用期", "岗位", "部门", "身份证", "证件",
            "研发", "权限", "授权", "工作台", "待办", "通知", "报销", "请假", "密码", "设置", "字号", "数量", "状态",
            "按钮", "页面", "单据", "单子", "提交", "保存", "修改", "删除", "规则", "流程", "本次", "累计", "记录",
            // A document name ending in 单 is one word ("退货单" must keep 货单).
            "退货单", "出货单", "报价单", "采购单", "领料单", "发料单", "收货单", "入库单", "出库单", "盘点单", "收款单", "付款单");

    /** The vocabulary of the built-in tables (an index adds the glossary and the documents' aliases). */
    static final Vocabulary DEFAULT = Vocabulary.of(SYNONYMS, COLLOQUIAL, List.of(), CORE_WORDS);

    /** Question and filler words removed from a query before it is split into terms. */
    private static final Pattern QUERY_FILLER = Pattern.compile("是什么意思|什么意思|意思|含义|区别|作用|这个|那个|这些|那些|这里|那里|怎么样|怎么办|怎么弄|怎么|怎样|如何|什么|为什么|为啥"
            + "|多少|哪些|哪个|哪里|一下子|一下|一些|一个|我们|你们|他们|请问|比如|例如|假如|如果|然后|最终|最后|可以|能不能|是不是|有没有"
            + "|会不会|算不算|行不行|应该|需要|系统|平台|erp|帮我|告诉我|谁来|谁去|谁能|谁可以|谁负责|时候"
            // Everyday filler of spoken questions ("仓库那边要怎么收", "东西该放哪才对").
            + "|那边|这边|东西|咋办|咋|啥|干嘛|干啥|到底|才对|弄|搞"
            // Spoken lead-ins ("我想听听…", "想问一下…"): they carry no topic.
            + "|我想听听|想听听|听听|我想知道|想知道|我想问|想问问|想问|我想"
            + "|\\b(?:how|what|why|when|where|which|who|does|do|is|are|the|a|an|of|to|in|on|for|and|or|this|that|it|i|you|my|me|please)\\b");
    /**
     * Single characters that carry no topic. They are never cut out of the question (that would split real words:
     * 在途, 让料, 对账, 供给, 有效期); a bigram is only dropped when it holds a particle (的, 了, 吗 ... and 得 written for
     * 的) or consists of such characters alone ("是我").
     */
    private static final String PARTICLES = "的了吗呢吧啊呀么嘛哦哈得";
    private static final String FILLER_CHARACTERS = PARTICLES + "请是有在和与及或被把给让对将我你他她它这那些又谁就都也还";
    /** Weight of the earlier question's words when a follow-up is searched in the context of the conversation. */
    static final double CONTEXT_WEIGHT = 0.5;

    private final int size;
    private final int[] lengths;
    private final double averageLength;
    private final Map<String, int[]> postings;
    private final double[] priors;
    private final Vocabulary vocabulary;
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
            + "|按钮|布局|字号|permission|access|where|menu|button|권한|어디");
    private final boolean[] mechanics;

    /** The question asks about permissions, menus or where something is on screen. */
    static boolean mechanicsAsked(String question) {
        return question != null && MECHANICS_QUESTION.matcher(normalize(question)).find();
    }
    /** Each of the question's own words in the document title (up to three) adds this share to the score. */
    private static final double TITLE_BONUS = 0.15;
    private final List<Set<String>> documentTitles;
    /** Per chunk: the terms of its document title, aliases and section path. */
    private final List<Set<String>> headingTerms;

    /**
     * One scored chunk.
     *
     * @param matched   how many distinct own terms of the question the chunk holds
     * @param inHeading how many distinct own terms of the question its document title, aliases or section path hold
     * @param inContext how many distinct words of the earlier question (a follow-up's topic) the chunk holds
     */
    record Hit(int chunk, double score, int matched, int inHeading, int inContext) {}

    /**
     * @param documentTitles per chunk: its document's title (a document about the question's subject ranks first)
     * @param titles         per chunk: document title and section path
     * @param bodies         per chunk: the text
     */
    AiDocIndex(List<String> documentTitles, List<String> titles, List<String> bodies) {
        this(documentTitles, titles, bodies, null, DEFAULT);
    }

    /**
     * @param chunkPriors per chunk: a fixed weight (a plan or a pointer to a superseded document ranks lower), or
     *                    {@code null} for 1 everywhere
     * @param vocabulary  the words a question is read with
     */
    AiDocIndex(List<String> documentTitles, List<String> titles, List<String> bodies, double[] chunkPriors,
               Vocabulary vocabulary) {
        size = bodies.size();
        this.vocabulary = vocabulary;
        lengths = new int[size];
        priors = new double[size];
        mechanics = new boolean[size];
        Map<String, Set<String>> titleTerms = new HashMap<>();
        List<Set<String>> perChunk = new ArrayList<>(size);
        for (String title : documentTitles) perChunk.add(titleTerms.computeIfAbsent(title, key -> Set.copyOf(terms(key))));
        this.documentTitles = List.copyOf(perChunk);
        List<Set<String>> headings = new ArrayList<>(size);
        Map<String, int[]> built = new HashMap<>();
        Map<String, List<int[]>> building = new HashMap<>();
        long total = 0;
        for (int chunk = 0; chunk < size; chunk++) {
            Map<String, Integer> tf = new HashMap<>();
            List<String> body = terms(bodies.get(chunk));
            List<String> title = terms(titles.get(chunk));
            headings.add(Set.copyOf(title));
            for (String term : body) tf.merge(term, 1, Integer::sum);
            for (String term : title) tf.merge(term, TITLE_WEIGHT, Integer::sum);
            lengths[chunk] = body.size() + title.size() * TITLE_WEIGHT;
            priors[chunk] = (RULE_SECTION.matcher(titles.get(chunk)).find() ? RULE_PRIOR : 1.0)
                    * (chunkPriors == null ? 1.0 : chunkPriors[chunk]);
            String sections = titles.get(chunk).startsWith(documentTitles.get(chunk))
                    ? titles.get(chunk).substring(documentTitles.get(chunk).length()) : titles.get(chunk);
            mechanics[chunk] = MECHANICS_SECTION.matcher(sections).find();
            total += lengths[chunk];
            for (var entry : tf.entrySet()) {
                building.computeIfAbsent(entry.getKey(), key -> new ArrayList<>()).add(new int[] {chunk, entry.getValue()});
            }
        }
        this.headingTerms = List.copyOf(headings);
        averageLength = size == 0 ? 1 : Math.max(1, (double) total / size);
        building.forEach((term, list) -> {
            int[] packed = new int[list.size() * 2];
            for (int i = 0; i < list.size(); i++) {
                packed[2 * i] = list.get(i)[0];
                packed[2 * i + 1] = list.get(i)[1];
            }
            built.put(term, packed);
        });
        postings = built;
    }

    int termCount() { return postings.size(); }

    long postingCount() { return postings.values().stream().mapToLong(values -> values.length / 2).sum(); }

    /** The words this index reads questions with. */
    Vocabulary vocabulary() { return vocabulary; }

    /** True when some chunk holds the term (a question word no document uses can neither find nor miss anything). */
    boolean known(String term) { return postings.containsKey(term); }

    /** Rough heap estimate of the index structures (for the startup log). */
    long approximateBytes() {
        long bytes = (long) size * 4;
        for (var entry : postings.entrySet()) bytes += 64 + entry.getKey().length() * 2L + 16 + entry.getValue().length * 4L;
        return bytes;
    }

    /** Weighted query terms of a question read with this index's vocabulary (see {@link Vocabulary#queryTerms}). */
    Map<String, Double> query(String question, String context) {
        return vocabulary.queryTerms(question, context);
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
        int[] inContext = new int[size];
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
                if (counts(term.getValue())) matched[chunk]++;
                else if (term.getValue() == CONTEXT_WEIGHT) inContext[chunk]++;
            }
        }
        List<String> own = query.entrySet().stream().filter(term -> counts(term.getValue())).map(Map.Entry::getKey).toList();
        List<Hit> hits = new ArrayList<>();
        for (int chunk = 0; chunk < size; chunk++) {
            if (scores[chunk] <= 0 || !visible.test(chunk)) continue;
            Set<String> title = documentTitles.get(chunk);
            long inTitle = own.stream().filter(title::contains).limit(3).count();
            int inHeading = (int) own.stream().filter(headingTerms.get(chunk)::contains).count();
            double prior = priors[chunk] * (mechanics[chunk] && !mechanicsAsked ? MECHANICS_PRIOR : 1.0);
            hits.add(new Hit(chunk, scores[chunk] * prior * (1 + TITLE_BONUS * inTitle), matched[chunk], inHeading,
                    inContext[chunk]));
        }
        hits.sort((a, b) -> Double.compare(b.score(), a.score()));
        return hits.size() > limit ? List.copyOf(hits.subList(0, limit)) : List.copyOf(hits);
    }

    /** A query term of this weight is one of the question's words: its own, or the glossary term of its everyday word. */
    private static boolean counts(double weight) {
        return weight >= 1.0 || weight == ALIAS_WEIGHT;
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
            if (han(c)) {
                int start = i;
                while (i < n && han(value.charAt(i))) i++;
                bigrams(value.substring(start, i), terms);
            } else if (Character.isLetterOrDigit(c)) {
                int start = i;
                while (i < n && Character.isLetterOrDigit(value.charAt(i)) && !han(value.charAt(i))) i++;
                terms.add(value.substring(start, i));
            } else {
                i++;
            }
        }
        return terms;
    }

    private static boolean han(char c) {
        return Character.UnicodeScript.of(c) == Character.UnicodeScript.HAN;
    }

    /** The bigrams of one run of Chinese characters (a lone character stays itself). */
    private static void bigrams(String run, List<String> into) {
        if (run.length() == 1) {
            into.add(run);
        } else {
            for (int j = 0; j + 1 < run.length(); j++) into.add(run.substring(j, j + 2));
        }
    }

    /**
     * Weighted query terms (default vocabulary): the question's own words (weight 1, English and Korean business words
     * translated to the documents' words by {@link AiDocLexicon}) and synonyms of the words it uses (weight
     * {@value #SYNONYM_WEIGHT}). Question words, particles and bare numbers are left out.
     */
    static Map<String, Double> queryTerms(String question) {
        return DEFAULT.queryTerms(question, "");
    }

    /**
     * Query terms of a follow-up searched in the context of the conversation (default vocabulary): the earlier
     * question's words count at {@value #CONTEXT_WEIGHT} (they keep the topic, the current words decide), never as the
     * question's own.
     */
    static Map<String, Double> queryTerms(String question, String context) {
        return DEFAULT.queryTerms(question, context);
    }

    /**
     * The question's content terms (default vocabulary): whole filler words removed ("怎么", "什么意思"), everyday
     * phrases read in the documents' words, then terms of whole words; numbers, single letters or characters, and
     * bigrams holding a particle or made of filler characters only are left out.
     */
    static List<String> keyTerms(String question) {
        return DEFAULT.keyTerms(question);
    }

    /**
     * The words a question is read with: whole words (a bigram across two of them is not searched), everyday phrases
     * read in the documents' words, the glossary's everyday words and synonym groups. Immutable; {@link #DEFAULT} holds
     * the built-in tables and an index adds the glossary ({@link AiDocGlossary}) and the documents' aliases.
     *
     * @param words    whole words, normalized, two characters or more
     * @param longest  length of the longest word
     * @param phrases  built-in everyday phrase to the documents' words (the phrase itself is not searched)
     * @param aliases  glossary everyday word to its terms (searched with the word at {@value #ALIAS_WEIGHT}; one
     *                 everyday word may name several terms, so it never replaces the user's word)
     * @param glossaryTerms the glossary's terms
     * @param synonyms groups of words that find each other at the synonym weight
     */
    record Vocabulary(Set<String> words, int longest, Map<String, List<String>> phrases, Map<String, List<String>> aliases,
                      Set<String> glossaryTerms, List<List<String>> synonyms) {
        static Vocabulary of(List<List<String>> synonyms, List<Map.Entry<List<String>, List<String>>> colloquial,
                             List<AiDocGlossary.Entry> glossary, Collection<String> words) {
            Map<String, List<String>> phrases = new HashMap<>();
            for (var entry : colloquial) {
                for (String phrase : entry.getKey()) phrases.putIfAbsent(normalize(phrase), entry.getValue());
            }
            Map<String, List<String>> aliases = new HashMap<>();
            Set<String> terms = new LinkedHashSet<>();
            Set<String> all = new LinkedHashSet<>();
            for (AiDocGlossary.Entry entry : glossary) {
                String term = normalize(entry.term());
                all.add(term);
                if (term.length() >= 2) terms.add(term);
                for (String alias : entry.aliases()) {
                    String value = normalize(alias).strip();
                    if (value.length() < 2 || value.equals(term)) continue;
                    all.add(value);
                    List<String> named = new ArrayList<>(aliases.getOrDefault(value, List.of()));
                    if (!named.contains(term)) named.add(term);
                    aliases.put(value, List.copyOf(named));
                }
            }
            for (List<String> group : synonyms) all.addAll(group);
            all.addAll(phrases.keySet());
            all.addAll(words);
            Set<String> normalized = new LinkedHashSet<>();
            for (String word : all) {
                String value = normalize(word).strip();
                if (value.length() >= 2 && value.chars().allMatch(c -> han((char) c))) normalized.add(value);
            }
            int longest = normalized.stream().mapToInt(String::length).max().orElse(0);
            return new Vocabulary(Set.copyOf(normalized), longest, Map.copyOf(phrases), Map.copyOf(aliases), Set.copyOf(terms),
                    synonyms.stream().map(List::copyOf).toList());
        }

        /** The glossary terms a question names, by the term itself or by one of its everyday words (normalized). */
        Set<String> named(String question) {
            Set<String> named = new LinkedHashSet<>();
            if (question == null || question.isBlank() || glossaryTerms.isEmpty()) return named;
            String value = normalize(question + " " + AiDocLexicon.translate(question));
            for (String term : glossaryTerms) if (value.contains(term)) named.add(term);
            aliases.forEach((alias, names) -> {
                if (value.contains(alias)) named.addAll(names);
            });
            return named;
        }

        /**
         * Weighted query terms: the question's own words (weight 1) and synonyms of the words it uses (weight
         * {@value #SYNONYM_WEIGHT}); with a {@code context} (the earlier questions a follow-up continues) their words
         * count at {@value #CONTEXT_WEIGHT}, never as the question's own.
         */
        Map<String, Double> queryTerms(String question, String context) {
            Map<String, Double> weighted = new LinkedHashMap<>();
            if (question == null || question.isBlank()) return weighted;
            String value = normalize(question + " " + AiDocLexicon.translate(question));
            read(value, weighted, 1.0);
            addSynonyms(value, weighted, SYNONYM_WEIGHT, ALIAS_WEIGHT);
            if (context != null && !context.isBlank()) {
                String earlier = normalize(context + " " + AiDocLexicon.translate(context));
                read(earlier, weighted, CONTEXT_WEIGHT);
                addSynonyms(earlier, weighted, CONTEXT_WEIGHT * SYNONYM_WEIGHT, CONTEXT_WEIGHT * SYNONYM_WEIGHT);
            }
            return weighted;
        }

        /** The question's content terms (no synonyms): everyday phrases in the documents' words, then whole words. */
        List<String> keyTerms(String question) {
            Map<String, Double> weighted = new LinkedHashMap<>();
            if (question != null && !question.isBlank()) read(normalize(question), weighted, 1.0);
            return weighted.entrySet().stream().filter(term -> term.getValue() >= 1.0).map(Map.Entry::getKey).toList();
        }

        private void read(String value, Map<String, Double> weighted, double weight) {
            List<String> mapped = new ArrayList<>();
            String rest = replacePhrases(value, mapped);
            for (String word : mapped) {
                for (String term : content(segment(word))) weighted.putIfAbsent(term, weight);
            }
            for (String term : content(segment(QUERY_FILLER.matcher(rest).replaceAll(" ")))) weighted.putIfAbsent(term, weight);
        }

        /**
         * The text with every built-in everyday phrase (longest first) replaced by spaces; the documents' words for it
         * go to {@code mapped}.
         */
        private String replacePhrases(String value, List<String> mapped) {
            if (phrases.isEmpty()) return value;
            StringBuilder out = new StringBuilder(value);
            List<String> ordered = phrases.keySet().stream()
                    .sorted((a, b) -> a.length() != b.length() ? Integer.compare(b.length(), a.length()) : a.compareTo(b)).toList();
            for (String phrase : ordered) {
                int at = out.indexOf(phrase);
                if (at < 0) continue;
                mapped.addAll(phrases.get(phrase));
                while (at >= 0) {
                    out.replace(at, at + phrase.length(), " ".repeat(phrase.length()));
                    at = out.indexOf(phrase, at + phrase.length());
                }
            }
            return out.toString();
        }

        /**
         * Terms of a text read with the whole words: each run of Chinese characters is split greedily into the longest
         * known words; a known word gives its own bigrams, the characters between known words give the bigrams among
         * themselves, and a bigram across a word boundary is not a term.
         */
        List<String> segment(String text) {
            List<String> out = new ArrayList<>();
            if (text == null || text.isEmpty()) return out;
            String value = normalize(text);
            int i = 0;
            int n = value.length();
            while (i < n) {
                char c = value.charAt(i);
                if (han(c)) {
                    int start = i;
                    while (i < n && han(value.charAt(i))) i++;
                    splitRun(value.substring(start, i), out);
                } else if (Character.isLetterOrDigit(c)) {
                    int start = i;
                    while (i < n && Character.isLetterOrDigit(value.charAt(i)) && !han(value.charAt(i))) i++;
                    out.add(value.substring(start, i));
                } else {
                    i++;
                }
            }
            return out;
        }

        private void splitRun(String run, List<String> out) {
            int unknownFrom = 0;
            int previousWordEnd = -1;
            int i = 0;
            while (i < run.length()) {
                int length = Math.min(longest, run.length() - i);
                while (length >= 2 && !words.contains(run.substring(i, i + length))) length--;
                if (length < 2) {
                    i++;
                    continue;
                }
                if (i > unknownFrom) bigrams(run.substring(unknownFrom, i), out);
                // Two known words side by side are a phrase ("客户退货"): the bigram joining them is kept.
                if (previousWordEnd == i) out.add(run.substring(i - 1, i + 1));
                bigrams(run.substring(i, i + length), out);
                i += length;
                unknownFrom = i;
                previousWordEnd = i;
            }
            if (unknownFrom < run.length()) bigrams(run.substring(unknownFrom), out);
        }

        /** The glossary terms of the everyday words the question uses, and the synonym groups it names. */
        private void addSynonyms(String value, Map<String, Double> weighted, double weight, double aliasWeight) {
            aliases.forEach((alias, terms) -> {
                if (!value.contains(alias)) return;
                for (String word : terms) {
                    for (String term : content(segment(word))) weighted.putIfAbsent(term, aliasWeight);
                }
            });
            for (List<String> group : synonyms) {
                if (group.stream().noneMatch(value::contains)) continue;
                for (String word : group) {
                    for (String term : terms(word)) weighted.putIfAbsent(term, weight);
                }
            }
        }
    }

    /** Content terms: no numbers, single letters or characters, or bigrams holding a particle or only filler. */
    private static List<String> content(List<String> terms) {
        List<String> result = new ArrayList<>();
        Set<String> seen = new HashSet<>();
        for (String term : terms) {
            if (term.chars().allMatch(Character::isDigit)) continue;
            // A lone letter or a lone Chinese character says nothing about the topic.
            if (term.length() == 1) continue;
            if (term.length() == 2 && han(term.charAt(0))
                    && (PARTICLES.indexOf(term.charAt(0)) >= 0 || PARTICLES.indexOf(term.charAt(1)) >= 0
                    || (FILLER_CHARACTERS.indexOf(term.charAt(0)) >= 0 && FILLER_CHARACTERS.indexOf(term.charAt(1)) >= 0))) {
                continue;
            }
            if (seen.add(term)) result.add(term);
        }
        return result;
    }

    private static Map.Entry<List<String>, List<String>> colloquial(String phrases, String words) {
        return Map.entry(List.of(phrases.split("\\|")), List.of(words.split(" ")));
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
