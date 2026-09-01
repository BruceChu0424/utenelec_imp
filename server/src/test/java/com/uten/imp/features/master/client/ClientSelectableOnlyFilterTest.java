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

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

class ClientSelectableOnlyFilterTest {

    @Test
    @SuppressWarnings({"rawtypes", "unchecked"})
    void activeStatusIsFilteredBeforeDatabasePagination() {
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

        service.list(selectableFilter(), 1, 20, null, null);

        ArgumentCaptor<Specification<Client>> captor = ArgumentCaptor.forClass(Specification.class);
        verify(repository).findAll(captor.capture(), any(Pageable.class));
        Root<Client> root = mock(Root.class, Answers.RETURNS_DEEP_STUBS);
        CriteriaBuilder cb = mock(CriteriaBuilder.class, Answers.RETURNS_DEEP_STUBS);
        captor.getValue().toPredicate(root, null, cb);

        verify(cb).equal(any(), org.mockito.ArgumentMatchers.eq("使用"));
    }

    @Test
    void ordinaryCustomerListKeepsSelectableFilterOffByDefault() {
        var method = java.util.Arrays.stream(ClientController.class.getDeclaredMethods())
                .filter(candidate -> candidate.getName().equals("list"))
                .findFirst()
                .orElseThrow();
        var parameter = java.util.Arrays.stream(method.getParameters())
                .filter(candidate -> candidate.getName().equals("selectableOnly"))
                .findFirst()
                .orElseThrow();
        var requestParam = parameter.getAnnotation(
                org.springframework.web.bind.annotation.RequestParam.class);

        assertThat(requestParam.defaultValue()).isEqualTo("false");
    }

    private static ClientQueryFilter selectableFilter() {
        return new ClientQueryFilter(
                null, null, Set.of(), null, null, null, null, null, null, null,
                null, null, null, null, null, null, null, null, null, null,
                null, null, null, null, null, null, true, true);
    }
}
