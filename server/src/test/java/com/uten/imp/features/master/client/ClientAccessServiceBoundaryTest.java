package com.uten.imp.features.master.client;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.security.OwnerVisibility;
import com.uten.imp.security.SecurityContextCurrentUser;
import com.uten.imp.security.TxSessionVars;
import jakarta.persistence.EntityManager;
import org.junit.jupiter.api.Test;

import java.util.Set;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.when;

class ClientAccessServiceBoundaryTest {

    @Test
    void explicitReadOnlyViewerCannotOpenAccessSettingsByKnownUuid() {
        UUID clientId = UUID.randomUUID();
        UUID ownerId = UUID.randomUUID();
        UUID viewerId = UUID.randomUUID();
        Client client = new Client();
        client.setId(clientId);
        client.setOwnerEmployeeId(ownerId);

        EntityManager em = mock(EntityManager.class);
        ClientAccessPolicy policy = mock(ClientAccessPolicy.class);
        when(em.find(Client.class, clientId)).thenReturn(client);
        when(policy.evaluate()).thenReturn(new ClientAccessPolicy.ClientScope(
                new OwnerVisibility.OwnerScope(
                        false,
                        Set.of(viewerId),
                        Set.of(viewerId)),
                Set.of(clientId),
                true));
        ClientAccessService service = new ClientAccessService(
                em,
                mock(TxSessionVars.class),
                mock(SecurityContextCurrentUser.class),
                policy);

        ApiException error = assertThrows(ApiException.class, () -> service.get(clientId));

        assertThat(error.getCode()).isEqualTo(ErrorCode.NOT_FOUND);
    }
}
