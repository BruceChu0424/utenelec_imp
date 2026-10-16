package com.uten.imp.features.warehouse.taskcenter;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.application.port.WarehouseTaskScopePort;
import com.uten.imp.audit.AuditDetailViewRecorder;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.features.stock.StockDocAccessPolicy;
import com.uten.imp.security.AuthUser;
import com.uten.imp.security.OwnerVisibility.OwnerScope;
import com.uten.imp.security.ProductionStockTaskAccessPolicy;
import com.uten.imp.security.SecurityContextCurrentUser;
import jakarta.persistence.EntityManager;
import jakarta.persistence.Query;
import org.junit.jupiter.api.Test;
import org.mockito.ArgumentCaptor;

import java.math.BigDecimal;
import java.time.LocalDate;
import java.util.Collections;
import java.util.List;
import java.util.Optional;
import java.util.Set;
import java.util.UUID;

import static com.uten.imp.features.warehouse.taskcenter.WarehouseTaskCenterContracts.*;
import static org.assertj.core.api.Assertions.*;
import static org.mockito.ArgumentMatchers.*;
import static org.mockito.Mockito.*;

class WarehouseOutboundTaskCenterQueryServiceTest {
    private static final UUID ACTOR = UUID.fromString("00000000-0000-0000-0000-000000000001");
    private static final UUID OTHER_OWNER = UUID.fromString("00000000-0000-0000-0000-000000000002");

    @Test
    void oneDatabasePageUsesSourceIdentityAndGlobalFacetsRatherThanFirstPages() throws Exception {
        Fixture f = new Fixture(Set.of("stock_doc:view", "warehouse_sales_outbound:view"), true,
                new OwnerScope(true, Set.of()));
        UUID sharedId = UUID.randomUUID();
        Query count = query(); when(count.getSingleResult()).thenReturn(4L);
        Query rows = query(); when(rows.getResultList()).thenReturn(List.of(
                row("SALES", "SALES_SHIPMENT", sharedId, "SALES_SHIPPED", OTHER_OWNER, false),
                row("OTHER", "STOCK_DOC", sharedId, "OTHER_APPROVED", ACTOR, false)));
        Query states = query(); when(states.getResultList()).thenReturn(List.of(
                new Object[]{"SALES_PENDING", 2L}, new Object[]{"SALES_SHIPPED", 1L}, new Object[]{"OTHER_APPROVED", 1L}));
        Query bills = query(); when(bills.getResultList()).thenReturn(Collections.singletonList(new Object[]{"SAME-NUMBER", 4L}));
        when(f.em.createNativeQuery(anyString())).thenReturn(count, rows, states, bills);

        Page result = f.service.list(new Filter("ALL", null, null, null, null, null, null, 2, 2, "billNo", "asc", TaskView.ALL));
        assertThat(result.page()).isEqualTo(2);
        assertThat(result.total()).isEqualTo(4);
        assertThat(result.items()).extracting(Row::rowKey).containsExactly(
                "SALES:SALES_SHIPMENT:" + sharedId, "OTHER:STOCK_DOC:" + sharedId);
        assertThat(result.items()).allMatch(item -> !item.canHandle());
        verify(f.scopes).withQueryScopeCache(any());
        verify(f.scopes, never()).withScopeCache(any());
        assertThat(result.facets().get("status")).anyMatch(bucket -> bucket.value().equals("SALES_PENDING") && bucket.count() == 2);
        verify(rows).setParameter("offset", 2L);
        verify(rows).setParameter("limit", 2);
        ArgumentCaptor<String> sql = ArgumentCaptor.forClass(String.class);
        verify(f.em, times(4)).createNativeQuery(sql.capture());
        assertThat(sql.getAllValues().get(1)).contains("UNION ALL", "FROM filtered", "ORDER BY keyword_rank,bill_no ASC", "source_type,record_type,id", "OFFSET :offset");
        assertThat(sql.getAllValues().get(3)).contains("GROUP BY bill_no", "LIMIT 500");
        String json = new ObjectMapper().findAndRegisterModules().writeValueAsString(result);
        assertThat(json).doesNotContain("amountLocal", "totalOriginal", "price", "currency", "cost");
    }

