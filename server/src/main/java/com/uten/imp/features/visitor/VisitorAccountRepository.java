package com.uten.imp.features.visitor;

import org.springframework.data.jpa.repository.JpaRepository;

import java.util.Optional;
import java.util.UUID;

public interface VisitorAccountRepository extends JpaRepository<VisitorAccount, UUID> {
    Optional<VisitorAccount> findByPhoneHash(String phoneHash);

    boolean existsByPhoneHash(String phoneHash);

    boolean existsByVisitorNo(String visitorNo);
}
