package com.uten.imp.features.production.plan;

import com.uten.imp.common.domain.BaseEntity;
import jakarta.persistence.Column;
import jakarta.persistence.Entity;
import jakarta.persistence.Table;
import lombok.Getter;
import lombok.NoArgsConstructor;
import lombok.Setter;

import java.math.BigDecimal;
import java.time.OffsetDateTime;
import java.util.UUID;

/**
 * 生产计划明细 × 销售订货明细 联动（合并生产）。
 *
 * <p>多对多：一个计划行可合并多个订单行（100+50=150 一次投产）；
 * 一个订单行可拆到多个计划行（分批排产）。三量沿本表回写订单行：
 * allocated（排产）/ produced（报工）/ inbound（完工入库，入库即补预留）。
 *
 * <p>幂等：未删除行 (plan_item_id, order_item_id) 唯一（uq_pol_pair）。
 * order_item_id → sales_order_items.id 为跨模块逻辑 FK（契约 §一，不建 REFERENCES）。
 */
@Getter
@Setter
@NoArgsConstructor
@Entity
@Table(name = "plan_order_item_links")
public class PlanOrderItemLink extends BaseEntity {

    public static final short SOURCE_NORMAL = 0;   // 正常排产
    public static final short SOURCE_REMAKE = 1;   // 补产（不良缺额）

    @Column(name = "plan_item_id", nullable = false)
    private UUID planItemId;

    /** → sales_order_items.id（跨模块逻辑 FK）。 */
    @Column(name = "order_item_id", nullable = false)
    private UUID orderItemId;

    /** 本计划行分给该订单行的排产量（行单位）。 */
    @Column(name = "allocated_qty", nullable = false, precision = 18, scale = 4)
    private BigDecimal allocatedQty;

    /** 报工合格量回写。 */
    @Column(name = "produced_qty", nullable = false, precision = 18, scale = 4)
    private BigDecimal producedQty = BigDecimal.ZERO;

    /** 完工入库量回写（入库即补预留）。 */
    @Column(name = "inbound_qty", nullable = false, precision = 18, scale = 4)
    private BigDecimal inboundQty = BigDecimal.ZERO;

    /** 0正常排产 / 1补产。 */
    @Column(name = "source", nullable = false)
    private Short source = SOURCE_NORMAL;

    /** 完结缺额砍掉的分摊量（红冲完结报工时恢复并置空）。 */
    @Column(name = "capped_qty", precision = 18, scale = 4)
    private BigDecimal cappedQty;

    @Column(name = "is_deleted", nullable = false)
    private boolean deleted = false;

    @Column(name = "deleted_at")
    private OffsetDateTime deletedAt;
}
