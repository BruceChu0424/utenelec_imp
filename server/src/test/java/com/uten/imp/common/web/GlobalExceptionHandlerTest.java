package com.uten.imp.common.web;

import org.junit.jupiter.api.Test;
import org.springframework.dao.DataIntegrityViolationException;
import org.springframework.http.ResponseEntity;
import org.springframework.mock.web.MockHttpServletRequest;
import org.springframework.web.context.request.async.AsyncRequestNotUsableException;

import static org.junit.jupiter.api.Assertions.assertDoesNotThrow;
import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertNotNull;

class GlobalExceptionHandlerTest {
    @Test
    void finalReportShowsOnlyReviewedBusinessMessageAndNeverDriverDetails() {
        String message="该工单还有未审核报工单(SR20260924000001)，请先审核或删除这些草稿，再提前完结";
        var server = new org.postgresql.util.ServerErrorMessage(
                "SERROR\u0000C23514\u0000M"+message+"\u0000Dsecret SQL details\u0000Wprivate function stack\u0000nfinal_report_pending_drafts\u0000\u0000");
        var sql = new org.postgresql.util.PSQLException(server);
        var handler=new GlobalExceptionHandler();
        for(var response:java.util.List.of(
                handler.handleDataIntegrity(new DataIntegrityViolationException("failed",sql)),
                handler.handleHibernateConstraint(new org.hibernate.exception.ConstraintViolationException("failed",sql,"final_report_pending_drafts")),
                handler.handleOther(new org.springframework.transaction.TransactionSystemException("commit failed",
                        new jakarta.persistence.PersistenceException("wrapped",sql))))) {
            assertEquals(409,response.getStatusCode().value());
            assertEquals(message,response.getBody().getMessage());
            assertFalse(response.getBody().getMessage().contains("secret"));
            assertFalse(response.getBody().getMessage().contains("private"));
        }
        var unknown=new org.postgresql.util.PSQLException(new org.postgresql.util.ServerErrorMessage(
                "SERROR\u0000C23514\u0000Msecret business SQL\u0000nunknown_constraint\u0000\u0000"));
        assertFalse(handler.handleDataIntegrity(new DataIntegrityViolationException("failed",unknown)).getBody().getMessage().contains("secret"));
    }

    private static org.postgresql.util.PSQLException postgres(String state, String message, String extraFields) {
        return new org.postgresql.util.PSQLException(new org.postgresql.util.ServerErrorMessage(
                "SERROR\u0000C" + state + "\u0000M" + message + "\u0000" + extraFields + "\u0000"));
    }

    private static java.util.List<ResponseEntity<ApiError>> allAdapters(java.sql.SQLException sql) {
        var handler = new GlobalExceptionHandler();
        return java.util.List.of(
                handler.handleDataIntegrity(new DataIntegrityViolationException("failed", sql)),
                handler.handleHibernateConstraint(
                        new org.hibernate.exception.ConstraintViolationException("failed", sql, "any_name")),
                handler.handleOther(new org.springframework.transaction.TransactionSystemException("commit failed",
                        new jakarta.persistence.PersistenceException("wrapped", sql))));
    }

