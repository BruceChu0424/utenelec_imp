package com.uten.imp.features.org.department.staffpermission;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import org.junit.jupiter.api.Test;

import java.util.UUID;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.verifyNoInteractions;

class DepartmentStaffPermissionControllerTest {

    @Test
    void legacyUnboundedManagedMatrixIsExplicitlyRetired() {
        DepartmentStaffPermissionService legacy =
                mock(DepartmentStaffPermissionService.class);
        PagePermissionWorkspaceService workspace =
                mock(PagePermissionWorkspaceService.class);
        DepartmentStaffPermissionController controller =
                new DepartmentStaffPermissionController(legacy, workspace);

        ApiException error = assertThrows(
                ApiException.class,
                () -> controller.managed("sales.order", UUID.randomUUID()));

        assertEquals(ErrorCode.CONFLICT, error.getCode());
        verifyNoInteractions(legacy, workspace);
    }
}
