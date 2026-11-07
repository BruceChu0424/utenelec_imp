package com.uten.imp.businesschain;

import jakarta.persistence.EntityManager;
import jakarta.persistence.Query;
import org.junit.jupiter.api.Test;
import org.mockito.ArgumentCaptor;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.test.util.ReflectionTestUtils;
import com.uten.imp.features.subcontract.draw.SubcontractDrawQueryService;
import com.uten.imp.features.subcontract.short_delivery.SubcontractShortDeliveryService;
import java.util.List;
import java.util.UUID;
import static org.assertj.core.api.Assertions.*;
import static org.mockito.Mockito.*;

class HistoricalSubcontract1032SqlTransportTest {
    @Test void drawCoverageUsesTheInstalledOriginalDrawSetAuthority() {
        EntityManager actual=mock(EntityManager.class);
        Query statement=mock(Query.class);
        when(actual.createNativeQuery(anyString())).thenReturn(statement);
        when(statement.getResultList()).thenReturn(List.of());
        var service=mock(SubcontractDrawQueryService.class,CALLS_REAL_METHODS);
        var transport=HistoricalSubcontract1032SqlTransport.entityManager(actual);
        ReflectionTestUtils.setField(service,"em",transport);
        List<UUID> orderItems=List.of(UUID.randomUUID(),UUID.randomUUID());
        ReflectionTestUtils.invokeMethod(service,"facts",orderItems);
        var sql=ArgumentCaptor.forClass(String.class);
        verify(actual).createNativeQuery(sql.capture());
        verify(statement).setParameter("factItemIds",orderItems);
        assertThat(sql.getValue()).contains("fn_subcontract_draw_facts(oi.id)",
                "fn_subcontract_draw_sets(facts.usable_qty+facts.pending_qty, facts.bom_unit_qty)")
                .doesNotContain("fn_subcontract_actual_receipt_sets","base_bom_unit_qty");
    }

    @Test void actualNotificationQueryUsesItsWholeOriginalNullToleranceAndOverduePredicates() {
        JdbcTemplate jdbc=mock(JdbcTemplate.class);
        var service=mock(SubcontractShortDeliveryService.class,CALLS_REAL_METHODS);
        ReflectionTestUtils.setField(service,"jdbc",jdbc);UUID receipt=UUID.randomUUID();
        when(jdbc.queryForList(anyString(),eq(receipt))).thenReturn(List.of());
        assertThat(service.preStockedHoldReason(receipt)).isNull();
        var captured=ArgumentCaptor.forClass(String.class);verify(jdbc).queryForList(captured.capture(),eq(receipt));
        String current=captured.getValue();assertThat(current).contains("fn_subcontract_finished_delivery_floor");
        String original=HistoricalSubcontract1032SqlTransport.originalJdbcSql(current);
        assertThat(original).doesNotContain("fn_subcontract_finished_delivery_floor");
        String compact=original.replaceAll("\\s+","");
        assertThat(compact).contains("c.status='PENDING_OWNER'ANDoi.allowed_loss_pctISNOTNULL",
                "oi.qty*(100-oi.allowed_loss_pct)*0.01",
                "c.status='WAITING_MORE'ANDc.expected_complete_by<CURRENT_DATE");
        assertThat(HistoricalSubcontract1032SqlTransport.originalJdbcSql(current+" FOR UPDATE")).isEqualTo(current+" FOR UPDATE");
    }

