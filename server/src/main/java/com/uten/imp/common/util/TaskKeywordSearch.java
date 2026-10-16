package com.uten.imp.common.util;

import jakarta.persistence.Query;

import java.util.LinkedHashMap;
import java.util.Map;
import java.util.List;
import java.util.Arrays;
import java.util.Collections;

/** Shared native task search. SQL expressions are fixed application-owned fragments. */
public final class TaskKeywordSearch {
    private static final String PREFIX = "taskKeyword";
    private TaskKeywordSearch() { }

    public static String condition(String text, String... fields) {
        String condition = KeywordSearch.nativeCondition(text, PREFIX, fields);
        return condition.isEmpty() ? "TRUE" : condition;
    }

    /** Keep complete item identities before aggregation, so a partial name never ranks as exact. */
    public static String rank(String text, String[] fields, String... arrayFields) {
        if (KeywordSearch.terms(text).isEmpty()) return "0";
        var prefixTerms = new java.util.ArrayList<String>();
        for (int index = 0; index < KeywordSearch.terms(text).size(); index++) {
            String parameter = ":" + PREFIX + "Prefix" + (index == 0 ? "" : index);
            prefixTerms.add(prefixMatch(fields, arrayFields, value -> value + " ILIKE " + parameter + " ESCAPE '\\'"));
        }
        return rankExpression(":" + PREFIX + "Phrase", fields, arrayFields, String.join(" AND ", prefixTerms));
    }

    /** A visible goods name outranks document/code matches, before the task's normal stable order. */
    public static String rankNamesFirst(String text, String[] names, String[] nameArrays,
                                        String[] fields, String... arrayFields) {
        if (KeywordSearch.terms(text).isEmpty()) return "0";
        String phrase = ":" + PREFIX + "Phrase";
        String allWords = prefixMatch(names, nameArrays, field -> {
            var predicates = new java.util.ArrayList<String>();
            for (int index = 0; index < KeywordSearch.terms(text).size(); index++) {
                predicates.add(field + " ILIKE :" + PREFIX + (index == 0 ? "" : index) + " ESCAPE '\\'");
            }
            return "(" + String.join(" AND ", predicates) + ")";
        });
        return namesFirst(phrase, names, nameArrays, allWords, rank(text, fields, arrayFields));
    }

    private static String namesFirst(String phrase, String[] names, String[] arrays, String allWords, String fallback) {
        String exact = prefixMatch(names, arrays, field -> "lower(btrim(" + field + "))=" + phrase);
        String prefix = prefixMatch(names, arrays, field -> "left(lower(COALESCE(" + field + ",'')),length(" + phrase + "))=" + phrase);
        String contains = prefixMatch(names, arrays, field -> "POSITION(" + phrase + " IN lower(COALESCE(" + field + ",'')))>0");
        return "CASE WHEN " + exact + " THEN 0 WHEN " + prefix + " THEN 1 WHEN " + contains
                + " THEN 2 WHEN " + allWords + " THEN 3 ELSE 4+(" + fallback + ") END";
    }

    private static String rankExpression(String phrase, String[] fields, String[] arrayFields, String prefix) {
        StringBuilder sql = new StringBuilder("CASE");
        int tier = 0;
        for (String field : fields) {
            sql.append(" WHEN lower(btrim(").append(field).append("))=")
                    .append(phrase).append(" THEN ").append(tier++);
        }
        for (String field : arrayFields) {
            sql.append(" WHEN EXISTS (SELECT 1 FROM unnest(COALESCE(").append(field)
                    .append(",ARRAY[]::text[])) AS task_identity(value) WHERE lower(btrim(task_identity.value))=")
                    .append(phrase).append(") THEN ").append(tier++);
        }
        sql.append(" WHEN ").append(prefix).append(" THEN ").append(tier++);
        return sql.append(" ELSE ").append(tier).append(" END").toString();
    }

    private static String prefixMatch(String[] fields, String[] arrays, java.util.function.Function<String,String> predicate) {
        var conditions = new java.util.ArrayList<String>();
        for (String field : fields) conditions.add(predicate.apply(field));
        for (String field : arrays) conditions.add("EXISTS (SELECT 1 FROM unnest(COALESCE(" + field
                + ",ARRAY[]::text[])) AS task_prefix(value) WHERE " + predicate.apply("task_prefix.value") + ")");
        return "(" + String.join(" OR ", conditions) + ")";
    }

    /** Fixed-shape native queries retain one keyword parameter across rows/counts/facets. */
    public static String conditionParameter(String parameter, String... fields) {
        String match = String.join(" OR ", Arrays.stream(fields)
                .map(field -> "POSITION(task_word.value IN lower(COALESCE(" + field + ",'')))>0").toList());
        return "NOT EXISTS (SELECT 1 FROM regexp_split_to_table(lower(COALESCE(CAST(:" + parameter
                + " AS text),'')), '[[:space:]]+') AS task_word(value) WHERE task_word.value<>'' AND NOT ("
                + match + "))";
    }

