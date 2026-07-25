package com.uten.imp.features.purchase.request;

import org.springframework.data.jpa.repository.JpaRepository;
import org.springframework.data.jpa.repository.JpaSpecificationExecutor;

import java.util.Optional;
import java.util.UUID;

public interface PurchaseRequestRepository
        extends JpaRepository<PurchaseRequest, UUID>, JpaSpecificationExecutor<PurchaseRequest> {
    Optional<PurchaseRequest> findByLegacyId(Integer legacyId);
}