    /**
     * ADR-151: 我们自己的守卫函数 RAISE '中文' USING ERRCODE='23514'(无约束名), 文案原样给人看且回 422,
     * 不能再落成「数据已被其他操作更新」诱导用户反复刷新。只回主消息第一行, 不带 DETAIL/HINT/WHERE。
     */
    @Test
    void chineseBusinessGuardRaiseIsEchoedAs422WithoutDriverDetails() {
        String message = "批准盘点只能记入当前未盘点期间";
        var sql = postgres("23514", message + "\n第二行内部细节",
                "Dsecret detail\u0000Hsecret hint\u0000WPL/pgSQL function secret_fn() line 9 at RAISE\u0000Rexec_stmt_raise\u0000Fpl_exec.c\u0000");
        for (var response : allAdapters(sql)) {
            assertEquals(422, response.getStatusCode().value());
            assertEquals("VALIDATION_FAILED", response.getBody().getCode());
            assertEquals(message, response.getBody().getMessage());
            assertFalse(response.getBody().getMessage().contains("secret"));
            assertFalse(response.getBody().getMessage().contains("第二行"));
        }
        // 守卫函数带约束名(USING CONSTRAINT)但未登记: 仍是写给人看的中文守卫, 同样回显。
        var named = postgres("23514", "这种材料已有库存历史，应记录账面修正而不是上线期初",
                "nsome_unregistered_guard\u0000Rexec_stmt_raise\u0000");
        for (var response : allAdapters(named)) {
            assertEquals(422, response.getStatusCode().value());
            assertEquals("这种材料已有库存历史，应记录账面修正而不是上线期初", response.getBody().getMessage());
        }
        // JPA flush 走 JDBC 批量: 驱动抛 BatchUpdateException, 带守卫原文的 PSQLException 挂在
        // getNextException 上(2026-10-04 仓库资料改仓库用途实测), 同样回显守卫原因。
        var guard = postgres("23514", "仓库「塑胶仓库」还有库存, 不能改仓库用途", "Rexec_stmt_raise\u0000");
        var batch = new java.sql.BatchUpdateException("Batch entry 0 update public.warehouses ... was aborted",
                "23514", new int[0]);
        batch.setNextException(guard);
        for (var response : allAdapters(batch)) {
            assertEquals(422, response.getStatusCode().value());
            assertEquals("仓库「塑胶仓库」还有库存, 不能改仓库用途", response.getBody().getMessage());
        }
        // 超长文案截断到 300 字以内, 不把任意长度的库内文本整段回给客户端。
        var longGuard = postgres("23514", "超".repeat(400), "Rexec_stmt_raise\u0000");
        assertEquals(300, new GlobalExceptionHandler()
                .handleDataIntegrity(new DataIntegrityViolationException("x", longGuard)).getBody().getMessage().length());
    }

    /**
     * 行版本守卫(约束名 *_version_guard, V409/V740/V802)是别人刚改过: 409, 页面据此重读;
     * 中文原因原样给人看, 英文守卫给通用的「已被他人修改」, 都不带 DETAIL/HINT/WHERE。
     * 同类的规则守卫(同前缀、非版本)仍是 422。
     */
    @Test
    void versionGuardsAreConcurrencyConflictsWhileRuleGuardsStay422() {
        var chinese = postgres("23514", "这一期盘点已被别人改过, 请刷新后再试",
                "Dsecret detail\u0000nworkshop_material_count_version_guard\u0000Rexec_stmt_raise\u0000");
        for (var response : allAdapters(chinese)) {
            assertEquals(409, response.getStatusCode().value());
            assertEquals("CONFLICT", response.getBody().getCode());
            assertEquals("这一期盘点已被别人改过, 请刷新后再试", response.getBody().getMessage());
        }
        var english = postgres("23514", "production daily report row_version must advance by exactly one",
                "nproduction_daily_report_row_version_guard\u0000Rexec_stmt_raise\u0000");
        for (var response : allAdapters(english)) {
            assertEquals(409, response.getStatusCode().value());
            assertEquals("该记录已被他人修改，请刷新后重试", response.getBody().getMessage());
        }
        var rule = postgres("23514", "这个车间还没开通内料仓, 请先在「车间内料仓」开通",
                "nworkshop_material_settings_bin_guard\u0000Rexec_stmt_raise\u0000");
        for (var response : allAdapters(rule)) {
            assertEquals(422, response.getStatusCode().value());
            assertEquals("这个车间还没开通内料仓, 请先在「车间内料仓」开通", response.getBody().getMessage());
        }
    }

