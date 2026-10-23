package com.uten.imp.features.production.analysis;

import jakarta.persistence.EntityManager;
import jakarta.persistence.Query;
import org.junit.jupiter.api.Test;

import java.util.ArrayList;
import java.util.List;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.Mockito.*;

class MaterialAnalysisGoodsLifecycleReaderTest {
    @Test
    void currentRestrictionsAreReadOnlyScopedAndExplainSafeRefreshWithoutHidingHistory() {
        EntityManager em = mock(EntityManager.class);
        Query query = mock(Query.class);
        UUID analysis = UUID.randomUUID(), disabled = UUID.randomUUID(), stale = UUID.randomUUID(), empty = UUID.randomUUID(), orphan=UUID.randomUUID();
        List<String> statements = new ArrayList<>();
        when(em.createNativeQuery(anyString())).thenAnswer(call -> {
            statements.add(call.getArgument(0));
            return query;
        });
        when(query.setParameter(anyString(), any())).thenReturn(query);
        when(query.getResultList()).thenReturn(List.of(
                new Object[]{disabled, "SOURCE_DISABLED", "FG-1", "产品"},
                new Object[]{stale, "STALE_BOM", "RM-7", "原材料"},
                new Object[]{empty, "EMPTY_AFTER_DISABLE", "SA-3", "半成品"},
                new Object[]{orphan, "ORPHAN_SOURCE", "SA-4", "旧子件"}));

        var reasons = new MaterialAnalysisGoodsLifecycleReader(em).blockedReasons(analysis);

        assertThat(reasons.get(disabled)).contains("FG-1 产品", "已禁用", "已有任务与单据仍保留");
        assertThat(reasons.get(stale)).contains("RM-7 原材料", "请先刷新", "下达单据", "专属库存");
        assertThat(reasons.get(empty)).contains("SA-3 半成品", "最后一项生产物料", "维护并核对组装信息");
        assertThat(reasons.get(orphan)).contains("SA-4 旧子件", "原组装物料已移除", "不会恢复旧引用");
        verify(query).setParameter("analysisId", analysis);
        verify(query, never()).executeUpdate();
        assertThat(statements).singleElement().satisfies(sql -> assertThat(sql)
                .contains("item.analysis_id=:analysisId", "material.analysis_id=:analysisId")
                .contains("material.active", "material.node_role='BOM_COMPONENT'", "OR bom.is_deleted")
                .doesNotContain("depth = 1", "depth=1"));
    }
}
