package com.uten.imp.features.subcontract.draw;

import com.uten.imp.features.subcontract.SubcontractDocumentAccessPolicy;
import com.uten.imp.security.AuthUser;
import com.uten.imp.security.BusinessTaskRead;
import com.uten.imp.security.OwnerVisibility;
import com.uten.imp.security.SecurityContextCurrentUser;
import jakarta.persistence.EntityManager;
import jakarta.persistence.Query;
import org.junit.jupiter.api.Test;
import org.mockito.ArgumentCaptor;

import java.util.Optional;
import java.util.Set;
import java.util.UUID;

import static org.junit.jupiter.api.Assertions.*;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.Mockito.*;

class SubcontractDrawTaskAudienceTest {
    @Test
    void viewOnlyAndActionWithoutPageViewHaveNoDrawBadges() {
        for (Set<String> permissions : java.util.List.of(Set.of("subcontract_order:view"), Set.of("subcontract_order:draw"))) {
            var em = mock(EntityManager.class);
            var service = service(em, permissions, Set.of(UUID.randomUUID()));
            assertEquals(0, service.countDrawable());
            assertEquals(0, service.countSubmitted());
            verifyNoInteractions(em);
        }
    }

    @Test
    void drawTaskCountsKeepTheExplicitPooledDrawOperationWithinReadableOrders() {
        var em = mock(EntityManager.class);
        var query = mock(Query.class);
        when(em.createNativeQuery(anyString())).thenReturn(query);
        when(query.getSingleResult()).thenReturn(2L, 1L);
        UUID readableOwner = UUID.randomUUID();
        var service = service(em, Set.of("subcontract_order:view", "subcontract_order:draw"), Set.of(readableOwner));
        assertEquals(2, service.countDrawable());
        assertEquals(1, service.countSubmitted());
        verify(query, times(2)).setParameter("readOwners", Set.of(readableOwner));
        var sql = ArgumentCaptor.forClass(String.class);
        verify(em, times(2)).createNativeQuery(sql.capture());
        assertTrue(sql.getAllValues().stream().allMatch(statement -> statement.contains("o.maker_id IN (:readOwners)")));
    }

    @Test
    void countEndpointUsesTheActualTaskAudience() throws Exception {
        assertNotNull(SubcontractDrawController.class.getMethod("count").getAnnotation(BusinessTaskRead.class));
    }

    private static SubcontractDrawQueryService service(EntityManager em, Set<String> permissions, Set<UUID> visible) {
        var current = mock(SecurityContextCurrentUser.class);
        when(current.get()).thenReturn(Optional.of(new AuthUser(UUID.randomUUID(), UUID.randomUUID(),
                "finance", permissions, false, true, false)));
        var owners = mock(OwnerVisibility.class);
        when(owners.evaluate("subcontract", "subcontract:view:all"))
                .thenReturn(new OwnerVisibility.OwnerScope(false, visible, Set.of()));
        return new SubcontractDrawQueryService(em, new SubcontractDocumentAccessPolicy(owners, current));
    }
}
