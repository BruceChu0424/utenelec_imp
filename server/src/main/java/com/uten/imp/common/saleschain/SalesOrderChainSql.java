package com.uten.imp.common.saleschain;

/**
 * 销售订单行链路状态（{@code sales_order_items.chain_status}）的唯一 SQL 派生口径（V545）。
 *
 * <p>chain_status 是派生列（docs/07-业务链路/02 §一.6）：权威来源永远是数量本身。
 * 2026-09-10 之前派生规则内联在十余个写点里，且"planned − produced > 0"就把整行推进
 * 3/4/5/6——部分排产（订 10 排 4）后剩余 6 从待排产消失。本类把规则收口成一个 CASE：
 * <b>剩余未排量优先</b>——只要还有未排量，行就停在待排产（1 部分预留 / 2 待排产），
 * 已排/已产量只作进度展示，不改变"仍需排产"的事实。
 *
 * <p>派生顺序（{@link #chainStatusCaseSql}）：
 * <pre>
 *   chain_status ≤ 0（未上链 0 / 已取消 -1）        → 原值不动
 *   未交付量 ≤ 0（qty − shipped + returned − flag）   → 9 已发货
 *   预留 ≥ 未交付量                                  → 7 可发货
 *   已发 > 0                                         → 8 部分发货
 *   剩余未排量 > 0（未交付 − 预留 − max(已排−已产,0)） → 预留 > 0 ? 1 部分预留 : 2 待排产
 *   已产（完工入库）> 0                              → 6 部分完工
 *   producing（默认：原值已是 5）                    → 5 生产中（只由报工审核推进）
 *   未完工计划量 > 0                                 → plannedStatus（默认：原值 3 保留 3，否则 4）
 *   其余                                             → 2
 * </pre>
 * 唯一不走本 CASE 的写点是出货交接 {@code SalesShipmentService.applyReservedAndChainOnShip}
 * （只推 8/9：部分发货事实由出货路径产生，随后任何重算按上面顺序收敛）。
 * Java 侧镜像见 {@link SalesChainStatus}，两者一致性由 SalesChainStatusTest /
 * SalesOrderChainSqlPostgresTest 用同一张用例表钉死。
 */
public final class SalesOrderChainSql {

    private SalesOrderChainSql() {}

    /** 待排产 / 生产中 大类的行谓词只对链上活跃行（1..8）生效；0/-1/9 不参与。 */
    private static final String ACTIVE_CHAIN_RANGE = "BETWEEN 1 AND 8";

    /** 未交付量：qty − shipped + returned − flag（全项目统一的 outstanding 公式）。 */
    public static String outstandingSql(String alias) {
        return "(COALESCE(" + col(alias, "qty") + ",0) - COALESCE(" + col(alias, "shipped_qty") + ",0)"
                + " + COALESCE(" + col(alias, "returned_qty") + ",0)"
                + " - COALESCE(" + col(alias, "flag_qty") + ",0))";
    }

    /** 未完工计划量：max(planned − produced, 0)。 */
    public static String unfinishedPlanSql(String alias) {
        return "GREATEST(COALESCE(" + col(alias, "planned_qty") + ",0)"
                + " - COALESCE(" + col(alias, "produced_qty") + ",0), 0)";
    }

    /**
     * 剩余未排量：max(未交付 − 预留 − 未完工计划量, 0)。
     * 调度工作台"缺口"、销售进度 PENDING 判定、待排产大类都以此为准。
     */
    public static String unplannedQtySql(String alias) {
        return "GREATEST(" + outstandingSql(alias)
                + " - COALESCE(" + col(alias, "reserved_qty") + ",0)"
                + " - " + unfinishedPlanSql(alias) + ", 0)";
    }

    /** 待排产行谓词（销售订货列表/统计卡「待生产」大类）：链上活跃行且剩余未排量 > 0。 */
    public static String pendingPlanLinePredicate(String alias) {
        return "(COALESCE(" + col(alias, "chain_status") + ",0) " + ACTIVE_CHAIN_RANGE
                + " AND " + unplannedQtySql(alias) + " > 0)";
    }

    /**
     * 生产中行谓词（「生产中」大类）：链上活跃行且（未完工计划量 > 0 或已处于 5 生产中 / 6 部分完工）。
     * 部分排产的行同时满足待排产与生产中，两大类可同时命中（一单多卡）。
     */
    public static String inProductionLinePredicate(String alias) {
        return "(COALESCE(" + col(alias, "chain_status") + ",0) " + ACTIVE_CHAIN_RANGE
                + " AND (" + unfinishedPlanSql(alias) + " > 0"
                + " OR " + col(alias, "chain_status") + " IN (5,6)))";
    }

