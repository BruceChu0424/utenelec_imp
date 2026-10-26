package com.uten.imp.features.master;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.features.master.client.ClientService;
import com.uten.imp.features.master.client.dto.ClientQueryFilter;
import com.uten.imp.features.master.supplier.SupplierService;
import com.uten.imp.features.master.supplier.dto.SupplierQueryFilter;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.ValueSource;

import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.mockito.Mockito.*;

class PartySearchContextInputGuardTest {
    @ParameterizedTest @ValueSource(strings = {"keyword", "mobile", "phone", "phone2", "bankAccount"})
    void rowAndMetadataQueriesRejectTheSameOversizedSensitiveFilterBeforeAnyRead(String field) throws Exception {
        ClientQueryFilter client = mock(ClientQueryFilter.class);
        SupplierQueryFilter supplier = mock(SupplierQueryFilter.class);
        String value = "x".repeat(201);
        when(ClientQueryFilter.class.getMethod(field).invoke(client)).thenReturn(value);
        when(SupplierQueryFilter.class.getMethod(field).invoke(supplier)).thenReturn(value);
        ClientService clients = new ClientService(null, null, null, null, null, null, null, null);
        SupplierService suppliers = new SupplierService(null, null, null, null, null, null, null);
        assertThatThrownBy(() -> clients.list(client, 1, 20, null, null)).isInstanceOf(ApiException.class).hasMessageContaining("200");
        assertThatThrownBy(() -> clients.searchContext(client, 1, 100)).isInstanceOf(ApiException.class).hasMessageContaining("200");
        assertThatThrownBy(() -> suppliers.list(supplier, 1, 20, null, null)).isInstanceOf(ApiException.class).hasMessageContaining("200");
        assertThatThrownBy(() -> suppliers.searchContext(supplier, 1, 100)).isInstanceOf(ApiException.class).hasMessageContaining("200");
    }
}