    @Test
    void makerReadGrantNeverBecomesStockEditOrProductionTaskOwnership() {
        Fixture f = new Fixture(Set.of("stock_doc:view", "stock_doc:edit"), false,
                new OwnerScope(false, Set.of(ACTOR, OTHER_OWNER), Set.of(ACTOR)));
        var access = new WarehouseOutboundTaskCenterSql.Access(false, false, false, true, false,
                new OwnerScope(false, Set.of(ACTOR, OTHER_OWNER), Set.of(ACTOR)));
        Row other = f.service.map(row("OTHER", "STOCK_DOC", UUID.randomUUID(), "OTHER_DRAFT", OTHER_OWNER, true), access);
        assertThat(other.canHandle()).isFalse();
        assertThat(other.action()).isEqualTo("STOCK_DETAIL");
        assertThat(other.actionData().get("canEdit")).isEqualTo(false);
        Row draw = f.service.map(row("DRAW", "STOCK_DOC", UUID.randomUUID(), "DRAW_PENDING", ACTOR, true), access);
        assertThat(draw.canHandle()).isFalse();
        assertThat(draw.action()).isEqualTo("STOCK_DETAIL");
    }

    @Test
    void sourcePermissionAndSelectedWarehouseAreCheckedBeforeAnyRowsAreRead() {
        Fixture f = new Fixture(Set.of("stock_doc:view"), false, new OwnerScope(false, Set.of(ACTOR)));
        assertThatThrownBy(() -> f.service.list(new Filter("SALES", null, null, null, null, null, null, 1, 20)))
                .isInstanceOf(ApiException.class);
        verifyNoInteractions(f.em);
        UUID outside = UUID.randomUUID();
        when(f.scopes.current(outside)).thenThrow(new ApiException(com.uten.imp.common.web.ErrorCode.FORBIDDEN, "outside"));
        assertThatThrownBy(() -> f.service.list(new Filter("OTHER", null, null, null, null, null, outside, 1, 20)))
                .isInstanceOf(ApiException.class);
        verifyNoInteractions(f.em);
    }

    @Test
    void productionParticipantBypassesOnlyDrawMakerWhileManualStockStillUsesOwnerScope() {
        var scope = new WarehouseTaskScopePort.WarehouseTaskScope(true, List.of(UUID.randomUUID()), false);
        var access = new WarehouseOutboundTaskCenterSql.Access(false, false, false, true, true,
                new OwnerScope(false, Set.of(ACTOR)));
        var plan = WarehouseOutboundTaskCenterSql.build(new Filter("ALL", null, "外壳", null, null, null, null, 1, 20),
                access, scope, ACTOR.toString());
        assertThat(plan.cte()).contains("d.doc_type='DRAW' AND ((d.maker_id IN (:stockOwners) OR fn_is_production_linked_stock_document(d.id)))",
                "d.doc_type='OTHER_OUT' AND (d.maker_id IN (:stockOwners))",
                "d.doc_type='FINISHED_OUT' AND (d.maker_id IN (:stockOwners))", "fn_production_draw_requested(d.id)");
        assertThat(plan.cte()).contains("AND NOT COALESCE(warehouse.is_line_side,FALSE)");
        assertThat(plan.parameters().get("stockOwners")).isEqualTo(Set.of(ACTOR));
        assertThat(plan.parameters().get("warehouseScope")).isEqualTo(scope.idsCsv());
        assertThat(plan.cte()).doesNotContain("d.doc_type='WDRAW'", "total_original", "amount_local");
    }

    @Test
    void historyPermissionDoesNotAllowHandlingPendingSubcontractDrafts() {
        Fixture f = new Fixture(Set.of("warehouse_subcontract_outbound_history:view", "subcontract_outbound:execute",
                "subcontract_material_issue:view", "subcontract_material_issue:edit", "subcontract_material_issue:approve"), false,
                new OwnerScope(true, Set.of()));
        var access = new WarehouseOutboundTaskCenterSql.Access(false, false, true, false, false, new OwnerScope(true, Set.of()));
        Row result = f.service.map(row("SUBCONTRACT", "SUBCONTRACT_MATERIAL_ISSUE", UUID.randomUUID(),
                "SUBCONTRACT_PENDING", ACTOR, true), access);
        assertThat(result.action()).isEqualTo("HISTORY_DETAIL");
        assertThat(result.canHandle()).isFalse();
    }

