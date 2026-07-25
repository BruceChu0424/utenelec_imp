package com.uten.imp.features.stock;

import org.springframework.data.jpa.repository.JpaRepository;
import org.springframework.data.jpa.repository.JpaSpecificationExecutor;

import java.util.UUID;

/**
 * 出入库流水仓库（只增不改）。支持 Specification 查询（库存流水查询页用）。
 */
public interface StockMovementRepository
        extends JpaRepository<StockMovement, UUID>, JpaSpecificationExecutor<StockMovement> {
}
