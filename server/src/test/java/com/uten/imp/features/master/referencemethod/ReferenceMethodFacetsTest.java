package com.uten.imp.features.master.referencemethod;

import jakarta.persistence.EntityManager;
import jakarta.persistence.Query;
import org.junit.jupiter.api.Test;
import org.mockito.ArgumentCaptor;

import java.util.List;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertTrue;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.times;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

/**
 * 结算方式管理页表头筛选桶（范式同 ColorService#facets / VisitorApprovalFacetQueryTest）：
 * 桶映射、空值计数与 SQL 纪律（软删排除、白名单列、不拼用户输入）。
 */
class ReferenceMethodFacetsTest {

    @Test
    void bucketsAndNullCountsFollowTheFacetColumnWhitelist() {
        EntityManager entityManager = mock(EntityManager.class);
        Query statusBuckets = mock(Query.class);
        Query statusNulls = mock(Query.class);
        Query roleBuckets = mock(Query.class);
        Query roleNulls = mock(Query.class);
        Query baseBuckets = mock(Query.class);
        Query baseNulls = mock(Query.class);
        Query ruleBuckets = mock(Query.class);
        Query ruleNulls = mock(Query.class);
        // facets() 按 FACET_COLUMNS 顺序（status → systemRole → termsBase → dueRule）
        // 每列先桶聚合后空值计数，共 8 条 native query。
        when(entityManager.createNativeQuery(anyString())).thenReturn(
                statusBuckets, statusNulls,
                roleBuckets, roleNulls,
                baseBuckets, baseNulls,
                ruleBuckets, ruleNulls);
        when(statusBuckets.getResultList()).thenReturn(List.<Object[]>of(
                new Object[]{"使用", 8L},
                new Object[]{"禁用", 2L}));
        when(statusNulls.getSingleResult()).thenReturn(0L);
        when(roleBuckets.getResultList()).thenReturn(List.<Object[]>of(
                new Object[]{"CASH", 1L},
                new Object[]{"MONTHLY", 1L}));
        when(roleNulls.getSingleResult()).thenReturn(9L);
        when(baseBuckets.getResultList()).thenReturn(List.<Object[]>of(
                new Object[]{"RECEIPT_DATE", 6L},
                new Object[]{"STATEMENT_END", 4L}));
        when(baseNulls.getSingleResult()).thenReturn(0L);
        when(ruleBuckets.getResultList()).thenReturn(List.<Object[]>of(
                new Object[]{"NET_DAYS", 9L},
                new Object[]{"EOM_PLUS_DAYS", 1L}));
        when(ruleNulls.getSingleResult()).thenReturn(0L);

        SettlementMethodFacets facets =
                new ReferenceMethodService(null, null, null, null, entityManager)
                        .settlementAdminFacets();

        assertEquals(2, facets.status().size());
        assertEquals("使用", facets.status().get(0).value());
        assertEquals(8L, facets.status().get(0).count());
        assertEquals("禁用", facets.status().get(1).value());
        assertEquals(2, facets.systemRole().size());
        assertEquals("CASH", facets.systemRole().get(0).value());
        assertEquals("MONTHLY", facets.systemRole().get(1).value());
        assertEquals(2, facets.termsBase().size());
        assertEquals("RECEIPT_DATE", facets.termsBase().get(0).value());
        assertEquals(2, facets.dueRule().size());
        assertEquals("NET_DAYS", facets.dueRule().get(0).value());
        assertEquals(9L, facets.nullCounts().get("systemRole"));
        assertEquals(0L, facets.nullCounts().get("status"));
        assertEquals(0L, facets.nullCounts().get("termsBase"));
        assertEquals(0L, facets.nullCounts().get("dueRule"));

        ArgumentCaptor<String> sql = ArgumentCaptor.forClass(String.class);
        verify(entityManager, times(8)).createNativeQuery(sql.capture());
        List<String> statements = sql.getAllValues();
        // 8 条语句全部排除软删行；桶语句 group by、空值语句 is null。
        for (String statement : statements) {
            assertTrue(statement.contains("is_deleted = false"), "软删行不进桶：" + statement);
            assertTrue(statement.startsWith("select"), "只允许 select：" + statement);
        }
        for (int i = 0; i < statements.size(); i += 2) {
            String bucketSql = statements.get(i);
            String nullSql = statements.get(i + 1);
            assertTrue(bucketSql.contains("group by"), "桶语句必须聚合：" + bucketSql);
            assertTrue(bucketSql.contains("order by c desc, v asc"), "桶按命中数排序：" + bucketSql);
            assertTrue(bucketSql.contains("is not null"), "桶排除空值：" + bucketSql);
            assertTrue(nullSql.contains("is null"), "空值计数语句：" + nullSql);
            assertTrue(nullSql.startsWith("select count(*)"), "空值计数只允许 count：" + nullSql);
        }
        // 列名只允许来自硬编码白名单（本字典 4 个枚举列）；编号/名称等自由文本列不做筛选。
        String joined = String.join(" ", statements).toLowerCase();
        assertTrue(joined.contains("system_role") && joined.contains("terms_base")
                && joined.contains("due_rule") && joined.contains("status"));
        assertTrue(!joined.contains("name"), "自由文本列不进 facet：" + joined);
        assertTrue(!joined.contains(";") && !joined.contains("--"), "不允许多语句/注释注入：" + joined);
    }

    @Test
    void facetLimitIsAHardcodedConstantNotUserInput() {
        EntityManager entityManager = mock(EntityManager.class);
        Query unused = mock(Query.class);
        when(entityManager.createNativeQuery(anyString())).thenReturn(unused);
        when(unused.getResultList()).thenReturn(List.of());
        when(unused.getSingleResult()).thenReturn(0L);

        new ReferenceMethodService(null, null, null, null, entityManager)
                .settlementAdminFacets();

        ArgumentCaptor<String> sql = ArgumentCaptor.forClass(String.class);
        verify(entityManager, times(8)).createNativeQuery(sql.capture());
        for (String statement : sql.getAllValues()) {
            if (statement.contains("group by")) {
                assertTrue(statement.endsWith("limit 50"), "阈值是常量截断：" + statement);
            }
        }
    }
}