    @Test
    void impersonatedViewerRetainsReadableRowsWithoutAnyOutboundCommandCapability() {
        Fixture f = new Fixture(Set.of("warehouse_sales_outbound:execute", "subcontract_outbound:execute",
                "subcontract_material_issue:view", "subcontract_material_issue:edit", "subcontract_material_issue:approve",
                "stock_doc:edit", "stock_doc:approve", "stock_doc:issue"), true, new OwnerScope(true, Set.of()));
        var access = new WarehouseOutboundTaskCenterSql.Access(true, true, true, true, true, new OwnerScope(true, Set.of()));
        List<Object[]> pending = List.of(
                row("SALES", "SALES_SHIPMENT", UUID.randomUUID(), "SALES_PENDING", ACTOR, true),
                row("SUBCONTRACT", "SUBCONTRACT_MATERIAL_ISSUE", UUID.randomUUID(), "SUBCONTRACT_PENDING", ACTOR, true),
                row("DRAW", "STOCK_DOC", UUID.randomUUID(), "DRAW_PENDING", ACTOR, true),
                row("DRAW", "MATERIAL_DISCOVERY", UUID.randomUUID(), "DRAW_DISCOVERY_PENDING", ACTOR, true),
                row("OTHER", "STOCK_DOC", UUID.randomUUID(), "OTHER_DRAFT", ACTOR, true),
                row("FINISHED", "STOCK_DOC", UUID.randomUUID(), "FINISHED_DRAFT", ACTOR, true));
        assertThat(pending.stream().map(raw -> f.service.map(raw, access))).allMatch(Row::canHandle);

        when(f.user.getImpersonatedBy()).thenReturn(UUID.randomUUID());
        List<Row> readonly = pending.stream().map(raw -> f.service.map(raw, access)).toList();
        assertThat(readonly).hasSize(pending.size()).allMatch(item -> !item.canHandle());
        assertThat(readonly.getFirst().actionData().get("allowedWarehouseTargets")).isEqualTo(List.of());
        assertThat(readonly.get(1).action()).isEqualTo("HISTORY_DETAIL");
        assertThat(readonly.get(2).action()).isEqualTo("STOCK_DETAIL");
        assertThat(readonly.subList(4, 6)).allSatisfy(item -> {
            assertThat(item.action()).isEqualTo("STOCK_DETAIL");
            assertThat(item.actionData()).containsEntry("canEdit", false).containsEntry("canApprove", false);
        });
        assertThat(readonly.get(3).actionData()).containsEntry("requestId", pending.get(3)[2]);
        assertThat(readonly.get(3).action()).isEqualTo("HISTORY_DETAIL");
    }

    @Test
    void materialDiscoveryHistoryAndViewOnlyRecordsUseScopedPhysicalDetail() {
        Fixture f = new Fixture(Set.of("stock_doc:view"), true, new OwnerScope(false, Set.of(ACTOR)));
        var access = new WarehouseOutboundTaskCenterSql.Access(false, false, false, true, true, new OwnerScope(false, Set.of(ACTOR)));
        for (String status : List.of("DRAW_DISCOVERY_PENDING", "DRAW_DISCOVERY_CONFIGURED",
                "DRAW_DISCOVERY_CANCELLED", "DRAW_DISCOVERY_BLOCKED")) {
            UUID request = UUID.randomUUID();
            Row result = f.service.map(row("DRAW", "MATERIAL_DISCOVERY", request, status, ACTOR,
                    status.equals("DRAW_DISCOVERY_PENDING")), access);
            assertThat(result.canHandle()).isFalse();
            assertThat(result.action()).isEqualTo("HISTORY_DETAIL");
            assertThat(result.actionData()).containsEntry("requestId", request);
        }
    }

    @Test
    void cancelledSalesAndReversedDrawAvoidLegacyDetailGatesThatRejectRetainedFacts() {
        Fixture f = new Fixture(Set.of("stock_doc:view", "warehouse_sales_outbound:view"), true, new OwnerScope(true, Set.of()));
        var access = new WarehouseOutboundTaskCenterSql.Access(true, false, false, true, true, new OwnerScope(true, Set.of()));
        for (String status : List.of("SALES_SHIPPED", "SALES_CANCELLED", "SALES_REVERSED", "SALES_LEGACY")) {
            Row sales = f.service.map(row("SALES", "SALES_SHIPMENT", UUID.randomUUID(), status, ACTOR, false), access);
            assertThat(sales.canHandle()).isFalse();
            assertThat(sales.action()).isEqualTo("HISTORY_DETAIL");
        }
        Row reversedDraw = f.service.map(row("DRAW", "STOCK_DOC", UUID.randomUUID(), "DRAW_REVERSED", ACTOR, false), access);
        assertThat(reversedDraw.canHandle()).isFalse();
        assertThat(reversedDraw.action()).isEqualTo("HISTORY_DETAIL");
        assertThat(reversedDraw.actionData()).containsEntry("docType", "DRAW");
    }

