package com.uten.imp.security;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import jakarta.persistence.EntityManager;
import jakarta.persistence.Query;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.extension.ExtendWith;
import org.mockito.Mock;
import org.mockito.junit.jupiter.MockitoExtension;

import java.util.Collections;
import java.util.Optional;
import java.util.Set;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatCode;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

@ExtendWith(MockitoExtension.class)
class ProductionMaterialReadAccessPolicyTest {

    @Mock private EntityManager em;
    @Mock private Query query;
    @Mock private SecurityContextCurrentUser currentUser;
    @Mock private OwnerVisibility ownerVisibility;
    @Mock private ProductionStockTaskAccessPolicy warehouseTasks;

    private ProductionMaterialReadAccessPolicy policy;

    @BeforeEach
    void setUp() {
        when(em.createNativeQuery(anyString())).thenReturn(query);
        when(query.setParameter(anyString(), any())).thenReturn(query);
        policy = new ProductionMaterialReadAccessPolicy(
                em, currentUser, ownerVisibility, warehouseTasks);
    }

    @Test
    void normalPlanOwnerAndManualReadGrantCanReadButOtherOwnerGetsNotFound() {
        UUID actorEmployeeId = UUID.randomUUID();
        UUID otherOwnerId = UUID.randomUUID();
        UUID planId = UUID.randomUUID();
        when(currentUser.get()).thenReturn(Optional.of(staff(
                actorEmployeeId, Set.of("production_plan:view"))));
        planRow(planId, otherOwnerId);
        when(ownerVisibility.evaluate(
                "production_plan", "production_plan:view:all"))
                .thenReturn(new OwnerVisibility.OwnerScope(
                        false, Set.of(otherOwnerId), Set.of()));

        assertThatCode(() -> policy.requirePlanReadable(planId))
                .doesNotThrowAnyException();

        when(ownerVisibility.evaluate(
                "production_plan", "production_plan:view:all"))
                .thenReturn(new OwnerVisibility.OwnerScope(
                        false, Set.of(actorEmployeeId), Set.of(actorEmployeeId)));

        assertNotFound(() -> policy.requirePlanReadable(planId));
    }

    @Test
    void explicitPlanViewAllRetainsFullReadRange() {
        UUID planId = UUID.randomUUID();
        when(currentUser.get()).thenReturn(Optional.of(staff(
                UUID.randomUUID(),
                Set.of("production_plan:view", "production_plan:view:all"))));
        planRow(planId, UUID.randomUUID());
        when(ownerVisibility.evaluate(
                "production_plan", "production_plan:view:all"))
                .thenReturn(new OwnerVisibility.OwnerScope(
                        true, Set.of(), Set.of()));

        assertThatCode(() -> policy.requirePlanReadable(planId))
                .doesNotThrowAnyException();
    }

    @Test
    void warehouseSubtreePoolWithStockViewCanReadAnotherOwnersPlan() {
        UUID planId = UUID.randomUUID();
        when(currentUser.get()).thenReturn(Optional.of(staff(
                UUID.randomUUID(), Set.of("stock_doc:view"))));
        when(warehouseTasks.canAccessWarehouseTasks()).thenReturn(true);
        planRow(planId, UUID.randomUUID());

        assertThatCode(() -> policy.requirePlanReadable(planId))
                .doesNotThrowAnyException();
        verify(ownerVisibility, never()).evaluate(anyString(), anyString());
    }

    @Test
    void nonWarehouseStockViewerCannotUsePlanEndpointAsAnIdOracle() {
        UUID planId = UUID.randomUUID();
        when(currentUser.get()).thenReturn(Optional.of(staff(
                UUID.randomUUID(), Set.of("stock_doc:view"))));
        when(warehouseTasks.canAccessWarehouseTasks()).thenReturn(false);
        planRow(planId, UUID.randomUUID());

        assertNotFound(() -> policy.requirePlanReadable(planId));
        verify(ownerVisibility, never()).evaluate(anyString(), anyString());
    }

    @Test
    void warehouseSubtreePoolCanReadAnotherOwnersProductionDraw() {
        UUID drawId = UUID.randomUUID();
        when(currentUser.get()).thenReturn(Optional.of(staff(
                UUID.randomUUID(), Set.of("stock_doc:view"))));
        when(warehouseTasks.canAccessWarehouseTasks()).thenReturn(true);
        drawRow(drawId, UUID.randomUUID(), true);

        assertThatCode(() -> policy.requireDrawReadable(drawId))
                .doesNotThrowAnyException();
    }

    @Test
    void warehouseSubtreePoolCannotBypassOwnerForAManualDraw() {
        UUID actorEmployeeId = UUID.randomUUID();
        UUID drawId = UUID.randomUUID();
        when(currentUser.get()).thenReturn(Optional.of(staff(
                actorEmployeeId, Set.of("stock_doc:view"))));
        drawRow(drawId, UUID.randomUUID(), false);
        when(ownerVisibility.evaluate("stock_doc", "stock_doc:view:all"))
                .thenReturn(new OwnerVisibility.OwnerScope(
                        false, Set.of(actorEmployeeId), Set.of(actorEmployeeId)));

        assertNotFound(() -> policy.requireDrawReadable(drawId));
    }

    @Test
    void normallyVisibleDrawIsReadableAndKnownOtherOwnerDrawIsNotFound() {
        UUID actorEmployeeId = UUID.randomUUID();
        UUID otherOwnerId = UUID.randomUUID();
        UUID drawId = UUID.randomUUID();
        when(currentUser.get()).thenReturn(Optional.of(staff(
                actorEmployeeId, Set.of("stock_doc:view"))));
        drawRow(drawId, otherOwnerId, false);
        when(ownerVisibility.evaluate("stock_doc", "stock_doc:view:all"))
                .thenReturn(new OwnerVisibility.OwnerScope(
                        false, Set.of(otherOwnerId), Set.of()));

        assertThatCode(() -> policy.requireDrawReadable(drawId))
                .doesNotThrowAnyException();

        when(ownerVisibility.evaluate("stock_doc", "stock_doc:view:all"))
                .thenReturn(new OwnerVisibility.OwnerScope(
                        false, Set.of(actorEmployeeId), Set.of(actorEmployeeId)));

        assertNotFound(() -> policy.requireDrawReadable(drawId));
    }

    @Test
    void missingOrWrongTypeDocumentIsIndistinguishableFromForbidden() {
        UUID id = UUID.randomUUID();
        when(query.getResultList()).thenReturn(Collections.emptyList());

        assertNotFound(() -> policy.requireDrawReadable(id));
    }

    private void planRow(UUID id, UUID ownerId) {
        when(query.getResultList()).thenReturn(Collections.singletonList(
                new Object[]{id, ownerId}));
    }

    private void drawRow(
            UUID id, UUID ownerId, boolean productionLinked) {
        when(query.getResultList()).thenReturn(Collections.singletonList(
                new Object[]{id, ownerId, productionLinked}));
    }

    private void assertNotFound(org.assertj.core.api.ThrowableAssert.ThrowingCallable call) {
        assertThatThrownBy(call)
                .isInstanceOfSatisfying(ApiException.class, error ->
                        assertThat(error.getCode()).isEqualTo(ErrorCode.NOT_FOUND));
    }

    private static AuthUser staff(
            UUID employeeId, Set<String> permissions) {
        return new AuthUser(
                UUID.randomUUID(), employeeId, "material-read-test",
                Set.of(), permissions, false, true, false);
    }
}
