package com.uten.imp.features.master.client;

import com.uten.imp.security.AuthUser;
import com.uten.imp.security.OwnerVisibility;
import com.uten.imp.security.SecurityContextCurrentUser;
import jakarta.persistence.EntityManager;
import jakarta.persistence.Query;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;

import java.util.List;
import java.util.Optional;
import java.util.Set;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.when;

class ClientAccessPolicyTest {

    private final OwnerVisibility ownerVisibility = mock(OwnerVisibility.class);
    private final SecurityContextCurrentUser currentUser = mock(SecurityContextCurrentUser.class);
    private final EntityManager entityManager = mock(EntityManager.class);
    private final Query grantQuery = mock(Query.class);
    private final ClientAccessPolicy policy =
            new ClientAccessPolicy(ownerVisibility, currentUser, entityManager);

    @BeforeEach
    void setUpGrantQuery() {
        when(entityManager.createNativeQuery(anyString())).thenReturn(grantQuery);
        when(grantQuery.setParameter(anyString(), org.mockito.ArgumentMatchers.any()))
                .thenReturn(grantQuery);
        when(grantQuery.getResultList()).thenReturn(List.of());
    }

    @Test
    void ownerlessCustomerIsHiddenUnlessCallerCanAssignOrSeeAll() {
        UUID employeeId = UUID.randomUUID();
        Client client = client(UUID.randomUUID(), null);
        when(ownerVisibility.evaluate(ClientAccessPolicy.SCOPE, ClientAccessPolicy.VIEW_ALL))
                .thenReturn(new OwnerVisibility.OwnerScope(
                        false, Set.of(employeeId), Set.of(employeeId)));

        when(currentUser.get()).thenReturn(Optional.of(user(employeeId, Set.of())));
        var ordinary = policy.evaluate();
        assertThat(policy.canRead(client, ordinary)).isFalse();
        assertThat(policy.canWrite(client, ordinary)).isFalse();

        when(currentUser.get()).thenReturn(Optional.of(
                user(employeeId, Set.of(ClientAccessPolicy.ASSIGN))));
        var assigner = policy.evaluate();
        assertThat(policy.canRead(client, assigner)).isTrue();
        assertThat(policy.canWrite(client, assigner)).isFalse();
        assertThat(policy.canManageAccess(client, assigner)).isTrue();

        when(ownerVisibility.evaluate(ClientAccessPolicy.SCOPE, ClientAccessPolicy.VIEW_ALL))
                .thenReturn(new OwnerVisibility.OwnerScope(true, Set.of(), Set.of()));
        var companyWide = policy.evaluate();
        assertThat(policy.canRead(client, companyWide)).isTrue();
        assertThat(policy.canWrite(client, companyWide)).isTrue();
        assertThat(policy.canManageAccess(client, companyWide)).isTrue();
    }

    @Test
    void residualViewerGrantNeverMakesAnOwnerlessCustomerReadable() {
        UUID employeeId = UUID.randomUUID();
        Client ownerless = client(UUID.randomUUID(), null);
        when(ownerVisibility.evaluate(ClientAccessPolicy.SCOPE, ClientAccessPolicy.VIEW_ALL))
                .thenReturn(new OwnerVisibility.OwnerScope(
                        false, Set.of(employeeId), Set.of(employeeId)));
        when(currentUser.get()).thenReturn(Optional.of(
                user(employeeId, Set.of("client:view"))));
        // Simulate a historical active grant that survived after owner removal.
        when(grantQuery.getResultList()).thenReturn(List.of(1));

        var scope = policy.evaluate();

        assertThat(policy.canRead(ownerless, scope)).isFalse();
        assertThat(policy.canWrite(ownerless, scope)).isFalse();
        assertThat(policy.canManageAccess(ownerless, scope)).isFalse();
    }

    @Test
    void explicitCustomerShareIsReadOnlyEvenWithFunctionalEditPermission() {
        UUID employeeId = UUID.randomUUID();
        UUID ownerId = UUID.randomUUID();
        UUID sharedClientId = UUID.randomUUID();
        when(currentUser.get()).thenReturn(Optional.of(
                user(employeeId, Set.of("client:view", "client:edit"))));
        when(ownerVisibility.evaluate(ClientAccessPolicy.SCOPE, ClientAccessPolicy.VIEW_ALL))
                .thenReturn(new OwnerVisibility.OwnerScope(
                        false, Set.of(employeeId), Set.of(employeeId)));
        when(grantQuery.getResultList()).thenReturn(List.of(sharedClientId));

        Client sharedClient = client(sharedClientId, ownerId);
        var scope = policy.evaluate();

        assertThat(policy.canRead(sharedClient, scope)).isTrue();
        assertThat(policy.canWrite(sharedClient, scope)).isFalse();
        assertThat(policy.canManageAccess(sharedClient, scope)).isFalse();
    }

    @Test
    void ownerScopeCanBeReadableWithoutBeingWritable() {
        UUID employeeId = UUID.randomUUID();
        UUID delegatedOwner = UUID.randomUUID();
        when(currentUser.get()).thenReturn(Optional.of(
                user(employeeId, Set.of(ClientAccessPolicy.ASSIGN))));
        when(ownerVisibility.evaluate(ClientAccessPolicy.SCOPE, ClientAccessPolicy.VIEW_ALL))
                .thenReturn(new OwnerVisibility.OwnerScope(
                        false,
                        Set.of(employeeId, delegatedOwner),
                        Set.of(employeeId)));

        Client delegatedClient = client(UUID.randomUUID(), delegatedOwner);
        var scope = policy.evaluate();

        assertThat(policy.canRead(delegatedClient, scope)).isTrue();
        assertThat(policy.canWrite(delegatedClient, scope)).isFalse();
        assertThat(policy.canManageAccess(delegatedClient, scope)).isFalse();
    }

    private static Client client(UUID id, UUID ownerEmployeeId) {
        Client client = new Client();
        client.setId(id);
        client.setOwnerEmployeeId(ownerEmployeeId);
        return client;
    }

    private static AuthUser user(UUID employeeId, Set<String> permissions) {
        return new AuthUser(
                UUID.randomUUID(), employeeId, "tester", Set.of(), permissions,
                false, true, false);
    }
}