    /** 真正的 CHECK 约束违反(有约束名、未登记)是输入不合规: 中性文案 422, 约束名只进日志。 */
    @Test
    void unregisteredCheckConstraintIsANeutralRuleViolationNotAConcurrencyConflict() {
        var check = postgres("23514",
                "new row for relation \"stock_count_requests\" violates check constraint \"stock_count_requests_reason_check\"",
                "Dsecret Failing row contains (secret)\u0000tstock_count_requests\u0000nstock_count_requests_reason_check\u0000RExecConstraints\u0000");
        // 即使数据库按中文 lc_messages 输出, 也只认例程名, 不把约束原文当守卫文案回显。
        var localized = postgres("23514", "关系 \"secret_table\" 的新列违反了检查约束 \"secret_check\"",
                "nsecret_check\u0000RExecConstraints\u0000");
        // 英文守卫 RAISE(内部不变量)同样只给中性文案。
        var english = postgres("23514", "Posted run facts are immutable; secret", "Rexec_stmt_raise\u0000");
        var notNull = postgres("23502", "null value in column \"secret\" violates not-null constraint", "RExecConstraints\u0000");
        for (var sql : java.util.List.of(check, localized, english, notNull)) {
            for (var response : allAdapters(sql)) {
                assertEquals(422, response.getStatusCode().value());
                assertEquals("VALIDATION_FAILED", response.getBody().getCode());
                assertEquals(GlobalExceptionHandler.RULE_VIOLATION_MESSAGE, response.getBody().getMessage());
                assertFalse(response.getBody().getMessage().contains("其他操作"));
                assertFalse(response.getBody().getMessage().contains("secret"));
            }
        }
    }

    /** 22xxx(数值溢出/文字超长)是提交内容超范围: 422; 23505/23P01/23503 才是并发占用/引用变化: 409。 */
    @Test
    void dataRangeIs422AndUniqueOrReferenceViolationsStay409() {
        for (var response : allAdapters(postgres("22003", "numeric field overflow secret", "RAPICheckNumeric\u0000"))) {
            assertEquals(422, response.getStatusCode().value());
            assertEquals(GlobalExceptionHandler.DATA_RANGE_MESSAGE, response.getBody().getMessage());
        }
        for (String state : java.util.List.of("23505", "23P01")) {
            for (var response : allAdapters(postgres(state, "duplicate key value violates unique constraint \"secret\"",
                    "nsecret_key\u0000R_bt_check_unique\u0000"))) {
                assertEquals(409, response.getStatusCode().value());
                assertEquals("CONFLICT", response.getBody().getCode());
                assertEquals(GlobalExceptionHandler.DUPLICATE_MESSAGE, response.getBody().getMessage());
            }
        }
        for (var response : allAdapters(postgres("23503", "insert or update violates foreign key constraint \"secret\"",
                "nsecret_fk\u0000Rri_ReportViolation\u0000"))) {
            assertEquals(409, response.getStatusCode().value());
            assertEquals(GlobalExceptionHandler.REFERENCE_MESSAGE, response.getBody().getMessage());
        }
        // 我们自己的守卫函数用唯一冲突码 RAISE 中文原因(如 V738「需求编号已属于另一份物料分析」): 仍是 409,
        // 但原因原样给人看(只取第一行), 不再说成「已重复提交, 刷新查看结果」让人以为办成了。
        for (var response : allAdapters(postgres("23505", "需求编号 X1 已属于另一份物料分析\n内部细节 secret",
                "Dsecret detail\u0000Rexec_stmt_raise\u0000"))) {
            assertEquals(409, response.getStatusCode().value());
            assertEquals("需求编号 X1 已属于另一份物料分析", response.getBody().getMessage());
        }
        // 英文唯一冲突(真正的唯一索引)不回显库内文字。
        for (var response : allAdapters(postgres("23505", "duplicate secret", "Rexec_stmt_raise\u0000"))) {
            assertEquals(GlobalExceptionHandler.DUPLICATE_MESSAGE, response.getBody().getMessage());
        }
    }

