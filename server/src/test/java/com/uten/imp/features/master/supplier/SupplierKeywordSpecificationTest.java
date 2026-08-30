package com.uten.imp.features.master.supplier;

import com.uten.imp.common.mastercode.CategoryDrivenCodeService;
import com.uten.imp.common.util.EmployeeNameResolver;
import com.uten.imp.features.org.employee.EmployeeRepository;
import com.uten.imp.features.master.supplier.dto.SupplierQueryFilter;
import com.uten.imp.features.master.supplier.SupplierController;
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
import static org.mockito.ArgumentMatchers.eq;
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

    @Test
    @SuppressWarnings({"rawtypes", "unchecked"})
    void selectableSupplierFilterExcludesDisabledAndInternalWorkshopsBeforePagination() {
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

        SupplierQueryFilter selectable = new SupplierQueryFilter(
                null, null, Set.of(),
                null, null, null, null, null, null, null, null, null, null,
                null, null, null, null, null, null, null, null, null, true);
        service.list(selectable, 1, 20, null, null);

        ArgumentCaptor<Specification<Supplier>> captor = ArgumentCaptor.forClass(Specification.class);
        verify(repository).findAll(captor.capture(), any(Pageable.class));
        Root<Supplier> root = mock(Root.class, Answers.RETURNS_DEEP_STUBS);
        CriteriaBuilder cb = mock(CriteriaBuilder.class, Answers.RETURNS_DEEP_STUBS);
        captor.getValue().toPredicate(root, null, cb);

        verify(root).get("internalWorkshop");
        verify(cb).isNull(any());
        verify(cb).equal(any(), eq("使用"));
    }

    @Test
    void ordinarySupplierListKeepsSelectableFilterOffByDefault() {
        var method = java.util.Arrays.stream(SupplierController.class.getDeclaredMethods())
                .filter(candidate -> candidate.getName().equals("list"))
                .findFirst()
                .orElseThrow();
        var parameter = java.util.Arrays.stream(method.getParameters())
                .filter(candidate -> candidate.getName().equals("selectableOnly"))
                .findFirst()
                .orElseThrow();
        var requestParam = parameter.getAnnotation(
                org.springframework.web.bind.annotation.RequestParam.class);

        org.assertj.core.api.Assertions.assertThat(requestParam.defaultValue())
                .isEqualTo("false");
    }

    private static SupplierQueryFilter filter(String keyword) {
        return new SupplierQueryFilter(
                null, keyword, Set.of(),
                null, null, null, null, null, null, null, null, null, null,
                null, null, null, null, null, null, null, null, null);
    }
}
