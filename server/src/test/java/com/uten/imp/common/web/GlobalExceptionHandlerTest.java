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

        ResponseEntity<ApiError> response = handler.handlePessimisticLock(failure);

        assertEquals(409, response.getStatusCode().value());
        assertNotNull(response.getBody());
        assertEquals("CONFLICT", response.getBody().getCode());
        assertEquals("并发操作占用，请刷新后重试", response.getBody().getMessage());
        assertFalse(response.getBody().getMessage().contains("secret SQL"));
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
