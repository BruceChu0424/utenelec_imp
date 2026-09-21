package com.uten.imp.features.master.client;

import com.uten.imp.common.mastercode.CategoryCodeAllocation;
import com.uten.imp.common.mastercode.CategoryDrivenCodeService;
import com.uten.imp.common.util.EmployeeNameResolver;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.master.client.dto.ClientSaveRequest;
import com.uten.imp.features.master.clientcategory.ClientCategory;
import com.uten.imp.features.master.clientcategory.ClientCategoryRepository;
import com.uten.imp.features.org.employee.Employee;
import com.uten.imp.features.org.employee.EmployeeRepository;
import com.uten.imp.security.TxSessionVars;
import jakarta.persistence.EntityManager;
import org.junit.jupiter.api.Test;

import java.util.Optional;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

class ClientOwnershipWriteBoundaryTest {

    @Test
    void createDefaultsOwnerToTheCurrentEmployee() {
        Fixture fixture = fixture();
        UUID currentEmployeeId = UUID.randomUUID();
        Employee current = employee(currentEmployeeId, "active", 19);
        when(fixture.accessPolicy.requireCurrentEmployeeId()).thenReturn(currentEmployeeId);
        when(fixture.employeeRepository.findById(currentEmployeeId)).thenReturn(Optional.of(current));
        when(fixture.names.nameOf(currentEmployeeId)).thenReturn("当前业务员");

        var detail = fixture.service.create(request(fixture.category.getId()));

        assertThat(detail.getOwnerEmployeeId()).isEqualTo(currentEmployeeId);
        assertThat(detail.getOwnerEmployeeName()).isEqualTo("当前业务员");
        verify(fixture.clientRepository).save(any(Client.class));
    }

    @Test
    void createRejectsAResignedExplicitOwnerEvenForAnAssigner() {
        Fixture fixture = fixture();
        UUID currentEmployeeId = UUID.randomUUID();
        UUID resignedEmployeeId = UUID.randomUUID();
        when(fixture.accessPolicy.requireCurrentEmployeeId()).thenReturn(currentEmployeeId);
        when(fixture.accessPolicy.hasAssignAuthority()).thenReturn(true);
        when(fixture.employeeRepository.findById(resignedEmployeeId))
                .thenReturn(Optional.of(employee(resignedEmployeeId, "resigned", 20)));
        ClientSaveRequest request = request(fixture.category.getId());
        request.setOwnerEmployeeId(resignedEmployeeId);

        ApiException error = assertThrows(ApiException.class, () -> fixture.service.create(request));

        assertThat(error.getCode()).isEqualTo(ErrorCode.CONFLICT);
        verify(fixture.clientRepository, never()).save(any(Client.class));
    }

    private static Fixture fixture() {
        ClientRepository clients = mock(ClientRepository.class);
        ClientCategoryRepository categories = mock(ClientCategoryRepository.class);
        CategoryDrivenCodeService codes = mock(CategoryDrivenCodeService.class);
        ClientAccessPolicy accessPolicy = mock(ClientAccessPolicy.class);
        EmployeeRepository employees = mock(EmployeeRepository.class);
        EmployeeNameResolver names = mock(EmployeeNameResolver.class);
        ClientCategory category = new ClientCategory();
        category.setId(UUID.randomUUID());
        category.setName("客户分类");
        when(categories.findById(category.getId())).thenReturn(Optional.of(category));
        when(codes.allocate(CategoryDrivenCodeService.MasterType.CLIENT, category.getId(), null))
                .thenReturn(new CategoryCodeAllocation("KH000001", 1, category.getId(), true));
        ClientService service = new ClientService(
                clients,
                categories,
                mock(TxSessionVars.class),
                mock(EntityManager.class),
                codes,
                accessPolicy,
                employees,
                names);
        return new Fixture(
                service, clients, employees, accessPolicy, names, category);
    }

    private static ClientSaveRequest request(UUID categoryId) {
        ClientSaveRequest request = new ClientSaveRequest();
        request.setCategoryId(categoryId);
        request.setName("客户甲");
        return request;
    }

    private static Employee employee(UUID id, String status, int legacyId) {
        Employee employee = new Employee();
        employee.setId(id);
        employee.setStatus(status);
        employee.setLegacyId(legacyId);
        return employee;
    }

    private record Fixture(
            ClientService service,
            ClientRepository clientRepository,
            EmployeeRepository employeeRepository,
            ClientAccessPolicy accessPolicy,
            EmployeeNameResolver names,
            ClientCategory category) {
    }
}
