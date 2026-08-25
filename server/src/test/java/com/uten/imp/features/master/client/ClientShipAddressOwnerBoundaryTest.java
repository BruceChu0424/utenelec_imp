package com.uten.imp.features.master.client;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.master.client.dto.ClientShipAddressSaveRequest;
import com.uten.imp.security.SecurityContextCurrentUser;
import com.uten.imp.security.TxSessionVars;
import jakarta.persistence.EntityManager;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;

import java.util.Optional;
import java.util.UUID;

import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.mockito.Mockito.doThrow;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

class ClientShipAddressOwnerBoundaryTest {

    private final ClientShipAddressRepository addressRepository =
            mock(ClientShipAddressRepository.class);
    private final ClientRepository clientRepository = mock(ClientRepository.class);
    private final ClientAccessPolicy accessPolicy = mock(ClientAccessPolicy.class);
    private final ClientAccessPolicy.ClientScope accessScope =
            mock(ClientAccessPolicy.ClientScope.class);
    private final EntityManager entityManager = mock(EntityManager.class);
    private final ClientShipAddressService service = new ClientShipAddressService(
            addressRepository,
            clientRepository,
            accessPolicy,
            entityManager,
            mock(SecurityContextCurrentUser.class),
            mock(TxSessionVars.class));

    private UUID clientId;
    private Client client;

    @BeforeEach
    void setUp() {
        clientId = UUID.randomUUID();
        client = new Client();
        client.setId(clientId);
        client.setOwnerEmployeeId(UUID.randomUUID());
        when(clientRepository.findById(clientId)).thenReturn(Optional.of(client));
        when(entityManager.find(
                Client.class, clientId, jakarta.persistence.LockModeType.PESSIMISTIC_WRITE))
                .thenReturn(client);
        when(accessPolicy.evaluate()).thenReturn(accessScope);
    }

    @Test
    void listHidesAnotherOwnersAddressBook() {
        doThrow(notFound()).when(accessPolicy).requireReadable(client, accessScope);

        assertThrows(ApiException.class, () -> service.list(clientId));

        verify(addressRepository, never())
                .findByClientIdAndDeletedFalseOrderByLastUsedAtDesc(clientId);
    }

    @Test
    void addHidesAnotherOwnersCustomerEvenWithAddressCreatePermission() {
        doThrow(notFound()).when(accessPolicy).requireWritable(client, accessScope);

        assertThrows(ApiException.class, () -> service.add(
                clientId, new ClientShipAddressSaveRequest("测试地址", "13800000000")));

        var order = org.mockito.Mockito.inOrder(entityManager, accessPolicy);
        order.verify(entityManager).find(
                Client.class, clientId, jakarta.persistence.LockModeType.PESSIMISTIC_WRITE);
        order.verify(accessPolicy).evaluate();
        order.verify(accessPolicy).requireWritable(client, accessScope);
        verify(entityManager, never()).createNativeQuery(org.mockito.ArgumentMatchers.anyString());
    }

    @Test
    void deleteHidesAnotherOwnersCustomerBeforeResolvingAddressId() {
        doThrow(notFound()).when(accessPolicy).requireWritable(client, accessScope);

        assertThrows(ApiException.class, () -> service.delete(clientId, UUID.randomUUID()));

        var order = org.mockito.Mockito.inOrder(entityManager, accessPolicy);
        order.verify(entityManager).find(
                Client.class, clientId, jakarta.persistence.LockModeType.PESSIMISTIC_WRITE);
        order.verify(accessPolicy).evaluate();
        order.verify(accessPolicy).requireWritable(client, accessScope);
        verify(addressRepository, never()).findByIdAndDeletedFalse(
                org.mockito.ArgumentMatchers.any(UUID.class));
    }

    private static ApiException notFound() {
        return new ApiException(ErrorCode.NOT_FOUND, "客户不存在");
    }
}
