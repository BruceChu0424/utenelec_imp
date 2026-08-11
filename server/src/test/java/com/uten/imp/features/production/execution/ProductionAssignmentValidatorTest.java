package com.uten.imp.features.production.execution;

import com.uten.imp.common.web.ApiException;
import jakarta.persistence.EntityManager;
import jakarta.persistence.Query;
import org.junit.jupiter.api.Test;

import java.time.LocalDate;
import java.util.Collections;
import java.util.List;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.verifyNoInteractions;
import static org.mockito.Mockito.when;

class ProductionAssignmentValidatorTest {

    @Test
    void acceptsProductionWorkshopTeamAndActiveOwnerInScope() {
        UUID workshopId = UUID.randomUUID();
        UUID teamId = UUID.randomUUID();
        UUID employeeId = UUID.randomUUID();
        EntityManager em = mock(EntityManager.class);
        Query departments = query();
        when(departments.getResultList()).thenReturn(List.of(
                new Object[]{workshopId, UUID.randomUUID(),
                        "/MFG_CENTER/DEPT_PROD/WS_A/", "DEPT_PROD"},
                new Object[]{teamId, workshopId,
                        "/MFG_CENTER/DEPT_PROD/WS_A/TEAM_A/", "WS_A"}));
        Query employees = query();
        when(employees.getResultList()).thenReturn(Collections.singletonList(
                new Object[]{employeeId, "active",
                        "/MFG_CENTER/DEPT_PROD/WS_A/TEAM_A/"}));
        when(em.createNativeQuery(anyString())).thenAnswer(invocation ->
                invocation.<String>getArgument(0).contains("FROM departments")
                        ? departments : employees);

        new ProductionAssignmentValidator(em).validate(
                new ProductionAssignmentValidator.Assignment(
                        workshopId, teamId, employeeId,
                        LocalDate.of(2026, 8, 3),
                        LocalDate.of(2026, 8, 4)));
    }

    @Test
    void rejectsTeamWithoutWorkshopBeforeReadingMasterData() {
        EntityManager em = mock(EntityManager.class);

        assertThatThrownBy(() -> new ProductionAssignmentValidator(em)
                .validate(new ProductionAssignmentValidator.Assignment(
                        null, UUID.randomUUID(), null, null, null)))
                .isInstanceOf(ApiException.class)
                .hasMessageContaining("先选择生产车间");
        verifyNoInteractions(em);
    }

    @Test
    void rejectsWorkshopOutsideProductionAndResignedOwner() {
        UUID workshopId = UUID.randomUUID();
        UUID employeeId = UUID.randomUUID();
        EntityManager em = mock(EntityManager.class);
        Query departments = query();
        when(departments.getResultList()).thenReturn(Collections.singletonList(
                new Object[]{workshopId, UUID.randomUUID(),
                        "/GM/FIN_CENTER/", "GM"}));
        Query employees = query();
        when(employees.getResultList()).thenReturn(Collections.singletonList(
                new Object[]{employeeId, "resigned", "/GM/FIN_CENTER/"}));
        when(em.createNativeQuery(anyString())).thenAnswer(invocation ->
                invocation.<String>getArgument(0).contains("FROM departments")
                        ? departments : employees);

        assertThatThrownBy(() -> new ProductionAssignmentValidator(em)
                .validate(new ProductionAssignmentValidator.Assignment(
                        workshopId, null, employeeId, null, null)))
                .isInstanceOf(ApiException.class)
                .hasMessageContaining("生产部直属");
    }

    @Test
    void rejectsOwnerOutsideSelectedWorkshopScope() {
        UUID workshopId = UUID.randomUUID();
        UUID employeeId = UUID.randomUUID();
        EntityManager em = mock(EntityManager.class);
        Query departments = query();
        when(departments.getResultList()).thenReturn(Collections.singletonList(
                new Object[]{workshopId, UUID.randomUUID(),
                        "/MFG_CENTER/DEPT_PROD/WS_A/", "DEPT_PROD"}));
        Query employees = query();
        when(employees.getResultList()).thenReturn(Collections.singletonList(
                new Object[]{employeeId, "probation",
                        "/MFG_CENTER/DEPT_PROD/WS_B/"}));
        when(em.createNativeQuery(anyString())).thenAnswer(invocation ->
                invocation.<String>getArgument(0).contains("FROM departments")
                        ? departments : employees);

        assertThatThrownBy(() -> new ProductionAssignmentValidator(em)
                .validate(new ProductionAssignmentValidator.Assignment(
                        workshopId, null, employeeId, null, null)))
                .isInstanceOf(ApiException.class)
                .hasMessageContaining("组织范围");
    }

    private static Query query() {
        Query query = mock(Query.class);
        when(query.setParameter(anyString(), any())).thenReturn(query);
        return query;
    }
}
