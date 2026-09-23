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
    void subcontractPreparedOutboundLineageGuardHasAnActionableMessageForBothAdapters() {
        // V458/V634 DEFERRED 守卫在 COMMIT 时抛; 2026-09-21 之前财务批量批准只看到通用文案。
        var sql = new java.sql.SQLException(
                "ERROR: subcontract prepared-outbound lineage is inconsistent\n  Where: PL/pgSQL function secret", "23514");
        var handler = new GlobalExceptionHandler();
        var jdbc = handler.handleDataIntegrity(new DataIntegrityViolationException("could not execute statement", sql));
        var jpa = handler.handleHibernateConstraint(new org.hibernate.exception.ConstraintViolationException(
                "could not execute statement", sql, "subcontract_prepared_outbound_lineage_guard"));
        for (var response : java.util.List.of(jdbc, jpa)) {
            assertEquals(409, response.getStatusCode().value());
            assertEquals("CONFLICT", response.getBody().getCode());
            assertEquals("委外订货明细数量超过前置自制台账或通知批次可下单量(或订货行来源与前置自制批次对不上)，"
                    + "请核对委外前置自制台账与通知批次后重新提交", response.getBody().getMessage());
            assertFalse(response.getBody().getMessage().contains("PL/pgSQL"));
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