    /**
     * 读请求(GET)没有用户提交的内容: 22xxx / 23502 只可能是服务端缺陷(拼错参数、漏列), 回 500 不让用户去改输入;
     * 写请求仍回 422。两种都记 error 日志带完整堆栈(日志断言省略, 只断言状态码)。
     */
    @Test
    void dataErrorsOnReadRequestsAreServerFaultsNotUserInput() {
        var request = new org.springframework.mock.web.MockHttpServletRequest("GET", "/api/reports/x");
        org.springframework.web.context.request.RequestContextHolder.setRequestAttributes(
                new org.springframework.web.context.request.ServletRequestAttributes(request));
        try {
            for (var sql : java.util.List.of(
                    postgres("22P02", "invalid input syntax for type uuid: \"\" secret", "Rstring_to_uuid\u0000"),
                    postgres("22012", "division by zero", "Rint4div\u0000"),
                    postgres("23502", "null value in column \"secret\"", "RExecConstraints\u0000"))) {
                for (var response : allAdapters(sql)) {
                    assertEquals(500, response.getStatusCode().value());
                    assertEquals("INTERNAL", response.getBody().getCode());
                    assertFalse(String.valueOf(response.getBody().getMessage()).contains("secret"));
                }
            }
            request.setMethod("POST");
            for (var response : allAdapters(postgres("22001", "value too long secret", "Rvarchar\u0000"))) {
                assertEquals(422, response.getStatusCode().value());
                assertEquals(GlobalExceptionHandler.DATA_RANGE_MESSAGE, response.getBody().getMessage());
            }
        } finally {
            org.springframework.web.context.request.RequestContextHolder.resetRequestAttributes();
        }
    }

    /** pgjdbc 的批量异常: 原因(cause)与 getNextException 都挂着带服务端细节的 PSQLException。 */
    @Test
    void driverBatchExceptionWithCauseStillEchoesTheGuard() {
        var guard = postgres("23514", "仓库「五金仓库」还是 3 个货品的所属仓库, 不能改成不核算", "Rexec_stmt_raise\u0000");
        var batch = new java.sql.BatchUpdateException("Batch entry 0 was aborted", "23514", 0, new long[0], guard);
        batch.setNextException(guard);
        for (var response : allAdapters(batch)) {
            assertEquals(422, response.getStatusCode().value());
            assertEquals("仓库「五金仓库」还是 3 个货品的所属仓库, 不能改成不核算", response.getBody().getMessage());
        }
    }

    @Test
    void workshopDirectTargetGuardShowsItsPlainReasonAndNeverDriverDetails() {
        // V736/ADR-127：数据库直送断言的原因文案是统一维护的大白话，并发穿透到守卫时原样给用户。
        String message="无法转到下一道工序：上层 HV5ZJ012 是委外件：本工单做的物料先送入仓库，由委外人员领料发给委外商";
        var sql=new org.postgresql.util.PSQLException(new org.postgresql.util.ServerErrorMessage(
                "SERROR\u0000C23514\u0000M"+message+"\u0000Dsecret SQL details\u0000HSUBCONTRACT_ROUTE\u0000nworkshop_direct_target_guard\u0000\u0000"));
        var handler=new GlobalExceptionHandler();
        for(var response:java.util.List.of(
                handler.handleDataIntegrity(new DataIntegrityViolationException("failed",sql)),
                handler.handleHibernateConstraint(new org.hibernate.exception.ConstraintViolationException("failed",sql,"workshop_direct_target_guard")),
                handler.handleOther(new jakarta.persistence.PersistenceException("wrapped",sql)))) {
            assertEquals(409,response.getStatusCode().value());
            assertEquals(message,response.getBody().getMessage());
            assertFalse(response.getBody().getMessage().contains("secret"));
            assertFalse(response.getBody().getMessage().contains("SUBCONTRACT_ROUTE"));
        }
        var forged=new org.postgresql.util.PSQLException(new org.postgresql.util.ServerErrorMessage(
                "SERROR\u0000C23514\u0000Msecret business SQL\u0000nworkshop_direct_target_guard\u0000\u0000"));
        assertEquals("无法转到下一道工序：上层工单当前不能接收，请刷新后重新选择",
                handler.handleDataIntegrity(new DataIntegrityViolationException("failed",forged)).getBody().getMessage());
    }

