package com.uten.imp.audit;

import org.junit.jupiter.api.Test;
import org.springframework.transaction.annotation.Propagation;
import org.springframework.transaction.annotation.Transactional;

import java.lang.reflect.Method;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;

import static org.junit.jupiter.api.Assertions.assertEquals;

class AuditServiceTransactionContractTest {

    @Test
    void committedSuccessAuditMustJoinAndRollBackWithTheBusinessTransaction()
            throws Exception {
        Method method = AuditService.class.getMethod(
                "logCommitted",
                java.util.UUID.class,
                String.class,
                String.class,
                String.class,
                String.class,
                String.class);
        Transactional transactional = method.getAnnotation(Transactional.class);

        assertEquals(Propagation.MANDATORY, transactional.propagation(),
                "claim success audit must not open an independent transaction");
        Method sessionAware = AuditService.class.getMethod(
                "logCommitted",
                java.util.UUID.class,
                String.class,
                String.class,
                String.class,
                String.class,
                String.class,
                java.util.UUID.class);
        assertEquals(
                Propagation.MANDATORY,
                sessionAware.getAnnotation(Transactional.class).propagation());
    }

    @Test
    void failureAndAuthenticationAuditStillUsesIndependentTransaction()
            throws Exception {
        Method method = AuditService.class.getMethod(
                "logExplicit",
                java.util.UUID.class,
                String.class,
                String.class,
                String.class,
                String.class,
                String.class);
        Transactional transactional = method.getAnnotation(Transactional.class);

        assertEquals(Propagation.REQUIRES_NEW, transactional.propagation());
        Method sessionAware = AuditService.class.getMethod(
                "logExplicit",
                java.util.UUID.class,
                String.class,
                String.class,
                String.class,
                String.class,
                String.class,
                java.util.UUID.class);
        assertEquals(
                Propagation.REQUIRES_NEW,
                sessionAware.getAnnotation(Transactional.class).propagation());
    }

    @Test
    void authorizedDetailViewAuditFailsClosedInAnIndependentTransaction()
            throws Exception {
        Method method = AuditService.class.getMethod(
                "logSuccessfulDetailView",
                java.util.UUID.class,
                String.class,
                String.class,
                String.class,
                java.util.UUID.class,
                String.class,
                String.class,
                String.class);
        Transactional transactional = method.getAnnotation(Transactional.class);

        assertEquals(Propagation.REQUIRES_NEW, transactional.propagation(),
                "a successful detail response must not be returned without its audit row");
    }

    @Test
    void claimAndNoticeSuccessEventsUseTheRollbackCoupledWriter()
            throws Exception {
        for (String path : java.util.List.of(
                "src/main/java/com/uten/imp/features/common/taskclaim/TaskClaimService.java",
                "src/main/java/com/uten/imp/features/org/hrtask/HrTaskClaimService.java",
                "src/main/java/com/uten/imp/features/notice/NoticeService.java")) {
            String source = Files.readString(Path.of(path), StandardCharsets.UTF_8);
            org.junit.jupiter.api.Assertions.assertTrue(
                    source.contains("audit.logCommitted("), path);
        }
        String notice = Files.readString(Path.of(
                "src/main/java/com/uten/imp/features/notice/NoticeService.java"),
                StandardCharsets.UTF_8);
        org.junit.jupiter.api.Assertions.assertTrue(
                java.util.List.of(
                        "notice_publish", "notice_acknowledge", "notice_bless",
                        "notice_bless_withdraw", "view_notice", "notice_read_all",
                        "notice_popup_ack", "notice_celebration_batch_publish",
                        "notice_todo_complete", "notice_delete")
                        .stream().allMatch(notice::contains));
        org.junit.jupiter.api.Assertions.assertTrue(!notice.contains("audit.logExplicit("),
                "V424 notification success events must roll back with their writes");
    }

    @Test
    void employeeAndVisitorLoginLogoutSuccessUseTheRollbackCoupledWriter()
            throws Exception {
        String staffLogin = Files.readString(Path.of(
                "src/main/java/com/uten/imp/features/auth/LoginService.java"),
                StandardCharsets.UTF_8);
        String visitorAuth = Files.readString(Path.of(
                "src/main/java/com/uten/imp/features/visitor/VisitorAuthService.java"),
                StandardCharsets.UTF_8);

        org.junit.jupiter.api.Assertions.assertTrue(
                staffLogin.contains("audit.logCommitted(user.getId(), user.getLoginAccount(),"));
        org.junit.jupiter.api.Assertions.assertTrue(
                visitorAuth.contains("audit.logCommitted(account.getId(), maskPhone(phone), \"visitor_login\""));
        org.junit.jupiter.api.Assertions.assertTrue(
                visitorAuth.contains("audit.logCommitted(token.get().getVisitorAccountId(), null,"));
        org.junit.jupiter.api.Assertions.assertTrue(
                staffLogin.contains("audit.logExplicit")
                        && visitorAuth.contains("audit.logExplicit"),
                "login/logout failure evidence must remain REQUIRES_NEW");
    }

