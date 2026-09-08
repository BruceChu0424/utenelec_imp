package com.uten.imp.features.visitor;

import org.springframework.data.jpa.repository.JpaRepository;
import org.springframework.data.jpa.repository.Lock;
import jakarta.persistence.LockModeType;

import java.util.Optional;
import java.util.UUID;

public interface VisitorAccountRepository extends JpaRepository<VisitorAccount, UUID> {
    Optional<VisitorAccount> findByPhoneHash(String phoneHash);

    @Lock(LockModeType.PESSIMISTIC_WRITE)
    Optional<VisitorAccount> findAndLockById(UUID id);

    /** JwtAuthFilter 逐请求状态复查用的闭投影（只取 status 列）。 */
    interface AccountState {
        String getStatus();
    }

    Optional<AccountState> findAccountStateById(UUID id);
}