    public static String rankParameter(String parameter, String[] fields, String... arrayFields) {
        String alternatives = prefixMatch(fields, arrayFields,
                field -> "left(lower(COALESCE(" + field + ",'')),length(task_word.value))=task_word.value");
        String prefix = "NOT EXISTS (SELECT 1 FROM regexp_split_to_table(lower(COALESCE(CAST(:" + parameter
                + " AS text),'')), '[[:space:]]+') AS task_word(value) WHERE task_word.value<>'' AND NOT " + alternatives + ")";
        String expression = rankExpression("lower(btrim(COALESCE(CAST(:" + parameter + " AS text),'')))", fields, arrayFields, prefix);
        return "CASE WHEN COALESCE(CAST(:" + parameter + " AS text),'')='' THEN 0 ELSE " + expression + " END";
    }

    public static String rankNamesFirstParameter(String parameter, String[] names, String[] nameArrays,
                                                 String[] fields, String... arrayFields) {
        String phrase = "lower(btrim(COALESCE(CAST(:" + parameter + " AS text),'')))";
        String allWords = prefixMatch(names, nameArrays, field ->
                "NOT EXISTS (SELECT 1 FROM regexp_split_to_table(" + phrase
                        + ", '[[:space:]]+') AS name_word(value) WHERE name_word.value<>'' AND POSITION(name_word.value IN lower(COALESCE("
                        + field + ",'')))=0)");
        return "CASE WHEN " + phrase + "='' THEN 0 ELSE "
                + namesFirst(phrase, names, nameArrays, allWords, rankParameter(parameter, fields, arrayFields)) + " END";
    }

    /** Positional JDBC variant; arguments are appended in the same operation as SQL construction. */
    public static String rankNamesFirstPositional(String text, List<Object> args, String[] names, String... fields) {
        if (KeywordSearch.terms(text).isEmpty()) return "";
        StringBuilder sql = new StringBuilder("CASE");
        for (int mode = 0; mode < 4; mode++) {
            var alternatives = new java.util.ArrayList<String>();
            for (String name : names) {
                if (mode == 0) {
                    alternatives.add("lower(btrim(" + name + "))=?");
                    args.add(KeywordSearch.phrase(text));
                } else if (mode < 3) {
                    alternatives.add(name + " ILIKE ? ESCAPE '\\'");
                    args.add(mode == 1 ? KeywordSearch.prefixPattern(KeywordSearch.phrase(text))
                            : KeywordSearch.containsPattern(KeywordSearch.phrase(text)));
                } else {
                    alternatives.add("(" + String.join(" AND ", Collections.nCopies(KeywordSearch.terms(text).size(), name + " ILIKE ? ESCAPE '\\'")) + ")");
                    for (String term : KeywordSearch.terms(text)) args.add(KeywordSearch.containsPattern(term));
                }
            }
            sql.append(" WHEN (").append(String.join(" OR ", alternatives)).append(") THEN ").append(mode);
        }
        String fallback = rankPositional(text, fields);
        appendRank(args, text, fields.length);
        return sql.append(" ELSE 4+(").append(fallback).append(") END").toString();
    }

    public static String conditionPositional(String text, String... fields) {
        String alternative = "(" + String.join(" OR ", Arrays.stream(fields)
                .map(field -> field + " ILIKE ? ESCAPE '\\'").toList()) + ")";
        return String.join(" AND ", Collections.nCopies(KeywordSearch.terms(text).size(), alternative));
    }

    public static void appendContains(List<Object> args, String text, int fields) {
        for (String word : KeywordSearch.terms(text)) {
            for (int index = 0; index < fields; index++) args.add(KeywordSearch.containsPattern(word));
        }
    }

    public static String rankPositional(String text, String... fields) {
        if (KeywordSearch.terms(text).isEmpty()) return "";
        var sql = new StringBuilder("CASE");
        for (int index = 0; index < fields.length; index++) {
            sql.append(" WHEN lower(btrim(").append(fields[index]).append("))=? THEN ").append(index);
        }
        String alternative = "(" + String.join(" OR ", Arrays.stream(fields)
                .map(field -> field + " ILIKE ? ESCAPE '\\'").toList()) + ")";
        sql.append(" WHEN ").append(String.join(" AND ", Collections.nCopies(KeywordSearch.terms(text).size(), alternative)))
                .append(" THEN ").append(fields.length);
        return sql.append(" ELSE ").append(fields.length + 1).append(" END").toString();
    }

    public static void appendRank(List<Object> args, String text, int fields) {
        if (!KeywordSearch.terms(text).isEmpty()) {
            for (int index = 0; index < fields; index++) args.add(KeywordSearch.phrase(text));
            for (String word : KeywordSearch.terms(text)) {
                for (int index = 0; index < fields; index++) args.add(KeywordSearch.prefixPattern(word));
            }
        }
    }

    public static Map<String, Object> parameters(String text) {
        var values = new LinkedHashMap<String, Object>();
        var words = KeywordSearch.terms(text);
        for (int index = 0; index < words.size(); index++) {
            values.put(index == 0 ? PREFIX : PREFIX + index, KeywordSearch.containsPattern(words.get(index)));
            values.put(PREFIX + "Prefix" + (index == 0 ? "" : index), KeywordSearch.prefixPattern(words.get(index)));
        }
        if (!words.isEmpty()) values.put(PREFIX + "Phrase", KeywordSearch.phrase(text));
        return values;
    }

    public static void bind(Query query, String text, boolean ranked) {
        parameters(text).forEach((key, value) -> {
            if (ranked || (!key.endsWith("Phrase") && !key.contains("Prefix"))) query.setParameter(key, value);
        });
    }
}
