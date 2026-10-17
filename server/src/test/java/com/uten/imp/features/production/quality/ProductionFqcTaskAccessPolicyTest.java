package com.uten.imp.features.production.quality;

import com.uten.imp.security.AuthUser;
import com.uten.imp.security.SecurityContextCurrentUser;
import jakarta.persistence.EntityManager;
import jakarta.persistence.Query;
import org.junit.jupiter.api.Test;

import java.util.Optional;
import java.util.Set;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.Mockito.*;

class ProductionFqcTaskAccessPolicyTest {
    private final EntityManager em = mock(EntityManager.class);
    private final Query query = mock(Query.class);
    private final SecurityContextCurrentUser current = mock(SecurityContextCurrentUser.class);
    private final ProductionFqcTaskAccessPolicy policy = new ProductionFqcTaskAccessPolicy(em, current);
    private final UUID user = UUID.randomUUID(), employee = UUID.randomUUID();

    @Test void effectiveReviewPermissionAllowsActiveStaffWithoutDepartmentOrGrantSourceRequirements() {
        actor(Set.of("production_quality_inspection:view", "production_quality_inspection:approve"));
        when(em.createNativeQuery(anyString())).thenReturn(query);
        when(query.setParameter(anyString(), any())).thenReturn(query);
        when(query.getSingleResult()).thenReturn(1L);

        assertThat(policy.canAccessQualityPool()).isTrue();

        var sql = org.mockito.ArgumentCaptor.forClass(String.class);
        verify(em).createNativeQuery(sql.capture());
        assertThat(sql.getValue()).contains("account.status = 'active'", "employee.status IN")
                .doesNotContain("departments", "user_permission_overrides", "authority_source");
        verify(query).setParameter("employeeId", employee);
        verify(query).setParameter("userId", user);
    }

    @Test void viewOnlyPermissionDoesNotExpandTheExistingProductionDocumentScope() {
        actor(Set.of("production_quality_inspection:view"));
        assertThat(policy.canAccessQualityPool()).isFalse();
        actor(Set.of("production_quality_inspection:approve"));
        assertThat(policy.canAccessQualityPool()).isFalse();
        verifyNoInteractions(em);
    }

    @Test void inactiveAccountOrEmployeeCannotHandleTheReviewPool() {
        actor(Set.of("production_quality_inspection:view", "production_quality_inspection:approve"));
        when(em.createNativeQuery(anyString())).thenReturn(query);
        when(query.setParameter(anyString(), any())).thenReturn(query);
        when(query.getSingleResult()).thenReturn(0L);
        assertThat(policy.canAccessQualityPool()).isFalse();
    }

    @Test void visitorAndUnboundStaffCannotHandleTheReviewPool() {
        when(current.get()).thenReturn(Optional.of(AuthUser.visitor(user, "visitor", "V1", Set.of())));
        assertThat(policy.canAccessQualityPool()).isFalse();
        when(current.get()).thenReturn(Optional.of(new AuthUser(user, null, "staff",
                Set.of("production_quality_inspection:view", "production_quality_inspection:approve"), false, true, false)));
        assertThat(policy.canAccessQualityPool()).isFalse();
        verifyNoInteractions(em);
    }

    private void actor(Set<String> permissions) {
        when(current.get()).thenReturn(Optional.of(new AuthUser(user, employee, "staff", permissions, false, true, false)));
    }
}
