package com.uten.imp.features.subcontract.order;

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
 * 委外订货单主表（委外管理）。源 E_Order（2 行·本期保结构）。
 *
 * <p>链路核心节点：审核仅状态变更（无库存联动、无应收应付）+ 回写
 * {@code application_items.ordered_qty}（如挂申请明细）。成品进仓/退货继续回写
 * {@code received_qty/returned_qty}，is_closed 由成品维度派生。
 * {@code issued_qty/material_returned_qty} 是 legacy 展示字段，不再由新业务写入，
 * 因为不同子件数量不能聚合到成品订货行。
 *
 * <p>BOM 展开决策（design doc 22 §五）：本期不实现自动展开触发器；
 * {@code subcontract_order_cost_items} 表保结构 + 迁老库 67 行原样数据，<b>只读不展开</b>。
 * 后置 Service {@code expandOrderBom()} 待 BOM 引擎落地。
 */
@Getter
@Setter
@NoArgsConstructor
@Entity
@Table(name = "subcontract_orders")
public class SubcontractOrder extends SoftDeletableEntity {

    @Column(name = "legacy_id", unique = true)
    private Integer legacyId;            // E_Order.ID

    @Column(name = "bill_no", nullable = false)
    private String billNo;

    @Column(name = "bill_date", nullable = false)
    private LocalDate billDate;

    @Column(name = "supplier_id")
    private UUID supplierId;             // VendID（委外商）

    @Column(name = "warehouse_id")
    private UUID warehouseId;            // StockID

    @Column(name = "currency_id")
    private UUID currencyId;             // CurID

    @Column(name = "exchange_rate", precision = 18, scale = 6)
    private BigDecimal exchangeRate;     // CRate

    @Column(name = "settlement_method_id")
    private UUID settlementMethodId;

    @Column(name = "tax_rate", precision = 18, scale = 4)
    private BigDecimal taxRate;          // TRate

    @Column(name = "purchaser_id")
    private UUID purchaserId;            // 业务员（无 FK）

    @Column(name = "maker_id")
    private UUID makerId;

    @Column(name = "approver_id")
    private UUID approverId;

    @Column(name = "deliver_date")
    private LocalDate deliverDate;       // SendDate 交货日

    /** 结案标志（老库 CF_E_Order 触发器，本期由 Service 派生 is_closed；保留 fulfill 字段供前端展示）。 */
    @Column(name = "fulfill", nullable = false)
    private boolean fulfill = false;

    private String remark;

    @Column(name = "total_original", columnDefinition = "numeric")
    private BigDecimal totalOriginal;

    @Column(name = "total_local", columnDefinition = "numeric")
    private BigDecimal totalLocal;

    /** 0 草稿 / 1 已审 / -1 红冲。 */
    @Column(name = "status", nullable = false)
    private Short status = 0;

    @Column(name = "is_closed", nullable = false)
    private boolean closed = false;

    @Column(name = "source_doc_no")
    private String sourceDocNo;
}
