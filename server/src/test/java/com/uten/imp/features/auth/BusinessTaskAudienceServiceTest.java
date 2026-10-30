package com.uten.imp.features.auth;

import com.uten.imp.security.AuthUser;
import com.uten.imp.security.EmployeeHandoverVisibility;
import com.uten.imp.security.OwnerVisibility;
import com.uten.imp.security.SecurityContextCurrentUser;
import jakarta.persistence.EntityManager;
import jakarta.persistence.Query;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.Test;
import org.springframework.security.authentication.UsernamePasswordAuthenticationToken;
import org.springframework.security.authentication.AnonymousAuthenticationToken;
import org.springframework.security.core.authority.SimpleGrantedAuthority;
import org.springframework.security.core.context.SecurityContextHolder;

import java.time.Instant;
import java.util.List;
import java.util.Set;
import java.util.UUID;

import static org.assertj.core.api.Assertions.*;
import static org.mockito.ArgumentMatchers.*;
import static org.mockito.Mockito.*;

class BusinessTaskAudienceServiceTest {
    private final PermissionResolver permissions = mock(PermissionResolver.class);
    private final BusinessTaskAudienceService tasks = new BusinessTaskAudienceService(permissions);
    private final SecurityContextCurrentUser current = new SecurityContextCurrentUser();

    @AfterEach void clean() { SecurityContextHolder.clearContext(); }

    @Test void absentAnonymousAndVisitorPrincipalsRetainTheEndpointGuardsWithoutInventingStaffAuthority() {
        assertThat(tasks.read(() -> com.uten.imp.security.BusinessTaskContext.active())).isFalse();
        SecurityContextHolder.getContext().setAuthentication(new AnonymousAuthenticationToken("audit", "anonymous",
                List.of(new SimpleGrantedAuthority("ANONYMOUS"))));
        assertThat(tasks.read(() -> com.uten.imp.security.BusinessTaskContext.active())).isFalse();
        var visitor = AuthUser.visitor(UUID.randomUUID(), "visitor-audit", "V-AUDIT", Set.of("notice:read"));
        SecurityContextHolder.getContext().setAuthentication(
                UsernamePasswordAuthenticationToken.authenticated(visitor, null, visitor.getAuthorities()));
        assertThat(tasks.read(() -> current.get().orElseThrow())).isSameAs(visitor);
        verifyNoInteractions(permissions);
    }

    @Test void administratorCapabilityIsNotBusinessTaskSubscriptionAndSessionMetadataSurvives() {
        AuthUser actor = actor(true, Set.of("subcontract_order:view", "subcontract_order:draw", "finance_order_approval:approve"));
        var original = SecurityContextHolder.getContext();
        when(permissions.grantedPermsOf(actor.getId())).thenReturn(Set.of("finance_order_approval:approve"));
        tasks.read(() -> {
            AuthUser taskActor = current.get().orElseThrow();
            assertThat(taskActor.isSuperAdmin()).isFalse();
            assertThat(taskActor.getPermissions()).containsExactly("finance_order_approval:approve");
            assertThat(taskActor.getId()).isEqualTo(actor.getId());
            assertThat(taskActor.getEmployeeId()).isEqualTo(actor.getEmployeeId());
            assertThat(taskActor.getImpersonatedBy()).isEqualTo(actor.getImpersonatedBy());
            assertThat(taskActor.getSessionId()).isEqualTo(actor.getSessionId());
            assertThat(taskActor.isRemoteAccess()).isTrue();
            return null;
        });
        assertThat(SecurityContextHolder.getContext()).isSameAs(original);
        assertThat(current.get()).containsSame(actor);
        assertThat(actor.isSuperAdmin()).isTrue();
    }

