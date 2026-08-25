package com.uten.imp.features.master.client;

import org.junit.jupiter.api.Test;
import org.springframework.transaction.annotation.Isolation;
import org.springframework.transaction.annotation.Transactional;

import java.lang.reflect.Method;

import static org.assertj.core.api.Assertions.assertThat;

class ClientReadSnapshotContractTest {

    @Test
    void multiQueryCustomerReadsUseOneRepeatableDatabaseSnapshot() throws Exception {
        assertRepeatable(ClientService.class, "list",
                com.uten.imp.features.master.client.dto.ClientQueryFilter.class,
                int.class, int.class, String.class, String.class);
        assertRepeatable(ClientService.class, "dict", boolean.class);
        assertRepeatable(ClientService.class, "facets", java.util.UUID.class, boolean.class);
        assertRepeatable(ClientService.class, "export",
                com.uten.imp.features.master.client.dto.ClientQueryFilter.class,
                String.class, String.class);
        assertRepeatable(ClientService.class, "detail", java.util.UUID.class);
        assertRepeatable(ClientAccessService.class, "get", java.util.UUID.class);
        assertRepeatable(ClientShipAddressService.class, "list", java.util.UUID.class);
    }

    private static void assertRepeatable(
            Class<?> type, String name, Class<?>... parameterTypes) throws Exception {
        Method method = type.getDeclaredMethod(name, parameterTypes);
        Transactional tx = method.getAnnotation(Transactional.class);
        assertThat(tx).as(type.getSimpleName() + "." + name).isNotNull();
        assertThat(tx.readOnly()).isTrue();
        assertThat(tx.isolation()).isEqualTo(Isolation.REPEATABLE_READ);
    }
}
