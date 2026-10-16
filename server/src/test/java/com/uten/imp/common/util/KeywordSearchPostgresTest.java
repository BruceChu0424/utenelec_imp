package com.uten.imp.common.util;

import jakarta.persistence.Query;
import org.junit.jupiter.api.AfterAll;
import org.junit.jupiter.api.BeforeAll;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.jdbc.core.namedparam.NamedParameterJdbcTemplate;
import org.springframework.jdbc.datasource.DriverManagerDataSource;
import org.testcontainers.containers.PostgreSQLContainer;

import java.util.HashMap;
import java.util.List;
import java.util.Map;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.when;

@EnabledIfEnvironmentVariable(named = "UTEN_RUN_DB_TESTS", matches = "(?i)true")
class KeywordSearchPostgresTest {
    static final PostgreSQLContainer<?> DATABASE = new PostgreSQLContainer<>("postgres:16-alpine");

    @BeforeAll static void start() { DATABASE.start(); }
    @AfterAll static void stop() { DATABASE.stop(); }

    @Test
    void compoundWordsCrossFieldsButNeverExpandLiteralWildcardCharacters() {
        assertEquals(List.of("literal"), search("螺丝\u3000M3_20%"));
        assertEquals(List.of("backslash", "literal", "wildcard-lookalike"), search("螺丝 M3"));
        assertEquals(List.of(), search("开关 M3_20%"));
    }

    @Test
    void backslashAndNullFieldsKeepLiteralSearchSemantics() {
        assertEquals(List.of("backslash"), search("M3\\A"));
        assertEquals(List.of("nullable"), search("onlymodel"));
    }

    @Test
    void sharedNativeRankOrdersExactIdentifiersThenNamesThenPrefixAndContainsBeforePaging() {
        var dataSource = new DriverManagerDataSource(DATABASE.getJdbcUrl(), DATABASE.getUsername(), DATABASE.getPassword());
        String rank = KeywordSearch.nativeRank("M3", "kw", "fixture.code", "fixture.name");
        String sql = """
                SELECT id FROM (VALUES
                    ('contains','XM3X','ordinary'), ('prefix','M3XX','ordinary'),
                    ('name','OTHER','M3'), ('code','M3','ordinary')
                ) fixture(id,code,name) WHERE
                """ + KeywordSearch.nativeCondition("M3", "kw", "fixture.code", "fixture.name")
                + " ORDER BY " + rank + ", id LIMIT 2 OFFSET 0";
        assertEquals(List.of("code", "name"), new NamedParameterJdbcTemplate(dataSource)
                .queryForList(sql, KeywordSearch.nativeRankParameters("M3", "kw"), String.class));
    }

    private static final String NAME_RANK_FIXTURE = """
            FROM (VALUES
                ('name-exact','other','Metric Screw',ARRAY['Metric Screw']),
                ('name-prefix','other','Metric Screw extra',ARRAY['Metric Screw extra']),
                ('name-contains','other','Small Metric Screw',ARRAY['Small Metric Screw']),
                ('name-words','other','Metric steel Screw',ARRAY['Metric steel Screw']),
                ('code-exact','Metric Screw','ordinary',ARRAY['ordinary']),
                ('split-items','other','ordinary',ARRAY['Metric','Screw'])
            ) fixture(id,code,name,names)
            """;
    private static final List<String> NAME_RANK_ORDER = List.of(
            "name-exact", "name-prefix", "name-contains", "name-words", "code-exact", "split-items");
    private static final List<String> BLANK_SEARCHES = java.util.Arrays.asList(
            null, "", " \t\r\n", "\u0085", "\u00a0", "\u1680", "\u2007", "\u2028\u2029", "\u202f", "\u205f", "\u3000");

    @Test void nativeTaskRankPrioritizesOneWholeGoodsNameOverExactCodeBeforePagination() {
        String rank = TaskKeywordSearch.rankNamesFirst("Metric Screw", new String[]{"name"}, new String[]{}, new String[]{"code"});
        var jdbc = new NamedParameterJdbcTemplate(new DriverManagerDataSource(DATABASE.getJdbcUrl(), DATABASE.getUsername(), DATABASE.getPassword()));
        assertEquals(NAME_RANK_ORDER, jdbc.queryForList("SELECT id " + NAME_RANK_FIXTURE + " ORDER BY " + rank + ",id",
                TaskKeywordSearch.parameters("Metric Screw"), String.class));
        assertEquals(List.of("name-prefix"), jdbc.queryForList("SELECT id " + NAME_RANK_FIXTURE + " ORDER BY " + rank + ",id LIMIT 1 OFFSET 1",
                TaskKeywordSearch.parameters("Metric Screw"), String.class));
    }

