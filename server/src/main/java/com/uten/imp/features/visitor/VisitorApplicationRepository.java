package com.uten.imp.features.visitor;

import jakarta.persistence.LockModeType;
import org.springframework.data.jpa.repository.JpaRepository;
import org.springframework.data.jpa.repository.JpaSpecificationExecutor;
import org.springframework.data.jpa.repository.Lock;

import java.util.Optional;
import java.util.UUID;

public interface VisitorApplicationRepository
        extends JpaRepository<VisitorApplication, UUID>, JpaSpecificationExecutor<VisitorApplication> {
    Optional<VisitorApplication> findByQrToken(String qrToken);

    Optional<VisitorApplication> findByPasscode(String passcode);

    /** M2：悲观锁查询（SELECT ... FOR UPDATE），防 checkIn 并发重复签到。 */
    @Lock(LockModeType.PESSIMISTIC_WRITE)
    Optional<VisitorApplication> findAndLockById(UUID id);
}
