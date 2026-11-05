package com.uten.imp.features.production.execution;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.application.port.SalesDeliveryInventoryPort;
import com.uten.imp.application.port.SalesDeliveryMutationPort;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.production.ProductionDocumentAccessPolicy;
import com.uten.imp.features.production.ProductionWorkshopMembership;
import com.uten.imp.security.AuthUser;
import com.uten.imp.security.DocumentAccessPolicy;
import com.uten.imp.security.SecurityContextCurrentUser;
import com.uten.imp.security.TxSessionVars;
import jakarta.persistence.EntityManager;
import jakarta.persistence.Query;
import org.junit.jupiter.api.Test;
import java.math.BigDecimal;
import java.time.OffsetDateTime;
import java.util.*;
import static com.uten.imp.features.production.execution.DeliveryProcessingContracts.*;
import static org.assertj.core.api.Assertions.*;
import static org.mockito.ArgumentMatchers.*;
import static org.mockito.Mockito.*;

class DeliveryProcessingServiceAuthorizationTest {
    @Test void viewPermissionDoesNotAuthorizeAnyProcessingMutation() {
        var f=new Fixture("production_execution:view");
        for(Runnable action:List.<Runnable>of(
                ()->f.service.assign(f.component,new Assignment(1L,UUID.randomUUID(),null,UUID.randomUUID())),
                ()->f.service.start(f.component,new Start(1L,f.warehouse,UUID.randomUUID())),
                ()->f.service.report(f.component,new Report(1L,BigDecimal.ONE,"LASER","全部加工和检验已完成",UUID.randomUUID())),
                ()->f.service.cancelStart(f.component,new CancelStart(1L,UUID.randomUUID())))) forbidden(action);
        verifyNoInteractions(f.em,f.membership,f.footprints,f.inventory,f.assignments);
    }

    @Test void globalTaskReadStillCannotStartReportCancelOrReadWarehouseChoicesForAnotherWorkshop() {
        var f=new Fixture("production_execution:view","production_workshop_task:view:all",
                "production_execution:start","production_daily_report:create");
        var view=f.service.get(f.component);
        assertThat(view.canStart()).isFalse();assertThat(view.canReport()).isFalse();assertThat(view.canCancelStart()).isFalse();
        for(Runnable action:List.<Runnable>of(
                ()->f.service.start(f.component,new Start(1L,f.warehouse,UUID.randomUUID())),
                ()->f.service.report(f.component,new Report(1L,BigDecimal.ONE,"LASER","已核对全部加工对象",UUID.randomUUID())),
                ()->f.service.cancelStart(f.component,new CancelStart(1L,UUID.randomUUID())),
                ()->f.service.warehouses(f.component))) forbidden(action);
        verify(f.query,never()).executeUpdate();
        verifyNoInteractions(f.inventory,f.assignments);
        verify(f.membership,atLeastOnce()).isWorkshopMember(f.workshop,f.responsible,f.employee);
    }

    @Test void dispatchRequiresTheOriginalProductionSourceScopeEvenWithGlobalReadAndAssignPermission() {
        var f=new Fixture("production_execution:view","production_workshop_task:view:all","production_execution:assign");
        when(f.access.nativeReadScope("analysis.maker_id","processingOwners"))
                .thenReturn(new DocumentAccessPolicy.NativeReadScope("analysis.maker_id IN (:processingOwners)","processingOwners",Set.of(f.employee)));
        when(f.query.getSingleResult()).thenReturn(false);
        forbidden(()->f.service.assign(f.component,new Assignment(1L,UUID.randomUUID(),null,UUID.randomUUID())));
        verify(f.query,never()).executeUpdate();verifyNoInteractions(f.inventory,f.assignments);
    }

    @Test void anUnassignedTaskIsNotFoundBeforeAnyShipmentLockOrMutation() {
        var f=new Fixture("production_execution:view","production_execution:start");
        when(f.query.getResultList()).thenReturn(List.of());
        assertThatThrownBy(()->f.service.start(f.component,new Start(1L,f.warehouse,UUID.randomUUID())))
                .isInstanceOfSatisfying(ApiException.class,e->assertThat(e.getCode()).isEqualTo(ErrorCode.NOT_FOUND));
        verify(f.query).setParameter("employeeId",f.employee);
        verify(f.query,never()).executeUpdate();verifyNoInteractions(f.footprints,f.inventory,f.assignments);
    }

    @Test void inactiveOperatorCannotUseAnOldAssignmentOrGlobalReadToWrite() {
        var f=new Fixture("production_execution:view","production_execution:start","production_workshop_task:view:all");
        doThrow(new ApiException(ErrorCode.FORBIDDEN,"员工已不可办理")).when(f.membership).requireActiveOperator();
        forbidden(()->f.service.start(f.component,new Start(1L,f.warehouse,UUID.randomUUID())));
        verifyNoInteractions(f.em,f.footprints,f.inventory,f.assignments);
    }

