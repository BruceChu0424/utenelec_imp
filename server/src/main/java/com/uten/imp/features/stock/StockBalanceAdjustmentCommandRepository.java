package com.uten.imp.features.stock;

import org.springframework.data.jpa.repository.JpaRepository;

import java.util.Optional;
import java.util.UUID;

interface StockBalanceAdjustmentCommandRepository
        extends JpaRepository<StockBalanceAdjustmentCommand, UUID> {

    Optional<StockBalanceAdjustmentCommand> findByRequestKey(String requestKey);

    boolean existsByStockDocumentId(UUID stockDocumentId);
}
