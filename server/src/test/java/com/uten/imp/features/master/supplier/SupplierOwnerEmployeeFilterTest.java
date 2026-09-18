package com.uten.imp.features.master.supplier;

import com.uten.imp.common.mastercode.CategoryDrivenCodeService;
import com.uten.imp.common.util.EmployeeNameResolver;
import com.uten.imp.features.master.supplier.dto.SupplierQueryFilter;
import com.uten.imp.features.master.suppliercategory.SupplierCategory;
import com.uten.imp.features.master.suppliercategory.SupplierCategoryRepository;
import com.uten.imp.features.org.employee.EmployeeRepository;
import com.uten.imp.security.TxSessionVars;
import jakarta.persistence.EntityManager;
import jakarta.persistence.Query;
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

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.ArgumentMatchers.eq;
import static org.mockito.Mockito.atLeastOnce;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

/**
 * 供应商「业务员」表头筛选（2026-09-16）：
 * ①列表 ownerEmployeeId=按 owner_employee_id 等值（前端业务员列 ownerEmployeeName
 *   的桶值=员工 UUID 回传此参数）；
 * ②facets empId 桶 JOIN employees 按 owner_employee_id 分组、label 出人名，
 *   空值计数按 owner_employee_id is null（= 前端列「未分配」）。
 */
class SupplierOwnerEmployeeFilterTest {

    @Test
    @SuppressWarnings({"rawtypes", "unchecked"})
    void ownerEmployeeIdFiltersOnOwnerEmployeeIdBeforePagination() {
        SupplierRepository repository = mock(SupplierRepository.class);
        when(repository.findAll(any(Specification.class), any(Pageable.class)))
                .thenReturn(new PageImpl<>(List.of()));
        SupplierService service = service(mock(EntityManager.class), repository);

        UUID owner = UUID.randomUUID();
        service.list(filter(owner), 1, 20, null, null);

        ArgumentCaptor<Specification<Supplier>> captor = ArgumentCaptor.forClass(Specification.class);
        verify(repository).findAll(captor.capture(), any(Pageable.class));
        Root<Supplier> root = mock(Root.class, Answers.RETURNS_DEEP_STUBS);
        CriteriaBuilder cb = mock(CriteriaBuilder.class, Answers.RETURNS_DEEP_STUBS);
        captor.getValue().toPredicate(root, null, cb);

        verify(root).get("ownerEmployeeId");
        verify(cb).equal(any(), eq(owner));
    }

    @Test
    void facetsEmpIdBucketsJoinEmployeesForNamesAndCountUnassignedOwners() {
        EntityManager em = mock(EntityManager.class);
        Query query = mock(Query.class);
        when(em.createNativeQuery(anyString())).thenReturn(query);
        when(query.setParameter(anyString(), any())).thenReturn(query);
        when(query.getResultList()).thenReturn(List.of());
        when(query.getSingleResult()).thenReturn(0L);

        UUID categoryId = UUID.randomUUID();
        SupplierCategory category = new SupplierCategory();
        category.setId(categoryId);
        SupplierCategoryRepository categories = mock(SupplierCategoryRepository.class);
        when(categories.findSubtree(categoryId)).thenReturn(List.of(category));

        service(em, mock(SupplierRepository.class), categories).facets(categoryId);

        ArgumentCaptor<String> sql = ArgumentCaptor.forClass(String.class);
        verify(em, atLeastOnce()).createNativeQuery(sql.capture());
        assertThat(sql.getAllValues()).anySatisfy(statement -> assertThat(statement)
                .contains("join employees on employees.id = suppliers.owner_employee_id")
                .contains("group by employees.id, employees.full_name"));
        assertThat(sql.getAllValues()).anySatisfy(statement -> assertThat(statement)
                .contains("owner_employee_id is null")
                .doesNotContain("join employees"));
    }

    private static SupplierService service(EntityManager em, SupplierRepository repository) {
        return service(em, repository, mock(SupplierCategoryRepository.class));
    }

    private static SupplierService service(
            EntityManager em, SupplierRepository repository, SupplierCategoryRepository categories) {
        return new SupplierService(
                repository,
                categories,
                mock(TxSessionVars.class),
                em,
                mock(CategoryDrivenCodeService.class),
                mock(EmployeeRepository.class),
                mock(EmployeeNameResolver.class));
    }

    private static SupplierQueryFilter filter(UUID ownerEmployeeId) {
        return new SupplierQueryFilter(
                null,                    // categoryId
                null,                    // keyword
                Set.of(),                // nullFields
                null,                    // name
                null,                    // description
                null,                    // tday
                null,                    // place
                null,                    // empId
                ownerEmployeeId,         // ownerEmployeeId（业务员表头筛选）
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
                null,                    // website
                null,                    // shipVia
                null,                    // shipAddress
                false);                  // selectableOnly
    }
}
