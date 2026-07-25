package com.uten.imp.features.stock;

import com.uten.imp.common.domain.SoftDeletableEntity;
import jakarta.persistence.Column;
import jakarta.persistence.Entity;
import jakarta.persistence.Table;
import lombok.Getter;
import lombok.NoArgsConstructor;
import lombok.Setter;

import java.math.BigDecimal;
import java.time.LocalDate;
import java.util.UUID;

/**
 * 仓库管理统一出入库单据头（库存管理）。doc_type 判别 9 类（源老库 O_*）：
 * TRANSFER 调拨 / OTHER_IN 其它入 / OTHER_OUT 其它出 / DRAW 领料 / WDRAW 退料 /
 * WASTE 损耗 / FINISHED_IN 产成品进仓 / FINISHED_OUT 产成品出仓 / CHECK 盘点。
 *
 * <p>审核（status 0→1）：按 doc_type 调 {@link StockService#recordMovement} 写流水 + upsert 余额
 * （调拨双仓双动、盘点按盘盈亏）。红冲（1→-1）反向冲销。去触发器化，全在 Service 事务。
 * legacy_id 不设 unique：各 O_ 表 IDENTITY 独立、ID 跨表会重复（唯一键是 doc_type+bill_no）。
 */
@Getter
@Setter
@NoArgsConstructor
@Entity
@Table(name = "stock_documents")
public class StockDocument extends SoftDeletableEntity {

    @Column(name = "legacy_id")
    private Integer legacyId;

    @Column(name = "doc_type", nullable = false)
    private String docType;

    @Column(name = "bill_no", nullable = false)
    private String billNo;

    @Column(name = "bill_date", nullable = false)
    private LocalDate billDate;

    @Column(name = "warehouse_id")
    private UUID warehouseId;

    /** 调拨调入仓（仅 TRANSFER）。 */
    @Column(name = "to_warehouse_id")
    private UUID toWarehouseId;

    @Column(name = "supplier_id")
    private UUID supplierId;

    @Column(name = "client_id")
    private UUID clientId;

    @Column(name = "worker_id")
    private UUID workerId;

    @Column(name = "maker_id")
    private UUID makerId;

    @Column(name = "approver_id")
    private UUID approverId;

    @Column(name = "plan_no")
    private String planNo;

    private String remark;

    @Column(name = "total_original", precision = 18, scale = 4)
    private BigDecimal totalOriginal;

    @Column(name = "total_local", precision = 18, scale = 4)
    private BigDecimal totalLocal;

    @Column(name = "status", nullable = false)
    private Short status = 0;

    @Column(name = "is_closed", nullable = false)
    private boolean closed = false;

    @Column(name = "source_doc_no")
    private String sourceDocNo;
}