    @Test void aggregatedTaskNamesNeverTreatDifferentLineNamesAsOneWholeMatchingName() {
        String rank = TaskKeywordSearch.rankNamesFirst("Metric Screw", new String[]{}, new String[]{"names"}, new String[]{"code"});
        var jdbc = new NamedParameterJdbcTemplate(new DriverManagerDataSource(DATABASE.getJdbcUrl(), DATABASE.getUsername(), DATABASE.getPassword()));
        assertEquals(NAME_RANK_ORDER, jdbc.queryForList("SELECT id " + NAME_RANK_FIXTURE + " ORDER BY " + rank + ",id",
                TaskKeywordSearch.parameters("Metric Screw"), String.class));
    }

    @Test void fixedParameterTaskRankKeepsTheSameScalarAndArrayNamePriority() {
        var jdbc = new NamedParameterJdbcTemplate(new DriverManagerDataSource(DATABASE.getJdbcUrl(), DATABASE.getUsername(), DATABASE.getPassword()));
        for (boolean array : List.of(false, true)) {
            String rank = TaskKeywordSearch.rankNamesFirstParameter("keyword", array ? new String[]{} : new String[]{"name"},
                    array ? new String[]{"names"} : new String[]{}, new String[]{"code"});
            assertEquals(NAME_RANK_ORDER, jdbc.queryForList("SELECT id " + NAME_RANK_FIXTURE + " ORDER BY " + rank + ",id",
                    Map.of("keyword", "Metric Screw"), String.class));
        }
    }

    @Test void positionalTaskRankBindsAllNameTiersAndLiteralCharactersInSqlOrder() {
        var jdbc = new org.springframework.jdbc.core.JdbcTemplate(new DriverManagerDataSource(DATABASE.getJdbcUrl(), DATABASE.getUsername(), DATABASE.getPassword()));
        var args = new java.util.ArrayList<Object>();
        String rank = TaskKeywordSearch.rankNamesFirstPositional("Metric Screw", args, new String[]{"name"}, "code");
        assertEquals(NAME_RANK_ORDER, jdbc.queryForList("SELECT id " + NAME_RANK_FIXTURE + " ORDER BY " + rank + ",id", String.class, args.toArray()));
        args.clear();
        rank = TaskKeywordSearch.rankNamesFirstPositional("A%_B", args, new String[]{"name"}, "code");
        assertEquals(List.of("literal", "lookalike"), jdbc.queryForList("""
                SELECT id FROM (VALUES ('literal','other','A%_B'), ('lookalike','A%_B','AxYB')) fixture(id,code,name)
                ORDER BY
                """ + rank + ",id", String.class, args.toArray()));
    }

    @Test
    void inactiveRanksAreNumericExpressionsInOrderProjectionAndAggregateWithoutParameters() {
        var jdbc = new NamedParameterJdbcTemplate(new DriverManagerDataSource(
                DATABASE.getJdbcUrl(), DATABASE.getUsername(), DATABASE.getPassword()));
        String fixture = "FROM (VALUES (1,10),(2,20)) fixture(id,business_order)";
        for (String text : BLANK_SEARCHES) {
            assertEquals(Map.of(), KeywordSearch.nativeRankParameters(text, "kw"));
            assertEquals(Map.of(), TaskKeywordSearch.parameters(text));
            List<String> ranks = List.of(
                    KeywordSearch.nativeRank(text, "kw", "name", "code"),
                    CategoryKeywordSearch.nativeRank(text, "kw", "material_categories", "category_id",
                            "code", "name", "name", "code"),
                    TaskKeywordSearch.rank(text, new String[]{"code"}, "names"),
                    TaskKeywordSearch.rankNamesFirst(text, new String[]{"name"}, new String[]{"names"}, new String[]{"code"}));
            for (String rank : ranks) {
                assertEquals(List.of(2, 1), jdbc.queryForList(
                        "SELECT id " + fixture + " ORDER BY " + rank + ",business_order DESC,id", Map.of(), Integer.class));
                assertEquals(List.of(0, 0), jdbc.queryForList(
                        "SELECT " + rank + " AS search_rank " + fixture + " ORDER BY business_order DESC,id", Map.of(), Integer.class));
                assertEquals(0, jdbc.queryForObject("SELECT MIN(" + rank + ") " + fixture, Map.of(), Integer.class));
            }
            var args = new java.util.ArrayList<Object>(List.of("existing"));
            assertEquals("", TaskKeywordSearch.rankPositional(text, "name", "code"));
            assertEquals("", TaskKeywordSearch.rankNamesFirstPositional(text, args, new String[]{"name"}, "code"));
            assertEquals(List.of("existing"), args);
        }
    }

