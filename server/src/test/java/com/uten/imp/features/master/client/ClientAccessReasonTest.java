package com.uten.imp.features.master.client;

import com.uten.imp.security.OwnerVisibility;
import com.uten.imp.security.SecurityContextCurrentUser;
import jakarta.persistence.EntityManager;
import org.junit.jupiter.api.Test;

import java.util.Set;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.Mockito.mock;

class ClientAccessReasonTest {

    private final ClientAccessPolicy policy = new ClientAccessPolicy(
            mock(OwnerVisibility.class),
            mock(SecurityContextCurrentUser.class),
            mock(EntityManager.class));

    @Test
    void detailReasonDistinguishesUnassignedManageableOwnerScopeAndShare() {
        UUID caller = UUID.randomUUID();
        UUID delegated = UUID.randomUUID();
        UUID other = UUID.randomUUID();
        var scope = new ClientAccessPolicy.ClientScope(
                new OwnerVisibility.OwnerScope(
                        false, Set.of(caller, delegated), Set.of(caller)),
                Set.of(), caller, true);

        assertThat(policy.accessReason(client(null), scope))
                .isEqualTo(ClientAccessPolicy.ACCESS_REASON_UNASSIGNED);
        assertThat(policy.accessReason(client(caller), scope))
                .isEqualTo(ClientAccessPolicy.ACCESS_REASON_MANAGEABLE);
        assertThat(policy.accessReason(client(delegated), scope))
                .isEqualTo(ClientAccessPolicy.ACCESS_REASON_OWNER_SCOPE_READ_ONLY);
        assertThat(policy.accessReason(client(other), scope))
                .isEqualTo(ClientAccessPolicy.ACCESS_REASON_SHARED);
    }

    private static Client client(UUID ownerEmployeeId) {
        Client client = new Client();
        client.setId(UUID.randomUUID());
        client.setOwnerEmployeeId(ownerEmployeeId);
        return client;
    }
}