    @Test
    void subcontractStepDrawGuardsHavePlainLanguageMessagesForEveryAdapter() {
        // ADR-143(V798)：委外回厂/领料数据库闸并发穿透时，按约束名给大白话，不落成通用「数据已被其他操作更新」。
        var handler = new GlobalExceptionHandler();
        record Case(String constraint, String databaseMessage, String expected) { }
        var cases = java.util.List.of(
                new Case("subcontract_target_outbound_first_guard",
                        "subcontract receipt material basis nets more than IQC replacements and finance-approved supplier material",
                        "回厂数量超过委外商用已发直属物料能做成的套数，超出部分要先在到货异常里经财务批准(委外商自带料)；"
                                + "请刷新预计到货后按可回厂数量登记，或先在委外任务中心领料"),
                new Case("subcontract_target_outbound_first_guard",
                        "subcontract receipt has no frozen draw plan lines, so its returnable quantity is 0",
                        "该委外订货明细没有领料计划(直属物料)，可回厂数量为 0；请先维护委外件 BOM，并在委外任务中心领料后再登记回厂"),
                new Case("subcontract_target_outbound_first_guard",
                        "subcontract receipt consumes more of a material than the supplier holds",
                        "委外商手里的直属物料不够核销这次回厂(已被回厂核销的发料也不能再红冲或退料)；"
                                + "请刷新后核对委外领料、退料与回厂记录"),
                new Case("subcontract_target_outbound_consumption_guard",
                        "subcontract receipt material consumption 10.0000 differs from target 20.0000 beyond the reversal tolerance",
                        "委外回厂核销的直属物料数量与回厂数量对不上，本次操作已回滚；请刷新后重试"),
                new Case("subcontract_receipt_material_basis_guard",
                        "approved subcontract receipt line lacks its frozen material basis",
                        "委外回厂明细缺少物料核销依据，本次操作已回滚；请刷新后重试"),
                new Case("subcontract_material_issue_item_requested_qty_chk",
                        "new row for relation \"subcontract_material_issue_items\" violates check constraint \"subcontract_material_issue_item_requested_qty_chk\"",
                        "仓库出仓数量不能超过委外人员提交的领料数量，只能改少；请改小后再提交"),
                new Case("subcontract_draw_issue_requested_guard",
                        "submitted draw quantity and its plan line are immutable",
                        "委外领料单的物料行和提交数量只能由委外领料生成，仓库只能改少、填 0 不发或整张退回委外；请刷新拣货页后重试"),
                new Case("subcontract_draw_issue_identity_guard",
                        "subcontract draw is only accepted on an open plan line",
                        "该委外任务已结束领料或订货已结清，不能再领料发料；请刷新后核对"),
                new Case("subcontract_draw_issue_identity_guard",
                        "subcontract issue line must carry the exact frozen draw-plan material",
                        "委外领料行必须是该任务领料计划里的物料(物料与颜色不能改)；请刷新拣货页后重试"),
                new Case("subcontract_draw_plan_basis_guard",
                        "subcontract draw plan line must freeze one drawable direct BOM edge of the ordered goods",
                        "委外件的 BOM 刚有改动，领料计划与当前 BOM 的直属物料对不上；请刷新后重新审批"),
                new Case("subcontract_material_plan_items_check",
                        "new row for relation \"subcontract_material_plan_items\" violates check constraint \"subcontract_material_plan_items_check\"",
                        "委外直属物料累计发出不能超过领料计划量；请刷新后核对本次出仓数量"));
        for (var c : cases) {
            var postgres = new org.postgresql.util.PSQLException(new org.postgresql.util.ServerErrorMessage(
                    "SERROR\u0000C23514\u0000M" + c.databaseMessage() + "\u0000Dsecret SQL details\u0000Wprivate function stack\u0000n"
                            + c.constraint() + "\u0000\u0000"));
            var plain = new java.sql.SQLException("ERROR: " + c.databaseMessage() + "\n  Where: secret", "23514");
            for (var response : java.util.List.of(
                    handler.handleDataIntegrity(new DataIntegrityViolationException("x", postgres)),
                    handler.handleHibernateConstraint(new org.hibernate.exception.ConstraintViolationException("x", postgres, c.constraint())),
                    handler.handleOther(new org.springframework.transaction.TransactionSystemException("commit failed",
                            new jakarta.persistence.PersistenceException("wrapped", postgres))),
                    handler.handleDataIntegrity(new DataIntegrityViolationException("x", plain)))) {
                assertEquals(409, response.getStatusCode().value(), c.databaseMessage());
                assertEquals("CONFLICT", response.getBody().getCode());
                assertEquals(c.expected(), response.getBody().getMessage(), c.databaseMessage());
                assertFalse(response.getBody().getMessage().contains("secret"));
                assertFalse(response.getBody().getMessage().contains("private"));
            }
        }
        // 无约束名的出仓占用闸按固定英文句首识别；不相干的 23514 按 ADR-151 §4 是「规则不满足」:
        // 中性文案 422(不再说「被其他操作更新」)。
        var allocation = new java.sql.SQLException("ERROR: approved subcontract draw issue lacks exact reservation coverage", "23514");
        assertEquals("委外领料单的库存占用与出仓明细对不上(可能刚被撤回、退回或改少)，本次操作已回滚；请刷新拣货页后重试",
                handler.handleDataIntegrity(new DataIntegrityViolationException("x", allocation)).getBody().getMessage());
        var unrelated = new java.sql.SQLException("ERROR: something else entirely", "23514");
        var unrelatedResponse = handler.handleDataIntegrity(new DataIntegrityViolationException("x", unrelated));
        assertEquals(422, unrelatedResponse.getStatusCode().value());
        assertEquals(GlobalExceptionHandler.RULE_VIOLATION_MESSAGE, unrelatedResponse.getBody().getMessage());
    }