    @Test
    void fixedParameterBlankRanksRetainBusinessOrderEvenForBlankIdentityFields() {
        var jdbc = new NamedParameterJdbcTemplate(new DriverManagerDataSource(
                DATABASE.getJdbcUrl(), DATABASE.getUsername(), DATABASE.getPassword()));
        String fixture = """
                FROM (VALUES
                    (1,10,''::text,''::text,ARRAY['']::text[]),
                    (2,20,'ordinary','CODE',ARRAY['ordinary']),
                    (3,30,NULL,NULL,NULL),
                    (4,40,E'\\t',E'\\t',ARRAY[E'\\t'])
                ) fixture(id,business_order,name,code,names)
                """;
        List<String> ranks = List.of(
                TaskKeywordSearch.rankParameter("keyword", new String[]{"name", "code"}, "names"),
                TaskKeywordSearch.rankNamesFirstParameter("keyword", new String[]{"name"}, new String[]{"names"}, new String[]{"code"}));
        for (String text : BLANK_SEARCHES) {
            Map<String, Object> params = new HashMap<>();
            params.put("keyword", text);
            for (String rank : ranks) {
                assertEquals(List.of(4, 3, 2, 1), jdbc.queryForList(
                        "SELECT id " + fixture + " ORDER BY " + rank + ",business_order DESC,id", params, Integer.class));
                assertEquals(List.of(0, 0, 0, 0), jdbc.queryForList(
                        "SELECT " + rank + " AS search_rank " + fixture + " ORDER BY business_order DESC,id", params, Integer.class));
            }
        }
    }

    @Test
    void fixedParameterWordsAndRankingUseTheSameUnicodeSeparatorsAsJava() {
        var jdbc = new NamedParameterJdbcTemplate(new DriverManagerDataSource(
                DATABASE.getJdbcUrl(), DATABASE.getUsername(), DATABASE.getPassword()));
        for (String separator : BLANK_SEARCHES.stream().filter(value -> value != null && !value.isEmpty()).toList()) {
            String text = "Metric" + separator + "Screw";
            assertEquals(List.of("metric", "screw"), KeywordSearch.terms(text));
            String condition = TaskKeywordSearch.conditionParameter("keyword", "name", "code", "array_to_string(names,' ')");
            String rank = TaskKeywordSearch.rankNamesFirstParameter("keyword", new String[]{"name"}, new String[]{"names"}, new String[]{"code"});
            assertEquals(NAME_RANK_ORDER, jdbc.queryForList("SELECT id " + NAME_RANK_FIXTURE
                    + " WHERE " + condition + " ORDER BY " + rank + ",id", Map.of("keyword", text), String.class));
            assertEquals(List.of("name-prefix"), jdbc.queryForList("SELECT id " + NAME_RANK_FIXTURE
                    + " WHERE " + condition + " ORDER BY " + rank + ",id LIMIT 1 OFFSET 1", Map.of("keyword", text), String.class));
            assertEquals(List.of(), jdbc.queryForList("SELECT id " + NAME_RANK_FIXTURE
                    + " WHERE " + condition, Map.of("keyword", text + separator + "missing"), String.class));
        }
    }

    @Test
    void fixedParameterLiteralWordsRemainLiteralAcrossUnicodeSeparators() {
        var jdbc = new NamedParameterJdbcTemplate(new DriverManagerDataSource(
                DATABASE.getJdbcUrl(), DATABASE.getUsername(), DATABASE.getPassword()));
        for (String literal : List.of("A%_B", "M3\\A")) {
            String condition = TaskKeywordSearch.conditionParameter("keyword", "name");
            String rank = TaskKeywordSearch.rankNamesFirstParameter("keyword", new String[]{"name"}, new String[]{}, new String[]{"name"});
            assertEquals(List.of("literal"), jdbc.queryForList("""
                    SELECT id FROM (VALUES
                        ('literal',CAST(:literalName AS text)), ('lookalike','AxYB Screw')
                    ) fixture(id,name) WHERE
                    """ + condition + " ORDER BY " + rank + ",id", Map.of(
                    "keyword", literal + "\u00a0Screw", "literalName", literal + " Screw"), String.class));
        }
    }

    private List<String> search(String text) {
        Map<String, Object> parameters = new HashMap<>();
        Query query = mock(Query.class);
        when(query.setParameter(anyString(), any())).thenAnswer(call -> {
            parameters.put(call.getArgument(0), call.getArgument(1));
            return query;
        });
        KeywordSearch.bindNative(query, text, "kw");
        String condition = KeywordSearch.nativeCondition(text, "kw", "fixture.name", "fixture.model");
        String sql = """
                SELECT id FROM (VALUES
                    ('literal', '不锈钢螺丝', 'M3_20%'),
                    ('wildcard-lookalike', '不锈钢螺丝', 'M3X20A'),
                    ('unrelated', '双联开关', 'M5'),
                    ('backslash', '螺丝', 'M3\\A'),
                    ('nullable', NULL, 'onlymodel')
                ) fixture(id,name,model) WHERE
                """ + condition + " ORDER BY id";
        var dataSource = new DriverManagerDataSource(DATABASE.getJdbcUrl(), DATABASE.getUsername(), DATABASE.getPassword());
        return new NamedParameterJdbcTemplate(dataSource).queryForList(sql, parameters, String.class);
    }
}
