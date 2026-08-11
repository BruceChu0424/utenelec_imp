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
 * <p>新发料当前可保存草稿，但审核 fail-closed：委外订货尚未冻结 BOM
 * 版本，也没有子件级发料权威台账。只有这两项模型完整落地后，审核才可
 * 在同一事务中执行库存出库。
 *
 * <p>历史已审核发料仍允许红冲及关联退料/损耗；成品订货行上的
 * {@code issued_qty/material_returned_qty} 仅作 legacy 展示，不是权威口径。
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

    /** 经办人 legacy id（E_SOut.WorkID → B_Worker.ID）。报表 LEFT JOIN employees 出名。 */
    @Column(name = "operator_legacy_id")
    private Integer operatorLegacyId;

    /** 经办人名（历史冻结兜底；新单据走 worker_id JOIN employees）。 */
    @Column(name = "operator_name")
    private String operatorName;

    /** 制单员 legacy id（E_SOut.MakeID → Sys_Operator.ID）。 */
    @Column(name = "maker_legacy_id")
    private Integer makerLegacyId;

    /** 制单员名（迁移期冻结 Sys_Operator.fname）。 */
    @Column(name = "maker_name")
    private String makerName;

    /** 审核员 legacy id（E_SOut.ApproverID → Sys_Operator.ID）。 */
    @Column(name = "approver_legacy_id")
    private Integer approverLegacyId;

    /** 审核员名（迁移期冻结 Sys_Operator.fname）。 */
    @Column(name = "approver_name")
    private String approverName;
}
