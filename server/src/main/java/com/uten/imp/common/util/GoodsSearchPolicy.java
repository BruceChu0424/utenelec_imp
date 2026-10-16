package com.uten.imp.common.util;
import jakarta.persistence.criteria.CriteriaBuilder;
import jakarta.persistence.criteria.Expression;
import jakarta.persistence.criteria.Predicate;

import java.util.ArrayDeque;
import java.util.ArrayList;
import java.util.Collection;
import java.util.HashMap;
import java.util.LinkedHashMap;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.Set;
import java.util.UUID;

/** Goods identity/category search, with explicitly requested descriptive matches after every primary match. */
public final class GoodsSearchPolicy {
    public static final int RELATED_RANK_OFFSET = 100;
    public enum SubjectMode { STRICT, PREFER }
    private static final String NAME_CUT_PATTERN = "[\\(（\\[【].*$";
    private static final String NAME_SPACE_PATTERN = nameSpacePattern();
    private static final String SIZE_SEGMENT = "[mφø]?[0-9]+(?:\\.[0-9]+)?(?: *[x×*] *[mφø]?[0-9]+(?:\\.[0-9]+)?){0,3}(?: *(?:mm|cm|m|in|寸))?";
    private final String query;
    private final CategoryKeywordSearch.Plan identity;
    private final CategoryKeywordSearch.Plan remaining;
    private final String remainingQuery;
    private final List<Set<UUID>> intentScopes;
    private final List<SubjectProof> subjectProofs;
    private final boolean includeRelated;
    private final SubjectMode subjectMode;

    public GoodsSearchPolicy(String query, Collection<CategoryKeywordSearch.Node> nodes,
                             boolean inferCategoryIntent, boolean includeRelated) {
        this(query, nodes, inferCategoryIntent, includeRelated, SubjectMode.STRICT);
    }

    public GoodsSearchPolicy(String query, Collection<CategoryKeywordSearch.Node> nodes,
                             boolean inferCategoryIntent, boolean includeRelated, SubjectMode subjectMode) {
        this.query = query;
        this.identity = CategoryKeywordSearch.plan(query, nodes);
        this.includeRelated = includeRelated;
        this.subjectMode = java.util.Objects.requireNonNull(subjectMode);
        Map<String, Set<UUID>> intents = new LinkedHashMap<>();
        if (inferCategoryIntent && active()) {
            String phrase = KeywordSearch.phrase(query);
            Set<UUID> whole = intentBranch(phrase, nodes);
            if (!whole.isEmpty()) {
                intents.put(phrase, whole);
            } else {
                for (String term : KeywordSearch.terms(query)) {
                    Set<UUID> ids = intentBranch(term, nodes);
                    if (!ids.isEmpty()) intents.put(term, ids);
                }
            }
        }
        if (intents.size() > 1) {
            Set<UUID> common = new LinkedHashSet<>(intents.values().iterator().next());
            intents.values().forEach(common::retainAll);
            // Separate category subjects do not establish one clear product
            // kind. Keep ordinary cross-field/category AND search available.
            if (common.isEmpty()) intents.clear();
        }
        intentScopes = List.copyOf(intents.values());
        subjectProofs = intents.keySet().stream().map(token -> {
            String rest = token.equals(KeywordSearch.phrase(query)) ? "" : String.join(" ",
                    KeywordSearch.terms(query).stream().filter(term -> !term.equals(token)).toList());
            List<String> aliases = java.util.stream.Stream.of(token, subject(token)).filter(value -> !value.isEmpty()).distinct().toList();
            String noun = subject(token);
            String nounPattern = !noun.isEmpty() && noun.codePoints().allMatch(c -> Character.UnicodeScript.of(c) == Character.UnicodeScript.HAN)
                    ? "^.*" + noun + "(?: *" + SIZE_SEGMENT + ")?$" : null;
            return new SubjectProof(aliases, rest, CategoryKeywordSearch.plan(rest, nodes), nounPattern);
        }).toList();
        remainingQuery = intents.containsKey(KeywordSearch.phrase(query)) ? ""
                : String.join(" ", KeywordSearch.terms(query).stream().filter(term -> !intents.containsKey(term)).toList());
        remaining = intentScopes.isEmpty() ? identity : CategoryKeywordSearch.plan(remainingQuery, nodes);
    }

