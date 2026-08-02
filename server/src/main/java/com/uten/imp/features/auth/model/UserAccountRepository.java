package com.uten.imp.features.auth.model;

import jakarta.persistence.LockModeType;
import org.springframework.data.jpa.repository.JpaRepository;
import org.springframework.data.jpa.repository.JpaSpecificationExecutor;
import org.springframework.data.jpa.repository.Lock;
import org.springframework.data.jpa.repository.Modifying;
import org.springframework.data.jpa.repository.Query;
import org.springframework.data.repository.query.Param;

import java.util.Optional;
import java.util.UUID;

public interface UserAccountRepository extends JpaRepository<UserAccount, UUID>, JpaSpecificationExecutor<UserAccount> {

    Optional<UserAccount> findByLoginAccount(String loginAccount);

    Optional<UserAccount> findByEmployeeId(UUID employeeId);

    boolean existsByLoginAccount(String loginAccount);

    /** Serialize concurrent login-failure increments for the same account. */
    @Lock(LockModeType.PESSIMISTIC_WRITE)
    @Query("select u from UserAccount u where u.id = :id")
    Optional<UserAccount> findByIdForUpdate(@Param("id") UUID id);

    /** JwtAuthFilter 逐请求状态复查用的闭投影（只取状态列，不抓整实体）。 */
    interface AccountState {
        UUID getEmployeeId();
        String getLoginAccount();
        String getStatus();
        boolean isMustChangePassword();
        boolean isSuperAdmin();
        boolean isDeleted();
        long getAuthVersion();
        long getAuthorizationEpoch();
    }

    @Query(value = """
            SELECT u.employee_id AS "employeeId",
                   u.login_account AS "loginAccount",
                   u.status AS "status",
                   u.must_change_password AS "mustChangePassword",
                   u.is_super_admin AS "superAdmin",
                   u.is_deleted AS "deleted",
                   u.auth_version AS "authVersion",
                   s.epoch AS "authorizationEpoch"
            FROM users u
            CROSS JOIN authorization_state s
            WHERE u.id = :id
              AND s.singleton_id = 1
            """, nativeQuery = true)
    Optional<AccountState> findAccountStateById(@Param("id") UUID id);

    /**
     * Invalidates every previously issued staff access token after a credential change.
     * The mapped entity keeps authVersion read-only so ordinary saves cannot undo this bump.
     */
    @Modifying(flushAutomatically = true, clearAutomatically = true)
    @Query(value = """
            UPDATE users
            SET auth_version = auth_version + 1
            WHERE id = :id
            """, nativeQuery = true)
    int bumpAuthVersion(@Param("id") UUID id);
}
