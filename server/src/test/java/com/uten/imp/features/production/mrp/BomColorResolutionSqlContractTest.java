package com.uten.imp.features.production.mrp;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import jakarta.persistence.EntityManager;
import jakarta.persistence.Query;
import org.junit.jupiter.api.Test;
import org.mockito.ArgumentCaptor;

import java.lang.reflect.Field;
import java.math.BigDecimal;
import java.time.LocalDate;
import java.util.Collections;
import java.util.List;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.times;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

class BomColorResolutionSqlContractTest {

    private static final String NORMALIZED_EFFECTIVE_COLOR = """
            COALESCE(NULLIF(b.color_legacy_id, 0),
            NULLIF(component.color_legacy_id, 0))
            """.replaceAll("\\s+", " ").trim();

    @Test
    void planAndOrderMrpNormalizeZeroAtTheSeedAndEveryRecursiveLevel()
            throws Exception {
        assertMrpColorContract(staticSql("MRP_SQL"));
        assertMrpColorContract(staticSql("MRP_ORDER_SQL"));
    }

    @Test
    void executionSnapshotKeepsZeroAsTheNullMaterialDimension() {
        EntityManager em = mock(EntityManager.class);
        Object[] execution = executionRow(null, null);
        Query rows = resultQuery(Collections.singletonList(
                execution));
        Query sourceItems = resultQuery(List.of((UUID) execution[0]));
        Query availability = resultQuery(List.of());
        when(em.createNativeQuery(anyString()))
                .thenReturn(rows, sourceItems, availability);

        ProductionExecutionPlanningService.Snapshot snapshot =
                new ProductionExecutionPlanningService(em)
                        .preview(UUID.randomUUID(), UUID.randomUUID());

        assertThat(snapshot.productLines()).hasSize(1);
        assertThat(snapshot.productLines().getFirst().materials())
                .singleElement()
                .extracting(CompleteKitAllocator.MaterialUsage::colorId)
                .isNull();

        ArgumentCaptor<String> sql = ArgumentCaptor.forClass(String.class);
        verify(em, times(3)).createNativeQuery(sql.capture());
        String snapshotSql = normalize(sql.getAllValues().getFirst());
        assertThat(occurrences(snapshotSql, NORMALIZED_EFFECTIVE_COLOR))
                .isEqualTo(2);
        assertThat(snapshotSql)
                .doesNotContain(
                        "COALESCE(b.color_legacy_id, component.color_legacy_id)")
                .contains("resolved_color.legacy_id = "
                        + NORMALIZED_EFFECTIVE_COLOR);
    }

    @Test
    void executionSnapshotStillRejectsANonZeroOrphanColor() {
        EntityManager em = mock(EntityManager.class);
        Object[] execution = executionRow(null, 777);
        Query rows = resultQuery(Collections.singletonList(
                execution));
        Query sourceItems = resultQuery(List.of((UUID) execution[0]));
        when(em.createNativeQuery(anyString()))
                .thenReturn(rows, sourceItems);

        assertThatThrownBy(() ->
                new ProductionExecutionPlanningService(em)
                        .preview(UUID.randomUUID(), UUID.randomUUID()))
                .isInstanceOf(ApiException.class)
                .hasMessage("BOM、颜色或基本单位数据不完整，禁止生成执行分段")
                .satisfies(error -> assertThat(((ApiException) error).getCode())
                        .isEqualTo(ErrorCode.CONFLICT));
    }

    private static void assertMrpColorContract(String rawSql) {
        String sql = normalize(rawSql);
        assertThat(sql)
                .doesNotContain(
                        "COALESCE(b.color_legacy_id, component.color_legacy_id)");
        assertThat(occurrences(sql, NORMALIZED_EFFECTIVE_COLOR))
                .as("seed/recursive join, invalid_requirement and color_bad "
                        + "diagnostic all share one rule")
                .isEqualTo(6);
        assertThat(occurrences(
                sql,
                NORMALIZED_EFFECTIVE_COLOR
                        + " IS NOT NULL AND (resolved_color.id IS NULL"
                        + " OR resolved_color.is_deleted)"))
                .as("non-zero orphan/deleted colors must fail closed "
                        + "(invalid_requirement + color_bad diagnostic)")
                .isEqualTo(4);
    }

    private static String staticSql(String fieldName) throws Exception {
        Field field = MrpService.class.getDeclaredField(fieldName);
        field.setAccessible(true);
        return (String) field.get(null);
    }

    private static Query resultQuery(List<?> result) {
        Query query = mock(Query.class);
        when(query.setParameter(anyString(), any())).thenReturn(query);
        when(query.getResultList()).thenReturn(result);
        return query;
    }

    private static Object[] executionRow(
            UUID resolvedColorId,
            Integer effectiveColorLegacyId) {
        Object[] row = new Object[23];
        row[0] = UUID.randomUUID();
        row[1] = 1;
        row[2] = UUID.randomUUID();
        row[3] = null;
        row[4] = UUID.randomUUID();
        row[5] = BigDecimal.ONE;
        row[6] = BigDecimal.TEN;
        row[7] = LocalDate.of(2026, 7, 31);
        row[8] = LocalDate.of(2026, 8, 1);
        row[9] = UUID.randomUUID();
        row[10] = UUID.randomUUID();
        row[11] = "FG-001";
        row[12] = "Finished good";
        row[13] = UUID.randomUUID();
        row[14] = UUID.randomUUID();
        row[15] = resolvedColorId;
        row[16] = UUID.randomUUID();
        row[17] = BigDecimal.ONE;
        row[18] = effectiveColorLegacyId;
        row[19] = false;
        row[20] = null;
        row[21] = null;
        row[22] = "\u91c7\u8d2d";
        return row;
    }

    private static int occurrences(String text, String value) {
        int count = 0;
        int from = 0;
        while ((from = text.indexOf(value, from)) >= 0) {
            count++;
            from += value.length();
        }
        return count;
    }

    private static String normalize(String value) {
        return value.replaceAll("\\s+", " ").replaceAll("\\(\\s+", "(").replaceAll("\\s+\\)", ")").trim();
    }
}
