package com.uten.imp.features.master.client;

import com.uten.imp.common.mastercode.CategoryDrivenCodeService;
import com.uten.imp.common.util.EmployeeNameResolver;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.master.clientcategory.ClientCategoryRepository;
import com.uten.imp.features.master.dto.MasterStatusChangeRequest;
import com.uten.imp.features.org.employee.EmployeeRepository;
import com.uten.imp.security.TxSessionVars;
import jakarta.persistence.EntityManager;
import jakarta.persistence.LockModeType;
import org.junit.jupiter.api.Test;
import org.mockito.InOrder;

import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.Mockito.doThrow;
import static org.mockito.Mockito.inOrder;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

class ClientStatusOwnerLockTest {

    @Test
    void lockedOwnerIsRevalidatedBeforeStatusMutation() {
        Fixture fixture = fixture();
        Client lockedAfterHandover = client(fixture.clientId, 8L, "使用");
        when(fixture.entityManager.find(
                Client.class, fixture.clientId, LockModeType.PESSIMISTIC_WRITE))
                .thenReturn(lockedAfterHandover);
        doThrow(new ApiException(ErrorCode.NOT_FOUND, "客户不存在"))
                .when(fixture.accessPolicy)
                .requireWritable(lockedAfterHandover, fixture.scope);

        assertThrows(ApiException.class, () -> fixture.service.changeStatus(
                fixture.clientId, new MasterStatusChangeRequest("禁用", 8L)));

        verifyLockThenOwnerCheck(fixture, lockedAfterHandover);
        assertThat(lockedAfterHandover.getStatus()).isEqualTo("使用");
        verify(fixture.repository, never()).save(any(Client.class));
    }

    @Test
    void staleVersionStillConflictsAfterLockAndOwnerCheck() {
        Fixture fixture = fixture();
        Client locked = client(fixture.clientId, 9L, "使用");
        when(fixture.entityManager.find(
                Client.class, fixture.clientId, LockModeType.PESSIMISTIC_WRITE))
                .thenReturn(locked);

        ApiException error = assertThrows(ApiException.class, () -> fixture.service.changeStatus(
                fixture.clientId, new MasterStatusChangeRequest("禁用", 8L)));

        assertThat(error.getCode()).isEqualTo(ErrorCode.CONFLICT);
        verifyLockThenOwnerCheck(fixture, locked);
        assertThat(locked.getStatus()).isEqualTo("使用");
        verify(fixture.repository, never()).save(any(Client.class));
    }

    private static void verifyLockThenOwnerCheck(Fixture fixture, Client client) {
        InOrder order = inOrder(fixture.entityManager, fixture.accessPolicy);
        order.verify(fixture.entityManager).find(
                Client.class, fixture.clientId, LockModeType.PESSIMISTIC_WRITE);
        order.verify(fixture.accessPolicy).evaluate();
        order.verify(fixture.accessPolicy).requireWritable(client, fixture.scope);
    }

    private static Fixture fixture() {
        ClientRepository repository = mock(ClientRepository.class);
        EntityManager entityManager = mock(EntityManager.class);
        ClientAccessPolicy accessPolicy = mock(ClientAccessPolicy.class);
        ClientAccessPolicy.ClientScope scope = mock(ClientAccessPolicy.ClientScope.class);
        when(accessPolicy.evaluate()).thenReturn(scope);
        ClientService service = new ClientService(
                repository,
                mock(ClientCategoryRepository.class),
                mock(TxSessionVars.class),
                entityManager,
                mock(CategoryDrivenCodeService.class),
                accessPolicy,
                mock(EmployeeRepository.class),
                mock(EmployeeNameResolver.class));
        return new Fixture(
                UUID.randomUUID(), service, repository, entityManager, accessPolicy, scope);
    }

    private static Client client(UUID id, long version, String status) {
        Client client = new Client();
        client.setId(id);
        client.setOwnerEmployeeId(UUID.randomUUID());
        client.setVersion(version);
        client.setStatus(status);
        return client;
    }

    private record Fixture(
            UUID clientId,
            ClientService service,
            ClientRepository repository,
            EntityManager entityManager,
            ClientAccessPolicy accessPolicy,
            ClientAccessPolicy.ClientScope scope) {
    }
}
