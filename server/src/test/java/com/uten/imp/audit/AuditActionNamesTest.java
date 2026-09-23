package com.uten.imp.audit;

import org.junit.jupiter.api.Test;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertNull;

class AuditActionNamesTest {

    static class SalesOrderController {
    }

    static class HRTaskController {
    }

    static class GlController {
    }

    @Test
    void derivesResourceDotMethodFromTheHandlingControllerMethod() {
        assertEquals("sales_order.approve",
                AuditActionNames.semanticAction(SalesOrderController.class, "approve"));
        assertEquals("sales_order.approve_batch",
                AuditActionNames.semanticAction(SalesOrderController.class, "approveBatch"));
        assertEquals("hr_task.claim", AuditActionNames.semanticAction(HRTaskController.class, "claim"));
        assertEquals("gl.generate_all", AuditActionNames.semanticAction(GlController.class, "generateAll"));
    }

    @Test
    void splitsOnlySemanticCodes() {
        assertEquals("stock_doc", AuditActionNames.resourceOf("stock_doc.reverse"));
        assertEquals("reverse", AuditActionNames.verbOf("stock_doc.reverse"));
        assertNull(AuditActionNames.resourceOf("login_failed"));
        assertNull(AuditActionNames.verbOf("http_post"));
    }

    @Test
    void keyActionsHaveCentralChineseNamesOthersFallBack() {
        assertEquals("审核通过", AuditActionNames.verbLabel("approve"));
        assertEquals("驳回", AuditActionNames.verbLabel("reject"));
        assertEquals("红冲", AuditActionNames.verbLabel("reverse"));
        assertEquals("财务反审核", AuditActionNames.verbLabel("finance_audit_reverse"));
        assertEquals("作废", AuditActionNames.verbLabel("cancel"));
        assertEquals("过账", AuditActionNames.verbLabel("post_run"));
        assertEquals("删除", AuditActionNames.verbLabel("delete"));
        assertNull(AuditActionNames.verbLabel("save_routes"));
    }
}
