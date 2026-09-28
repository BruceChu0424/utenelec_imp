package com.uten.imp.features.production.schedule;

import com.uten.imp.features.production.schedule.dto.ScheduleOrderLine;
import jakarta.persistence.EntityManager;
import jakarta.persistence.Query;
import org.junit.jupiter.api.Test;
import org.mockito.ArgumentCaptor;

import java.math.BigDecimal;
import java.time.LocalDate;
import java.util.List;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.times;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

/**
 * 「从订单带明细」的一层 BOM 零件(ADR-129 §2.3)：一条查询取回全部订单行与零件，
 * 计算用量来自 v_goods_bom_item_usage，需求小计走共享边公式，颜色取 BOM 行颜色；
 * 用量不大于零的存量行不计算(不再让整张订单 500)。
 */
class ProductionScheduleOrderLinesTest {

    @Test
    void orderLinesAndTheirBomComeFromOneQueryWithTheSharedEdgeFormula() {
        UUID orderId = UUID.randomUUID();
        UUID firstLine = UUID.randomUUID();
        UUID secondLine = UUID.randomUUID();
        UUID label = UUID.randomUUID();
        UUID carton = UUID.randomUUID();
        UUID legacy = UUID.randomUUID();
        UUID bomColor = UUID.randomUUID();
        EntityManager em = mock(EntityManager.class);
        Query approved = mock(Query.class);
        when(approved.setParameter(anyString(), any())).thenReturn(approved);
        when(approved.getSingleResult()).thenReturn(1L);
        Query lines = mock(Query.class);
        when(lines.setParameter(anyString(), any())).thenReturn(lines);
        when(lines.getResultList()).thenReturn(List.of(
                row(firstLine, 1, component(label, "L-01", bomColor, "0.500001",
                        "PER_UNIT", "1", "5.0001")),
                row(firstLine, 1, component(carton, "PK-01", null, "2",
                        "PER_PACKAGE", "6", "4")),
                row(firstLine, 1, component(legacy, "OLD-01", null, null,
                        "PER_UNIT", "1", null)),
                row(secondLine, 2, new Object[12])));
        when(em.createNativeQuery(anyString())).thenReturn(approved, lines);

        List<ScheduleOrderLine> result =
                new ProductionScheduleService(em, null, null).orderLines(orderId);

        assertThat(result).extracting(ScheduleOrderLine::orderItemId)
                .containsExactly(firstLine, secondLine);
        assertThat(result.getFirst().unitRate()).isEqualByComparingTo("1");
        assertThat(result.getFirst().bom()).hasSize(3);
        ScheduleOrderLine.BomComponent perUnit = result.getFirst().bom().getFirst();
        assertThat(perUnit.goodsId()).isEqualTo(label);
        assertThat(perUnit.colorId()).isEqualTo(bomColor);
        assertThat(perUnit.perQty()).isEqualByComparingTo("0.500001");
        assertThat(perUnit.needQty()).isEqualByComparingTo("5.0001");
        ScheduleOrderLine.BomComponent perPackage = result.getFirst().bom().get(1);
        assertThat(perPackage.perQty())
                .as("每包 2 个、每包产出 6 件：单件用量向上取整到 6 位")
                .isEqualByComparingTo("0.333334");
        assertThat(perPackage.needQty()).isEqualByComparingTo("4");
        ScheduleOrderLine.BomComponent nonPositive = result.getFirst().bom().get(2);
        assertThat(nonPositive.goodsId())
                .as("用量不大于零的存量 BOM 行照样列出，不让整张订单带入失败")
                .isEqualTo(legacy);
        assertThat(nonPositive.perQty()).isNull();
        assertThat(nonPositive.needQty()).isNull();
        assertThat(result.get(1).bom()).isEmpty();

        ArgumentCaptor<String> sql = ArgumentCaptor.forClass(String.class);
        verify(em, times(2)).createNativeQuery(sql.capture());
        assertThat(sql.getAllValues().get(1))
                .contains("LEFT JOIN v_goods_bom_item_usage usage ON usage.bom_item_id = b.id")
                .contains("fn_material_analysis_edge_required(")
                .contains("CASE WHEN b.qty > 0 THEN usage.effective_qty END AS effective_qty")
                .contains("CASE WHEN b.qty > 0 THEN fn_material_analysis_edge_required(")
                .contains("line.need * line.rate, usage.effective_qty, b.consumption_basis,")
                .contains("ON resolved_color.id = COALESCE(b.color_id, component.color_id)");
    }

    private static Object[] component(
            UUID goodsId, String code, UUID colorId, String effectiveQty,
            String basis, String basisOutputQty, String needQty) {
        return new Object[]{
                goodsId, code, code + " name", null, colorId, colorId == null ? null : "BOM color",
                effectiveQty == null ? null : new BigDecimal(effectiveQty), basis,
                new BigDecimal(basisOutputQty),
                needQty == null ? null : new BigDecimal(needQty), BigDecimal.ZERO, false};
    }

    private static Object[] row(UUID lineId, int lineNo, Object[] component) {
        Object[] row = new Object[29];
        row[0] = lineId;
        row[1] = lineNo;
        row[2] = UUID.randomUUID();
        row[3] = "FG-" + lineNo;
        row[4] = "Finished good";
        row[5] = null;
        row[6] = null;
        row[7] = null;
        row[8] = UUID.randomUUID();
        row[9] = "piece";
        row[10] = new BigDecimal("10");
        row[11] = BigDecimal.ZERO;
        row[12] = new BigDecimal("10");
        row[13] = LocalDate.of(2026, 10, 1);
        row[14] = "SO-1";
        row[15] = "Client";
        row[16] = BigDecimal.ONE;
        System.arraycopy(component, 0, row, 17, component.length);
        return row;
    }
}
