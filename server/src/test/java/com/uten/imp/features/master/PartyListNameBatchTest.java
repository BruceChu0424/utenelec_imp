package com.uten.imp.features.master;

import com.uten.imp.common.util.EmployeeNameResolver;
import com.uten.imp.features.master.client.*;
import com.uten.imp.features.master.client.dto.ClientQueryFilter;
import com.uten.imp.features.master.clientcategory.ClientCategoryRepository;
import com.uten.imp.features.master.supplier.*;
import com.uten.imp.features.master.supplier.dto.SupplierQueryFilter;
import com.uten.imp.features.master.suppliercategory.SupplierCategoryRepository;
import jakarta.persistence.EntityManager;
import jakarta.persistence.Query;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.springframework.data.domain.PageImpl;
import org.springframework.data.domain.PageRequest;
import org.springframework.data.domain.Pageable;
import org.springframework.data.jpa.domain.Specification;

import java.math.BigDecimal;
import java.util.List;
import java.util.Map;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.ArgumentMatchers.*;
import static org.mockito.Mockito.*;

/** Caller coverage: page-local names must not change authorization, legacy shadows, amounts or ordering. */
@SuppressWarnings({"rawtypes", "unchecked"})
class PartyListNameBatchTest {
    private final ClientRepository clients = mock(ClientRepository.class);
    private final SupplierRepository suppliers = mock(SupplierRepository.class);
    private final ClientAccessPolicy access = mock(ClientAccessPolicy.class);
    private final EmployeeNameResolver names = mock(EmployeeNameResolver.class);
    private final EntityManager em = mock(EntityManager.class);
    private ClientService clientService;
    private SupplierService supplierService;

    @BeforeEach void services() {
        Query coOwners = mock(Query.class);
        when(em.createNativeQuery(contains("client_co_owners"))).thenReturn(coOwners);
        when(coOwners.setParameter(anyString(),any())).thenReturn(coOwners);
        when(coOwners.getResultList()).thenReturn(List.of());
        clientService = new ClientService(clients, mock(ClientCategoryRepository.class), null, em,
                null, access, null, names);
        supplierService = new SupplierService(suppliers, mock(SupplierCategoryRepository.class), null,
                em, null, null, names);
    }

    @Test void clientsResolveOnlyReturnedOwnersAndKeepUnknownIdsRawFieldsAndAccessDecisions() {
        UUID owner = UUID.randomUUID(), unknown = UUID.randomUUID();
        List<Client> rows = List.of(client(owner), client(null), client(owner), client(unknown));
        when(clients.findAll(any(Specification.class), any(Pageable.class)))
                .thenReturn(new PageImpl<>(rows, PageRequest.of(2, 4), 100));
        when(names.namesOf(anyCollection())).thenReturn(Map.of(owner, "历史员工"));
        var scope = new ClientAccessPolicy.ClientScope(
                new com.uten.imp.security.OwnerVisibility.OwnerScope(false, java.util.Set.of(owner),java.util.Set.of(owner)),java.util.Set.of(),true);
        when(access.evaluate()).thenReturn(scope);

        var result = clientService.list(mock(ClientQueryFilter.class), 3, 4, null, null);

        verify(names).namesOf(java.util.Arrays.asList(owner, null, owner, unknown));
        verify(names, never()).nameOf(any());
        assertThat(result.getItems()).extracting(row -> row.getOwnerEmployeeName())
                .containsExactly("历史员工", null, "历史员工", null);
        assertThat(result.getItems()).extracting(row -> row.getId())
                .containsExactlyElementsOf(rows.stream().map(Client::getId).toList());
        assertThat(result.getItems()).extracting(row -> row.isWritable()).containsExactly(true, false, true, false);
        assertThat(result.getItems()).extracting(row -> row.isAccessManageable()).containsExactly(true, true, true, false);
        assertThat(result.getItems()).allSatisfy(row -> {
            assertThat(row.getEmpId()).isEqualTo("0017. 原文");
            assertThat(row.getCredit()).isEqualByComparingTo("0.0001");
            assertThat(row.getVersion()).isEqualTo(7L);
        });
        assertThat(result.getPage()).isEqualTo(3);
        assertThat(result.getSize()).isEqualTo(4);
        assertThat(result.getTotal()).isEqualTo(100);
    }

