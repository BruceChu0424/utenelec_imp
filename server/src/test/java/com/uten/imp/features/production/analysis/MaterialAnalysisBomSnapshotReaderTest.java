package com.uten.imp.features.production.analysis;

import com.uten.imp.common.web.ApiException;
import jakarta.persistence.EntityManager;
import jakarta.persistence.Query;
import org.junit.jupiter.api.Test;

import java.math.BigDecimal;
import java.util.ArrayList;
import java.util.Collections;
import java.util.List;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.Mockito.*;

class MaterialAnalysisBomSnapshotReaderTest {
    @Test
    void fiveHundredSourcesUseTwoQueriesAndRetainTheirOwnIdentityAndRate() {
        EntityManager em = mock(EntityManager.class);
        // ADR-111：校验查询只返回违规行，零行即通过。
        Query validation = query(List.of());
        Query tree = query(List.of());
        when(em.createNativeQuery(anyString())).thenReturn(validation, tree);
        UUID goods = UUID.randomUUID();
        var sources = new ArrayList<MaterialAnalysisService.SourceLine>();
        for (int i = 0; i < 500; i++) sources.add(source(goods, BigDecimal.valueOf(i + 1)));
        Object[] first = new Object[25];
        first[24] = sources.getFirst().analysisItemId();
        Object[] last = new Object[25];
        last[24] = sources.getLast().analysisItemId();
        when(tree.getResultList()).thenReturn(List.of(first, last));

        var result = new MaterialAnalysisBomSnapshotReader(em).read(sources);

        verify(em, times(2)).createNativeQuery(anyString());
        verify(validation).setParameter("goodsIds", goods.toString());
        verify(tree).setParameter("source0", sources.getFirst().analysisItemId());
        verify(tree).setParameter("source499", sources.getLast().analysisItemId());
        verify(tree).setParameter("rate499", new BigDecimal("500"));
        assertThat(result.get(sources.getFirst().analysisItemId())).containsExactly(first);
        assertThat(result.get(sources.getLast().analysisItemId())).containsExactly(last);
    }

    @Test
    void invalidGraphStopsBeforeAnySnapshotReadAndNamesTheOffendingRows() {
        for (String kind : List.of("CYCLE", "TOO_DEEP", "COMPONENT_DELETED", "QTY,ROW_COLOR_LEGACY")) {
            EntityManager em = mock(EntityManager.class);
            Query invalid = query(Collections.singletonList(new Object[]{
                    kind, "FG-1", "成品", "SA-1", "半成品", "RM-9", "底衬", 2, 7L}));
            when(em.createNativeQuery(anyString())).thenReturn(invalid);
            ApiException error = assertThrows(ApiException.class, () -> new MaterialAnalysisBomSnapshotReader(em)
                    .read(List.of(source(UUID.randomUUID(), BigDecimal.ONE))));
            verify(em, times(1)).createNativeQuery(anyString());
            // 报错点名到行：成品、父件、组件编号都在，且给出总处数与「未列出」提示。
            assertThat(error.getMessage())
                    .contains("7 处问题")
                    .contains("FG-1 成品")
                    .contains("SA-1 半成品")
                    .contains("RM-9 底衬")
                    .contains("还有 6 处未列出")
                    .doesNotContain(kind);
        }
    }

    @Test
    void emptyBatchAndInvalidConversionNeverReachTheDatabase() {
        EntityManager em = mock(EntityManager.class);
        var reader = new MaterialAnalysisBomSnapshotReader(em);
        assertThat(reader.read(List.of())).isEmpty();
        assertThrows(ApiException.class,
                () -> reader.read(List.of(source(UUID.randomUUID(), BigDecimal.ZERO))));
        verifyNoInteractions(em);
    }

    private static MaterialAnalysisService.SourceLine source(UUID goods, BigDecimal rate) {
        var source = mock(MaterialAnalysisService.SourceLine.class);
        when(source.analysisItemId()).thenReturn(UUID.randomUUID());
        when(source.goodsId()).thenReturn(goods);
        when(source.unitRate()).thenReturn(rate);
        return source;
    }

    private static Query query(List<Object[]> rows) {
        Query query = mock(Query.class);
        when(query.setParameter(anyString(), any())).thenReturn(query);
        when(query.getResultList()).thenReturn(rows);
        return query;
    }
}
