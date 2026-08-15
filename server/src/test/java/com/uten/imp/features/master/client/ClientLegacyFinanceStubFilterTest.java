package com.uten.imp.features.master.client;

import com.uten.imp.common.mastercode.CategoryDrivenCodeService;
import com.uten.imp.common.util.EmployeeNameResolver;
import com.uten.imp.features.master.client.dto.ClientQueryFilter;
import com.uten.imp.features.master.clientcategory.ClientCategoryRepository;
import com.uten.imp.features.org.employee.EmployeeRepository;
import com.uten.imp.security.OwnerVisibility;
import com.uten.imp.security.TxSessionVars;
import jakarta.persistence.EntityManager;
import jakarta.persistence.criteria.CriteriaBuilder;
import jakarta.persistence.criteria.Root;
import org.junit.jupiter.api.Test;
import org.mockito.Answers;
import org.mockito.ArgumentCaptor;
import org.springframework.data.domain.PageImpl;
import org.springframework.data.domain.Pageable;
import org.springframework.data.jpa.domain.Specification;

import java.util.List;
import java.util.Set;

import static org.mockito.ArgumentMatchers.any;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

class ClientLegacyFinanceStubFilterTest {

    @Test
    @SuppressWarnings({"rawtypes", "unchecked"})
    void pickerFilterExcludesLegacyFinanceCodesBeforeDatabasePagination() {
        ClientRepository repository = mock(ClientRepository.class);
        when(repository.findAll(any(Specification.class), any(Pageable.class)))
                .thenReturn(new PageImpl<>(List.of()));
        OwnerVisibility ownerVisibility = mock(OwnerVisibility.class);
        when(ownerVisibility.evaluate("client", "client:view:all"))
                .thenReturn(new OwnerVisibility.OwnerScope(true, Set.of()));
        ClientService service = new ClientService(
                repository,
                mock(ClientCategoryRepository.class),
                mock(TxSessionVars.class),
                mock(EntityManager.class),
                mock(CategoryDrivenCodeService.class),
                ownerVisibility,
                mock(EmployeeRepository.class),
                mock(EmployeeNameResolver.class));

        service.list(filter(true), 1, 20, null, null);

        ArgumentCaptor<Specification<Client>> captor = ArgumentCaptor.forClass(Specification.class);
        verify(repository).findAll(captor.capture(), any(Pageable.class));
        Root<Client> root = mock(Root.class, Answers.RETURNS_DEEP_STUBS);
        CriteriaBuilder cb = mock(CriteriaBuilder.class, Answers.RETURNS_DEEP_STUBS);
        captor.getValue().toPredicate(root, null, cb);

        verify(cb).notLike(any(), org.mockito.ArgumentMatchers.eq("legacy-fin-cl-%"));
    }

    private static ClientQueryFilter filter(boolean excludeLegacyFinanceStub) {
        return new ClientQueryFilter(
                null, // categoryId
                null, // keyword
                Set.of(), // nullFields
                null, // code
                null, // name
                null, // fullName
                null, // clientXz
                null, // tday
                null, // region
                null, // placeId
                null, // empId
                null, // legalPerson
                null, // linkman
                null, // mobile
                null, // phone
                null, // phone2
                null, // fax
                null, // postcode
                null, // address
                null, // bank
                null, // bankAccount
                null, // taxId
                null, // credit
                null, // website
                excludeLegacyFinanceStub);
    }
}
