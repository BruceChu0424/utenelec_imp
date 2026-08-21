package com.uten.imp.features.production.mrp;

import jakarta.persistence.EntityManager;
import jakarta.persistence.Query;
import org.junit.jupiter.api.Test;
import org.mockito.ArgumentCaptor;

import java.math.BigDecimal;
import java.time.LocalDate;
import java.util.Collections;
import java.util.List;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.times;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

class ProductionWorkshopPreferencePreviewSqlTest {

    @Test
    void previewUsesAnActiveLearnedWorkshopBeforeThePlanDepartmentFallback() {
        EntityManager em = mock(EntityManager.class);
        UUID learnedWorkshopId = UUID.randomUUID();
        Object[] execution = executionRow(learnedWorkshopId);
        Query rows = resultQuery(Collections.singletonList(execution));
        Query sourceItems = resultQuery(List.of((UUID) execution[0]));
        Query availability = resultQuery(List.of());
        when(em.createNativeQuery(anyString()))
                .thenReturn(rows, sourceItems, availability);

        ProductionExecutionPlanningService.Snapshot snapshot =
                new ProductionExecutionPlanningService(em)
                        .preview(UUID.randomUUID(), UUID.randomUUID());

        assertThat(snapshot.productLines()).singleElement()
                .extracting(CompleteKitAllocator.ProductLine
                        ::defaultWorkshopDepartmentId)
                .isEqualTo(learnedWorkshopId);
        ArgumentCaptor<String> sql = ArgumentCaptor.forClass(String.class);
        // V298：快照前多一次 material_analysis_id 预查（分析备料绑定），第 1 个仍是主查询。
        verify(em, times(4)).createNativeQuery(sql.capture());
        assertThat(normalize(sql.getAllValues().getFirst()))
                .contains("case when preferred_workshop_parent.id is not null then workshop_preference.workshop_department_id when plan_workshop_parent.id is not null then p.department_id else null end")
                .contains("left join production_goods_workshop_preferences workshop_preference on workshop_preference.goods_id = product.id")
                .contains("left join departments preferred_workshop on preferred_workshop.id = workshop_preference.workshop_department_id and preferred_workshop.is_deleted = false")
                .contains("preferred_workshop_parent.code = 'dept_prod'")
                .contains("plan_workshop_parent.code = 'dept_prod'");
        String warehouseSql = normalize(sql.getAllValues().get(3));
        assertThat(warehouseSql)
                .contains("preplan_analysis_stock_exact_pegs exact_peg")
                .contains("beneficiary.analysis_item_id = :analysisitemid")
                .contains("a.available_qty + coalesce(own.own_qty, 0) - greatest(")
                .doesNotContain("greatest( a.available_qty - greatest(");
    }

    private static Query resultQuery(List<?> values) {
        Query query = mock(Query.class);
        when(query.setParameter(anyString(), any())).thenReturn(query);
        when(query.getResultList()).thenReturn(values);
        return query;
    }

    private static Object[] executionRow(UUID workshopId) {
        Object[] row = new Object[29];
        row[0] = UUID.randomUUID();
        row[1] = 1;
        row[2] = UUID.randomUUID();
        row[3] = null;
        row[4] = UUID.randomUUID();
        row[5] = BigDecimal.ONE;
        row[6] = BigDecimal.TEN;
        row[7] = LocalDate.of(2026, 8, 2);
        row[8] = LocalDate.of(2026, 8, 3);
        row[9] = workshopId;
        row[10] = UUID.randomUUID();
        row[11] = "FG-001";
        row[12] = "Finished good";
        row[13] = UUID.randomUUID();
        row[14] = UUID.randomUUID();
        row[15] = null;
        row[16] = UUID.randomUUID();
        row[17] = BigDecimal.ONE;
        row[18] = null;
        row[19] = false;
        row[20] = null;
        row[21] = null;
        row[22] = "\u91c7\u8d2d";
        row[23] = null; // no analysis route override; master source remains authoritative
        row[24] = "START";
        row[25] = true;
        row[26] = "PER_UNIT";
        row[27] = BigDecimal.ONE;
        row[28] = true;
        return row;
    }

    private static String normalize(String value) {
        return value.toLowerCase().replaceAll("\\s+", " ").trim();
    }
}