    @Test void supplierNamesAndLossRatesUseIndependentPageBatchesWithoutTouchingLegacyOwnerText() {
        UUID owner = UUID.randomUUID(), unknown = UUID.randomUUID();
        List<Supplier> rows = List.of(supplier(owner), supplier(null), supplier(owner), supplier(unknown));
        when(suppliers.findAll(any(Specification.class), any(Pageable.class)))
                .thenReturn(new PageImpl<>(rows, PageRequest.of(1, 4), 20));
        when(names.namesOf(anyCollection())).thenReturn(Map.of(owner, "离职员工"));
        Query rates = mock(Query.class);
        when(em.createNativeQuery(contains("v_subcontract_supplier_loss_summary"))).thenReturn(rates);
        when(rates.setParameter(eq("ids"), any())).thenReturn(rates);
        when(rates.getResultList()).thenReturn(java.util.Collections.singletonList(
                new Object[]{rows.get(2).getId(), new BigDecimal("0.123456")}));

        var result = supplierService.list(mock(SupplierQueryFilter.class), 2, 4, null, null);

        verify(names).namesOf(java.util.Arrays.asList(owner, null, owner, unknown));
        verify(names, never()).nameOf(any());
        verify(rates).setParameter("ids", rows.stream().map(Supplier::getId).toList());
        assertThat(result.getItems()).extracting(row -> row.getOwnerEmployeeName())
                .containsExactly("离职员工", null, "离职员工", null);
        assertThat(result.getItems()).extracting(row -> row.getEmpId())
                .containsOnly("0008 原始文本");
        assertThat(result.getItems().get(2).getLossRate()).isEqualByComparingTo("0.123456");
        assertThat(result.getItems().get(0).getLossRate()).isNull();
        assertThat(result.getItems()).extracting(row -> row.getId())
                .containsExactlyElementsOf(rows.stream().map(Supplier::getId).toList());
        assertThat(result.getPage()).isEqualTo(2);
        assertThat(result.getTotal()).isEqualTo(20);
    }

    @Test void emptyPagesDoNotResolveNamesOrQueryLossRates() {
        when(clients.findAll(any(Specification.class), any(Pageable.class)))
                .thenReturn(new PageImpl<>(List.of()));
        when(suppliers.findAll(any(Specification.class), any(Pageable.class)))
                .thenReturn(new PageImpl<>(List.of()));
        assertThat(clientService.list(mock(ClientQueryFilter.class), 1, 20, null, null).getItems()).isEmpty();
        assertThat(supplierService.list(mock(SupplierQueryFilter.class), 1, 20, null, null).getItems()).isEmpty();
        verifyNoInteractions(names, em);
    }

    @Test void subsequentReadsResolveCurrentNamesRatherThanKeepingAccountOrServerLocalCache() {
        UUID owner = UUID.randomUUID();
        when(clients.findAll(any(Specification.class), any(Pageable.class)))
                .thenReturn(new PageImpl<>(List.of(client(owner))));
        when(names.namesOf(anyCollection())).thenReturn(Map.of(owner, "A"), Map.of(owner, "B"), Map.of(owner, "A2"));
        for (String expected : List.of("A", "B", "A2")) {
            assertThat(clientService.list(mock(ClientQueryFilter.class), 1, 20, null, null)
                    .getItems().getFirst().getOwnerEmployeeName()).isEqualTo(expected);
        }
        verify(names, times(3)).namesOf(List.of(owner));
    }

    private static Client client(UUID owner) {
        Client row = new Client(); row.setId(UUID.randomUUID()); row.setOwnerEmployeeId(owner);
        row.setEmpId("0017. 原文"); row.setCredit(new BigDecimal("0.0001")); row.setVersion(7L);
        return row;
    }
    private static Supplier supplier(UUID owner) {
        Supplier row = new Supplier(); row.setId(UUID.randomUUID()); row.setOwnerEmployeeId(owner);
        row.setEmpId("0008 原始文本"); return row;
    }
}