    @Test
    void downstreamMaterialIssueIsAConsistentActionableConflictForBothDatabaseAdapters() {
        var sql = new java.sql.SQLException("Custody has already been issued by its destination task; secret SQL", "23514");
        var handler = new GlobalExceptionHandler();
        var jdbc = handler.handleDataIntegrity(new DataIntegrityViolationException("receipt rejected", sql));
        var jpa = handler.handleHibernateConstraint(new org.hibernate.exception.ConstraintViolationException(
                "receipt rejected", sql, "return_custody_guard"));
        for (var response : java.util.List.of(jdbc, jpa)) {
            assertEquals(409, response.getStatusCode().value());
            assertEquals("CONFLICT", response.getBody().getCode());
            assertEquals("这批余料已被后续工单领用，请先处理对应后续领料，再撤回收仓", response.getBody().getMessage());
            assertFalse(response.getBody().getMessage().contains("secret SQL"));
        }
    }

    @Test
    void masterIntegrityGuardsHavePlainLanguageMessagesForBothAdapters() {
        // ADR-111 V683/V684：旁路写入或并发撞上数据库闸时，不能落成「数据已被其他操作更新」。
        var handler = new GlobalExceptionHandler();
        var cases = java.util.Map.of(
                "ERROR: goods is still a component of an active BOM and cannot be soft-deleted\n  Detail: secret",
                "这个货品还是其它货品组装清单(BOM)里的组件，不能删除；请先在用到它的货品的 BOM 里移除它",
                "ERROR: color is still used by an active goods row or active BOM row and cannot be soft-deleted",
                "这个颜色还有货品或组装清单(BOM)在用，不能删除；请先修改这些货品或 BOM",
                "ERROR: unit is still used by an active goods row and cannot be soft-deleted",
                "这个单位还有货品在用，不能删除；请先修改这些货品",
                "ERROR: goods category has been deleted\n  Detail: goods x category y",
                "所选分类刚被删除，请刷新后重新选择分类",
                "ERROR: active master requires an active category",
                "所选分类刚被删除，请刷新后重新选择分类",
                "ERROR: category parent has been deleted",
                "上级分类刚被删除，请刷新后重新选择上级分类");
        for (var entry : cases.entrySet()) {
            var sql = new java.sql.SQLException(entry.getKey(), "23514");
            var jdbc = handler.handleDataIntegrity(new DataIntegrityViolationException("x", sql));
            var jpa = handler.handleHibernateConstraint(new org.hibernate.exception.ConstraintViolationException(
                    "x", sql, "master_guard"));
            for (var response : java.util.List.of(jdbc, jpa)) {
                assertEquals(409, response.getStatusCode().value());
                assertEquals(entry.getValue(), response.getBody().getMessage());
                assertFalse(response.getBody().getMessage().contains("secret"));
            }
        }
    }

