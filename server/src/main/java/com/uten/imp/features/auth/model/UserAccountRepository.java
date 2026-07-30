package com.uten.imp.features.auth.model;

import org.springframework.data.jpa.repository.JpaRepository;
import org.springframework.data.jpa.repository.JpaSpecificationExecutor;

import java.util.Optional;
import java.util.UUID;

public interface UserAccountRepository extends JpaRepository<UserAccount, UUID>, JpaSpecificationExecutor<UserAccount> {

    Optional<UserAccount> findByLoginAccount(String loginAccount);

    Optional<UserAccount> findByEmployeeId(UUID employeeId);

    boolean existsByLoginAccount(String loginAccount);

    /** JwtAuthFilter 逐请求状态复查用的闭投影（只取状态列，不抓整实体）。 */
    interface AccountState {
        String getStatus();
        boolean isMustChangePassword();
        boolean isSuperAdmin();
        boolean isDeleted();
    }

    Optional<AccountState> findAccountStateById(UUID id);
}
