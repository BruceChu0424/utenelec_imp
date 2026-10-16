package com.uten.imp.common.util;

import jakarta.persistence.Query;
import jakarta.persistence.criteria.CriteriaBuilder;
import jakarta.persistence.criteria.CriteriaQuery;
import jakarta.persistence.criteria.Expression;
import jakarta.persistence.criteria.Order;
import jakarta.persistence.criteria.Predicate;
import jakarta.persistence.criteria.Root;
import org.springframework.data.domain.Sort;

import java.util.ArrayDeque;
import java.util.ArrayList;
import java.util.Collection;
import java.util.HashMap;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Map;
import java.util.Locale;
import java.util.Set;
import java.util.UUID;
import java.util.stream.IntStream;

/** One authoritative category-or-record match, before pagination and without broadening the caller's access scope. */
public final class CategoryKeywordSearch {
    private CategoryKeywordSearch() {}

    public record Node(UUID id, UUID parentId, String name, String code) {}

    public static Plan plan(String query, Collection<Node> nodes) { return new Plan(query, nodes); }

    public static final class Plan {
        private final String query;
        private final List<String> terms;
        private final Map<String, Set<UUID>> contains = new HashMap<>();
        private final Map<String, Set<UUID>> prefix = new HashMap<>();
        private final Set<UUID> exact;

        private Plan(String query, Collection<Node> nodes) {
            this.query = query;
            terms = KeywordSearch.terms(query);
            Map<UUID, List<UUID>> children = new HashMap<>();
            for (Node node : nodes) children.computeIfAbsent(node.parentId(), ignored -> new ArrayList<>()).add(node.id());
            for (String term : terms) {
                contains.put(term, branches(nodes, children, term, 2));
                prefix.put(term, branches(nodes, children, term, 1));
            }
            exact = terms.isEmpty() ? Set.of() : branches(nodes, children, KeywordSearch.phrase(query), 0);
        }

        public boolean active() { return !terms.isEmpty(); }

        public Set<UUID> containingCategories(String term) { return contains.getOrDefault(term, Set.of()); }

        /** Search metadata for merging more than 32 authorized category roots across request batches. */
        public int rankValue(UUID category, String code, String name, List<String> visible) {
            int nameRank = fieldRank(name);
            if (nameRank < 4) return nameRank;
            int codeRank = fieldRank(code);
            if (codeRank < 4) return 4 + codeRank;
            for (int mode = 0; mode < 3; mode++) {
                final int tier = mode;
                if (visible.stream().anyMatch(value -> fieldRank(value) == tier)) return 8 + mode;
            }
            if (matchesWords(null, visible, false)) return 11;
            if (category != null && exact.contains(category)) return 12;
            if (matchesWords(category, visible, true)) return 13;
            return matchesWords(category, visible, false) ? 14 : 15;
        }

        private int fieldRank(String value) {
            String phrase = KeywordSearch.phrase(query);
            String normalized = value == null ? "" : value.toLowerCase(Locale.ROOT);
            if (sqlTrimLower(value).equals(phrase)) return 0;
            if (normalized.startsWith(phrase)) return 1;
            if (normalized.contains(phrase)) return 2;
            return terms.stream().allMatch(normalized::contains) ? 3 : 4;
        }

        private boolean matchesWords(UUID category, List<String> fields, boolean startsWith) {
            for (String term : terms) {
                Set<UUID> ids = (startsWith ? prefix : contains).get(term);
                if (category != null && ids.contains(category)) continue;
                if (fields.stream().filter(java.util.Objects::nonNull).map(value -> value.toLowerCase(Locale.ROOT))
                        .noneMatch(value -> startsWith ? value.startsWith(term) : value.contains(term))) return false;
            }
            return true;
        }

        public Predicate predicate(CriteriaBuilder cb, Expression<UUID> category,
                                   List<Expression<String>> visible, List<Expression<String>> secondary) {
            List<Expression<String>> all = new ArrayList<>(visible);
            all.addAll(secondary);
            return words(cb, category, all, false);
        }

