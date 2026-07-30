package com.uten.imp.features.visitor;

import com.uten.imp.features.org.department.DepartmentRepository;
import com.uten.imp.features.org.employee.EmployeeRepository;
import org.junit.jupiter.api.Test;
import org.mockito.ArgumentCaptor;
import org.springframework.data.domain.PageImpl;
import org.springframework.data.domain.Pageable;
import org.springframework.data.domain.Sort;
import org.springframework.data.jpa.domain.Specification;

import java.util.List;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

@SuppressWarnings("unchecked")
class VisitorDirectoryPagingTest {

    @Test
    void employeePickerAppliesLimitAndStableSortInDatabase() {
        EmployeeRepository employeeRepository = mock(EmployeeRepository.class);
        when(employeeRepository.findAll(
                any(Specification.class),
                any(Pageable.class))).thenReturn(new PageImpl<>(List.of()));
        VisitorDirectoryService service = new VisitorDirectoryService(
                employeeRepository,
                mock(DepartmentRepository.class));

        service.listEmployees(null, null);

        ArgumentCaptor<Pageable> captor = ArgumentCaptor.forClass(Pageable.class);
        verify(employeeRepository).findAll(
                any(Specification.class),
                captor.capture());
        Pageable pageable = captor.getValue();
        assertEquals(0, pageable.getPageNumber());
        assertEquals(50, pageable.getPageSize());
        assertEquals(
                List.of("fullName", "id"),
                pageable.getSort().stream().map(Sort.Order::getProperty).toList());
    }
}
