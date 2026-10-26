package com.uten.imp.common.concurrency;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import jakarta.persistence.EntityManager;
import jakarta.persistence.EntityNotFoundException;
import jakarta.persistence.LockModeType;
import java.util.function.BooleanSupplier;

/** Refresh a managed master row under its write lock before checking mutable eligibility. */
public final class MasterRowWriteLock {
    private MasterRowWriteLock() {}

    public static void refreshActive(EntityManager em, Object row, BooleanSupplier deleted, String missingMessage) {
        try {
            em.refresh(row, LockModeType.PESSIMISTIC_WRITE);
        } catch (EntityNotFoundException missing) {
            throw new ApiException(ErrorCode.NOT_FOUND, missingMessage);
        }
        if (deleted.getAsBoolean()) throw new ApiException(ErrorCode.NOT_FOUND, missingMessage);
    }
}
