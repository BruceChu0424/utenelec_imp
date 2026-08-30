package com.uten.imp.features.org.department;

import com.uten.imp.features.org.department.dto.DepartmentPickerNode;
import com.uten.imp.features.org.employee.EmployeeController;
import org.junit.jupiter.api.Test;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.web.bind.annotation.GetMapping;

import java.lang.reflect.RecordComponent;
import java.util.Arrays;
import java.util.List;
import java.util.Set;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

class DepartmentEmployeePickerSecurityContractTest {

    @Test
    void employeePickerTreeUsesEmployeeViewWithoutGrantingDepartmentView() throws Exception {
        DepartmentService service = mock(DepartmentService.class);
        DepartmentController controller = new DepartmentController(
                service,
                mock(WorkforceOverviewService.class),
                mock(com.uten.imp.audit.AuditDetailViewRecorder.class));
        List<DepartmentPickerNode> expected = List.of();
        when(service.employeePickerTree()).thenReturn(expected);

        assertThat(controller.employeePickerTree()).isSameAs(expected);
        verify(service).employeePickerTree();

        var method = DepartmentController.class.getDeclaredMethod("employeePickerTree");
        var employeeList = EmployeeController.class.getDeclaredMethod(
                "list",
                int.class,
                int.class,
                String.class,
                Set.class,
                UUID.class,
                boolean.class);
        assertThat(method.getAnnotation(GetMapping.class).value())
                .containsExactly("/employee-picker-tree");
        assertThat(method.getAnnotation(PreAuthorize.class).value())
                .isEqualTo("hasAuthority('employee:view')")
                .isEqualTo(employeeList.getAnnotation(PreAuthorize.class).value());
    }

    @Test
    void pickerTreeDtoCannotExposeEmployeeOrDepartmentManagementFields() {
        assertThat(Arrays.stream(DepartmentPickerNode.class.getRecordComponents())
                .map(RecordComponent::getName))
                .containsExactly("id", "code", "name", "level", "parentId", "children")
                .doesNotContain("managerId", "managerName", "headcount", "staff");
    }
}
