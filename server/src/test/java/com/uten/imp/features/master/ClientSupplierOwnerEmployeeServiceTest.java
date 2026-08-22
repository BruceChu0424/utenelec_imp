package com.uten.imp.features.master;

import com.uten.imp.common.mastercode.CategoryCodeAllocation;
import com.uten.imp.common.mastercode.CategoryDrivenCodeService;
import com.uten.imp.common.util.EmployeeNameResolver;
import com.uten.imp.features.master.client.ClientRepository;
import com.uten.imp.features.master.client.ClientService;
import com.uten.imp.features.master.client.dto.ClientDetail;
import com.uten.imp.features.master.client.dto.ClientSaveRequest;
import com.uten.imp.features.master.clientcategory.ClientCategory;
import com.uten.imp.features.master.clientcategory.ClientCategoryRepository;
import com.uten.imp.features.master.supplier.SupplierRepository;
import com.uten.imp.features.master.supplier.SupplierService;
import com.uten.imp.features.master.supplier.dto.SupplierDetail;
import com.uten.imp.features.master.supplier.dto.SupplierSaveRequest;
import com.uten.imp.features.master.suppliercategory.SupplierCategory;
import com.uten.imp.features.master.suppliercategory.SupplierCategoryRepository;
import com.uten.imp.features.org.employee.Employee;
import com.uten.imp.features.org.employee.EmployeeRepository;
import com.uten.imp.security.OwnerVisibility;
import com.uten.imp.security.TxSessionVars;
import jakarta.persistence.EntityManager;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.Test;

import java.util.Optional;
import java.util.UUID;

import org.springframework.security.authentication.TestingAuthenticationToken;
import org.springframework.security.core.context.SecurityContextHolder;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

class ClientSupplierOwnerEmployeeServiceTest {

    @Test
    void websiteClientKeepsItsRealUncategorizedCategoryWhenEdited() {
        authenticate("client:edit");
        UUID clientId = UUID.randomUUID();
        UUID categoryId = UUID.randomUUID();
        ClientCategory uncategorized = new ClientCategory();
        uncategorized.setId(categoryId);
        uncategorized.setLegacyId(-1);
        uncategorized.setName("未分类");
        com.uten.imp.features.master.client.Client existing =
                new com.uten.imp.features.master.client.Client();
        existing.setId(clientId);
        existing.setName("官网询盘客户");
        existing.setCode("KH000001");
        existing.setCodeSequence(1L);
        existing.setCodeManaged(true);
        existing.setCategory(uncategorized);

        ClientRepository repo = mock(ClientRepository.class);
        ClientCategoryRepository categories = mock(ClientCategoryRepository.class);
        CategoryDrivenCodeService codes = mock(CategoryDrivenCodeService.class);
        when(repo.findById(clientId)).thenReturn(Optional.of(existing));
        when(categories.findById(categoryId)).thenReturn(Optional.of(uncategorized));
        when(codes.allocateForUpdate(
                CategoryDrivenCodeService.MasterType.CLIENT,
                clientId,
                categoryId,
                "KH000001",
                new CategoryCodeAllocation("KH000001", 1L, null, true)))
                .thenReturn(new CategoryCodeAllocation("KH000001", 1L, null, true));

        OwnerVisibility visibility = mock(OwnerVisibility.class);
        when(visibility.evaluate("client", "client:view:all"))
                .thenReturn(new OwnerVisibility.OwnerScope(true, java.util.Set.of()));
        ClientService service = new ClientService(
                repo, categories, mock(TxSessionVars.class),
                mock(EntityManager.class), codes, visibility,
                mock(EmployeeRepository.class), mock(EmployeeNameResolver.class));
        ClientSaveRequest request = new ClientSaveRequest();
        request.setCategoryId(categoryId);
        request.setName("官网客户已核实");
        request.setCode("KH000001");

        ClientDetail detail = service.update(clientId, request);

        assertThat(detail.getCategoryId()).isEqualTo(categoryId);
        assertThat(detail.getName()).isEqualTo("官网客户已核实");
    }

