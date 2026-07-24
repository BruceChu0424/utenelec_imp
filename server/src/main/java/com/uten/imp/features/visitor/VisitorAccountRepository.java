package com.uten.imp.features.visitor;

import org.springframework.data.jpa.repository.JpaRepository;

import java.util.Optional;
import java.util.UUID;

public interface VisitorAccountRepository extends JpaRepository<VisitorAccount, UUID> {
    Optional<VisitorAccount> findByPhoneHash(String phoneHash);

    boolean existsByVisitorNo(String visitorNo);

    /** JwtAuthFilter 逐请求状态复查用的闭投影（只取 status 列）。 */
    interface AccountState {
        String getStatus();
    }

    Optional<AccountState> findAccountStateById(UUID id);
}
