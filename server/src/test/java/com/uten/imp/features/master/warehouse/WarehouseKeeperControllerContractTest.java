package com.uten.imp.features.master.warehouse;

import com.uten.imp.features.master.warehouse.dto.WarehouseKeeperSaveRequest;
import org.junit.jupiter.api.Test;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PutMapping;

import java.lang.reflect.Method;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;

/** ADR-115 仓库负责人端点的路由与权限: 看负责人随仓库查看权, 改负责人与选候选人要仓库编辑权。 */
class WarehouseKeeperControllerContractTest {

    @Test
    void keeperEndpointsUseWarehousePermissions() throws Exception {
        Method assignments = WarehouseController.class.getDeclaredMethod("keeperAssignments");
        Method candidates = WarehouseController.class.getDeclaredMethod("keeperCandidates", String.class);
        Method myScope = WarehouseController.class.getDeclaredMethod("myScope");
        Method keepers = WarehouseController.class.getDeclaredMethod("keepers", UUID.class);
        Method replace = WarehouseController.class.getDeclaredMethod(
                "replaceKeepers", UUID.class, WarehouseKeeperSaveRequest.class);

        assertThat(assignments.getAnnotation(GetMapping.class).value()).containsExactly("/keepers");
        assertThat(assignments.getAnnotation(PreAuthorize.class).value())
                .isEqualTo("hasAuthority('warehouse:view')");
        assertThat(candidates.getAnnotation(GetMapping.class).value()).containsExactly("/keeper-candidates");
        assertThat(candidates.getAnnotation(PreAuthorize.class).value())
                .isEqualTo("hasAuthority('warehouse:edit')");
        // 「我的仓库」只回本人负责的仓与范围 id, 不含他人信息: 登录即可读。
        assertThat(myScope.getAnnotation(GetMapping.class).value()).containsExactly("/my-scope");
        assertThat(myScope.getAnnotation(PreAuthorize.class).value()).isEqualTo("isAuthenticated()");
        assertThat(keepers.getAnnotation(GetMapping.class).value()).containsExactly("/{id}/keepers");
        assertThat(keepers.getAnnotation(PreAuthorize.class).value())
                .isEqualTo("hasAuthority('warehouse:view')");
        assertThat(replace.getAnnotation(PutMapping.class).value()).containsExactly("/{id}/keepers");
        assertThat(replace.getAnnotation(PreAuthorize.class).value())
                .isEqualTo("hasAuthority('warehouse:edit')");
    }
}
