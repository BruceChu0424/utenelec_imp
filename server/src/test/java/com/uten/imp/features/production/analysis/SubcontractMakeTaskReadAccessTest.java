package com.uten.imp.features.production.analysis;

import com.uten.imp.features.production.ProductionDocumentAccessPolicy;
import com.uten.imp.security.AuthUser;
import com.uten.imp.security.OwnerVisibility;
import com.uten.imp.security.SecurityContextCurrentUser;
import jakarta.persistence.EntityManager;
import jakarta.persistence.Query;
import org.junit.jupiter.api.Test;

import java.math.BigDecimal;
import java.util.List;
import java.util.Optional;
import java.util.Set;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.ArgumentMatchers.*;
import static org.mockito.Mockito.*;

class SubcontractMakeTaskReadAccessTest {
    private final UUID reader = UUID.randomUUID();
    private final UUID maker = UUID.randomUUID();

    @Test
    void sharedSubcontractReaderCanTrackProgressWithoutGettingPlanningActions() {
        Fixture f = fixture(Set.of("subcontract_application:view"), false);
        var rows = f.service.tasks(new SubcontractMakeTaskService.TaskPageRequest(1, 20, null, null, null));
        assertThat(rows.getItems().getFirst().allowedActions()).isEmpty();
        verify(f.em).createNativeQuery(argThat(sql -> sql.startsWith("SELECT COUNT(*)")
                && !sql.contains("visibleAnalysisOwners")));
    }

    @Test
    void planningReaderCountAndRowsShareOwnerScopeAndManualVisibilityDoesNotGrantWrite() {
        Fixture f = fixture(Set.of("production_material_analysis:view", "production_material_analysis:notify"), false);
        var rows = f.service.tasks(new SubcontractMakeTaskService.TaskPageRequest(1, 20, null, null, null));
        assertThat(rows.getItems().getFirst().allowedActions()).isEmpty();
        verify(f.em, times(2)).createNativeQuery(argThat(sql -> sql.contains("analysis.maker_id IN (:visibleAnalysisOwners)")));
        verify(f.count).setParameter("visibleAnalysisOwners", Set.of(reader, maker));
        verify(f.rows).setParameter("visibleAnalysisOwners", Set.of(reader, maker));
    }

    @Test
    void planningOperatorWithWritableOwnerGetsTheAvailableBatchAction() {
        Fixture f = fixture(Set.of("production_material_analysis:view", "production_material_analysis:notify"), true);
        var rows = f.service.tasks(new SubcontractMakeTaskService.TaskPageRequest(1, 20, null, null, null));
        assertThat(rows.getItems().getFirst().allowedActions()).containsExactly("NOTIFY_SUBCONTRACT");
    }

    private Fixture fixture(Set<String> permissions, boolean writable) {
        var current = mock(SecurityContextCurrentUser.class);
        var user = new AuthUser(UUID.randomUUID(), reader, "reader", Set.of(), permissions, false, true, false);
        when(current.get()).thenReturn(Optional.of(user));
        var visibility = mock(OwnerVisibility.class);
        when(visibility.evaluate(anyString(), anyString())).thenReturn(new OwnerVisibility.OwnerScope(
                false, Set.of(reader, maker), writable ? Set.of(reader, maker) : Set.of(reader)));
        var access = new ProductionDocumentAccessPolicy(visibility, current);
        var em = mock(EntityManager.class);
        var count = mock(Query.class);
        var rows = mock(Query.class);
        when(em.createNativeQuery(anyString())).thenAnswer(call ->
                call.<String>getArgument(0).startsWith("SELECT COUNT(*)") ? count : rows);
        when(count.getSingleResult()).thenReturn(1L);
        when(rows.setFirstResult(anyInt())).thenReturn(rows);
        when(rows.setMaxResults(anyInt())).thenReturn(rows);
        Object[] row = new Object[25];
        row[0] = UUID.randomUUID(); row[1] = UUID.randomUUID(); row[2] = "CONFIRMED";
        row[4] = UUID.randomUUID(); row[12] = BigDecimal.TEN; row[13] = BigDecimal.TEN;
        row[14] = BigDecimal.ZERO; row[15] = BigDecimal.TEN; row[16] = BigDecimal.TEN;
        row[18] = "ACTIVE"; row[21] = 1L; row[22] = 0L; row[23] = 1L; row[24] = maker;
        when(rows.getResultList()).thenReturn(java.util.Collections.singletonList(row));
        return new Fixture(new SubcontractMakeTaskService(em, mock(MaterialAnalysisService.class),
                access, null, null, current), em, count, rows);
    }

    private record Fixture(SubcontractMakeTaskService service, EntityManager em, Query count, Query rows) {}
}
