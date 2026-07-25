package com.uten.imp.features.purchase.ret;

import org.springframework.data.jpa.repository.JpaRepository;
import org.springframework.data.jpa.repository.JpaSpecificationExecutor;

import java.util.Optional;
import java.util.UUID;

public interface PurchaseReturnRepository
        extends JpaRepository<PurchaseReturn, UUID>, JpaSpecificationExecutor<PurchaseReturn> {
    Optional<PurchaseReturn> findByLegacyId(Integer legacyId);
}
