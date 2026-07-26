package com.uten.imp.features.subcontract.material_return;

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
 * 委外材料退货单主表（委外管理）。源 E_SWithDraw（材料退）。
 *
 * <p>无币种、无 Price（材料按成本退回）。审核（status 0→1）触发（同事务）：
 * <ol>
 *   <li>库存入库 {@code TYPE_SUBCONTRACT_MATERIAL_RETURN=16} {@code DIR_IN=+1}</li>
 *   <li>双回写：{@code material_issue_items.returned_qty += qty}
 *       + {@code order_items.material_returned_qty += qty}（子件维度双回写）</li>
 * </ol>
 * <b>不立应付</b>（材料退回不是加工费结算）。
 *
 * <p>{@code b_style} 老库字段（含义模糊，照搬；非 ArAp 业务类型，仅溯源）。
 */
@Getter
@Setter
@NoArgsConstructor
@Entity
@Table(name = "subcontract_material_returns")
public class SubcontractMaterialReturn extends SoftDeletableEntity {

    @Column(name = "legacy_id", unique = true)
    private Integer legacyId;            // E_SWithDraw.ID

    @Column(name = "bill_no", nullable = false)
    private String billNo;

    @Column(name = "bill_date", nullable = false)
    private LocalDate billDate;

    @Column(name = "supplier_id")
    private UUID supplierId;

    @Column(name = "warehouse_id")
    private UUID warehouseId;            // 必填（入库仓）

    @Column(name = "worker_id")
    private UUID workerId;               // WorkID（无 FK）

    @Column(name = "maker_id")
    private UUID makerId;

    @Column(name = "approver_id")
    private UUID approverId;

    /** BStyle 老库字段（含义模糊，照搬；非 ArAp 业务类型）。 */
    @Column(name = "b_style")
    private Integer bStyle;

    private String remark;

    /** 无币种；original=local。 */
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