    @Test
    void laterActualStockOutHasADependencyMessageButUnrelatedSqlDoesNotBorrowIt() {
        var handler = new GlobalExceptionHandler();
        var expected = handler.handleDataIntegrity(new DataIntegrityViolationException("receipt rejected",
                new java.sql.SQLException("Original material receipt has later actual stock consumption; reverse that dependency first", "23514")));
        assertEquals(409, expected.getStatusCode().value());
        assertEquals("本次收仓之后已有依赖其成本的出库，请先处理对应后续出库，再撤回收仓", expected.getBody().getMessage());
        var unrelated = handler.handleDataIntegrity(new DataIntegrityViolationException("different conflict",
                new java.sql.SQLException("Custody has already been issued by its destination task", "23505")));
        assertFalse(unrelated.getBody().getMessage().contains("后续工单"));
    }

    @Test
    void lifetimeMasterCodeConflictHasAnActionableMessageWithoutDatabaseDetails() {
        GlobalExceptionHandler handler = new GlobalExceptionHandler();
        DataIntegrityViolationException failure = new DataIntegrityViolationException(
                "could not execute statement",
                new RuntimeException(
                        "master code is reserved for another identity: "
                                + "domain=GOODS code=V6000001 secret SQL"));

        ResponseEntity<ApiError> response = handler.handleDataIntegrity(failure);

        assertEquals(409, response.getStatusCode().value());
        assertNotNull(response.getBody());
        assertEquals("该编号已被当前或历史主档使用，不能重复分配；请更换编号",
                response.getBody().getMessage());
        assertFalse(response.getBody().getMessage().contains("secret SQL"));
    }

    @Test
    void dataIntegrityConflictDoesNotExposeDatabaseDetails() {
        GlobalExceptionHandler handler = new GlobalExceptionHandler();
        DataIntegrityViolationException failure = new DataIntegrityViolationException(
                "could not execute statement",
                new RuntimeException("secret SQL and constraint details"));

        ResponseEntity<ApiError> response = handler.handleDataIntegrity(failure);

        assertEquals(409, response.getStatusCode().value());
        assertNotNull(response.getBody());
        assertEquals("CONFLICT", response.getBody().getCode());
        assertFalse(response.getBody().getMessage().contains("secret SQL"));
    }

