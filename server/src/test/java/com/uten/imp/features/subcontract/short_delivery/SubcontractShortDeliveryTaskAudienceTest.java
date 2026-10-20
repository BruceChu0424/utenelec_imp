package com.uten.imp.features.subcontract.short_delivery;

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

class SubcontractShortDeliveryTaskAudienceTest {
    @Test
    void orderViewDoesNotSubscribeToShortDeliveryTasks() {
        var em = mock(EntityManager.class);
        var service = service(em, access(Set.of("subcontract_order:view"),
                new OwnerVisibility.OwnerScope(true, Set.of())));
        assertEquals(new SubcontractShortDeliveryContracts.Counts(0, 0, 0), service.counts());
        verifyNoInteractions(em);
    }

    @Test
    void countsExcludeManuallyVisibleOwnersAndPreserveWritableHandoverOwners() {
        var em = mock(EntityManager.class);
        var query = mock(Query.class);
        when(em.createNativeQuery(anyString())).thenReturn(query);
        when(query.getSingleResult()).thenReturn(new Object[]{1L, 2L, 3L});
        UUID me = UUID.randomUUID(), handedOver = UUID.randomUUID(), readOnly = UUID.randomUUID();
        var service = service(em, access(Set.of("subcontract_order:view", "subcontract_short_delivery:decide"),
                new OwnerVisibility.OwnerScope(false, Set.of(me, handedOver, readOnly), Set.of(me, handedOver))));

        assertEquals(new SubcontractShortDeliveryContracts.Counts(1, 2, 3), service.counts());

        verify(query).setParameter("owners", Set.of(me, handedOver));
        var sql = ArgumentCaptor.forClass(String.class);
        verify(em).createNativeQuery(sql.capture());
        assertTrue(sql.getValue().contains("c.owner_employee_id IS NOT NULL"));
        assertTrue(sql.getValue().contains("c.owner_employee_id IN (:owners)"));
    }

    @Test
    void everyEndpointBrowsesUnderTheSessionPrincipal() throws Exception {
        // 2026-10-19 ADR-184 修订二: 分段计数是展示层数字, 须与列表、工作台徽章汇总
        // 同一口径——/count 不再挂 @BusinessTaskRead(任务改写会剥超管镜像, 超管打开
        // 页面时可办分段数全为 0/403)。
        assertNull(SubcontractShortDeliveryController.class.getMethod("count").getAnnotation(BusinessTaskRead.class));
        assertNull(SubcontractShortDeliveryController.class.getMethod("detail", UUID.class).getAnnotation(BusinessTaskRead.class));
    }

    private static SubcontractDocumentAccessPolicy access(Set<String> permissions, OwnerVisibility.OwnerScope scope) {
        var current = mock(SecurityContextCurrentUser.class);
        when(current.get()).thenReturn(Optional.of(new AuthUser(UUID.randomUUID(), UUID.randomUUID(),
                "finance", permissions, false, true, false)));
        var owners = mock(OwnerVisibility.class);
        when(owners.evaluate("subcontract", "subcontract:view:all")).thenReturn(scope);
        return new SubcontractDocumentAccessPolicy(owners, current);
    }

    private static SubcontractShortDeliveryService service(EntityManager em, SubcontractDocumentAccessPolicy access) {
        return new SubcontractShortDeliveryService(null, em, null, null, null, access, null, null, null, null, null);
    }
}
