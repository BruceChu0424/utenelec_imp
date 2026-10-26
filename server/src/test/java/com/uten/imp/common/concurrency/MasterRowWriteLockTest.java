package com.uten.imp.common.concurrency;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import jakarta.persistence.EntityManager;
import jakarta.persistence.EntityNotFoundException;
import jakarta.persistence.LockModeType;
import java.util.concurrent.atomic.AtomicBoolean;
import org.junit.jupiter.api.Test;
import static org.junit.jupiter.api.Assertions.*;
import static org.mockito.Mockito.*;

class MasterRowWriteLockTest {
    @Test void eligibilityIsReadAfterTheLockRefreshRatherThanFromTheOriginalSnapshot() {
        var em = mock(EntityManager.class); var row = new Object(); var deleted = new AtomicBoolean(false);
        doAnswer(call -> { deleted.set(true); return null; }).when(em).refresh(row, LockModeType.PESSIMISTIC_WRITE);
        ApiException error = assertThrows(ApiException.class,
                () -> MasterRowWriteLock.refreshActive(em, row, deleted::get, "主档不存在"));
        assertEquals(ErrorCode.NOT_FOUND, error.getCode());
    }
    @Test void activeRowsKeepTheirExistingWriteProtocolAndPhysicalDeletionIsAlsoNotFound() {
        var em = mock(EntityManager.class); var row = new Object();
        assertDoesNotThrow(() -> MasterRowWriteLock.refreshActive(em, row, () -> false, "主档不存在"));
        doThrow(new EntityNotFoundException()).when(em).refresh(row, LockModeType.PESSIMISTIC_WRITE);
        ApiException error = assertThrows(ApiException.class,
                () -> MasterRowWriteLock.refreshActive(em, row, () -> false, "主档不存在"));
        assertEquals(ErrorCode.NOT_FOUND, error.getCode());
    }
}
