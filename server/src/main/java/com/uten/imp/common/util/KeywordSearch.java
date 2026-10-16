package com.uten.imp.common.util;

import jakarta.persistence.criteria.CriteriaBuilder;
import jakarta.persistence.criteria.Expression;
import jakarta.persistence.criteria.Predicate;
import jakarta.persistence.Query;

import java.util.Arrays;
import java.util.List;
import java.util.Locale;
import java.util.LinkedHashMap;
import java.util.Map;
import java.util.stream.IntStream;

/** Ordinary search: every whitespace-separated word must match at least one field. */
public final class KeywordSearch {
    /** A numeric expression, never PostgreSQL's ordinal ORDER BY syntax. */
    public static final String INACTIVE_NATIVE_RANK = "CAST(0 AS integer)";

    private KeywordSearch() {}

    public static List<String> terms(String query) {
        if (query == null || query.isBlank()) return List.of();
        return Arrays.stream(query.toLowerCase(Locale.ROOT).split("(?U)\\s+"))
                .filter(term -> !term.isEmpty()).distinct().toList();
    }

    public static String phrase(String query) {
        return query == null ? "" : query.toLowerCase(Locale.ROOT).replaceAll("(?U)\\s+", " ").trim();
    }

    public static boolean matches(String text, String... fields) {
        return terms(text).stream().allMatch(word -> Arrays.stream(fields)
                .filter(java.util.Objects::nonNull).anyMatch(value -> value.toLowerCase(Locale.ROOT).contains(word)));
    }

    /** Name tiers first, then each real identity field in declared business priority. */
    public static int rankValue(String text, String name, String... fields) {
        if (terms(text).isEmpty()) return 0;
        int rank = fieldRankValue(text, name);
        if (rank < 4) return rank;
        for (int index = 0; index < fields.length; index++) {
            rank = fieldRankValue(text, fields[index]);
            if (rank < 4) return 4 + index * 4 + rank;
        }
        return 4 + fields.length * 4;
    }

    private static int fieldRankValue(String text, String value) {
        if (value == null) return 4;
        String normalized = value.toLowerCase(Locale.ROOT), phrase = phrase(text);
        // PostgreSQL btrim removes ASCII spaces only; never collapse field contents.
        int start = 0, end = normalized.length();
        while (start < end && normalized.charAt(start) == ' ') start++;
        while (end > start && normalized.charAt(end - 1) == ' ') end--;
        if (normalized.substring(start, end).equals(phrase)) return 0;
        if (normalized.startsWith(phrase)) return 1;
        if (normalized.contains(phrase)) return 2;
        return terms(text).stream().allMatch(normalized::contains) ? 3 : 4;
    }

    /** Treat SQL wildcard characters as literal input, including the escape character itself. */
    public static String containsPattern(String term) {
        return "%" + escape(term) + "%";
    }

    public static String prefixPattern(String term) {
        return escape(term) + "%";
    }

    private static String escape(String term) {
        return term.replace("\\", "\\\\").replace("%", "\\%").replace("_", "\\_");
    }

    public static Predicate exact(CriteriaBuilder cb, Expression<String> field, String query) {
        return cb.equal(cb.lower(cb.trim(field)), phrase(query));
    }

    /** First matching tier wins; the fallback is the number of supplied tiers. */
    public static Expression<Integer> rank(CriteriaBuilder cb, Predicate... tiers) {
        if (tiers.length == 0) return cb.literal(0);
        CriteriaBuilder.Case<Integer> result = cb.selectCase();
        for (int index = 0; index < tiers.length; index++) result = result.when(tiers[index], index);
        return result.otherwise(tiers.length);
    }

    public static String nativeRank(String text, String prefix, String... fields) {
        if (terms(text).isEmpty()) return INACTIVE_NATIVE_RANK;
        StringBuilder result = new StringBuilder("CASE");
        for (int index = 0; index < fields.length; index++) {
            result.append(" WHEN lower(btrim(").append(fields[index]).append(")) = :")
                    .append(prefix).append("Phrase THEN ").append(index);
        }
        result.append(" WHEN ").append(nativeWords(text, prefix + "Prefix", fields))
                .append(" THEN ").append(fields.length)
                .append(" WHEN ").append(nativeCondition(text, prefix, fields))
                .append(" THEN ").append(fields.length + 1)
                .append(" ELSE ").append(fields.length + 2).append(" END");
        return result.toString();
    }

    /** Extra parameters are allowed by NamedParameterJdbcTemplate; JPA callers bind only those present in SQL. */
    public static Map<String, Object> nativeRankParameters(String text, String prefix) {
        Map<String, Object> parameters = new LinkedHashMap<>();
        List<String> words = terms(text);
        for (int index = 0; index < words.size(); index++) {
            parameters.put(parameterName(prefix, index), containsPattern(words.get(index)));
            parameters.put(parameterName(prefix + "Prefix", index), prefixPattern(words.get(index)));
        }
        if (!words.isEmpty()) parameters.put(prefix + "Phrase", phrase(text));
        return parameters;
    }

    /** Field expressions and parameter prefix must be fixed application-owned SQL fragments. */
    public static String nativeCondition(String query, String prefix, String... fields) {
        return nativeWords(query, prefix, fields);
    }

    private static String nativeWords(String query, String prefix, String... fields) {
        List<String> words = terms(query);
        return IntStream.range(0, words.size()).mapToObj(index -> "(" +
                String.join(" OR ", Arrays.stream(fields)
                        .map(field -> field + " ILIKE :" + parameterName(prefix, index) + " ESCAPE '\\'")
                        .toList()) + ")").collect(java.util.stream.Collectors.joining(" AND "));
    }

    public static void bindNative(Query query, String text, String prefix) {
        List<String> words = terms(text);
        for (int index = 0; index < words.size(); index++) {
            query.setParameter(parameterName(prefix, index), containsPattern(words.get(index)));
        }
    }

    public static void bindNative(Map<String, Object> parameters, String text, String prefix) {
        List<String> words = terms(text);
        for (int index = 0; index < words.size(); index++) {
            parameters.put(parameterName(prefix, index), containsPattern(words.get(index)));
        }
    }

    private static String parameterName(String prefix, int index) {
        return index == 0 ? prefix : prefix + index;
    }

    @SafeVarargs
    public static Predicate allTerms(CriteriaBuilder cb, String query, Expression<String>... fields) {
        List<Predicate> words = terms(query).stream().map(term -> {
            String pattern = containsPattern(term);
            Predicate[] alternatives = Arrays.stream(fields)
                    .map(field -> cb.like(cb.lower(field), pattern, '\\'))
                    .toArray(Predicate[]::new);
            return cb.or(alternatives);
        }).toList();
        return cb.and(words.toArray(Predicate[]::new));
    }
}
