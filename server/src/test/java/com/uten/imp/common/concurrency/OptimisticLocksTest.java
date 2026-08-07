package com.uten.imp.common.concurrency;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import org.junit.jupiter.api.Test;

import static org.junit.jupiter.api.Assertions.assertDoesNotThrow;
import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertThrows;

/** {@link OptimisticLocks} 显式版本校验单元测试（主档丢失更新防护，V231）。 */
class OptimisticLocksTest {

    @Test
    void matchingVersionPasses() {
        assertDoesNotThrow(() -> OptimisticLocks.requireUpToDate(5L, 5L));
    }

    @Test
    void zeroVersionPassesForFreshRecord() {
        assertDoesNotThrow(() -> OptimisticLocks.requireUpToDate(0L, 0L));
    }

    @Test
    void staleVersionConflicts() {
        ApiException ex = assertThrows(ApiException.class,
                () -> OptimisticLocks.requireUpToDate(6L, 5L));
        assertEquals(ErrorCode.CONFLICT, ex.getCode());
    }

    @Test
    void nullExpectedIsAllowedForLegacyClients() {
        // 旧客户端不回传 version → 放行，不破坏前向兼容
        assertDoesNotThrow(() -> OptimisticLocks.requireUpToDate(6L, null));
    }
}
