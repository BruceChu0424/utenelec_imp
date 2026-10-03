package com.uten.imp.features.ai;

import com.uten.imp.features.ai.job.AiJobController;
import com.uten.imp.features.ai.job.AiJobService;
import com.uten.imp.security.AuthUser;
import com.uten.imp.features.ai.provider.AiProviderController;
import com.uten.imp.security.RequiresStepUp;
import com.uten.imp.security.StepUpExempt;
import org.junit.jupiter.api.Test;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.transaction.annotation.Transactional;
import org.springframework.web.bind.annotation.DeleteMapping;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.PutMapping;
import org.springframework.web.bind.annotation.RequestMapping;

import java.lang.reflect.Method;
import java.util.Arrays;
import java.util.List;
import java.util.Map;
import java.util.TreeMap;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;

/**
 * 接口安全契约(ADR-133): AI 服务设置只给超管 + authorization:manage, 改配置与「已保存密钥」探测要再认证,
 * 只有两个「本次新填密钥」探测豁免; 识别任务与状态只给员工账号(访客不行)。
 */
class AiControllerSecurityContractTest {

    private static final String SUPER_ADMIN = "hasAuthority('authorization:manage') and principal.superAdmin";
    private static final String STAFF = "isAuthenticated() and !principal.visitor";

    @Test
    void providerSettingsAreSuperAdminOnlyAndEveryWriteDeclaresStepUp() {
        assertThat(AiProviderController.class.getAnnotation(PreAuthorize.class).value()).isEqualTo(SUPER_ADMIN);
        assertThat(AiProviderController.class.getAnnotation(RequestMapping.class).value())
                .containsExactly("/api/admin/ai");

        Map<String, String> writes = new TreeMap<>();
        for (Method method : AiProviderController.class.getDeclaredMethods()) {
            String path = writePath(method);
            if (path == null) {
                continue;
            }
            if (method.isAnnotationPresent(RequiresStepUp.class)) {
                writes.put(path, "STEP_UP");
            } else if (method.isAnnotationPresent(StepUpExempt.class)) {
                assertThat(method.getAnnotation(StepUpExempt.class).value()).contains("不读取已保存密钥");
                writes.put(path, "EXEMPT");
            } else {
                writes.put(path, "NONE");
            }
        }
        assertThat(writes).containsExactlyInAnyOrderEntriesOf(Map.of(
                "POST /providers", "STEP_UP",
                "PUT /providers/{id}", "STEP_UP",
                "DELETE /providers/{id}", "STEP_UP",
                "POST /providers/{id}/default", "STEP_UP",
                "POST /providers/{id}/enabled", "STEP_UP",
                "POST /providers/{id}/test", "STEP_UP",
                "POST /providers/{id}/models", "STEP_UP",
                "POST /providers/test", "EXEMPT",
                "POST /providers/models", "EXEMPT"));
    }

    @Test
    void jobAndStatusEndpointsAreStaffOnly() throws Exception {
        assertThat(AiJobController.class.getAnnotation(PreAuthorize.class).value()).isEqualTo(STAFF);
        assertThat(AiStatusController.class.getAnnotation(PreAuthorize.class).value()).isEqualTo(STAFF);
        assertThat(AiJobController.class.getAnnotation(RequestMapping.class).value()).containsExactly("/api/ai/jobs");
        List<String> mappings = Arrays.stream(AiJobController.class.getDeclaredMethods())
                .map(AiControllerSecurityContractTest::anyPath)
                .filter(path -> path != null)
                .sorted()
                .toList();
        assertThat(mappings).containsExactly(
                "GET /{id}", "GET /{id}/history", "POST ", "POST /{id}/cancel");
        // A method-level override must not weaken the class's staff-only guard.
        for (Method method : AiJobController.class.getDeclaredMethods()) {
            if (anyPath(method) == null) continue;
            PreAuthorize override = method.getAnnotation(PreAuthorize.class);
            assertThat(override == null ? STAFF : override.value())
                    .as("effective authorization of %s", method.getName()).isEqualTo(STAFF);
        }
        assertThat(AiJobService.class.getDeclaredMethod("history", UUID.class, AuthUser.class)
                .getAnnotation(Transactional.class).readOnly()).isTrue();
    }

    @Test
    void statusDtoCarriesNoProviderDetails() {
        List<String> components = Arrays.stream(AiStatusController.AiStatus.class.getRecordComponents())
                .map(component -> component.getName()).toList();
        assertThat(components).containsExactly("available", "aiAllowedForMe", "supportsVision");
    }

    private static String writePath(Method method) {
        if (method.isAnnotationPresent(PostMapping.class)) {
            return "POST " + String.join("", method.getAnnotation(PostMapping.class).value());
        }
        if (method.isAnnotationPresent(PutMapping.class)) {
            return "PUT " + String.join("", method.getAnnotation(PutMapping.class).value());
        }
        if (method.isAnnotationPresent(DeleteMapping.class)) {
            return "DELETE " + String.join("", method.getAnnotation(DeleteMapping.class).value());
        }
        return null;
    }

    private static String anyPath(Method method) {
        String write = writePath(method);
        if (write != null) {
            return write;
        }
        if (method.isAnnotationPresent(GetMapping.class)) {
            return "GET " + String.join("", method.getAnnotation(GetMapping.class).value());
        }
        return null;
    }
}
