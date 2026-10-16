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