    public boolean active() { return identity.active(); }

    public boolean hasCategoryIntent() { return !intentScopes.isEmpty(); }

    public Predicate primary(CriteriaBuilder cb, Expression<UUID> category,
                             Expression<String> code, Expression<String> name,
                             List<Expression<String>> visible) {
        if (!active()) return cb.conjunction();
        Predicate words = identity.predicate(cb, category, visible, List.of());
        if (hasCategoryIntent()) {
            Predicate preferred = preferred(cb, category, code, name, visible);
            words = subjectMode == SubjectMode.STRICT ? preferred : cb.or(words, preferred);
        }
        return definite(cb, cb.or(KeywordSearch.exact(cb, name, query), KeywordSearch.exact(cb, code, query), words));
    }

    public Predicate predicate(CriteriaBuilder cb, Expression<UUID> category,
                               Expression<String> code, Expression<String> name,
                               List<Expression<String>> visible, List<Expression<String>> descriptions) {
        Predicate primary = primary(cb, category, code, name, visible);
        if (!active() || !includeRelated) return primary;
        Predicate full = identity.predicate(cb, category, visible, descriptions);
        if (hasCategoryIntent()) full = cb.or(full,
                cb.and(intent(cb, category), remaining.predicate(cb, category, visible, descriptions)),
                subjectMatches(cb, category, code, name, visible, descriptions, true));
        // COALESCE is necessary: a record with nullable identity fields may match
        // only its description; SQL NOT UNKNOWN must not silently discard it.
        Predicate related = cb.and(definite(cb, full), cb.not(primary));
        return cb.or(primary, related);
    }

    public Expression<Integer> rank(CriteriaBuilder cb, Expression<UUID> category,
                                    Expression<String> code, Expression<String> name,
                                    List<Expression<String>> visible) {
        if (!active()) return cb.literal(0);
        Expression<Integer> base = identity.rank(cb, category, code, name, visible);
        var rank = cb.<Integer>selectCase()
                .when(KeywordSearch.exact(cb, name, query), 0)
                .when(KeywordSearch.exact(cb, code, query), 1);
        if (hasCategoryIntent()) rank = rank.when(subjectMatches(cb, category, code, name, visible, List.of(), false), 2);
        if (subjectMode == SubjectMode.PREFER && hasCategoryIntent()) {
            rank = rank.when(preferred(cb, category, code, name, visible), cb.sum(base, 2));
        }
        return rank.when(primary(cb, category, code, name, visible), cb.sum(base,
                        subjectMode == SubjectMode.PREFER && hasCategoryIntent() ? 20 : 2))
                .otherwise(cb.sum(base, RELATED_RANK_OFFSET));
    }

    public int rankValue(UUID category, String code, String name, List<String> visible) {
        if (!active()) return 0;
        if (exact(name)) return 0;
        if (exact(code)) return 1;
        if (hasCategoryIntent() && hasSubjectProof(category, code, name, visible, false)) return 2;
        int offset = !isPrimary(category, code, name, visible) ? RELATED_RANK_OFFSET
                : subjectMode == SubjectMode.PREFER && hasCategoryIntent() && !isPreferred(category, code, name, visible) ? 20 : 2;
        return identity.rankValue(category, code, name, visible) + offset;
    }

    /** Metadata for rows already admitted by predicate(); never a substitute for candidate filtering. */
    public String matchKind(UUID category, String code, String name, List<String> visible) {
        return active() ? (isPrimary(category, code, name, visible) ? "PRIMARY" : "RELATED") : null;
    }

