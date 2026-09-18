package com.uten.imp.features.master.client;

import com.uten.imp.common.mastercode.CategoryDrivenCodeService;
import com.uten.imp.common.util.EmployeeNameResolver;
import com.uten.imp.features.master.client.dto.ClientQueryFilter;
import com.uten.imp.features.master.clientcategory.ClientCategoryRepository;
import com.uten.imp.features.org.employee.EmployeeRepository;
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
import java.util.UUID;

import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.eq;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

/**
 * 客户列表「负责人」表头筛选（2026-09-16）：ownerEmployeeId=按 owner_employee_id 等值
 * （前端负责人列 ownerEmployeeName 的桶值=员工 UUID 回传此参数）。
 */
class ClientOwnerEmployeeFilterTest {

    @Test
    @SuppressWarnings({"rawtypes", "unchecked"})
    void ownerEmployeeIdFiltersOnOwnerEmployeeIdBeforePagination() {
        ClientRepository repository = mock(ClientRepository.class);
        when(repository.findAll(any(Specification.class), any(Pageable.class)))
                .thenReturn(new PageImpl<>(List.of()));
        ClientAccessPolicy accessPolicy = mock(ClientAccessPolicy.class);
        when(accessPolicy.evaluate()).thenReturn(mock(ClientAccessPolicy.ClientScope.class));
        ClientService service = new ClientService(
                repository,
                mock(ClientCategoryRepository.class),
                mock(TxSessionVars.class),
                mock(EntityManager.class),
                mock(CategoryDrivenCodeService.class),
                accessPolicy,
                mock(EmployeeRepository.class),
                mock(EmployeeNameResolver.class));

        UUID owner = UUID.randomUUID();
        service.list(filter(owner), 1, 20, null, null);

        ArgumentCaptor<Specification<Client>> captor = ArgumentCaptor.forClass(Specification.class);
        verify(repository).findAll(captor.capture(), any(Pageable.class));
        Root<Client> root = mock(Root.class, Answers.RETURNS_DEEP_STUBS);
        CriteriaBuilder cb = mock(CriteriaBuilder.class, Answers.RETURNS_DEEP_STUBS);
        captor.getValue().toPredicate(root, null, cb);

        verify(root).get("ownerEmployeeId");
        verify(cb).equal(any(), eq(owner));
    }

    private static ClientQueryFilter filter(UUID ownerEmployeeId) {
        return new ClientQueryFilter(
                null,                    // categoryId
                null,                    // keyword
                Set.of(),                // nullFields
                null,                    // code
                null,                    // name
                null,                    // fullName
                null,                    // salesPaymentType
                null,                    // clientXz
                null,                    // tday
                null,                    // region
                null,                    // placeId
                null,                    // empId
                ownerEmployeeId,         // ownerEmployeeId（负责人表头筛选）
                null,                    // legalPerson
                null,                    // linkman
                null,                    // mobile
                null,                    // phone
                null,                    // phone2
                null,                    // fax
                null,                    // postcode
                null,                    // address
                null,                    // bank
                null,                    // bankAccount
                null,                    // taxId
                null,                    // credit
                null,                    // creditFloor
                null,                    // website
                false,                   // excludeLegacyFinanceStub
                false);                  // selectableOnly
    }
}