        public Expression<Integer> rank(CriteriaBuilder cb, Expression<UUID> category,
                                        Expression<String> code, Expression<String> name,
                                        List<Expression<String>> visible) {
            return KeywordSearch.rank(cb,
                    KeywordSearch.exact(cb, name, query), phraseLike(cb, name, true), phraseLike(cb, name, false),
                    fieldWords(cb, List.of(name)),
                    KeywordSearch.exact(cb, code, query), phraseLike(cb, code, true), phraseLike(cb, code, false),
                    fieldWords(cb, List.of(code)),
                    cb.or(visible.stream().map(field -> KeywordSearch.exact(cb, field, query)).toArray(Predicate[]::new)),
                    cb.or(visible.stream().map(field -> phraseLike(cb, field, true)).toArray(Predicate[]::new)),
                    cb.or(visible.stream().map(field -> phraseLike(cb, field, false)).toArray(Predicate[]::new)),
                    fieldWords(cb, visible),
                    categories(cb, category, exact), words(cb, category, visible, true), words(cb, category, visible, false));
        }

        private Predicate phraseLike(CriteriaBuilder cb, Expression<String> field, boolean startsWith) {
            String phrase = KeywordSearch.phrase(query);
            return cb.like(cb.lower(field), startsWith ? KeywordSearch.prefixPattern(phrase) : KeywordSearch.containsPattern(phrase), '\\');
        }

        private Predicate fieldWords(CriteriaBuilder cb, List<Expression<String>> fields) {
            List<Predicate> required = new ArrayList<>();
            for (String term : terms) required.add(cb.or(fields.stream()
                    .map(field -> cb.like(cb.lower(field), KeywordSearch.containsPattern(term), '\\')).toArray(Predicate[]::new)));
            return cb.and(required.toArray(Predicate[]::new));
        }

        private Predicate words(CriteriaBuilder cb, Expression<UUID> category,
                                List<Expression<String>> fields, boolean startsWith) {
            List<Predicate> required = new ArrayList<>();
            for (String term : terms) {
                List<Predicate> alternatives = new ArrayList<>();
                String pattern = startsWith ? KeywordSearch.prefixPattern(term) : KeywordSearch.containsPattern(term);
                for (Expression<String> field : fields) alternatives.add(cb.like(cb.lower(field), pattern, '\\'));
                alternatives.add(categories(cb, category, (startsWith ? prefix : contains).get(term)));
                required.add(cb.or(alternatives.toArray(Predicate[]::new)));
            }
            return cb.and(required.toArray(Predicate[]::new));
        }
    }

    private static Predicate categories(CriteriaBuilder cb, Expression<UUID> category, Set<UUID> ids) {
        return ids.isEmpty() ? cb.disjunction() : category.in(ids);
    }

    private static Set<UUID> branches(Collection<Node> nodes, Map<UUID, List<UUID>> children, String query, int mode) {
        Set<UUID> result = new LinkedHashSet<>();
        ArrayDeque<UUID> pending = new ArrayDeque<>();
        for (Node node : nodes) {
            if (matches(node.name(), query, mode) || matches(node.code(), query, mode)) pending.add(node.id());
        }
        while (!pending.isEmpty()) {
            UUID id = pending.remove();
            if (result.add(id)) pending.addAll(children.getOrDefault(id, List.of()));
        }
        return Set.copyOf(result);
    }

    private static boolean matches(String value, String query, int mode) {
        String normalized = value == null ? "" : value.toLowerCase(Locale.ROOT);
        return switch (mode) {
            case 0 -> sqlTrimLower(value).equals(query);
            case 1 -> normalized.startsWith(query);
            default -> normalized.contains(query);
        };
    }

    /** Match PostgreSQL btrim(text): retain interior whitespace and non-space characters. */
    private static String sqlTrimLower(String value) {
        if (value == null) return "";
        int start = 0, end = value.length();
        while (start < end && value.charAt(start) == ' ') start++;
        while (end > start && value.charAt(end - 1) == ' ') end--;
        return value.substring(start, end).toLowerCase(Locale.ROOT);
    }

    /** Pageable must be unsorted for a ranked query so Spring Data preserves these orders. */
    public static void order(CriteriaQuery<?> query, CriteriaBuilder cb, Root<?> root,
                             Expression<Integer> rank, Sort tieBreak) {
        if (query == null || query.getResultType() == Long.class || query.getResultType() == long.class) return;
        List<Order> orders = new ArrayList<>();
        orders.add(cb.asc(rank));
        for (Sort.Order item : tieBreak) orders.add(item.isAscending() ? cb.asc(root.get(item.getProperty())) : cb.desc(root.get(item.getProperty())));
        if (tieBreak.getOrderFor("id") == null) orders.add(cb.asc(root.get("id")));
        query.orderBy(orders);
    }

    /** SQL identifiers are application-owned constants; every user value is a bound parameter. */
    public static String nativeCondition(String text, String parameter, String table, String category,
                                         String... fields) {
        return nativeWords(text, parameter, table, category, false, fields);
    }