    @Test void costCompletenessUsesTheOriginalRealPlanAndUnreversedConsumptionQuery() {
        var jdbc=mock(org.springframework.jdbc.core.namedparam.NamedParameterJdbcTemplate.class);
        var service=mock(com.uten.imp.features.stock.valuation.SubcontractOwnMaterialCostService.class,CALLS_REAL_METHODS);
        ReflectionTestUtils.setField(service,"db",jdbc);UUID receipt=UUID.randomUUID();
        when(jdbc.queryForObject(anyString(),anyMap(),eq(Boolean.class))).thenReturn(true);
        assertThat((Boolean)ReflectionTestUtils.invokeMethod(service,"materialScopeComplete",receipt,java.math.BigDecimal.ONE)).isTrue();
        var captured=ArgumentCaptor.forClass(String.class);verify(jdbc).queryForObject(captured.capture(),anyMap(),eq(Boolean.class));
        String named=captured.getValue();
        String current=org.springframework.jdbc.core.namedparam.NamedParameterUtils.substituteNamedParameters(
                org.springframework.jdbc.core.namedparam.NamedParameterUtils.parseSqlStatement(named),
                new org.springframework.jdbc.core.namedparam.MapSqlParameterSource(java.util.Map.of("id",receipt,"target",java.math.BigDecimal.ONE)));
        String original=HistoricalSubcontract1032SqlTransport.originalJdbcSql(current);
        assertThat(original).doesNotContain("fn_subcontract_receipt_material_line_proven","material_consumption_version");
        assertThat(original).contains("item.material_basis_qty*COALESCE(item.unit_rate,1)=?",
                "issue.plan_item_id=plan.id","c.reversal_of IS NULL AND c.qty_doc>0","reversed.reversal_of=c.id");
        assertThat(HistoricalSubcontract1032SqlTransport.originalJdbcSql(current+" FOR UPDATE")).isEqualTo(current+" FOR UPDATE");
    }

    @Test void ceilingComesFromTheOriginalStoredOrderFactAndOtherSqlIsUntouched() {
        String original="SELECT fn_subcontract_normal_receipt_limit(source_item.id) FROM subcontract_order_items source_item WHERE id=:id";
        assertThat(HistoricalSubcontract1032SqlTransport.originalJdbcSql(original))
                .isEqualTo("SELECT (SELECT original1032.qty FROM public.subcontract_order_items original1032 WHERE original1032.id=source_item.id AND NOT original1032.is_deleted) FROM subcontract_order_items source_item WHERE id=:id");
        assertThat(HistoricalSubcontract1032SqlTransport.originalJdbcSql("SELECT fn_subcontract_normal_receipt_limit(?)"))
                .isEqualTo("SELECT (SELECT original1032.qty FROM public.subcontract_order_items original1032 WHERE original1032.id=? AND NOT original1032.is_deleted)");
        assertThat(HistoricalSubcontract1032SqlTransport.originalJdbcSql("SELECT fn_subcontract_physical_receipt_capacity(?)"))
                .isEqualTo("SELECT fn_subcontract_returnable_qty(?)");
        String text="SELECT 'fn_subcontract_normal_receipt_limit(source_item.id)',\"fn_subcontract_normal_receipt_limit(source_item.id)\" -- fn_subcontract_normal_receipt_limit(source_item.id)";
        assertThat(HistoricalSubcontract1032SqlTransport.originalJdbcSql(text)).isEqualTo(text);
        String unsupported="SELECT fn_subcontract_normal_receipt_limit(:source)";
        assertThat(HistoricalSubcontract1032SqlTransport.originalJdbcSql(unsupported)).isEqualTo(unsupported);
    }

    @Test void onlyTheExactImplicitVersionReadIsAdaptedAndItStillExecutesAgainstTheRealRow() {
        EntityManager actual=mock(EntityManager.class);Query statement=mock(Query.class);
        when(actual.createNativeQuery("SELECT 1 FROM subcontract_receipt_items WHERE id=:id\n")).thenReturn(statement);
        when(statement.setParameter("id","original-row")).thenReturn(statement);
        var transport=HistoricalSubcontract1032SqlTransport.entityManager(actual);
        Query adapted=transport.createNativeQuery("SELECT material_consumption_version FROM subcontract_receipt_items WHERE id=:id");
        assertThat(adapted.setParameter("id","original-row")).isSameAs(adapted);
        verify(statement).setParameter("id","original-row");
        verify(statement,never()).getSingleResult();
        assertThatThrownBy(()->transport.createNativeQuery("SELECT material_consumption_version FROM subcontract_receipt_items WHERE id=:id FOR UPDATE"))
                .isInstanceOf(IllegalStateException.class);
    }
}