    @Test void readOnlyWorkshopActorNeedsNoGoodsPickerRightsAndCannotReadAnotherActorsSubmissionReceipt() {
        var f=new Fixture("production_execution:view","production_workshop_task:view:all");
        var task=f.service.get(f.component);
        assertThat(task.processingTargets()).hasSize(1);
        assertThat(task.canAssign()).isFalse();assertThat(task.canStart()).isFalse();assertThat(task.canReport()).isFalse();
        when(f.receipt.getResultList()).thenReturn(Collections.singletonList(new Object[]{f.component,UUID.randomUUID(),2L}));
        assertThatThrownBy(()->f.service.outcome(f.component,UUID.randomUUID()))
                .isInstanceOfSatisfying(ApiException.class,e->assertThat(e.getCode()).isEqualTo(ErrorCode.NOT_FOUND));
        verify(f.query,never()).executeUpdate();verify(f.receipt,never()).executeUpdate();
        verifyNoInteractions(f.inventory,f.footprints,f.assignments);
    }

    @Test void physicalIssueFreezesAssignmentBeforeStartUntilWarehouseActuallyCancelsTheIssue() {
        var f=new Fixture("production_execution:view","production_workshop_task:view:all","production_execution:assign");
        f.row[21]=null;
        when(f.membership.isWorkshopMember(f.workshop,f.responsible,f.employee)).thenReturn(true);
        assertThat(f.service.get(f.component).canAssign()).isFalse();
        assertThatThrownBy(()->f.service.assign(f.component,new Assignment(1L,UUID.randomUUID(),UUID.randomUUID(),UUID.randomUUID())))
                .isInstanceOfSatisfying(ApiException.class,e->{
                    assertThat(e.getCode()).isEqualTo(ErrorCode.CONFLICT);
                    assertThat(e.getMessage()).contains("实物已发至加工");
                });
        verify(f.query,never()).executeUpdate();verifyNoInteractions(f.assignments,f.inventory);
        // A later, separate warehouse return command clears custody first. It
        // retains the old handover ledger rather than changing its assignment.
        f.row[31]=null;
        assertThat(f.service.get(f.component).canAssign()).isTrue();
    }

    private static void forbidden(Runnable action) {
        assertThatThrownBy(action::run).isInstanceOfSatisfying(ApiException.class,
                e->assertThat(e.getCode()).isEqualTo(ErrorCode.FORBIDDEN));
    }

    private static final class Fixture {
        final UUID component=UUID.randomUUID(),shipment=UUID.randomUUID(),employee=UUID.randomUUID(),
                warehouse=UUID.randomUUID(),workshop=UUID.randomUUID(),responsible=UUID.randomUUID();
        final EntityManager em=mock(EntityManager.class);
        final SecurityContextCurrentUser users=mock(SecurityContextCurrentUser.class);
        final TxSessionVars tx=mock(TxSessionVars.class);
        final ProductionDocumentAccessPolicy access=mock(ProductionDocumentAccessPolicy.class);
        final ProductionWorkshopMembership membership=mock(ProductionWorkshopMembership.class);
        final ProductionAssignmentValidator assignments=mock(ProductionAssignmentValidator.class);
        final SalesDeliveryMutationPort footprints=mock(SalesDeliveryMutationPort.class);
        final SalesDeliveryInventoryPort inventory=mock(SalesDeliveryInventoryPort.class);
        final Query query=mock(Query.class,RETURNS_SELF),receipt=mock(Query.class,RETURNS_SELF),actions=mock(Query.class,RETURNS_SELF);
        final Object[] row=new Object[34];
        final DeliveryProcessingService service=new DeliveryProcessingService(em,users,tx,access,membership,assignments,footprints,inventory,new ObjectMapper());
        Fixture(String... permissions) {
            Set<String> granted=Set.of(permissions);
            when(access.hasAuthority(anyString())).thenAnswer(call->granted.contains(call.getArgument(0)));
            when(users.get()).thenReturn(Optional.of(new AuthUser(UUID.randomUUID(),employee,"operator",granted,false,true,false)));
            when(users.employeeId()).thenReturn(Optional.of(employee));when(users.requireEmployeeId()).thenReturn(employee);
            when(em.createNativeQuery(anyString())).thenAnswer(call->{
                String sql=call.getArgument(0);
                if(sql.startsWith("SELECT component_id,actor_employee_id"))return receipt;
                if(sql.startsWith("SELECT component_id,action_type"))return actions;
                return query;
            });
            when(actions.getResultList()).thenReturn(List.of());
            row[0]=component;row[1]=shipment;row[2]="SHIP-TEST";row[3]=UUID.randomUUID();row[4]="[]";
            row[5]=UUID.randomUUID();row[6]="KIT";row[7]="交付件";row[9]=UUID.randomUUID();row[10]="个";
            row[11]=BigDecimal.TEN;row[12]=BigDecimal.ZERO;row[13]="[\"LASER\"]";row[14]=warehouse;
            row[15]="实物仓";row[16]=workshop;row[17]="另一车间";row[18]=responsible;row[19]="另一操作人";
            row[20]=1L;row[21]=OffsetDateTime.parse("2026-11-04T00:00:00Z");row[25]=0;row[26]=1;
            row[27]=false;row[28]=false;row[29]=false;row[31]=OffsetDateTime.parse("2026-11-04T00:00:00Z");
            row[33]="[{\"path\":[],\"goodsId\":\""+row[5]+"\",\"code\":\"PLATE\",\"name\":\"激光面板\",\"unitId\":\""+row[9]
                    +"\",\"unitName\":\"个\",\"quantityExact\":\"10\",\"quantityNumerator\":\"10\",\"quantityDenominator\":\"1\",\"operations\":[\"LASER\"]}]";
            when(query.getResultList()).thenReturn(Collections.singletonList(row));
        }
    }
}
