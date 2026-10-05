package com.uten.imp.features.stock;

import org.springframework.data.jpa.repository.JpaRepository;
import org.springframework.data.jpa.repository.JpaSpecificationExecutor;

import java.util.UUID;

public interface StockDocumentRepository
        extends JpaRepository<StockDocument, UUID>, JpaSpecificationExecutor<StockDocument> {

    /** ADR-146 专门通道的幂等回放: 同一制单人同一重试键只有一张单。 */
    java.util.Optional<StockDocument> findByMakerIdAndChannelRequestKey(UUID makerId, String channelRequestKey);
}
