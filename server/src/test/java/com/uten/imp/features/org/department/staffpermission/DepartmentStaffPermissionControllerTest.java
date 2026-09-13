package com.uten.imp.features.org.department.staffpermission;

import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.common.web.GlobalExceptionHandler;
import org.junit.jupiter.api.Test;
import org.springframework.test.web.servlet.MockMvc;
import org.springframework.test.web.servlet.setup.MockMvcBuilders;

import java.util.UUID;

import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.verifyNoInteractions;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.jsonPath;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.status;

class DepartmentStaffPermissionControllerTest {

    @Test
    void legacyUnboundedManagedMatrixIsExplicitlyRetired() throws Exception {
        DepartmentStaffPermissionService legacy =
                mock(DepartmentStaffPermissionService.class);
        PagePermissionWorkspaceService workspace =
                mock(PagePermissionWorkspaceService.class);
        DepartmentStaffPermissionController controller =
                new DepartmentStaffPermissionController(legacy, workspace);

        MockMvc mvc = MockMvcBuilders.standaloneSetup(controller)
                .setControllerAdvice(new GlobalExceptionHandler())
                .build();

        mvc.perform(get("/api/department-staff-permissions/managed")
                        .param("surfaceKey", "sales.order")
                        .param("departmentId", UUID.randomUUID().toString()))
                .andExpect(status().isConflict())
                .andExpect(jsonPath("$.code").value(ErrorCode.CONFLICT.name()));

        verifyNoInteractions(legacy, workspace);
    }
}
