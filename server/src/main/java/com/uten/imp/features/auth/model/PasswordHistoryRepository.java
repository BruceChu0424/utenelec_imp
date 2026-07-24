package com.uten.imp.features.auth.model;

import org.springframework.data.domain.Pageable;
import org.springframework.data.jpa.repository.JpaRepository;

import java.util.List;
import java.util.UUID;

public interface PasswordHistoryRepository extends JpaRepository<PasswordHistory, UUID> {

    /** 最近 N 条历史（按 changed_at 倒序），用于改密时防重用。 */
    default List<PasswordHistory> findRecent(UUID userId, int size) {
        return findByUserIdOrderByChangedAtDesc(userId, Pageable.ofSize(size));
    }

    List<PasswordHistory> findByUserIdOrderByChangedAtDesc(UUID userId, Pageable pageable);
}