    private boolean isPrimary(UUID category, String code, String name, List<String> visible) {
        if (!active() || exact(name) || exact(code)) return true;
        boolean ordinary = identity.rankValue(category, code, name, visible) < 15;
        if (!hasCategoryIntent()) return ordinary;
        return isPreferred(category, code, name, visible) || (subjectMode == SubjectMode.PREFER && ordinary);
    }

    private boolean exact(String value) {
        return exact(value, query);
    }

    private static boolean exact(String value, String text) {
        if (value == null) return false;
        int start = 0, end = value.length();
        while (start < end && value.charAt(start) == ' ') start++;
        while (end > start && value.charAt(end - 1) == ' ') end--;
        return value.substring(start, end).toLowerCase(Locale.ROOT).equals(KeywordSearch.phrase(text));
    }

    private boolean isPreferred(UUID category, String code, String name, List<String> visible) {
        if (visible.stream().anyMatch(this::exact)) return true;
        if (category != null && intentScopes.stream().allMatch(ids -> ids.contains(category))
                && (!remaining.active() || remaining.rankValue(category, code, name, visible) < 15)) return true;
        return hasSubjectProof(category, code, name, visible, true);
    }

    private boolean hasSubjectProof(UUID category, String code, String name, List<String> visible, boolean includeHead) {
        return subjectProofs.stream().anyMatch(proof -> (proof.aliases().stream().anyMatch(alias -> exact(name, alias) || exact(code, alias))
                || includeHead && proof.nounPattern() != null && java.util.regex.Pattern.matches(proof.nounPattern(), nameHead(name)))
                && (!proof.remaining().active() || proof.remaining().rankValue(category, code, name, visible) < 15));
    }

    private Predicate preferred(CriteriaBuilder cb, Expression<UUID> category, Expression<String> code,
                                Expression<String> name, List<Expression<String>> visible) {
        return definite(cb, cb.or(cb.and(intent(cb, category), remaining.predicate(cb, category, visible, List.of())),
                subjectMatches(cb, category, code, name, visible, List.of(), true),
                cb.or(visible.stream().map(field -> KeywordSearch.exact(cb, field, query)).toArray(Predicate[]::new))));
    }

    private Predicate subjectMatches(CriteriaBuilder cb, Expression<UUID> category, Expression<String> code,
                                     Expression<String> name, List<Expression<String>> visible, List<Expression<String>> descriptions, boolean includeHead) {
        List<Predicate> proofs = new ArrayList<>();
        for (SubjectProof proof : subjectProofs) {
            List<Predicate> exact = new ArrayList<>();
            for (String alias : proof.aliases()) {
                exact.add(KeywordSearch.exact(cb, name, alias));
                exact.add(KeywordSearch.exact(cb, code, alias));
            }
            if (includeHead && proof.nounPattern() != null) {
                var cut = cb.function("regexp_replace", String.class, cb.lower(cb.coalesce(name, "")),
                        cb.literal(NAME_CUT_PATTERN), cb.literal(""), cb.literal("s"));
                var head = cb.trim(cb.function("regexp_replace", String.class, cut,
                        cb.literal(NAME_SPACE_PATTERN), cb.literal(" "), cb.literal("g")));
                exact.add(cb.isTrue(cb.function("regexp_like", Boolean.class, head, cb.literal(proof.nounPattern()))));
            }
            proofs.add(cb.and(cb.or(exact.toArray(Predicate[]::new)), proof.remaining().predicate(cb, category, visible, descriptions)));
        }
        return cb.or(proofs.toArray(Predicate[]::new));
    }

    private Predicate intent(CriteriaBuilder cb, Expression<UUID> category) {
        return cb.and(intentScopes.stream().map(category::in).toArray(Predicate[]::new));
    }

