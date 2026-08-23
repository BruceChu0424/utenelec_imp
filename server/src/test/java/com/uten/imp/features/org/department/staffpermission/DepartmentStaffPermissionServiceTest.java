package com.uten.imp.features.org.department.staffpermission;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.rbac.ManagerPermissionDelegationRepository;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.extension.ExtendWith;
import org.mockito.Mock;
import org.mockito.junit.jupiter.MockitoExtension;

import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.verify;

/**
 * 旧版个人覆盖兼容路由的行为契约：恒定 403，不触碰任何委派或中央覆盖存储。
 * 整部门矩阵面板与单人委派写入的行为由 {@code PagePermissionWorkspaceServiceTest}
 * 与 {@code PagePermissionOrganizationScopePostgresTest} 覆盖。
 */
@ExtendWith(MockitoExtension.class)
class DepartmentStaffPermissionServiceTest {

    @Mock private ManagerPermissionDelegationRepository delegationRepo;

    private final DepartmentStaffPermissionService service =
            new DepartmentStaffPermissionService();

    @Test
    void legacyOverrideEndpointCannotTouchCentralOverrides() {
        ApiException error = assertThrows(
                ApiException.class,
                () -> service.setStaffOverride(
                        UUID.randomUUID(), "sales_order:view", "grant"));

        assertEquals(ErrorCode.FORBIDDEN, error.getCode());
        assertThat(error.getMessage()).contains("中央个人覆盖");
        verify(delegationRepo, never()).saveAndFlush(any());
    }
}
