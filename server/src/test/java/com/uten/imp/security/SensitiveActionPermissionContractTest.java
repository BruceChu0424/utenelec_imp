package com.uten.imp.security;

import com.uten.imp.features.attachment.AttachmentController;
import com.uten.imp.features.org.employee.EmployeeCommandService;
import com.uten.imp.features.org.employee.EmployeeController;
import com.uten.imp.features.org.hrtask.HrTaskClaimService;
import com.uten.imp.features.org.hrtask.HrTaskController;
import com.uten.imp.features.rd_task.RdTaskController;
import com.uten.imp.features.visitor.SecurityVisitorController;
import com.uten.imp.features.webinquiry.WebsiteInquiryController;
import com.uten.imp.features.webinquiry.WebsiteInquiryService;
import com.uten.imp.features.webinquiry.dto.StatusUpdateRequest;
import org.aopalliance.intercept.MethodInvocation;
import org.junit.jupiter.api.Test;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.security.authentication.TestingAuthenticationToken;
import org.springframework.security.authorization.AuthorizationDecision;
import org.springframework.security.authorization.method.PreAuthorizeAuthorizationManager;

import java.lang.reflect.Method;
import java.lang.reflect.Modifier;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.Arrays;
import java.util.List;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.when;

class SensitiveActionPermissionContractTest {

    @Test
    void employeeLifecycleAndTaskTakeoverUseTheSameExactGateAtBothLayers() {
        assertBoth(EmployeeController.class, EmployeeCommandService.class,
                "transfer", "employee:transfer");
        assertBoth(EmployeeController.class, EmployeeCommandService.class,
                "offboard", "employee:offboard");
        assertBoth(EmployeeController.class, EmployeeCommandService.class,
                "confirm", "employee:confirm");
        assertBoth(EmployeeController.class, EmployeeCommandService.class,
                "rehire", "employee:rehire");
        assertBoth(EmployeeController.class, EmployeeCommandService.class,
                "renewContract", "employee:contract_renew");
        assertBoth(EmployeeController.class, EmployeeCommandService.class,
                "setAvatar", "employee:avatar_edit");
        assertBoth(HrTaskController.class, HrTaskClaimService.class,
                "takeover", "employee:task_takeover");
    }

    @Test
    void attachmentsUseIndependentControllerActions() {
        assertGate(AttachmentController.class, "presign", "attachment:upload");
        assertGate(AttachmentController.class, "confirm", "attachment:upload");
        assertGate(AttachmentController.class, "uploadRaw", "attachment:upload");
        assertGate(AttachmentController.class, "list", "attachment:view");
        assertGate(AttachmentController.class, "downloadGrant", "attachment:download");
        assertGate(AttachmentController.class, "downloadRaw", "attachment:download");
        assertGate(AttachmentController.class, "preview", "attachment:download");
        // 上传后标注分类：属于「整理自己传的文件」，不借用删除权限，也不额外新增权限码。
        assertGate(AttachmentController.class, "setCategory", "attachment:upload");
        assertGate(AttachmentController.class, "delete", "attachment:delete");
        assertGate(AttachmentController.class, "reconciliationFindings",
                "attachment:reconcile:view");
        assertGate(AttachmentController.class, "approveReconciliationDelete",
                "attachment:reconcile:approve_delete");
    }

    @Test
    void rdTaskCommandsDoNotInheritAnImplicitViewRequirement() {
        assertThat(RdTaskController.class.getAnnotation(PreAuthorize.class)).isNull();
        assertGate(RdTaskController.class, "list", "rd_task:view");
        assertGate(RdTaskController.class, "count", "rd_task:view");
        assertGate(RdTaskController.class, "create", "rd_task:create");
        assertGate(RdTaskController.class, "assign", "rd_task:assign");
        assertGate(RdTaskController.class, "resolve", "rd_task:resolve");
    }

    @Test
    void visitorVerificationAndCheckInAreIndependent() {
        assertGate(SecurityVisitorController.class, "verify", "visitor:verify");
        assertGate(SecurityVisitorController.class, "checkIn", "visitor:check-in");
    }