    @Test void nestedCountsResolveOnceAndFailureAlwaysRestoresOriginalPrincipal() {
        AuthUser actor = actor(true, Set.of("production_plan:view"));
        when(permissions.grantedPermsOf(actor.getId())).thenReturn(Set.of("production_plan:view"));
        var original = SecurityContextHolder.getContext();
        assertThatThrownBy(() -> tasks.read(() -> tasks.read(() -> {
            assertThat(current.get().orElseThrow().isSuperAdmin()).isFalse();
            throw new IllegalStateException("isolated source failure");
        }))).isInstanceOf(IllegalStateException.class).hasMessage("isolated source failure");
        assertThat(SecurityContextHolder.getContext()).isSameAs(original);
        verify(permissions, times(1)).grantedPermsOf(actor.getId());
        tasks.read(() -> null);
        verify(permissions, times(2)).grantedPermsOf(actor.getId());
    }

    @Test void revocationAndSessionIntersectionPreventOldOrUnseenGrantsFromReturning() {
        AuthUser actor = actor(false, Set.of("subcontract_order:view", "subcontract_order:draw"));
        when(permissions.grantedPermsOf(actor.getId()))
                .thenReturn(Set.of("subcontract_order:view", "subcontract_order:draw", "sales_order:edit"))
                .thenReturn(Set.of("subcontract_order:view"));
        assertThat(tasks.read(() -> current.get().orElseThrow().getPermissions()))
                .containsExactlyInAnyOrder("subcontract_order:view", "subcontract_order:draw");
        assertThat(tasks.read(() -> current.get().orElseThrow().getPermissions()))
                .containsExactly("subcontract_order:view");
    }

    @Test void publicationTaskIdentityProbeDoesNotBorrowTheOuterReadWindow() {
        AuthUser actor=actor(true,Set.of("production_plan:view","production_plan:view:all"));
        when(permissions.grantedPermsOf(actor.getId())).thenReturn(Set.of("production_plan:view","production_plan:view:all")).thenReturn(Set.of("production_plan:view"));
        tasks.read(()->{
            assertThat(current.get().orElseThrow().getPermissions()).contains("production_plan:view:all");
            AuthUser fresh=tasks.freshTaskSubject(actor);
            assertThat(fresh.isSuperAdmin()).isFalse();
            assertThat(fresh.getPermissions()).containsExactly("production_plan:view");
            return null;
        });
        verify(permissions,times(2)).grantedPermsOf(actor.getId());
    }

    @Test void taskOwnersRetainHandoverButManualReadDelegationDoesNotBecomeWriteResponsibility() {
        AuthUser actor = actor(true, Set.of("subcontract:view:all", "subcontract_order:view", "subcontract_order:edit"));
        UUID handedOver = UUID.randomUUID(), readOnly = UUID.randomUUID();
        when(permissions.grantedPermsOf(actor.getId()))
                .thenReturn(Set.of("subcontract_order:view", "subcontract_order:edit"));
        EntityManager em = mock(EntityManager.class);
        Query query = mock(Query.class);
        when(em.createNativeQuery(anyString())).thenReturn(query);
        when(query.setParameter(anyString(), any())).thenReturn(query);
        when(query.getResultList()).thenReturn(List.of(readOnly));
        EmployeeHandoverVisibility handover = mock(EmployeeHandoverVisibility.class);
        when(handover.inheritedOwners(actor.getEmployeeId(), "subcontract")).thenReturn(Set.of(handedOver));
        var owners = new OwnerVisibility(current, em, handover);
        assertThat(owners.evaluate("subcontract", "subcontract:view:all").seeAll()).isTrue();
        var scope = tasks.read(() -> owners.evaluate("subcontract", "subcontract:view:all"));
        assertThat(scope.seeAll()).isFalse();
        assertThat(scope.visibleOwners()).containsExactlyInAnyOrder(actor.getEmployeeId(), handedOver, readOnly);
        assertThat(scope.writableOwners()).containsExactlyInAnyOrder(actor.getEmployeeId(), handedOver);
    }

    private AuthUser actor(boolean admin, Set<String> grants) {
        var actor = new AuthUser(UUID.randomUUID(), UUID.randomUUID(), "task-audit", grants,
                false, true, admin, true, UUID.randomUUID(), UUID.randomUUID());
        SecurityContextHolder.getContext().setAuthentication(
                UsernamePasswordAuthenticationToken.authenticated(actor, null, actor.getAuthorities()));
        return actor;
    }
}
