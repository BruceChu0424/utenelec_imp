package com.uten.imp.features.master.supplier;

import com.uten.imp.common.mastercode.CategoryDrivenCodeService;
import com.uten.imp.common.util.EmployeeNameResolver;
import com.uten.imp.features.org.employee.EmployeeRepository;
import com.uten.imp.features.master.supplier.dto.SupplierQueryFilter;
import com.uten.imp.features.master.suppliercategory.SupplierCategoryRepository;
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

class SupplierKeywordSpecificationTest {

    @Test
    @SuppressWarnings({"rawtypes", "unchecked"})
    void keywordSearchIncludesSupplierCode() {
        SupplierRepository repository = mock(SupplierRepository.class);
        when(repository.findAll(any(Specification.class), any(Pageable.class)))
                .thenReturn(new PageImpl<>(List.of()));
        SupplierService service = new SupplierService(
                repository,
                mock(SupplierCategoryRepository.class),
                mock(TxSessionVars.class),
                mock(EntityManager.class),
                mock(CategoryDrivenCodeService.class),
                mock(EmployeeRepository.class),
                mock(EmployeeNameResolver.class));

        service.list(filter("SUP-001"), 1, 20, null, null);

        ArgumentCaptor<Specification<Supplier>> captor = ArgumentCaptor.forClass(Specification.class);
        verify(repository).findAll(captor.capture(), any(Pageable.class));
        Root<Supplier> root = mock(Root.class, Answers.RETURNS_DEEP_STUBS);
        CriteriaBuilder cb = mock(CriteriaBuilder.class, Answers.RETURNS_DEEP_STUBS);
        captor.getValue().toPredicate(root, null, cb);

        verify(root).get("code");
    }

    private static SupplierQueryFilter filter(String keyword) {
        return new SupplierQueryFilter(
                null, keyword, Set.of(),
                null, null, null, null, null, null, null, null, null, null,
                null, null, null, null, null, null, null, null, null);
    }
}
