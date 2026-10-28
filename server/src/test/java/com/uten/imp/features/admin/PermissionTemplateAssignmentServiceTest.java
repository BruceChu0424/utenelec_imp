package com.uten.imp.features.admin;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.admin.dto.PermissionTemplateDtos.Unbind;
import com.uten.imp.features.auth.PermissionResolver;
import com.uten.imp.features.rbac.DepartmentPermissionRepository;
import com.uten.imp.features.rbac.PermissionRepository;
import com.uten.imp.security.TxSessionVars;
import jakarta.persistence.EntityManager;
import java.util.List;
import org.junit.jupiter.api.Test;

import static org.assertj.core.api.Assertions.assertThat;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.mockito.Mockito.*;

class PermissionTemplateAssignmentServiceTest {
    private final PermissionConfigurationTransferService transfer = mock(PermissionConfigurationTransferService.class);
    private final PermissionTemplateBindingService bindings = mock(PermissionTemplateBindingService.class);
    private final TxSessionVars tx = mock(TxSessionVars.class);
    private final PermissionTemplateAssignmentService service = new PermissionTemplateAssignmentService(
            mock(EntityManager.class), new ObjectMapper(), transfer, bindings, mock(PermissionRepository.class),
            mock(DepartmentPermissionRepository.class), mock(PermissionResolver.class),
            mock(PermissionOverrideAdminService.class), mock(DepartmentPermissionAdminService.class),
            mock(AdminUserSupport.class), mock(PermissionChangeAudit.class), tx);

    @Test void missingRequestUsesTheExistingTargetValidationContractBeforeReadingBindings() {
        ApiException failure = assertThrows(ApiException.class, () -> service.unbind(null));
        assertThat(failure.getCode()).isEqualTo(ErrorCode.VALIDATION_FAILED);
        assertThat(failure.getMessage()).isEqualTo("请选择 1 至 500 个不重复的员工或部门");
        verify(transfer).lockConfiguration();
        verify(transfer).requireActor();
        verify(tx).bind();
        verifyNoInteractions(bindings);
    }

    @Test void emptyTargetsKeepTheSameValidationAndNeverReadOrDetachBindings() {
        ApiException failure = assertThrows(ApiException.class,
                () -> service.unbind(new Unbind(List.of(), List.of(), List.of())));
        assertThat(failure.getCode()).isEqualTo(ErrorCode.VALIDATION_FAILED);
        assertThat(failure.getMessage()).isEqualTo("请选择 1 至 500 个不重复的员工或部门");
        verifyNoInteractions(bindings);
    }

    @Test void actorAuthorizationStillRunsBeforeRequestValidation() {
        ApiException forbidden = new ApiException(ErrorCode.FORBIDDEN);
        doThrow(forbidden).when(transfer).requireActor();
        assertThat(assertThrows(ApiException.class, () -> service.unbind(null))).isSameAs(forbidden);
        verifyNoInteractions(tx, bindings);
    }
}
