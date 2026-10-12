package com.uten.imp.features.warehouse.taskcenter;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.application.port.WarehouseTaskScopePort;
import com.uten.imp.application.port.WarehouseTaskScopePort.WarehouseTaskScope;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.features.stock.StockDocAccessPolicy;
import com.uten.imp.features.warehouse.taskcenter.WarehouseTaskCenterContracts.Filter;
import com.uten.imp.security.AuthUser;
import com.uten.imp.security.OwnerVisibility.OwnerScope;
import com.uten.imp.security.ProductionStockTaskAccessPolicy;
import com.uten.imp.security.SecurityContextCurrentUser;
import org.junit.jupiter.api.Test;
import org.springframework.jdbc.core.namedparam.NamedParameterJdbcTemplate;

import java.util.Optional;
import java.util.Set;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.verifyNoInteractions;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;
import static org.mockito.Mockito.doReturn;

class WarehouseInboundTaskCenterQueryServiceTest {
    @Test
    @SuppressWarnings({"unchecked", "rawtypes"})
    void authorizedListUsesAReadLeaseWithoutEnteringTheCommandCallback() {
        var jdbc=mock(NamedParameterJdbcTemplate.class);
        var current=mock(SecurityContextCurrentUser.class);
        when(current.get()).thenReturn(Optional.of(new AuthUser(UUID.randomUUID(),UUID.randomUUID(),"warehouse",
                Set.of("warehouse_purchase_receipt_history:view"),false,true,false)));
        var scopes=mock(WarehouseTaskScopePort.class);
        when(scopes.current(null)).thenReturn(WarehouseTaskScope.ALL);
        org.mockito.Mockito.doCallRealMethod().when(scopes).withQueryScopeCache(org.mockito.ArgumentMatchers.any());
        var stock=mock(StockDocAccessPolicy.class);
        when(stock.scope()).thenReturn(new OwnerScope(true,Set.of()));
        when(stock.nativeReadScope(org.mockito.ArgumentMatchers.anyString(),org.mockito.ArgumentMatchers.anyString(),
                org.mockito.ArgumentMatchers.any(OwnerScope.class)))
                .thenReturn(new com.uten.imp.security.DocumentAccessPolicy.NativeReadScope("1=1",null,Set.of()));
        when(jdbc.queryForObject(org.mockito.ArgumentMatchers.anyString(),
                org.mockito.ArgumentMatchers.any(org.springframework.jdbc.core.namedparam.MapSqlParameterSource.class),
                org.mockito.ArgumentMatchers.eq(Long.class))).thenReturn(0L);
        when(jdbc.query(org.mockito.ArgumentMatchers.anyString(),
                org.mockito.ArgumentMatchers.any(org.springframework.jdbc.core.namedparam.MapSqlParameterSource.class),
                org.mockito.ArgumentMatchers.any(org.springframework.jdbc.core.RowMapper.class))).thenReturn(java.util.List.of());
        var service=new WarehouseInboundTaskCenterQueryService(jdbc,new ObjectMapper(),current,scopes,stock,
                mock(ProductionStockTaskAccessPolicy.class));
        assertThat(service.list(filter("PURCHASE","")).total()).isZero();
        verify(scopes).withQueryScopeCache(org.mockito.ArgumentMatchers.any());
        verify(scopes,org.mockito.Mockito.never()).withScopeCache(org.mockito.ArgumentMatchers.any());
    }

    @Test
    void unknownSourceStatusSortAndUnauthorizedDomainNeverReachTheDatabase() {
        var jdbc=mock(NamedParameterJdbcTemplate.class);
        var current=mock(SecurityContextCurrentUser.class);
        when(current.get()).thenReturn(Optional.of(new AuthUser(UUID.randomUUID(),UUID.randomUUID(),"warehouse",
                Set.of("warehouse_purchase_receipt_history:view"),false,true,false)));
        var scope=mock(WarehouseTaskScopePort.class);
        var stock=mock(StockDocAccessPolicy.class);
        when(stock.scope()).thenReturn(new OwnerScope(false,Set.of()));
        var service=new WarehouseInboundTaskCenterQueryService(jdbc,new ObjectMapper(),current,scope,stock,
                mock(ProductionStockTaskAccessPolicy.class));
        assertThatThrownBy(()->service.list(filter("UNKNOWN",""))).isInstanceOf(ApiException.class);
        assertThatThrownBy(()->service.list(filter("ALL","PURCHASE_FUTURE_STATE"))).isInstanceOf(ApiException.class);
        assertThatThrownBy(()->service.list(new Filter("ALL","","",null,null,null,null,1,20,"total","asc")))
                .isInstanceOf(ApiException.class);
        assertThatThrownBy(()->service.list(filter("OTHER",""))).isInstanceOf(ApiException.class);
        verifyNoInteractions(jdbc,scope);
    }