    private static Predicate definite(CriteriaBuilder cb, Predicate predicate) {
        return cb.isTrue(cb.coalesce(predicate, false));
    }

    /** JDBC parity for native projections; identifiers are application-owned constants, all values are bound. */
    public NativeSearch nativeSearch(String parameter, String category, String code, String name,
                                     List<String> visible, List<String> descriptions) {
        if (!active()) return new NativeSearch("TRUE", KeywordSearch.INACTIVE_NATIVE_RANK, Map.of());
        Map<String, Object> parameters = new HashMap<>(CategoryKeywordSearch.rankParameters(query, parameter));
        String exactName = "lower(btrim(" + name + "))=:" + parameter + "Phrase";
        String exactCode = "lower(btrim(" + code + "))=:" + parameter + "Phrase";
        String primaryWords = CategoryKeywordSearch.nativeCondition(query, parameter, "material_categories", category, visible.toArray(String[]::new));
        String scope = "TRUE";
        String preferredWords = "FALSE";
        if (hasCategoryIntent()) {
            List<String> required = new ArrayList<>();
            for (int index = 0; index < intentScopes.size(); index++) {
                String key = parameter + "Intent" + index;
                parameters.put(key, intentScopes.get(index));
                required.add(category + " IN (:" + key + ")");
            }
            scope = "(" + String.join(" AND ", required) + ")";
            if (remaining.active()) KeywordSearch.bindNative(parameters, remainingQuery, parameter + "Remaining");
            preferredWords = "((" + scope + " AND " + nativeRemaining(parameter, category, visible) + ") OR "
                    + nativeSubjects(parameter, category, code, name, visible, parameters, true) + " OR "
                    + visible.stream().map(field -> "lower(btrim(" + field + "))=:" + parameter + "Phrase")
                    .collect(java.util.stream.Collectors.joining(" OR ", "(", ")")) + ")";
            primaryWords = subjectMode == SubjectMode.STRICT ? preferredWords : "(" + primaryWords + " OR " + preferredWords + ")";
        }
        String primary = "COALESCE((" + exactName + " OR " + exactCode + " OR (" + primaryWords + ")),FALSE)";
        String condition = primary;
        if (includeRelated) {
            List<String> all = new ArrayList<>(visible); all.addAll(descriptions);
            String full = CategoryKeywordSearch.nativeCondition(query, parameter, "material_categories", category, all.toArray(String[]::new));
            if (hasCategoryIntent()) full = "(" + full + ") OR (" + scope + " AND " + nativeRemaining(parameter, category, all) + ") OR "
                    + nativeSubjects(parameter, category, code, name, all, parameters, true);
            condition = "(" + primary + " OR (COALESCE((" + full + "),FALSE) AND NOT " + primary + "))";
        }
        String base = CategoryKeywordSearch.nativeRank(query, parameter, "material_categories", category, code, name, visible.toArray(String[]::new));
        String preferredRank = subjectMode == SubjectMode.PREFER && hasCategoryIntent()
                ? " WHEN COALESCE((" + preferredWords + "),FALSE) THEN 2+(" + base + ")" : "";
        String exactSubjectRank = hasCategoryIntent() ? " WHEN COALESCE((" + nativeSubjects(parameter, category, code, name, visible, parameters, false) + "),FALSE) THEN 2" : "";
        String rank = "CASE WHEN " + exactName + " THEN 0 WHEN " + exactCode + " THEN 1" + exactSubjectRank + preferredRank + " WHEN " + primary
                + " THEN " + (subjectMode == SubjectMode.PREFER && hasCategoryIntent() ? 20 : 2) + "+(" + base + ") ELSE " + RELATED_RANK_OFFSET + "+(" + base + ") END";
        return new NativeSearch(condition, rank, Map.copyOf(parameters));
    }

