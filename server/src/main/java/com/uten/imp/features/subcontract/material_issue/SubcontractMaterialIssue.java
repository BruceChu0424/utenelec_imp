package com.uten.imp.features.subcontract.material_issue;

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
 * 委外材料出仓单主表（委外管理）。源 E_SOut（发料）。
 *
 * <p>关键：<b>无币种、无 Price/Total/CurID</b>（材料按成本发出，不是销售）。
 * amount_local 由审核时 Service 按当年当月成本重算（替代老库 RefreshTotal_PROC，本期仅留字段）。
 *
 * <p>审核（status 0→1）触发（同事务）：
 * <ol>
 *   <li>库存出库 {@code TYPE_SUBCONTRACT_MATERIAL_ISSUE=15} {@code DIR_OUT=-1}</li>
 *   <li>回写订货明细 {@code issued_qty += qty}</li>
 *   <li>重算订货单 is_closed（发料维度，结案仅参考）</li>
 * </ol>
 * <b>不立应付</b>（材料发出不是加工费结算，加工费走进仓单 BOM 成本）。
 */
@Getter
@Setter
@NoArgsConstructor
@Entity
@Table(name = "subcontract_material_issues")
public class SubcontractMaterialIssue extends SoftDeletableEntity {

    @Column(name = "legacy_id", unique = true)
    private Integer legacyId;            // E_SOut.ID

    @Column(name = "bill_no", nullable = false)
    private String billNo;

    @Column(name = "bill_date", nullable = false)
    private LocalDate billDate;

    @Column(name = "supplier_id")
    private UUID supplierId;             // VendID（发给哪个委外商）

    @Column(name = "warehouse_id")
    private UUID warehouseId;            // StockID（发出仓，必填）

    @Column(name = "worker_id")
    private UUID workerId;               // WorkID 工人（无 FK）

    @Column(name = "maker_id")
    private UUID makerId;

    @Column(name = "approver_id")
    private UUID approverId;

    @Column(name = "deliver_date")
    private LocalDate deliverDate;       // SendDate

    private String remark;

    /** 无币种；original=local（本币成本）。 */
    @Column(name = "total_original", precision = 18, scale = 4)
    private BigDecimal totalOriginal;

    @Column(name = "total_local", precision = 18, scale = 4)
    private BigDecimal totalLocal;

    /** 0 草稿 / 1 已审 / -1 红冲。 */
    @Column(name = "status", nullable = false)
    private Short status = 0;

    @Column(name = "is_closed", nullable = false)
    private boolean closed = false;

    @Column(name = "source_doc_no")
    private String sourceDocNo;
}
