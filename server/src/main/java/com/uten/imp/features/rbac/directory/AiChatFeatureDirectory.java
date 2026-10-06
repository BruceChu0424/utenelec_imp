package com.uten.imp.features.rbac.directory;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.application.port.AiFeatureDirectoryPort;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.stereotype.Component;

import java.io.IOException;
import java.io.InputStream;
import java.text.Normalizer;
import java.util.ArrayList;
import java.util.Comparator;
import java.util.HashSet;
import java.util.LinkedHashMap;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.Objects;
import java.util.Set;
import java.util.regex.Pattern;

/**
 * The reviewed feature and page directory (SPEC P1-1, ADR-153 amendment): one entry per page with its Chinese title
 * and other names, module, purpose, menu path and the client route guard's permission codes. The resource
 * {@code ai-feature-map.json} is generated from the real client router, workbench and module cards and page docs by
 * {@code test/shared/ai/ai_feature_map_test.dart}, which fails on any drift. Routes stay on the server: answers carry
 * titles, module names and menu words only. The AI assistant reads what a user opens through
 * {@link AiFeatureDirectoryPort} (ADR-017), so the directory is read and the open rule applied in this one place.
 */
@Component
public class AiChatFeatureDirectory implements AiFeatureDirectoryPort {
    private static final Logger log = LoggerFactory.getLogger(AiChatFeatureDirectory.class);
    static final String RESOURCE = "ai-feature-map.json";

    /**
     * One page. {@code anyOf} null means no any-of requirement; a non-empty {@code hubOf} marks a module home page,
     * which opens when any of its cards opens (the client guard's rule).
     */
    public record Feature(String route, String title, List<String> aliases, String module, String purpose,
                          List<List<String>> paths, String parent, boolean record, List<String> anyOf,
                          List<String> allOf, List<String> hubOf) {
        boolean hub() {
            return !hubOf.isEmpty();
        }
    }

    /** What a reader lacks for one ordinary page: one of {@code anyOf} (empty when held) and every {@code allOf}. */
    public record Lack(List<String> anyOf, List<String> allOf) {
        boolean none() {
            return anyOf.isEmpty() && allOf.isEmpty();
        }

        Set<String> codes() {
            Set<String> codes = new LinkedHashSet<>(anyOf);
            codes.addAll(allOf);
            return codes;
        }
    }

    /** Question words that never name a page ("库存在哪里看" searches 库存). Longest first. */
    private static final List<String> FILLERS = List.of("做到哪一步了", "到哪一步了", "有哪些功能", "怎么进入", "怎么打开",
            "哪个页面", "什么页面", "哪一步", "系统里", "平台里", "在哪里", "在哪儿", "怎么进", "怎么找", "找不到", "打不开", "进不去", "看不到", "看不了", "点不了", "没有权限",
            "为什么", "能不能", "可不可以", "在哪", "哪里", "哪儿", "哪个", "页面", "入口", "菜单", "功能", "有哪些", "有什么",
            "我要", "我想", "想要", "可以", "怎么", "如何", "去哪", "查看", "打开", "进入", "没权限", "权限", "为啥", "一下",
            "请问", "帮我", "不了", "不能", "无法", "没法", "我能", "系统", "平台", "模块", "所有", "全部", "的", "呢", "吗", "了",
            "啊", "呀", "吧", "里", "我");
    private static final String LEADING_VERBS = "看查找去到在";
    private static final Pattern SEPARATORS = Pattern.compile("[\\s,，、/;；|]+");
    private static final Pattern NOISE = Pattern.compile("[\\p{P}\\p{S}\\s]+");

    private final List<Feature> features;
    private final Map<String, Feature> byRoute;

    @Autowired
    public AiChatFeatureDirectory(ObjectMapper json) {
        this(read(json));
    }

    /** A directory over the given {@code ai-feature-map.json} content (tests build small directories this way). */
    public static AiChatFeatureDirectory fromJson(JsonNode root) {
        return new AiChatFeatureDirectory(parse(root));
    }

    AiChatFeatureDirectory(List<Feature> features) {
        this.features = List.copyOf(features);
        Map<String, Feature> routes = new LinkedHashMap<>();
        for (Feature feature : this.features) routes.put(feature.route(), feature);
        this.byRoute = Map.copyOf(routes);
    }

    public List<Feature> features() {
        return features;
    }

