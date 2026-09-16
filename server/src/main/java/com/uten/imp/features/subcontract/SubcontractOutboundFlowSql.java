package com.uten.imp.features.subcontract;

/**
 * 委外「新流向」出仓量的共享 SQL 片段（V436 起的目标件出仓 + V581 的子件出仓）。
 *
 * <p>存在的理由：先出后进（回厂量不得超过已审出仓量）这条守恒在服务端有四处
 * 镜像——回厂审核、回厂草稿预检、出仓红冲、到货登记额度——它们必须逐字同口径，
 * 否则会出现「一处放行一处拒绝」或更糟的 fail-open。把折算式集中在这里，
 * 任何一次口径调整都只有一个落点。数据库侧的同款守恒在
 * {@code fn_assert_subcontract_target_outbound_receipt}（V507/V581）。
 *
 * <p><b>量纲</b>：四种新流向里 {@code COMPONENT_OUTBOUND} 发的是子件，
 * {@code issue_item.qty * unit_rate} 是**子件基本量**；其余三种发的是目标件本身，
 * 同样的表达式是**目标件基本量**。两者不能直接相加，必须先把子件量按冻结单耗
 * 折回目标件基本量：
 *
 * <pre>
 *   子件基本量 ÷ frozen_unit_qty          = 目标件订货单位数
 *   目标件订货单位数 × order_item.unit_rate = 目标件基本量
 * </pre>
 *
 * <p>{@code frozen_unit_qty} 为 NULL 或 ≤0 时按 NULL 传播（该行不计入），
 * 与「缺冻结单耗不得推算」的既有 fail-closed 口径一致。
 */
public final class SubcontractOutboundFlowSql {

    /** V436 起由出仓计划驱动的四种流向（不含 V304 历史 LEGACY 手工发料）。 */
    public static final String NEW_FLOW_MODES =
            "'DIRECT_OUTBOUND','MAKE_THEN_OUTBOUND','PREPARED_OUTBOUND','COMPONENT_OUTBOUND'";

    /**
     * 与 {@link #ISSUED_TARGET_BASE_SUM} 配套的 JOIN：取订货明细的冻结换算率。
     * 调用方的出仓明细别名必须是 {@code issue_item}。
     */
    public static final String ISSUED_ORDER_UNIT_JOIN =
            "JOIN subcontract_order_items order_unit\n"
            + "                             ON order_unit.id = issue_item.order_item_id\n";

    /**
     * 已审出仓量合计，统一折算到**目标件基本量**。
     * 调用方别名约定：出仓明细 {@code issue_item}、计划行 {@code plan_item}、
     * 订货明细 {@code order_unit}（见 {@link #ISSUED_ORDER_UNIT_JOIN}）。
     */
    public static final String ISSUED_TARGET_BASE_SUM =
            "SUM(CASE WHEN plan_item.flow_mode = 'COMPONENT_OUTBOUND'\n"
            + "                                    THEN ROUND(issue_item.qty"
            + " * COALESCE(issue_item.unit_rate, 1)\n"
            + "                                        / NULLIF(issue_item.frozen_unit_qty, 0)\n"
            + "                                        * COALESCE(order_unit.unit_rate, 1), 4)\n"
            + "                                    ELSE issue_item.qty"
            + " * COALESCE(issue_item.unit_rate, 1) END)";

    private SubcontractOutboundFlowSql() {
    }
}