    @Test
    void sourcePermissionsAndWarehouseScopeAreInsideTheSharedRelation() {
        UUID warehouse=UUID.randomUUID();
        var scope=new WarehouseTaskScope(true,java.util.List.of(warehouse),false);
        String base=WarehouseInboundTaskCenterSql.base(new WarehouseInboundTaskCenterSql.Access(
                false,true,false,false,false,false,"1=0"),scope);
        // Only an authorized receipt family is added to the relation. The common CTEs do not grant access.
        String relation=base.substring(base.indexOf("inbound_rows AS"));
        assertThat(relation).contains("FROM purchase_receipts h","physical.warehouse_ids",":warehouseScope")
                .doesNotContain("FROM subcontract_receipts h","FROM stock_documents document","FROM inbound_expectations expectation");
        assertThat(WarehouseInboundTaskCenterSql.rows(base)).contains("FROM inbound_rows","ORDER BY","LIMIT :limit OFFSET :offset");
        assertThat(WarehouseInboundTaskCenterSql.count(base)).contains(WarehouseInboundTaskCenterSql.predicate(true));
        assertThat(WarehouseInboundTaskCenterSql.facets(base)).contains(WarehouseInboundTaskCenterSql.predicate(false));
        assertThat(WarehouseInboundTaskCenterSql.billNoFacets(base)).doesNotContain("bill_no=CAST(:billNo");
    }

    @Test
    void authoritativeTaskStagesHaveNoPerSourcePageLimitAndFinalCountReplacesOnlyItsSameDocument() {
        String base=WarehouseInboundTaskCenterSql.base(new WarehouseInboundTaskCenterSql.Access(
                true,true,true,true,true,true,"document.maker_id IN (:stockOwners)"),
                new WarehouseTaskScope(true,java.util.List.of(UUID.randomUUID()),false));
        assertThat(base).contains("v_production_report_items_pending_registration","FINISHED_WAITING_FQC",
                "FINISHED_FQC_PARTIAL","FINISHED_RESIDUAL_COUNT","task.document_id=document.id",
                "fn_inbound_expectation_warehouse_ids(expectation.id)")
                .doesNotContain("LIMIT :limit","OFFSET :offset");
    }

    @Test
    void detailAuditIsWrittenOnlyAfterAScopeAuthorizedPhysicalLookupSucceeds() {
        var service=mock(WarehouseInboundTaskCenterQueryService.class);
        var audit=mock(com.uten.imp.audit.AuditDetailViewRecorder.class);
        var controller=new WarehouseInboundTaskCenterController(service,audit);
        UUID id=UUID.randomUUID();
        String key="PURCHASE:EXPECTATION:"+id;
        when(service.detail(key,null,1,50)).thenThrow(new ApiException(com.uten.imp.common.web.ErrorCode.FORBIDDEN,"越界"));
        assertThatThrownBy(()->controller.detail(key,null,1,50)).isInstanceOf(ApiException.class);
        verifyNoInteractions(audit);
        var row=new WarehouseTaskCenterContracts.Row(key,id,"PURCHASE","EXPECTATION","CD-01",null,
                java.time.LocalDate.of(2026,10,12),null,null,null,1,"PURCHASE_READY_REGISTER","采购待登记到货",
                "success","HISTORY_DETAIL",id,false,java.util.Map.of());
        // Re-stub without invoking the mock's previously configured forbidden lookup.
        doReturn(java.util.Map.of("row",row,"items",java.util.List.of())).when(service).detail(key,null,1,50);
        controller.detail(key,null,1,50);
        verify(audit).record("view_warehouse_inbound_expectation_detail","inbound_expectations",id,"CD-01",null,"仓库入库记录");
    }

    private static Filter filter(String source,String status) {
        return new Filter(source,status,"",null,null,null,null,1,20);
    }
}