    /** Whether the reader opens the page under the same any/all contract as the client route guard. */
    public boolean opens(Feature feature, Set<String> granted, boolean superAdmin) {
        if (superAdmin) return true;
        if (feature.hub()) {
            return feature.hubOf().stream().map(byRoute::get).filter(Objects::nonNull)
                    .anyMatch(card -> !card.hub() && opens(card, granted, false));
        }
        return lack(feature, granted).none();
    }

    @Override
    public Openable openable(Set<String> permissions, boolean superAdmin) {
        Set<String> granted = permissions == null ? Set.of() : permissions;
        Set<String> modules = new LinkedHashSet<>();
        Set<String> labels = new LinkedHashSet<>();
        for (Feature feature : features) {
            if (!opens(feature, granted, superAdmin)) continue;
            if (!feature.module().isBlank()) modules.add(feature.module().strip());
            labels.addAll(labels(feature));
        }
        return new Openable(List.copyOf(modules), List.copyOf(labels));
    }

    /** The names a page is shown by: title, other names, each menu step and each whole menu path. */
    private static List<String> labels(Feature feature) {
        Set<String> labels = new LinkedHashSet<>();
        addLabel(labels, feature.title());
        feature.aliases().forEach(alias -> addLabel(labels, alias));
        for (List<String> path : feature.paths()) {
            List<String> steps = path.stream().map(String::strip).filter(step -> !step.isEmpty()).toList();
            labels.addAll(steps);
            if (steps.size() > 1) labels.add(String.join(" > ", steps));
        }
        return List.copyOf(labels);
    }

    private static void addLabel(Set<String> labels, String label) {
        if (label != null && !label.isBlank()) labels.add(label.strip());
    }

    /**
     * The codes an ordinary page still needs; meaningless for a module home page. An any-of code that the all-of list
     * also requires is reported once, in the all-of list.
     */
    public Lack lack(Feature feature, Set<String> granted) {
        List<String> all = feature.allOf().stream().filter(code -> !granted.contains(code)).toList();
        boolean anyHeld = feature.anyOf() == null || feature.anyOf().stream().anyMatch(granted::contains);
        boolean anyInAll = feature.anyOf() != null && feature.anyOf().stream().anyMatch(feature.allOf()::contains);
        return new Lack(anyHeld || anyInAll ? List.of() : feature.anyOf(), all);
    }

    /** How to reach the page, in menu words ("工作台 > PMC运营部 > 仓库管理 > 即时库存"). Never a route. */
    public String howToOpen(Feature feature) {
        if (!feature.paths().isEmpty()) {
            return String.join("，或 ", feature.paths().stream().limit(2)
                    .map(steps -> String.join(" > ", steps)).toList());
        }
        Feature parent = feature.parent() == null ? null : byRoute.get(feature.parent());
        if (parent == null) return "没有固定的菜单入口，一般从相关页面或通知里点进来";
        String from;
        if (parent.hub()) from = "在「" + parent.title() + "」的相关页面里进入";
        else if (feature.record()) from = "在「" + parent.title() + "」里点开一条记录进入";
        else from = "从「" + parent.title() + "」进入";
        return parent.paths().isEmpty() ? from
                : from + "(「" + parent.title() + "」在 " + String.join(" > ", parent.paths().getFirst()) + ")";
    }

    /**
     * Pages whose names, module or purpose match the keyword, best first. Each term of the keyword is matched on its
     * own after the question words are dropped, so "库存 盘点" and "库存在哪里看" both work.
     */
    public List<Feature> search(String keyword) {
        List<String> terms = terms(keyword);
        if (terms.isEmpty()) return List.of();
        record Scored(Feature feature, int score) {}
        List<Scored> scored = new ArrayList<>();
        for (Feature feature : features) {
            int best = 0;
            int hits = 0;
            for (String term : terms) {
                int score = score(feature, term);
                if (score > 0) hits++;
                best = Math.max(best, score);
            }
            if (best > 0) scored.add(new Scored(feature, best + 5 * (hits - 1)));
        }
        // When a page is named, pages that only share the module or a word in their purpose are noise.
        int top = scored.stream().mapToInt(Scored::score).max().orElse(0);
        int floor = top >= 60 ? 30 : 1;
        return scored.stream()
                .filter(item -> item.score() >= floor)
                .sorted(Comparator.comparingInt(Scored::score).reversed()
                        .thenComparingInt(item -> item.feature().title().length())
                        .thenComparing(item -> item.feature().route()))
                .map(Scored::feature).toList();
    }