    @Test
    void pessimisticLockConflictIsRetryableAndDoesNotExposeDatabaseDetails() {
        GlobalExceptionHandler handler = new GlobalExceptionHandler();
        var failure = new org.springframework.dao.CannotAcquireLockException(
                "deadlock detected: secret SQL");

        ResponseEntity<ApiError> response = handler.handleDatabaseDeadline(failure);

        assertEquals(409, response.getStatusCode().value());
        assertNotNull(response.getBody());
        assertEquals("CONFLICT", response.getBody().getCode());
        assertEquals(GlobalExceptionHandler.LOCK_BUSY_MESSAGE, response.getBody().getMessage());
        assertEquals("1", response.getHeaders().getFirst("Retry-After"));
        assertFalse(response.getBody().getMessage().contains("secret SQL"));
    }

    /** ADR-107: 服务端截止时间三类 SQLState, 不论被哪层异常包着, 都回可重跑的 409 与中文提示。 */
    @Test
    void databaseDeadlineStatesBecomeRetryableConflictsWhateverWrapsThem() {
        GlobalExceptionHandler handler = new GlobalExceptionHandler();
        var cases = java.util.Map.of(
                "55P03", GlobalExceptionHandler.LOCK_BUSY_MESSAGE,
                "57014", GlobalExceptionHandler.TIMED_OUT_MESSAGE,
                "40P01", GlobalExceptionHandler.DEADLOCK_MESSAGE);
        cases.forEach((state, message) -> {
            var sql = new java.sql.SQLException("canceling statement: secret SQL", state);
            var hibernate = new org.hibernate.exception.GenericJDBCException("could not execute", sql);
            var jpa = new jakarta.persistence.PersistenceException("wrapped", hibernate);
            ResponseEntity<ApiError> response = handler.handleOther(jpa);
            assertEquals(409, response.getStatusCode().value(), state);
            assertEquals(message, response.getBody().getMessage(), state);
            assertEquals("1", response.getHeaders().getFirst("Retry-After"), state);
            assertFalse(response.getBody().getMessage().contains("secret"));
        });
        var timedOut = handler.handleDatabaseDeadline(
                new org.springframework.transaction.TransactionTimedOutException("deadline was ..."));
        assertEquals(GlobalExceptionHandler.TIMED_OUT_MESSAGE, timedOut.getBody().getMessage());
        var other = handler.handleOther(new IllegalStateException("boom"));
        assertEquals(500, other.getStatusCode().value(), "非截止时间类异常仍是 500");
    }

    @Test
    void retryableBusinessConflictCarriesRetryAfterButOrdinaryConflictDoesNot() {
        GlobalExceptionHandler handler = new GlobalExceptionHandler();
        var retryable = handler.handleApi(new com.uten.imp.application.concurrency.FulfillmentSourceConflictException(
                "warehouse busy", true, "有人正在处理同一仓库的单据，请稍后再试"));
        assertEquals(409, retryable.getStatusCode().value());
        assertEquals("1", retryable.getHeaders().getFirst("Retry-After"));
        assertEquals("有人正在处理同一仓库的单据，请稍后再试", retryable.getBody().getMessage());
        var ordinary = handler.handleApi(new ApiException(ErrorCode.CONFLICT, "单据已变化"));
        assertEquals(null, ordinary.getHeaders().getFirst("Retry-After"));
    }

    @Test
    void clientAbortedResponseIsNotTreatedAsServerError() {
        GlobalExceptionHandler handler = new GlobalExceptionHandler();
        MockHttpServletRequest request = new MockHttpServletRequest(
                "GET", "/api/procurement/inspection/pending-receipts");

        // 客户端断开分支只记 DEBUG、不生成错误响应（连接已死，写回无意义）；
        // 不抛异常即满足契约——不得落入 handleOther 的 ERROR 未处理异常。
        assertDoesNotThrow(() -> handler.handleClientAbortedResponse(
                new AsyncRequestNotUsableException(
                        "ServletOutputStream failed to flush"),
                request));
    }
}
