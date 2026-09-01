package com.uten.imp.features.master.supplier;

import com.uten.imp.common.mastercode.CategoryCodeAllocation;
import com.uten.imp.common.mastercode.CategoryDrivenCodeService;
import com.uten.imp.common.util.EmployeeNameResolver;
import com.uten.imp.features.master.supplier.dto.SupplierDetail;
import com.uten.imp.features.master.supplier.dto.SupplierSaveRequest;
import com.uten.imp.features.master.suppliercategory.SupplierCategory;
import com.uten.imp.features.master.suppliercategory.SupplierCategoryRepository;
import com.uten.imp.features.org.employee.EmployeeRepository;
import com.uten.imp.security.TxSessionVars;
import jakarta.persistence.EntityManager;
import jakarta.persistence.Query;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.Test;
import org.mockito.ArgumentCaptor;
import org.springframework.security.authentication.TestingAuthenticationToken;
import org.springframework.security.core.context.SecurityContextHolder;

import java.util.List;
import java.util.Optional;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.Mockito.lenient;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

/**
 * V452 供应商默认结算方式：UUID 真源写入 + price_style 旧快照同步 +
 * 字典/详情透出（镜像客户的 V285 契约；DB 触发器兜底一致性）。
 */
class SupplierDefaultSettlementMethodTest {

    private EntityManager emWithMethodRow(UUID methodId, int legacyId, String name) {
        EntityManager em = mock(EntityManager.class);
        Query resolverQuery = mock(Query.class);
        Query nameQuery = mock(Query.class);
        lenient().when(em.createNativeQuery(anyString())).thenReturn(resolverQuery);
        lenient().when(resolverQuery.setParameter(anyString(), any()))
                .thenReturn(resolverQuery);
        lenient().when(resolverQuery.setMaxResults(2)).thenReturn(resolverQuery);
        // resolver 命中唯一活动方式；详情名称解析命中同名行。
        lenient().when(resolverQuery.getResultList())
                .thenReturn(List.<Object[]>of(new Object[] {
                        methodId, legacyId, "JS0006", name, null}))
                .thenReturn(List.<Object[]>of(new Object[] {methodId, name}));
        return em;
    }

    @Test
    void uuidWriteSyncsLegacyShadowAndDetailExposesNames() {
        UUID categoryId = UUID.randomUUID();
        UUID methodId = UUID.randomUUID();
        SupplierCategory category = new SupplierCategory();
        category.setId(categoryId);
        category.setName("供应商分类");

        SupplierRepository repo = mock(SupplierRepository.class);
        SupplierCategoryRepository categories = mock(SupplierCategoryRepository.class);
        CategoryDrivenCodeService codes = mock(CategoryDrivenCodeService.class);
        EmployeeRepository employees = mock(EmployeeRepository.class);
        EmployeeNameResolver names = mock(EmployeeNameResolver.class);
        when(categories.findById(categoryId)).thenReturn(Optional.of(category));
        when(codes.allocate(CategoryDrivenCodeService.MasterType.SUPPLIER, categoryId, null))
                .thenReturn(new CategoryCodeAllocation("GY000001", 1L, categoryId, true));

        SupplierService service = new SupplierService(
                repo, categories, mock(TxSessionVars.class),
                emWithMethodRow(methodId, 6, "月结"),
                codes, employees, names);
        SupplierSaveRequest request = new SupplierSaveRequest();
        request.setCategoryId(categoryId);
        request.setName("供应商甲");
        request.setDefaultSettlementMethodId(methodId);

        SupplierDetail detail = service.create(request);

        ArgumentCaptor<Supplier> captor = ArgumentCaptor.forClass(Supplier.class);
        verify(repo).save(captor.capture());
        assertThat(captor.getValue().getDefaultSettlementMethodId()).isEqualTo(methodId);
        assertThat(captor.getValue().getPriceStyle()).isEqualTo(6);
        assertThat(detail.getDefaultSettlementMethodId()).isEqualTo(methodId);
        assertThat(detail.getDefaultSettlementMethodName()).isEqualTo("月结");
    }

    @Test
    void explicitNullClearsBothUuidAndLegacyShadow() {
        UUID categoryId = UUID.randomUUID();
        UUID supplierId = UUID.randomUUID();
        UUID methodId = UUID.randomUUID();
        SupplierCategory category = new SupplierCategory();
        category.setId(categoryId);
        category.setName("供应商分类");
        Supplier existing = new Supplier();
        existing.setId(supplierId);
        existing.setName("供应商甲");
        existing.setCategory(category);
        existing.setCode("GY000001");
        existing.setCodeSequence(1L);
        existing.setCodeManaged(true);
        existing.setDefaultSettlementMethodId(methodId);
        existing.setPriceStyle(6);

        SupplierRepository repo = mock(SupplierRepository.class);
        SupplierCategoryRepository categories = mock(SupplierCategoryRepository.class);
        CategoryDrivenCodeService codes = mock(CategoryDrivenCodeService.class);
        EmployeeRepository employees = mock(EmployeeRepository.class);
        EmployeeNameResolver names = mock(EmployeeNameResolver.class);
        when(repo.findById(supplierId)).thenReturn(Optional.of(existing));
        when(categories.findById(categoryId)).thenReturn(Optional.of(category));
        when(codes.allocateForUpdate(
                CategoryDrivenCodeService.MasterType.SUPPLIER,
                supplierId, categoryId, null,
                new CategoryCodeAllocation("GY000001", 1L, null, true)))
                .thenReturn(new CategoryCodeAllocation("GY000001", 1L, null, true));

        SupplierService service = new SupplierService(
                repo, categories, mock(TxSessionVars.class),
                mock(EntityManager.class), codes, employees, names);
        SupplierSaveRequest request = new SupplierSaveRequest();
        request.setCategoryId(categoryId);
        request.setName("供应商甲");
        request.setDefaultSettlementMethodId(null);
        authenticate("supplier:edit");

        service.update(supplierId, request);

        ArgumentCaptor<Supplier> captor = ArgumentCaptor.forClass(Supplier.class);
        verify(repo).save(captor.capture());
        assertThat(captor.getValue().getDefaultSettlementMethodId()).isNull();
        assertThat(captor.getValue().getPriceStyle()).isNull();
    }

    @Test
    void dictCarriesDefaultSettlementIdForOrderPrefill() {
        SupplierRepository repo = mock(SupplierRepository.class);
        Supplier withDefault = new Supplier();
        UUID methodId = UUID.randomUUID();
        withDefault.setDefaultSettlementMethodId(methodId);
        Supplier without = new Supplier();
        when(repo.findAll(any(org.springframework.data.jpa.domain.Specification.class),
                any(org.springframework.data.domain.Sort.class)))
                .thenReturn(List.of(withDefault, without));

        SupplierService service = new SupplierService(
                repo, mock(SupplierCategoryRepository.class), mock(TxSessionVars.class),
                mock(EntityManager.class), mock(CategoryDrivenCodeService.class),
                mock(EmployeeRepository.class), mock(EmployeeNameResolver.class));

        var dict = service.dict();

        assertThat(dict.getFirst().getDefaultSettlementMethodId()).isEqualTo(methodId);
        assertThat(dict.get(1).getDefaultSettlementMethodId()).isNull();
    }

    @AfterEach
    void clearSecurityContext() {
        SecurityContextHolder.clearContext();
    }

    private static void authenticate(String... permissions) {
        SecurityContextHolder.getContext().setAuthentication(
                new TestingAuthenticationToken("test", "n/a", permissions));
    }
}