    @Test
    void retainedDetailRechecksIdentityScopeAndReturnsOnlyPagedPhysicalLines() throws Exception {
        Fixture f = new Fixture(Set.of("warehouse_subcontract_outbound_history:view"), false, new OwnerScope(false, Set.of()));
        UUID id = UUID.randomUUID();
        Query header = query(); when(header.getResultList()).thenReturn(Collections.singletonList(
                row("SUBCONTRACT", "SUBCONTRACT_MATERIAL_ISSUE", id, "SUBCONTRACT_WITHDRAWN", OTHER_OWNER, false)));
        Query count = query(); when(count.getSingleResult()).thenReturn(2L);
        Query lines = query(); when(lines.getResultList()).thenReturn(Collections.singletonList(new Object[]{
                UUID.randomUUID(), 2, "MATERIAL-2", "撤回物料", "本色", "kg", new BigDecimal("3.25"), new BigDecimal("4"), null, null, "A-2"
        }));
        when(f.em.createNativeQuery(anyString())).thenReturn(header, count, lines);
        var detail = f.service.detail("SUBCONTRACT:SUBCONTRACT_MATERIAL_ISSUE:" + id, null, 2, 1);
        assertThat(detail.document().canHandle()).isFalse();
        assertThat(detail.document().actionData()).containsEntry("retained", true);
        assertThat(detail.page()).isEqualTo(2);
        assertThat(detail.total()).isEqualTo(2);
        assertThat(detail.lines().getFirst().quantity()).isEqualByComparingTo("3.25");
        verify(header).setParameter("rowId", id);
        verify(header).setParameter("rowSource", "SUBCONTRACT");
        verify(lines).setParameter("lineOffset", 1L);
        verify(f.audit).recordHistory("view_subcontract_material_issue_detail", "subcontract_material_issues", id,
                "SAME-NUMBER", null, "仓库出库实物记录");
        verify(f.scopes).withQueryScopeCache(any());
        verify(f.scopes, never()).withScopeCache(any());
        assertThat(new ObjectMapper().findAndRegisterModules().writeValueAsString(detail))
                .doesNotContain("price", "amount", "cost", "currency");
    }

    @Test
    void detailNeverReadsLinesForAnAbsentOrHiddenUnionRow() {
        Fixture f = new Fixture(Set.of("stock_doc:view"), false, new OwnerScope(false, Set.of(ACTOR)));
        Query header = query(); when(header.getResultList()).thenReturn(List.of());
        when(f.em.createNativeQuery(anyString())).thenReturn(header);
        assertThatThrownBy(() -> f.service.detail("OTHER:STOCK_DOC:" + UUID.randomUUID(), null, 1, 100)).isInstanceOf(ApiException.class);
        verify(f.em, times(1)).createNativeQuery(anyString());
        verifyNoInteractions(f.audit);
    }

    @Test
    void malformedStatusSortAndDateRangesCannotBroadenTheQuery() {
        for (Filter input : List.of(new Filter("ALL", "ignored", null, null, null, null, null, 1, 20),
                new Filter("ALL", null, null, null, null, null, null, 1, 20, "price", "asc"),
                new Filter("ALL", null, null, null, LocalDate.of(2026, 10, 2), LocalDate.of(2026, 10, 1), null, 1, 20))) {
            assertThatThrownBy(() -> WarehouseOutboundTaskCenterQueryService.normalize(input)).isInstanceOf(ApiException.class);
        }
    }

    private static Query query() { return mock(Query.class, RETURNS_SELF); }

    private static Object[] row(String source, String record, UUID id, String status, UUID maker, boolean actionable) {
        return new Object[]{source, record, id, "SAME-NUMBER", "SOURCE-1", LocalDate.of(2026, 10, 1),
                "往来单位", "原材料仓", "经办人", 1, status, maker,
                status.endsWith("APPROVED") || status.endsWith("SHIPPED") ? 1 : 0,
                status.equals("DRAW_PARTIAL") ? 1 : status.equals("DRAW_SHIPPED") ? 2 : 0,
                7L, null, true, actionable};
    }

    private static final class Fixture {
        final EntityManager em = mock(EntityManager.class);
        final WarehouseTaskScopePort scopes = mock(WarehouseTaskScopePort.class);
        final AuditDetailViewRecorder audit = mock(AuditDetailViewRecorder.class);
        final AuthUser user = mock(AuthUser.class);
        final WarehouseOutboundTaskCenterQueryService service;
        Fixture(Set<String> permissions, boolean production, OwnerScope owners) {
            StockDocAccessPolicy access = mock(StockDocAccessPolicy.class);
            when(access.hasAuthority(anyString())).thenAnswer(invocation -> permissions.contains(invocation.getArgument(0)));
            when(access.scope()).thenReturn(owners);
            SecurityContextCurrentUser actor = mock(SecurityContextCurrentUser.class);
            when(actor.get()).thenReturn(Optional.of(user));
            when(actor.employeeId()).thenReturn(Optional.of(ACTOR));
            when(scopes.current(any())).thenReturn(WarehouseTaskScopePort.WarehouseTaskScope.ALL);
            doCallRealMethod().when(scopes).withQueryScopeCache(any());
            ProductionStockTaskAccessPolicy tasks = mock(ProductionStockTaskAccessPolicy.class);
            when(tasks.canAccessWarehouseTasks()).thenReturn(production);
            service = new WarehouseOutboundTaskCenterQueryService(em, access, actor, scopes, tasks, audit);
        }
    }
}