    @Test
    void clientWriteUsesEmployeeUuidAndDerivesLegacyShadow() {
        UUID categoryId = UUID.randomUUID();
        UUID employeeId = UUID.randomUUID();
        ClientCategory category = new ClientCategory();
        category.setId(categoryId);
        category.setName("客户分类");
        Employee employee = employee(employeeId, 17);

        ClientRepository repo = mock(ClientRepository.class);
        ClientCategoryRepository categories = mock(ClientCategoryRepository.class);
        EmployeeRepository employees = mock(EmployeeRepository.class);
        CategoryDrivenCodeService codes = mock(CategoryDrivenCodeService.class);
        EmployeeNameResolver names = mock(EmployeeNameResolver.class);
        when(categories.findById(categoryId)).thenReturn(Optional.of(category));
        when(employees.findById(employeeId)).thenReturn(Optional.of(employee));
        when(codes.allocate(CategoryDrivenCodeService.MasterType.CLIENT, categoryId, null))
                .thenReturn(new CategoryCodeAllocation("KH000001", 1, categoryId, true));
        when(names.nameOf(employeeId)).thenReturn("王业务");

        ClientService service = new ClientService(
                repo, categories, mock(TxSessionVars.class), mock(EntityManager.class),
                codes, mock(OwnerVisibility.class), employees, names);
        ClientSaveRequest request = new ClientSaveRequest();
        request.setCategoryId(categoryId);
        request.setName("客户甲");
        request.setOwnerEmployeeId(employeeId);

        ClientDetail detail = service.create(request);

        assertThat(detail.getOwnerEmployeeId()).isEqualTo(employeeId);
        assertThat(detail.getOwnerEmployeeName()).isEqualTo("王业务");
        assertThat(detail.getEmpId()).isEqualTo("17");
        verify(repo).save(any());
    }

    @Test
    void supplierWriteUsesEmployeeUuidAndDerivesLegacyShadow() {
        UUID categoryId = UUID.randomUUID();
        UUID employeeId = UUID.randomUUID();
        SupplierCategory category = new SupplierCategory();
        category.setId(categoryId);
        category.setName("供应商分类");
        Employee employee = employee(employeeId, 23);

        SupplierRepository repo = mock(SupplierRepository.class);
        SupplierCategoryRepository categories = mock(SupplierCategoryRepository.class);
        EmployeeRepository employees = mock(EmployeeRepository.class);
        CategoryDrivenCodeService codes = mock(CategoryDrivenCodeService.class);
        EmployeeNameResolver names = mock(EmployeeNameResolver.class);
        when(categories.findById(categoryId)).thenReturn(Optional.of(category));
        when(employees.findById(employeeId)).thenReturn(Optional.of(employee));
        when(codes.allocate(CategoryDrivenCodeService.MasterType.SUPPLIER, categoryId, null))
                .thenReturn(new CategoryCodeAllocation("GY000001", 1, categoryId, true));
        when(names.nameOf(employeeId)).thenReturn("李业务");

        SupplierService service = new SupplierService(
                repo, categories, mock(TxSessionVars.class), mock(EntityManager.class),
                codes, employees, names);
        SupplierSaveRequest request = new SupplierSaveRequest();
        request.setCategoryId(categoryId);
        request.setName("供应商甲");
        request.setOwnerEmployeeId(employeeId);

        SupplierDetail detail = service.create(request);

        assertThat(detail.getOwnerEmployeeId()).isEqualTo(employeeId);
        assertThat(detail.getOwnerEmployeeName()).isEqualTo("李业务");
        assertThat(detail.getEmpId()).isEqualTo("23");
        verify(repo).save(any());
    }

    @AfterEach
    void clearSecurityContext() {
        SecurityContextHolder.clearContext();
    }

    private static void authenticate(String... permissions) {
        SecurityContextHolder.getContext().setAuthentication(
                new TestingAuthenticationToken("test", "n/a", permissions));
    }

    private static Employee employee(UUID id, int legacyId) {
        Employee employee = new Employee();
        employee.setId(id);
        employee.setLegacyId(legacyId);
        return employee;
    }
}
