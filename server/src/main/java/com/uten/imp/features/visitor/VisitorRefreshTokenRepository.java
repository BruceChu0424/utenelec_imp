package com.uten.imp.features.visitor;

import jakarta.persistence.LockModeType;
import org.springframework.data.jpa.repository.JpaRepository;
import org.springframework.data.jpa.repository.Lock;
import org.springframework.data.jpa.repository.Query;
import org.springframework.data.repository.query.Param;

import java.util.Optional;
import java.util.UUID;

public interface VisitorRefreshTokenRepository extends JpaRepository<VisitorRefreshToken, UUID> {
    /** 悲观锁查 token（杜绝并发 TOCTOU，支持重用检测）。 */
    @Lock(LockModeType.PESSIMISTIC_WRITE)
    @Query("select t from VisitorRefreshToken t where t.tokenHash = :hash")
    Optional<VisitorRefreshToken> findAndLockByTokenHash(@Param("hash") String hash);

    long countByVisitorAccountIdAndRevokedAtIsNull(UUID visitorAccountId);
}
