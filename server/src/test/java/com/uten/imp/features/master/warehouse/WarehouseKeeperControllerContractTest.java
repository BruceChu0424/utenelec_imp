package com.uten.imp.features.master.warehouse;

import com.uten.imp.audit.AuditDetailViewRecorder;
import com.uten.imp.audit.AuditService;
import com.uten.imp.common.export.WorkbookDownloadService;
import com.uten.imp.common.export.XlsxExportService;
import com.uten.imp.features.master.warehouse.dto.MyWarehouseScope;
import com.uten.imp.features.master.warehouse.dto.WarehouseKeeperSaveRequest;
import com.uten.imp.security.SecurityContextCurrentUser;
import org.junit.jupiter.api.Test;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PutMapping;
import org.springframework.web.bind.annotation.RequestParam;

import java.lang.reflect.Method;
import java.util.List;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.times;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.verifyNoMoreInteractions;
import static org.mockito.Mockito.when;

/** ADR-115 仓库负责人端点的路由与权限: 看负责人随仓库查看权, 改负责人与选候选人要仓库编辑权。 */
class WarehouseKeeperControllerContractTest {

    @Test
    void keeperEndpointsUseWarehousePermissions() throws Exception {
        Method assignments = WarehouseController.class.getDeclaredMethod("keeperAssignments");
        Method candidates = WarehouseController.class.getDeclaredMethod("keeperCandidates", String.class);
        Method candidatePage = WarehouseController.class.getDeclaredMethod("keeperCandidatesPage", String.class,
                int.class, int.class, UUID.class, boolean.class);
        Method myScope = WarehouseController.class.getDeclaredMethod("myScope", boolean.class);
        Method legacyMyScope = WarehouseController.class.getDeclaredMethod("myScope");
        Method keepers = WarehouseController.class.getDeclaredMethod("keepers", UUID.class);
        Method replace = WarehouseController.class.getDeclaredMethod(
                "replaceKeepers", UUID.class, WarehouseKeeperSaveRequest.class);

        assertThat(assignments.getAnnotation(GetMapping.class).value()).containsExactly("/keepers");
        assertThat(assignments.getAnnotation(PreAuthorize.class).value())
                .isEqualTo("hasAuthority('warehouse:view')");
        assertThat(candidates.getAnnotation(GetMapping.class).value()).containsExactly("/keeper-candidates");
        assertThat(candidates.getAnnotation(PreAuthorize.class).value())
                .isEqualTo("hasAuthority('warehouse:edit')");
        assertThat(candidatePage.getAnnotation(GetMapping.class).value()).containsExactly("/keeper-candidates/page");
        assertThat(candidatePage.getAnnotation(PreAuthorize.class).value()).isEqualTo("hasAuthority('warehouse:edit')");
        // 默认读取本人办理范围；forRead 显式选择只读范围，仍只需登录。
        assertThat(myScope.getAnnotation(GetMapping.class).value()).containsExactly("/my-scope");
        assertThat(myScope.getAnnotation(PreAuthorize.class).value()).isEqualTo("isAuthenticated()");
        assertThat(myScope.getParameters()[0].getAnnotation(RequestParam.class).defaultValue()).isEqualTo("false");
        assertThat(myScope.getParameters()[0].getName()).isEqualTo("forRead");
        assertThat(legacyMyScope.getAnnotation(GetMapping.class)).isNull();
        assertThat(keepers.getAnnotation(GetMapping.class).value()).containsExactly("/{id}/keepers");
        assertThat(keepers.getAnnotation(PreAuthorize.class).value())
                .isEqualTo("hasAuthority('warehouse:view')");
        assertThat(replace.getAnnotation(PutMapping.class).value()).containsExactly("/{id}/keepers");
        assertThat(replace.getAnnotation(PreAuthorize.class).value())
                .isEqualTo("hasAuthority('warehouse:edit')");
    }

    @Test
    void legacyDefaultKeepsCommandScopeAndReadModeMustBeExplicit() {
        var scopes = mock(WarehouseDataScopeService.class);
        var physical = new MyWarehouseScope("OTHER",false,List.of(),List.of(),null,false);
        var readOnly = new MyWarehouseScope("OTHER",true,List.of(),List.of(),null,false,List.of(),true);
        when(scopes.myScope(false)).thenReturn(physical);
        when(scopes.myScope(true)).thenReturn(readOnly);
        var controller = new WarehouseController(
                mock(WarehouseService.class),mock(WarehouseKeeperService.class),mock(AuditDetailViewRecorder.class),
                mock(XlsxExportService.class),mock(WorkbookDownloadService.class),mock(AuditService.class),
                mock(SecurityContextCurrentUser.class),scopes);

        assertThat(controller.myScope()).isSameAs(physical);
        assertThat(controller.myScope(false)).isSameAs(physical);
        assertThat(controller.myScope(true)).isSameAs(readOnly);
        verify(scopes,times(2)).myScope(false);
        verify(scopes).myScope(true);
        verifyNoMoreInteractions(scopes);
    }
}
