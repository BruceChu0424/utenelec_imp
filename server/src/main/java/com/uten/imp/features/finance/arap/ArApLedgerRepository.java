package com.uten.imp.features.finance.arap;

import jakarta.persistence.LockModeType;
import org.springframework.data.jpa.repository.JpaRepository;
import org.springframework.data.jpa.repository.JpaSpecificationExecutor;
import org.springframework.data.jpa.repository.Lock;
import org.springframework.data.jpa.repository.Query;
import org.springframework.data.repository.query.Param;

import java.util.Collection;
import java.util.List;
import java.util.Optional;
import java.util.UUID;

/**
 * 应收应付台账仓库。跨模块立帐入口（{@link ArApLedgerService#postArAp}）写入；
 * 收款/付款审核核销时由 {@code FinanceReceiptService}/{@code FinancePaymentService}
 * 加载实体（{@link #findById}）、改字段后 {@link #save} 回写（避免 @Modifying 后失同步）。
 *
 * <p>列表只读查询用 {@link JpaSpecificationExecutor}（direction/client/supplier/source/date 多条件）。
 */
public interface ArApLedgerRepository
        extends JpaRepository<ArApLedger, UUID>, JpaSpecificationExecutor<ArApLedger> {

    /** 跨模块红冲反查：按来源单据定位立帐行（一般为 1 行，保留 List 兜底批量/历史重复场景）。 */
    List<ArApLedger> findBySourceDocIdAndSourceDocTypeAndDeletedFalse(UUID sourceDocId, String sourceDocType);

    /**
     * Stable-order write lock for cross-document settlement. Different receipt
     * or payment documents can target the same ledger row, so locking only
     * their own document headers is insufficient.
     */
    @Lock(LockModeType.PESSIMISTIC_WRITE)
    @Query("""
            SELECT l
            FROM ArApLedger l
            WHERE l.id IN :ids AND l.deleted = false
            ORDER BY l.id
            """)
    List<ArApLedger> findAllByIdInForUpdate(@Param("ids") Collection<UUID> ids);

    @Lock(LockModeType.PESSIMISTIC_WRITE)
    @Query("""
            SELECT l
            FROM ArApLedger l
            WHERE l.sourceDocId = :sourceDocId
              AND l.sourceDocType = :sourceDocType
              AND l.deleted = false
            ORDER BY l.id
            """)
    List<ArApLedger> findBySourceForUpdate(
            @Param("sourceDocId") UUID sourceDocId,
            @Param("sourceDocType") String sourceDocType);

    /** 迁移/校验：按老库表名 + legacy_id 反查（解 M_in/M_out ID 冲突）。 */
    Optional<ArApLedger> findByLegacySourceAndLegacyId(String legacySource, Integer legacyId);

    /** 批量按 legacy_id 取未软删记录（迁移解析用）。 */
    List<ArApLedger> findByLegacySourceAndLegacyIdInAndDeletedFalse(
            String legacySource, Collection<Integer> legacyIds);
}
