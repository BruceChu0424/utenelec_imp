package com.uten.imp.features.sales.order;

import org.springframework.data.jpa.repository.JpaRepository;
import org.springframework.data.jpa.repository.JpaSpecificationExecutor;
import org.springframework.data.jpa.repository.Lock;
import org.springframework.data.jpa.repository.Query;
import org.springframework.data.repository.query.Param;

import jakarta.persistence.LockModeType;

import org.springframework.data.domain.Pageable;

import java.util.List;
import java.util.Optional;
import java.util.UUID;

/** 销售订货单主表仓库。 */
public interface SalesOrderRepository
        extends JpaRepository<SalesOrder, UUID>, JpaSpecificationExecutor<SalesOrder> {

    Optional<SalesOrder> findByLegacyId(Integer legacyId);

    /**
     * 客户最近一次销售订货条款（新建单「学习预填」：选客户后带出上次的结账方式/发运策略/币种）。
     * 条款都在单头，取该客户最新一张未删订单即可（不限审核状态——红冲/取消单也如实记录
     * 业务员上次的选择）。调用方传 PageRequest.of(0, 1) 只取一行。
     */
    @Query("""
            SELECT o.settlementMethodId, o.shipmentPolicy, o.currencyId
            FROM SalesOrder o
            WHERE o.clientId = :clientId AND o.deleted = false
            ORDER BY o.createdAt DESC, o.id DESC
            """)
    List<Object[]> findLastTermsByClientId(@Param("clientId") UUID clientId, Pageable pageable);

    /**
     * 财务确认/驳回共享同一订单头写锁，保证两个决策只能按提交顺序观察最新状态。
     */
    @Lock(LockModeType.PESSIMISTIC_WRITE)
    @Query("SELECT o FROM SalesOrder o WHERE o.id = :id AND o.deleted = false")
    Optional<SalesOrder> findActiveByIdForUpdate(@Param("id") UUID id);
}