    private String nativeSubjects(String parameter, String category, String code, String name,
                                  List<String> fields, Map<String,Object> parameters, boolean includeHead) {
        List<String> proofs = new ArrayList<>();
        for (int index = 0; index < subjectProofs.size(); index++) {
            SubjectProof proof = subjectProofs.get(index);
            String key = parameter + "Subject" + index;
            parameters.put(key, proof.aliases());
            String words = "TRUE";
            if (proof.remaining().active()) {
                KeywordSearch.bindNative(parameters, proof.remainingQuery(), key + "Words");
                words = CategoryKeywordSearch.nativeCondition(proof.remainingQuery(), key + "Words", "material_categories", category, fields.toArray(String[]::new));
            }
            String noun = "";
            if (includeHead && proof.nounPattern() != null) {
                parameters.put(parameter + "NameCut", NAME_CUT_PATTERN);
                parameters.put(parameter + "NameSpace", NAME_SPACE_PATTERN);
                parameters.put(key + "Noun", proof.nounPattern());
                noun = " OR regexp_like(btrim(regexp_replace(regexp_replace(lower(COALESCE(" + name + ",'')),:" + parameter
                        + "NameCut,'','s'),:" + parameter + "NameSpace,' ','g')),:" + key + "Noun)";
            }
            proofs.add("((lower(btrim(" + name + ")) IN (:" + key + ") OR lower(btrim(" + code + ")) IN (:" + key + ")" + noun + ") AND (" + words + "))");
        }
        return proofs.isEmpty() ? "FALSE" : "(" + String.join(" OR ", proofs) + ")";
    }

    private String nativeRemaining(String parameter, String category, List<String> fields) {
        return !remaining.active() ? "TRUE" : "(" + CategoryKeywordSearch.nativeCondition(remainingQuery,
                parameter + "Remaining", "material_categories", category, fields.toArray(String[]::new)) + ")";
    }

    public record NativeSearch(String condition, String rank, Map<String, Object> parameters) {}
    private record SubjectProof(List<String> aliases, String remainingQuery, CategoryKeywordSearch.Plan remaining, String nounPattern) {}

    /** Only inference uses the main noun; full original names remain searchable and visible. */
    private static String nameHead(String value) {
        if (value == null) return "";
        int end = value.length();
        for (char bracket : new char[]{'(', '（', '[', '【'}) {
            int at = value.indexOf(bracket);
            if (at >= 0) end = Math.min(end, at);
        }
        return KeywordSearch.phrase(value.substring(0, end));
    }

    private static String nameSpacePattern() {
        StringBuilder pattern = new StringBuilder("[\t\n").append((char) 0x0b).append("\f\r ");
        for (int cp : new int[]{0x85,0xa0,0x1680,0x2000,0x2001,0x2002,0x2003,0x2004,0x2005,0x2006,0x2007,0x2008,0x2009,0x200a,0x2028,0x2029,0x202f,0x205f,0x3000}) pattern.appendCodePoint(cp);
        return pattern.append("]+").toString();
    }

    private static Set<UUID> intentBranch(String token, Collection<CategoryKeywordSearch.Node> nodes) {
        String subject = subject(token);
        if (subject.isEmpty()) return Set.of();
        Map<UUID, List<UUID>> children = new HashMap<>();
        ArrayDeque<UUID> pending = new ArrayDeque<>();
        for (var node : nodes) {
            children.computeIfAbsent(node.parentId(), ignored -> new ArrayList<>()).add(node.id());
            String categoryName = KeywordSearch.phrase(node.name());
            if (categoryName.equals(token) || subject(categoryName).equals(subject)) pending.add(node.id());
        }
        Set<UUID> result = new LinkedHashSet<>();
        while (!pending.isEmpty()) {
            UUID id = pending.remove();
            if (result.add(id)) pending.addAll(children.getOrDefault(id, List.of()));
        }
        return Set.copyOf(result);
    }

    private static String subject(String value) {
        return value.replaceFirst("(?:类别|类)$", "");
    }
}