    /** The question's own words, without question words and punctuation; terms shorter than two characters drop. */
    static List<String> terms(String keyword) {
        if (keyword == null) return List.of();
        List<String> terms = new ArrayList<>();
        for (String part : SEPARATORS.split(Normalizer.normalize(keyword, Normalizer.Form.NFKC))) {
            String term = fold(part);
            for (String filler : FILLERS) term = term.replace(filler, "");
            // 「看库存」「查报销」「找工资条」: a leading look/find verb is not part of the page name.
            while (term.length() > 2 && LEADING_VERBS.indexOf(term.charAt(0)) >= 0) term = term.substring(1);
            while (term.length() > 2 && term.endsWith("看")) term = term.substring(0, term.length() - 1);
            if (term.length() >= 2 && !terms.contains(term)) terms.add(term);
        }
        return terms;
    }

    /** Case, width, spaces and punctuation folded; 帐 and 账 are one word. */
    static String fold(String text) {
        if (text == null) return "";
        return NOISE.matcher(Normalizer.normalize(text, Normalizer.Form.NFKC).toLowerCase(Locale.ROOT))
                .replaceAll("").replace('帐', '账');
    }

    /** 0 = unrelated; a name match outranks a module match, which outranks a purpose match. */
    static int score(Feature feature, String term) {
        int best = 0;
        List<String> names = new ArrayList<>();
        names.add(feature.title());
        names.addAll(feature.aliases());
        for (List<String> path : feature.paths()) if (!path.isEmpty()) names.add(path.getLast());
        for (String raw : names) {
            String name = fold(raw);
            if (name.isEmpty()) continue;
            if (name.equals(term)) best = Math.max(best, 100);
            else if (name.contains(term)) best = Math.max(best, 90 - Math.min(20, name.length() - term.length()));
            else if (name.length() >= 2 && term.contains(name)) best = Math.max(best, 75);
            else {
                double share = bigramShare(term, name);
                if (share >= 0.5) best = Math.max(best, (int) Math.round(60 * share));
            }
        }
        String module = fold(feature.module());
        if (!module.isEmpty() && (module.contains(term) || term.contains(module))) best = Math.max(best, 28);
        if (fold(feature.purpose()).contains(term)) best = Math.max(best, 25);
        return best;
    }

    /** Share of the term's character pairs that the name also contains. */
    static double bigramShare(String term, String name) {
        Set<String> wanted = bigrams(term);
        if (wanted.isEmpty()) return 0;
        Set<String> have = bigrams(name);
        long shared = wanted.stream().filter(have::contains).count();
        return (double) shared / wanted.size();
    }

    private static Set<String> bigrams(String text) {
        Set<String> pairs = new HashSet<>();
        for (int i = 0; i + 1 < text.length(); i++) pairs.add(text.substring(i, i + 2));
        return pairs;
    }

    private static List<Feature> read(ObjectMapper json) {
        try (InputStream in = AiChatFeatureDirectory.class.getClassLoader().getResourceAsStream(RESOURCE)) {
            if (in == null) {
                log.warn("AI feature directory {} is missing: the directory and access tools are not offered", RESOURCE);
                return List.of();
            }
            return parse(json.readTree(in));
        } catch (IOException unreadable) {
            log.warn("AI feature directory {} could not be read: the directory and access tools are not offered", RESOURCE);
            return List.of();
        }
    }

    static List<Feature> parse(JsonNode root) {
        List<Feature> parsed = new ArrayList<>();
        for (JsonNode item : root.path("features")) {
            List<List<String>> paths = new ArrayList<>();
            for (JsonNode path : item.path("paths")) paths.add(texts(path));
            JsonNode any = item.path("anyOf");
            parsed.add(new Feature(item.path("route").asText(""), item.path("title").asText(""), texts(item.path("aliases")),
                    item.path("module").asText(""), item.path("purpose").asText(""), List.copyOf(paths),
                    item.path("parent").isTextual() ? item.path("parent").asText() : null, item.path("record").asBoolean(false),
                    any.isArray() ? texts(any) : null, texts(item.path("allOf")), texts(item.path("hubOf"))));
        }
        return List.copyOf(parsed);
    }

    private static List<String> texts(JsonNode values) {
        List<String> out = new ArrayList<>();
        for (JsonNode value : values) if (value.isTextual() && !value.asText().isBlank()) out.add(value.asText());
        return List.copyOf(out);
    }
}
