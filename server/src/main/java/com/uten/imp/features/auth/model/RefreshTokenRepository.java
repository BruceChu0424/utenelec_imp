package com.uten.imp.features.auth.model;

import jakarta.persistence.LockModeType;
import org.springframework.data.jpa.repository.JpaRepository;
import org.springframework.data.jpa.repository.Lock;
import org.springframework.data.jpa.repository.Modifying;
import org.springframework.data.jpa.repository.Query;
import org.springframework.data.repository.query.Param;

import java.util.Optional;
import java.util.UUID;

public interface RefreshTokenRepository extends JpaRepository<RefreshToken, UUID> {

    Optional<RefreshToken> findByTokenHash(String tokenHash);

    /** Scalar lookup only: never cache the token entity before its rotation lock is acquired. */
    interface Identity {
        UUID getUserId();
        UUID getSessionId();
    }

    @Query("SELECT t.userId AS userId, t.sessionId AS sessionId FROM RefreshToken t WHERE t.tokenHash=:tokenHash")
    Optional<Identity> findIdentityByTokenHash(@Param("tokenHash") String tokenHash);

    /** 悲观锁查询（SELECT ... FOR UPDATE），用于刷新轮换时杜绝 TOCTOU 重用竞态。 */
    @Lock(LockModeType.PESSIMISTIC_WRITE)
    Optional<RefreshToken> findAndLockByTokenHash(@Param("tokenHash") String tokenHash);

    /** 撤销某用户的全部刷新令牌（改密 / 全部登出 / 锁定时调用）。 */
    @Modifying
    @Query("UPDATE RefreshToken t SET t.revokedAt = CURRENT_TIMESTAMP WHERE t.userId = :userId AND t.revokedAt IS NULL")
    int revokeAllByUserId(@Param("userId") UUID userId);
}