    @Test
    void websiteInquiryClosedAndAssignedToMeRequiresBothActions() throws Exception {
        Method controller = WebsiteInquiryController.class.getDeclaredMethod(
                "updateStatus", UUID.class, StatusUpdateRequest.class);
        Method service = WebsiteInquiryService.class.getDeclaredMethod(
                "updateStatus", UUID.class, StatusUpdateRequest.class);

        StatusUpdateRequest closeOnly = new StatusUpdateRequest("closed", null, false);
        StatusUpdateRequest closeAndClaim =
                new StatusUpdateRequest("closed", null, true);
        StatusUpdateRequest claim = new StatusUpdateRequest("following", null, true);

        for (Method method : List.of(controller, service)) {
            assertThat(authorize(method, closeOnly, "webinquiry:close").isGranted()).isTrue();
            assertThat(authorize(method, claim, "webinquiry:claim").isGranted()).isTrue();
            assertThat(authorize(
                    method, closeAndClaim, "webinquiry:close").isGranted()).isFalse();
            assertThat(authorize(
                    method, closeAndClaim, "webinquiry:claim").isGranted()).isFalse();
            assertThat(authorize(
                    method, closeAndClaim,
                    "webinquiry:close", "webinquiry:claim").isGranted()).isTrue();
        }

        assertGate(WebsiteInquiryController.class, "convert",
                "webinquiry:convert_client");
        assertGate(WebsiteInquiryService.class, "convert",
                "webinquiry:convert_client");
    }

    @Test
    void attachmentServicesEnforceTheSameGranularActionsBelowTheController() throws Exception {
        String service = Files.readString(Path.of(
                "src/main/java/com/uten/imp/features/attachment/AttachmentService.java"));
        assertThat(service)
                .contains("require(user, \"attachment:view\")")
                .contains("require(user, \"attachment:upload\")")
                .contains("require(user, \"attachment:delete\")")
                .contains("require(user, \"attachment:download\")")
                .contains("requireCanSelectAvatar(ownerId, user)")
                .doesNotContain("require(user, \"attachment:manage\")");

        String reconciliation = Files.readString(Path.of(
                "src/main/java/com/uten/imp/features/attachment/"
                        + "AttachmentReconciliationService.java"));
        assertThat(reconciliation)
                .contains("requireReconciler(\"attachment:reconcile:view\")")
                .contains("requireReconciler("
                        + "\"attachment:reconcile:approve_delete\")")
                .doesNotContain("contains(\"attachment:reconcile\")");
    }

    @Test
    void attachmentReconciliationPermissionsStayGlobalOnlyAndUnassignable() throws Exception {
        String migration = Files.readString(Path.of(
                "src/main/resources/db/migration/"
                        + "V328__permission_catalog_action_taxonomy.sql"));
        long unassignableDefinitions = java.util.regex.Pattern.compile(
                        "\\('attachment:reconcile:(?:view|approve_delete)'[^\\r\\n]+FALSE\\)")
                .matcher(migration)
                .results()
                .count();
        assertThat(unassignableDefinitions).isEqualTo(2);

        int surfaceStart = migration.indexOf("INSERT INTO permission_surfaces");
        assertThat(surfaceStart).isGreaterThanOrEqualTo(0);
        long surfaceLinks = java.util.regex.Pattern.compile(
                        "\\('[^']+',\\s*'attachment:reconcile:(?:view|approve_delete)'\\)")
                .matcher(migration.substring(surfaceStart))
                .results()
                .count();
        assertThat(surfaceLinks).isZero();
    }

    private static void assertBoth(
            Class<?> controller, Class<?> service, String method, String permission) {
        assertGate(controller, method, permission);
        assertGate(service, method, permission);
    }

    private static void assertGate(Class<?> type, String methodName, String permission) {
        List<Method> matches = Arrays.stream(type.getDeclaredMethods())
                .filter(method -> Modifier.isPublic(method.getModifiers()))
                .filter(method -> method.getName().equals(methodName))
                .toList();
        assertThat(matches).as(type.getSimpleName() + "." + methodName).hasSize(1);
        PreAuthorize gate = matches.getFirst().getAnnotation(PreAuthorize.class);
        assertThat(gate)
                .as(type.getSimpleName() + "." + methodName + " @PreAuthorize")
                .isNotNull();
        assertThat(gate.value()).isEqualTo("hasAuthority('" + permission + "')");
    }

    private static AuthorizationDecision authorize(
            Method method, StatusUpdateRequest request, String... authorities) {
        TestingAuthenticationToken authentication =
                new TestingAuthenticationToken("permission-user", null, authorities);
        authentication.setAuthenticated(true);
        MethodInvocation invocation = mock(MethodInvocation.class);
        when(invocation.getMethod()).thenReturn(method);
        when(invocation.getThis()).thenReturn(mock(method.getDeclaringClass()));
        when(invocation.getArguments())
                .thenReturn(new Object[]{UUID.randomUUID(), request});
        return new PreAuthorizeAuthorizationManager()
                .check(() -> authentication, invocation);
    }
}