    private static String nativeWords(String text, String parameter, String table, String category,
                                      boolean startsWith, String... fields) {
        List<String> terms = KeywordSearch.terms(text);
        return IntStream.range(0, terms.size()).mapToObj(index -> {
            String name = parameter + (startsWith ? "Prefix" : "") + (index == 0 ? "" : index);
            List<String> alternatives = new ArrayList<>();
            for (String field : fields) alternatives.add(field + " ILIKE :" + name + " ESCAPE '\\'");
            alternatives.add(nativeBranch(table, category, "(name ILIKE :" + name + " ESCAPE '\\' OR code ILIKE :" + name + " ESCAPE '\\')"));
            return "(" + String.join(" OR ", alternatives) + ")";
        }).collect(java.util.stream.Collectors.joining(" AND "));
    }

    public static String nativeRank(String text, String parameter, String table, String category,
                                    String code, String name, String... visibleFields) {
        if (KeywordSearch.terms(text).isEmpty()) return KeywordSearch.INACTIVE_NATIVE_RANK;
        List<String> tiers = new ArrayList<>();
        addFieldRanks(tiers, text, parameter, name);
        addFieldRanks(tiers, text, parameter, code);
        tiers.add(java.util.Arrays.stream(visibleFields).map(field -> "lower(btrim(" + field + "))=:" + parameter + "Phrase").collect(java.util.stream.Collectors.joining(" OR ", "(", ")")));
        tiers.add(phraseFields(parameter, true, visibleFields));
        tiers.add(phraseFields(parameter, false, visibleFields));
        tiers.add(KeywordSearch.nativeCondition(text, parameter, visibleFields));
        tiers.add(nativeBranch(table, category, "(lower(btrim(name))=:" + parameter + "Phrase OR lower(btrim(code))=:" + parameter + "Phrase)"));
        tiers.add(nativeWords(text, parameter, table, category, true, visibleFields));
        tiers.add(nativeWords(text, parameter, table, category, false, visibleFields));
        StringBuilder result = new StringBuilder("CASE");
        for (int i = 0; i < tiers.size(); i++) result.append(" WHEN ").append(tiers.get(i)).append(" THEN ").append(i);
        return result.append(" ELSE 15 END").toString();
    }

    private static void addFieldRanks(List<String> tiers, String text, String parameter, String field) {
        tiers.add("lower(btrim(" + field + "))=:" + parameter + "Phrase");
        tiers.add(phraseFields(parameter, true, field));
        tiers.add(phraseFields(parameter, false, field));
        tiers.add(KeywordSearch.nativeCondition(text, parameter, field));
    }

    private static String phraseFields(String parameter, boolean prefix, String... fields) {
        return java.util.Arrays.stream(fields).map(field -> field + " ILIKE :" + parameter
                + (prefix ? "PhrasePrefix" : "PhraseContains") + " ESCAPE '\\'")
                .collect(java.util.stream.Collectors.joining(" OR ", "(", ")"));
    }

    public static Map<String, Object> rankParameters(String text, String prefix) {
        Map<String, Object> result = new HashMap<>(KeywordSearch.nativeRankParameters(text, prefix));
        String phrase = KeywordSearch.phrase(text);
        result.put(prefix + "PhrasePrefix", KeywordSearch.prefixPattern(phrase));
        result.put(prefix + "PhraseContains", KeywordSearch.containsPattern(phrase));
        return result;
    }

    public static String nativeBranch(String table, String category, String seedPredicate) {
        return category + " IN (WITH RECURSIVE keyword_category AS ("
                + "SELECT id FROM " + table + " WHERE is_deleted=false AND " + seedPredicate
                + " UNION SELECT child.id FROM " + table + " child JOIN keyword_category parent ON child.parent_id=parent.id WHERE child.is_deleted=false"
                + ") SELECT id FROM keyword_category)";
    }

    public static void bindNative(Query query, String text, String prefix, boolean includeRank) {
        KeywordSearch.bindNative(query, text, prefix);
        if (includeRank) bindRank(query, text, prefix);
    }

    public static void bindRank(Query query, String text, String prefix) {
        if (KeywordSearch.terms(text).isEmpty()) return;
        for (var entry : rankParameters(text, prefix).entrySet()) {
            if (!entry.getKey().equals(prefix) && !entry.getKey().matches(java.util.regex.Pattern.quote(prefix) + "\\d+")) {
                query.setParameter(entry.getKey(), entry.getValue());
            }
        }
    }
}