    /**
     * 统一 chain_status 派生 CASE（可直接放在 UPDATE ... SET chain_status = 之后）。
     * 写点若同一语句还在改数量列，须把增量以 {@link ChainStatusInputs} 的 delta 传入：
     * PostgreSQL 的 SET 表达式读的是旧行值，CASE 里必须显式写 {@code reserved_qty - :q}。
     */
    public static String chainStatusCaseSql(ChainStatusInputs in) {
        String alias = in.alias();
        String outstanding = outstandingSql(alias);
        String reserved = "(COALESCE(" + col(alias, "reserved_qty") + ",0)" + in.reservedDelta() + ")";
        String shipped = "COALESCE(" + col(alias, "shipped_qty") + ",0)";
        String produced = "(COALESCE(" + col(alias, "produced_qty") + ",0)" + in.producedDelta() + ")";
        String unfinished = "GREATEST((COALESCE(" + col(alias, "planned_qty") + ",0)" + in.plannedDelta()
                + ") - " + produced + ", 0)";
        String unplanned = "(" + outstanding + " - " + reserved + " - " + unfinished + ")";
        String current = "COALESCE(" + col(alias, "chain_status") + ",0)";
        return "CASE WHEN " + current + " <= 0 THEN " + col(alias, "chain_status")
                + "\n  WHEN " + outstanding + " <= 0 THEN 9"
                + "\n  WHEN " + reserved + " >= " + outstanding + " THEN 7"
                + "\n  WHEN " + shipped + " > 0 THEN 8"
                + "\n  WHEN " + unplanned + " > 0 THEN CASE WHEN " + reserved + " > 0 THEN 1 ELSE 2 END"
                + "\n  WHEN " + produced + " > 0 THEN 6"
                + "\n  WHEN " + in.producingExpr() + " THEN 5"
                + "\n  WHEN " + unfinished + " > 0 THEN " + in.plannedStatusExpr()
                + "\n  ELSE 2 END";
    }

    /**
     * CASE 输入：表别名（"" 表示不带前缀）、三个数量列的同语句增量片段（如 {@code " - :q"}），
     * 以及 5/3-4 两个"粘性"状态的表达式。
     */
    public record ChainStatusInputs(
            String alias,
            String reservedDelta,
            String plannedDelta,
            String producedDelta,
            String plannedStatusExpr,
            String producingExpr) {

        /** 默认：无增量；已排产落点保留原值 3（待物料），否则 4；生产中只在原值已是 5 时保留。 */
        public static ChainStatusInputs of(String alias) {
            return new ChainStatusInputs(alias, "", "", "",
                    defaultPlannedStatusExpr(alias), defaultProducingExpr(alias));
        }

        public ChainStatusInputs reservedDelta(String delta) {
            return new ChainStatusInputs(alias, delta, plannedDelta, producedDelta,
                    plannedStatusExpr, producingExpr);
        }

        public ChainStatusInputs plannedDelta(String delta) {
            return new ChainStatusInputs(alias, reservedDelta, delta, producedDelta,
                    plannedStatusExpr, producingExpr);
        }

        public ChainStatusInputs producedDelta(String delta) {
            return new ChainStatusInputs(alias, reservedDelta, plannedDelta, delta,
                    plannedStatusExpr, producingExpr);
        }

        /** 排产审核时按物料判定传 {@code :st}（3 待物料 / 4 已排产）。 */
        public ChainStatusInputs plannedStatus(String expr) {
            return new ChainStatusInputs(alias, reservedDelta, plannedDelta, producedDelta,
                    expr, producingExpr);
        }

        /** 报工红冲 / FQC 回退等按"仍有有效报工量"判定是否停留在 5。 */
        public ChainStatusInputs producing(String expr) {
            return new ChainStatusInputs(alias, reservedDelta, plannedDelta, producedDelta,
                    plannedStatusExpr, expr);
        }

        static String defaultPlannedStatusExpr(String alias) {
            return "CASE WHEN COALESCE(" + col(alias, "chain_status") + ",0) = 3 THEN 3 ELSE 4 END";
        }

        static String defaultProducingExpr(String alias) {
            return "COALESCE(" + col(alias, "chain_status") + ",0) = 5";
        }
    }

    /**
     * "仍有有效报工量"表达式：该订单行任一有效分摊的 produced_qty > 0。
     * 报工红冲 / FQC 失败回退用它决定是否留在 5，不再无条件 5→4。
     * 外层 UPDATE 必须给 sales_order_items 起别名：EXISTS 子查询里裸写 {@code id}
     * 会按内层作用域绑到 plan_order_item_links.id，永远不相等。
     */
    public static String hasReportedQtySql(String alias) {
        if (alias == null || alias.isBlank()) {
            throw new IllegalArgumentException("hasReportedQtySql 需要外层 sales_order_items 别名");
        }
        return "EXISTS (SELECT 1 FROM plan_order_item_links chain_link"
                + " WHERE chain_link.order_item_id = " + col(alias, "id")
                + " AND chain_link.is_deleted = FALSE"
                + " AND COALESCE(chain_link.produced_qty,0) > 0)";
    }

    private static String col(String alias, String column) {
        return alias == null || alias.isEmpty() ? column : alias + "." + column;
    }
}