    @Test
    void transactionalAdministrationAndBusinessSuccessEventsUseCommittedWriter()
            throws Exception {
        java.util.Map<String, String> required = java.util.Map.of(
                "src/main/java/com/uten/imp/features/admin/UserAccountAdminService.java",
                "password_temporary_reset",
                "src/main/java/com/uten/imp/features/admin/systemsetting/SystemSettingsService.java",
                "update_system_setting",
                "src/main/java/com/uten/imp/features/webinquiry/WebsiteInquiryService.java",
                "webinquiry_convert",
                "src/main/java/com/uten/imp/features/sales/order/SalesOrderService.java",
                "sales_reservation_yield");
        for (var entry : required.entrySet()) {
            String source = Files.readString(Path.of(entry.getKey()), StandardCharsets.UTF_8);
            org.junit.jupiter.api.Assertions.assertTrue(source.contains("logCommitted("),
                    entry.getKey());
            org.junit.jupiter.api.Assertions.assertTrue(source.contains(entry.getValue()),
                    entry.getKey());
        }
        String password = Files.readString(Path.of(
                "src/main/java/com/uten/imp/features/auth/PasswordService.java"),
                StandardCharsets.UTF_8);
        org.junit.jupiter.api.Assertions.assertTrue(
                password.contains("audit.logCommitted(")
                        && password.contains("\"change_password\""));
        org.junit.jupiter.api.Assertions.assertTrue(
                password.contains("issueTokensAfterPasswordChange"));
        org.junit.jupiter.api.Assertions.assertTrue(
                password.contains("audit.logExplicit")
                        && password.contains("change_password_failed"));
    }

    @Test
    void attachmentBackendIsTargetEvidenceNeverAResultCode() throws Exception {
        String source = Files.readString(Path.of(
                "src/main/java/com/uten/imp/features/attachment/AttachmentService.java"),
                StandardCharsets.UTF_8);
        // 0907bda8 起：两处下载审计 target_id 传可解析的附件 UUID（审计页据此解析对象名），
        // 结果码固定 "success"；存储后端不得混入 target_id 或结果码任何位置。
        String compact = source.replaceAll("\\s+", "");
        org.junit.jupiter.api.Assertions.assertTrue(
                compact.contains(
                        "\"attachment_download_grant\",\"attachments\","
                                + "id.toString(),\"success\""),
                "download grant audit must keep the attachment UUID as target_id");
        org.junit.jupiter.api.Assertions.assertTrue(
                compact.contains(
                        "auditDownloadOrClose(input,user,\"attachment_download_raw\",metadata.getId())"),
                "raw download must pass its exact attachment UUID into the audited stream boundary");
        org.junit.jupiter.api.Assertions.assertTrue(
                compact.contains(
                        "auditDownloadOrClose(input,user,\"attachment_avatar_download\",image.getId())"),
                "avatar download must use the same fail-closed audited stream boundary");
        org.junit.jupiter.api.Assertions.assertFalse(
                compact.contains("storage.backend(),\"success\""),
                "storage backend must never be a result code");
        org.junit.jupiter.api.Assertions.assertFalse(
                compact.contains("；存储="),
                "target_id must stay a resolvable UUID, not a detail string");

        // Exercise the shared boundary rather than requiring inline audit calls.
        // A failed independent audit must not return a verified stream or leak its I/O slot.
        var audit = org.mockito.Mockito.mock(AuditService.class);
        var service = org.mockito.Mockito.mock(
                com.uten.imp.features.attachment.AttachmentService.class,
                org.mockito.Mockito.CALLS_REAL_METHODS);
        org.springframework.test.util.ReflectionTestUtils.setField(service, "audit", audit);
        java.util.UUID actor = java.util.UUID.randomUUID(), attachment = java.util.UUID.randomUUID();
        var user = new com.uten.imp.security.AuthUser(actor, actor, "reader",
                java.util.Set.of(), java.util.Set.of("attachment:download"), false, true, false);
        for (String action : java.util.List.of("attachment_download_raw", "attachment_avatar_download")) {
            org.mockito.Mockito.reset(audit);
            var successStream = org.mockito.Mockito.mock(java.io.InputStream.class);
            org.springframework.test.util.ReflectionTestUtils.invokeMethod(
                    service, "auditDownloadOrClose", successStream, user, action, attachment);
            org.mockito.Mockito.verify(audit).logExplicit(
                    actor, "reader", action, "attachments", attachment.toString(), "success");
            org.mockito.Mockito.verify(successStream, org.mockito.Mockito.never()).close();

            var auditFailure = new IllegalStateException("audit write unavailable");
            org.mockito.Mockito.doThrow(auditFailure).when(audit).logExplicit(
                    actor, "reader", action, "attachments", attachment.toString(), "success");
            var failureStream = org.mockito.Mockito.mock(java.io.InputStream.class);
            org.junit.jupiter.api.Assertions.assertSame(auditFailure,
                    org.junit.jupiter.api.Assertions.assertThrows(IllegalStateException.class,
                            () -> org.springframework.test.util.ReflectionTestUtils.invokeMethod(
                                    service, "auditDownloadOrClose", failureStream, user, action, attachment)));
            org.mockito.Mockito.verify(failureStream).close();

            var closeFailure = new java.io.IOException("close failed");
            var brokenStream = org.mockito.Mockito.mock(java.io.InputStream.class);
            org.mockito.Mockito.doThrow(closeFailure).when(brokenStream).close();
            org.junit.jupiter.api.Assertions.assertSame(auditFailure,
                    org.junit.jupiter.api.Assertions.assertThrows(IllegalStateException.class,
                            () -> org.springframework.test.util.ReflectionTestUtils.invokeMethod(
                                    service, "auditDownloadOrClose", brokenStream, user, action, attachment)));
            org.junit.jupiter.api.Assertions.assertArrayEquals(
                    new Throwable[]{closeFailure}, auditFailure.getSuppressed());
        }
    }
}
