package com.uten.imp.audit;

import org.junit.jupiter.api.Test;
import java.util.Map;
import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertNull;

class CompanyFileAuditTest {
    @Test
    void successfulMetadataViewsHaveSpecificChineseLabelsWithoutDocumentFields() {
        var interpreter = new AuditEventInterpreter();
        var log = new AuditLog();
        log.setAction("view_company_file_detail");
        log.setTargetType("company_file_nodes");
        log.setTargetId(java.util.UUID.randomUUID().toString());
        log.setEventSource("business");
        log.setResult("success");
        log.setHttpPath("/api/company-files/" + log.getTargetId());
        log.setAfter("{\"view_metadata_kind\":\"business_detail_view\","
                + "\"target_display_name\":\"公司资料\"}");
        var classification = AuditClassifier.classify(
                "business", log.getAction(), log.getTargetType(), log.getHttpPath(), "success", 200);
        log.setEventCategory(classification.eventCategory());
        log.setRiskLevel(classification.riskLevel());

        var event = interpreter.interpret(log);
        assertEquals("查看公司资料详情", event.actionLabel());
        assertEquals("公司资料", event.objectLabel());
        assertEquals("工作台 · 公司资料库", event.pageLabel());
        assertEquals("business", event.category());
        assertEquals("low", event.riskLevel());
        assertEquals("公司资料", event.targetDisplayName());
        var detail = AuditLogDetail.of(log, interpreter);
        assertEquals("查看公司资料详情", detail.actionLabel());
        assertEquals("公司资料", detail.targetDisplayName());
        assertNull(detail.targetBusinessCode());
        assertNull(detail.targetLegacyCode());
        assertNull(detail.before());
        assertNull(detail.after());
    }

    @Test
    void companyLibraryActionsHaveBusinessNamesWithoutAccountLockWording() {
        var interpreter = new AuditEventInterpreter();
        for (var action : Map.of(
                "company_file_upload_complete", "完成公司文件上传",
                "company_file_recycle", "移入公司资料回收站",
                "company_file.restore", "还原公司资料",
                "company_file.lock", "重新锁定公司资料",
                "company_file_unlock", "解锁公司资料",
                "company_file_password_clear", "清除公司资料密码").entrySet()) {
            var log = new AuditLog();
            log.setAction(action.getKey());
            log.setTargetType("company_file_nodes");
            log.setEventSource("business");
            log.setResult("success");
            var classification = AuditClassifier.classify(
                    "business", action.getKey(), "company_file_nodes", null, "success", 200);
            log.setRiskLevel(classification.riskLevel());
            log.setEventCategory(classification.eventCategory());
            var event = interpreter.interpret(log);
            assertEquals(action.getValue(), event.actionLabel());
            assertEquals("公司资料", event.objectLabel());
        }
    }

    @Test
    void changingFolderVisibilityAndPasswordIsHighRiskAuthorization() {
        for (var action : new String[]{"company_file_permissions_set", "company_file_password_set",
                "company_file_password_clear", "company_file.set_permissions", "company_file.set_password"}) {
            var classification = AuditClassifier.classify(
                    "business", action, "company_file_nodes", null, "success", 200);
            assertEquals("authorization", classification.eventCategory());
            assertEquals("high", classification.riskLevel());
        }
        assertEquals("high", AuditClassifier.classify(
                "business", "company_file_recycle", "company_file_nodes", null, "success", 200).riskLevel());
    }
}
