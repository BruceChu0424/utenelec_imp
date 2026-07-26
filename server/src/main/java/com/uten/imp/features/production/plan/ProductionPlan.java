package com.uten.imp.features.production.plan;

import com.uten.imp.common.domain.SoftDeletableEntity;
import jakarta.persistence.Column;
import jakarta.persistence.Entity;
import jakarta.persistence.Table;
import lombok.Getter;
import lombok.NoArgsConstructor;
import lombok.Setter;

import java.time.LocalDate;
import java.util.UUID;

/**
 * 生产计划单头（生产管理 · 源 F_Plan，7,235 行）。
 *
 * <p>审核状态机（design §4.1）：status 0 草稿 / 1 已审 / -1 红冲。审核（0→1）：
 * <ul>
 *   <li>重算 {@link #isClosed}（CheckFulfill4 派生，所有明细 qty - iqty ≤ 0）</li>
 *   <li>【本期后置】回写 sales_order_items 的 PQTY/LQTY/PlanNo（销售模块上线后）</li>
 *   <li>【本期后置】设 plan_items.step_legacy_id 首工序（车间模块上线后）</li>
 *   <li>【本期后置】填充 F_ProductingItem 按日产能（排产模块上线后）</li>
 * </ul>
 *
 * <p><b>不调</b> {@code StockService}（计划不动库存）<b>不调</b> {@code ArApLedgerService}（计划不立帐）。
 *
 * <p>车间字段：老库 WorkShop varchar(250) 装数字/名字（样本 "37"/"38"），新库 {@link #departmentId}
 * UUID 能对齐才填，{@link #workshopName} 原样文本留底（待 workshop_legacy_map 回填）。
 */
@Getter
@Setter
@NoArgsConstructor
@Entity
@Table(name = "production_plans")
public class ProductionPlan extends SoftDeletableEntity {

    @Column(name = "legacy_id", unique = true)
    private Integer legacyId;

    @Column(name = "bill_no", nullable = false)
    private String billNo;

    @Column(name = "bill_date", nullable = false)
    private LocalDate billDate;

    /** FStyle 生产类型（老库样本为空）。 */
    @Column(name = "f_style")
    private String fStyle;

    /** DDate 交货日期。 */
    @Column(name = "delivery_date")
    private LocalDate deliveryDate;

    /** WorkShop → departments（能对齐才填；老库 varchar 装名字/数字）。 */
    @Column(name = "department_id")
    private UUID departmentId;

    /** WorkShop varchar(250) 原样留底（车间编号/名字字符串）。 */
    @Column(name = "workshop_name")
    private String workshopName;

    /** WorkerID varchar(250) 多值名字，原样文本。 */
    @Column(name = "worker_name")
    private String workerName;

    /** Seller varchar(250) 跟单员，原样文本。 */
    @Column(name = "seller_name")
    private String sellerName;

    /** MakeID → employees（迁移留空，B_Worker 与 employees 无 legacy_id 对齐）。 */
    @Column(name = "maker_id")
    private UUID makerId;

    @Column(name = "approver_id")
    private UUID approverId;

    /** MakeID 老 ID 留底（后续 worker_legacy_map 回填）。 */
    @Column(name = "maker_legacy_id")
    private Integer makerLegacyId;

    @Column(name = "approver_legacy_id")
    private Integer approverLegacyId;

    /** Remark（text 大字段）。 */
    private String remark;

    /** 0 草稿 / 1 已审 / -1 红冲。 */
    @Column(name = "status", nullable = false)
    private Short status = 0;

    /** Fulfill 派生（CheckFulfill4 → Service 派生：所有明细 qty - iqty ≤ 0）。 */
    @Column(name = "is_closed", nullable = false)
    private boolean closed = false;

    /** Stop（手工中止）。 */
    @Column(name = "is_stopped", nullable = false)
    private boolean stopped = false;

    /** Cancel（取消）。 */
    @Column(name = "is_canceled", nullable = false)
    private boolean canceled = false;

    /** 软关联占位（销售订单号等）。 */
    @Column(name = "source_doc_no")
    private String sourceDocNo;
}
