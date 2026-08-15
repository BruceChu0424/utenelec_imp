package com.uten.imp.features.stock;

import org.springframework.data.jpa.repository.JpaRepository;
import org.springframework.data.jpa.repository.JpaSpecificationExecutor;

import java.util.UUID;

public interface StockDocumentRepository
        extends JpaRepository<StockDocument, UUID>, JpaSpecificationExecutor<StockDocument> {
}
