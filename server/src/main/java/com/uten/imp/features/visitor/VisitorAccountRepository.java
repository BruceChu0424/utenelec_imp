package com.uten.imp.features.visitor;

import org.springframework.data.domain.Page;
import org.springframework.data.domain.Pageable;
import org.springframework.data.jpa.repository.JpaRepository;
import org.springframework.data.jpa.repository.Lock;
import org.springframework.data.jpa.repository.Query;
import jakarta.persistence.LockModeType;

import java.util.Optional;
import java.util.UUID;

public interface VisitorAccountRepository extends JpaRepository<VisitorAccount, UUID> {
    Optional<VisitorAccount> findByPhoneHash(String phoneHash);

    @Lock(LockModeType.PESSIMISTIC_WRITE)
    Optional<VisitorAccount> findAndLockById(UUID id);

    /** 黑名单管理页：blocked 账号分页，拉黑时间新者优先（历史无 blocked_at 的排最后）。 */
    @Query("""
            select v from VisitorAccount v
            where v.status = 'blocked'
            order by v.blockedAt desc nulls last, v.updatedAt desc
            """)
    Page<VisitorAccount> findBlacklisted(Pageable pageable);
}
