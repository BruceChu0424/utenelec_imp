package com.uten.imp.features.sales.order;

import org.springframework.data.jpa.repository.JpaRepository;
import org.springframework.data.jpa.repository.JpaSpecificationExecutor;
import org.springframework.data.jpa.repository.Lock;
import org.springframework.data.jpa.repository.Query;
import org.springframework.data.repository.query.Param;

import jakarta.persistence.LockModeType;

import java.util.Optional;
import java.util.UUID;

/** 销售订货单主表仓库。 */
public interface SalesOrderRepository
        extends JpaRepository<SalesOrder, UUID>, JpaSpecificationExecutor<SalesOrder> {

    Optional<SalesOrder> findByLegacyId(Integer legacyId);

    /**
     * 财务确认/驳回共享同一订单头写锁，保证两个决策只能按提交顺序观察最新状态。
     */
    @Lock(LockModeType.PESSIMISTIC_WRITE)
    @Query("SELECT o FROM SalesOrder o WHERE o.id = :id AND o.deleted = false")
    Optional<SalesOrder> findActiveByIdForUpdate(@Param("id") UUID id);
}
