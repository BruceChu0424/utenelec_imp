package com.uten.imp.features.warehouse.inbound;

import com.uten.imp.application.port.WarehouseTaskScopePort.WarehouseTaskScope;
import com.uten.imp.security.SecurityContextCurrentUser;
import jakarta.persistence.EntityManager;
import jakarta.persistence.Query;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.Test;
import org.springframework.security.authentication.UsernamePasswordAuthenticationToken;
import org.springframework.security.core.authority.SimpleGrantedAuthority;
import org.springframework.security.core.context.SecurityContextHolder;
import java.util.List;
import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.Mockito.*;

class WarehouseQualityPreStockBadgeTest {
    @AfterEach void clear() { SecurityContextHolder.clearContext(); }

    @Test void aViewOnlyPhysicalKeeperStillTracksPendingInspectionWithinTheSelectedWarehouse() {
        SecurityContextHolder.getContext().setAuthentication(new UsernamePasswordAuthenticationToken("keeper","unused",
                List.of(new SimpleGrantedAuthority(ProcurementIqcStockInPermissions.VIEW))));
        var id=java.util.UUID.randomUUID();
        var scope=new WarehouseTaskScope(true,List.of(id),false);
        var scopes=mock(com.uten.imp.application.port.WarehouseTaskScopePort.class);
        when(scopes.access()).thenReturn(new com.uten.imp.application.port.WarehouseTaskScopePort.WarehouseAccess(
                com.uten.imp.application.port.WarehouseTaskScopePort.Role.KEEPER,List.of(id),scope,false));
        EntityManager em=mock(EntityManager.class); Query query=mock(Query.class,RETURNS_SELF);
        when(em.createNativeQuery(anyString())).thenReturn(query);
        when(query.getResultList()).thenReturn(List.<Object[]>of(new Object[]{"PURCHASE","WAITING_INSPECTION",1L}));
        var service=new WarehouseQualityResultService(em,mock(SecurityContextCurrentUser.class)); service.setWarehouseScopes(scopes);
        assertThat(service.typeCounts(scope).inProgress().get("PURCHASE")).isEqualTo(1);
        verify(query).setParameter("warehouse_scope",id.toString());
        verify(query).setParameter("taskCanStockIn",false);
        verify(query).setParameter("taskCanReturn",false);
        when(scopes.access()).thenReturn(new com.uten.imp.application.port.WarehouseTaskScopePort.WarehouseAccess(
                com.uten.imp.application.port.WarehouseTaskScopePort.Role.OTHER,List.of(),scope,false));
        clearInvocations(em);
        assertThat(service.typeCounts(scope).inProgress().get("PURCHASE")).isZero();
        verifyNoInteractions(em);
    }

    @Test void beforeInspectionKeeperReceivesWaitingBadgeWithoutFinalStockInAuthority() {
        SecurityContextHolder.getContext().setAuthentication(new UsernamePasswordAuthenticationToken("keeper","unused",
                List.of(new SimpleGrantedAuthority(ProcurementIqcStockInPermissions.VIEW),
                        new SimpleGrantedAuthority(ProcurementIqcStockInPermissions.BEFORE_INSPECTION))));
        EntityManager em=mock(EntityManager.class);
        Query query=mock(Query.class,RETURNS_SELF);
        when(em.createNativeQuery(anyString())).thenReturn(query);
        when(query.getResultList()).thenReturn(List.<Object[]>of(new Object[]{"PURCHASE","WAITING_INSPECTION",1L}));
        var counts=new WarehouseQualityResultService(em,mock(SecurityContextCurrentUser.class)).typeCounts(WarehouseTaskScope.ALL);
        assertThat(counts.inProgress().get("PURCHASE")).isEqualTo(1);
        assertThat(counts.actionable().get("PURCHASE")).isZero();
        verify(query).setParameter("taskCanStockIn",false);
        verify(query).setParameter("taskCanReturn",false);
    }

    /**
     * 品质检查结果页的二级分段(status-counts 的 TASK_* 桶)与一级大类(type-counts)、列表同一浏览范围:
     * 一级按浏览范围有数、二级却按职责范围少算(或被任务改写剥成 0)时, 父有红徽章、子分段却没有。
     * 桶内动作资格(入库/退回)照旧按会话权限判定。
     */
    @Test void segmentTaskBucketsShareTheParentBrowsingRangeAndKeepTheirActionEligibility() {
        SecurityContextHolder.getContext().setAuthentication(new UsernamePasswordAuthenticationToken("keeper","unused",
                List.of(new SimpleGrantedAuthority(ProcurementIqcStockInPermissions.VIEW),
                        new SimpleGrantedAuthority(ProcurementIqcStockInPermissions.CONFIRM))));
        var selected=java.util.UUID.randomUUID();
        var browse=new WarehouseTaskScope(true,List.of(selected,java.util.UUID.randomUUID()),false);
        var scopes=mock(com.uten.imp.application.port.WarehouseTaskScopePort.class);
        when(scopes.currentForRead(selected)).thenReturn(browse);
        when(scopes.current(selected)).thenReturn(new WarehouseTaskScope(true,List.of(selected),false));
        EntityManager em=mock(EntityManager.class); Query query=mock(Query.class,RETURNS_SELF);
        when(em.createNativeQuery(anyString())).thenReturn(query);
        when(query.getResultList()).thenReturn(List.<Object[]>of(new Object[]{"ALL_PASSED",2L}));
        var service=new WarehouseQualityResultService(em,mock(SecurityContextCurrentUser.class)); service.setWarehouseScopes(scopes);

        var counts=service.taskStatusCounts("ALL","",selected);

        assertThat(counts).containsEntry("ALL_PASSED",2L).containsEntry("RETURN_REQUIRED",0L);
        verify(query).setParameter("warehouse_scope",browse.idsCsv());
        verify(query).setParameter("taskCanStockIn",true);
        verify(query).setParameter("taskCanReturn",false);
        verify(scopes,never()).current(any());
    }
}
