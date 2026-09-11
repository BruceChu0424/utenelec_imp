package com.uten.imp.common.saleschain;

import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.Arguments;
import org.junit.jupiter.params.provider.MethodSource;
import org.junit.jupiter.api.Test;

import java.math.BigDecimal;
import java.util.List;
import java.util.stream.Stream;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertTrue;

/**
 * V545 链路状态派生规则的 Java 镜像用例表。SalesOrderChainSqlPostgresTest 用同一张表
 * 在真实 PostgreSQL 上跑 {@link SalesOrderChainSql#chainStatusCaseSql}，两边结果必须一致。
 */
class SalesChainStatusTest {

    /** current, qty, shipped, returned, flag, reserved, planned, produced, expected, 说明 */
    record Case(short current, String qty, String shipped, String returned, String flag,
                String reserved, String planned, String produced, short expected, String why) {
        static Case of(int current, String qty, String shipped, String returned, String flag,
                       String reserved, String planned, String produced, int expected, String why) {
            return new Case((short) current, qty, shipped, returned, flag, reserved, planned,
                    produced, (short) expected, why);
        }
    }

    static final List<Case> CASES = List.of(
            Case.of(0, "10", "0", "0", "0", "0", "0", "0", 0, "未上链行原值不动"),
            Case.of(-1, "10", "0", "0", "0", "0", "4", "0", -1, "已取消行原值不动"),
            Case.of(2, "10", "0", "0", "0", "0", "0", "0", 2, "无预留无排产 → 待排产"),
            Case.of(2, "10", "0", "0", "0", "4", "0", "0", 1, "部分预留"),
            Case.of(2, "10", "0", "0", "0", "10", "0", "0", 7, "预留够 → 可发货"),
            Case.of(2, "10", "0", "0", "0", "0", "4", "0", 2, "订 10 排 4：剩余未排 6 → 仍待排产（本次修复）"),
            Case.of(4, "10", "0", "0", "0", "0", "4", "0", 2, "旧数据 4 但未排 6 → 回待排产"),
            Case.of(1, "10", "0", "0", "0", "3", "4", "0", 1, "预留 3 + 排 4：未排 3 → 部分预留"),
            Case.of(5, "10", "0", "0", "0", "0", "4", "0", 2, "已报工但仍有未排量 → 待排产（5 不粘）"),
            Case.of(2, "10", "0", "0", "0", "0", "10", "0", 4, "排满 → 已排产"),
            Case.of(3, "10", "0", "0", "0", "0", "10", "0", 3, "排满且原值 3 → 保留待物料"),
            Case.of(5, "10", "0", "0", "0", "0", "10", "0", 5, "排满且原值 5 → 保留生产中"),
            Case.of(7, "10", "0", "0", "0", "0", "10", "0", 4, "入库红冲后（原值 7）→ 已排产"),
            Case.of(4, "10", "0", "0", "0", "5", "10", "5", 6, "部分入库（产 5 留 5）→ 部分完工"),
            Case.of(6, "10", "0", "0", "0", "3", "10", "3", 6, "部分完工保持"),
            Case.of(6, "10", "0", "0", "0", "10", "10", "10", 7, "全量入库 → 可发货"),
            Case.of(7, "10", "5", "0", "0", "5", "10", "10", 7, "部分发货后剩余全预留 → 可发货"),
            Case.of(7, "10", "4", "0", "0", "0", "10", "10", 8, "部分发货且预留被让出 → 部分发货"),
            Case.of(9, "10", "10", "2", "0", "0", "10", "10", 8, "全发后退 2（未排 2）→ 部分发货，缺口回待排列表"),
            Case.of(2, "10", "10", "0", "0", "0", "10", "10", 9, "退货红冲后未交付归零 → 已发货"),
            Case.of(9, "10", "10", "2", "2", "0", "10", "10", 9, "核销抵退货 → 已发货"),
            Case.of(7, "10", "0", "0", "0", "0", "10", "10", 2, "已产 10 但预留全部让出：未排 10 → 待排产"),
            Case.of(2, "10", "0", "0", "0", "0", "4", "4", 2, "排 4 产 4 预留已释放：未排 10 → 待排产"),
            Case.of(2, "10", null, null, null, null, null, null, 2, "空数量按 0")
    );

    static Stream<Arguments> cases() {
        return CASES.stream().map(c -> Arguments.of(c.why(), c));
    }

    @ParameterizedTest(name = "{0}")
    @MethodSource("cases")
    void javaMirrorFollowsTheUnifiedRule(String why, Case c) {
        assertEquals(c.expected(), SalesChainStatus.derive(
                c.current(), bd(c.qty()), bd(c.shipped()), bd(c.returned()), bd(c.flag()),
                bd(c.reserved()), bd(c.planned()), bd(c.produced())), why);
    }

    @Test
    void unplannedQtyIsOutstandingMinusReservedMinusUnfinishedPlanClampedAtZero() {
        assertEquals(0, new BigDecimal("6").compareTo(SalesChainStatus.unplannedQty(
                bd("10"), bd("0"), bd("0"), bd("0"), bd("0"), bd("4"), bd("0"))));
        assertEquals(0, BigDecimal.ZERO.compareTo(SalesChainStatus.unplannedQty(
                bd("10"), bd("0"), bd("0"), bd("0"), bd("4"), bd("6"), bd("0"))));
        assertEquals(0, BigDecimal.ZERO.compareTo(SalesChainStatus.unplannedQty(
                bd("10"), bd("0"), bd("0"), bd("0"), bd("20"), bd("0"), bd("0"))));
    }

    @Test
    void sqlCaseKeepsTheDocumentedPriorityOrder() {
        String sql = SalesOrderChainSql.chainStatusCaseSql(
                SalesOrderChainSql.ChainStatusInputs.of("i"));
        int shipped = sql.indexOf("THEN 9");
        int shippable = sql.indexOf("THEN 7");
        int partialShipped = sql.indexOf("THEN 8");
        int pending = sql.indexOf("THEN CASE WHEN");
        int partialDone = sql.indexOf("THEN 6");
        int producing = sql.indexOf("THEN 5");
        assertTrue(shipped < shippable && shippable < partialShipped
                && partialShipped < pending && pending < partialDone && partialDone < producing,
                sql);
        assertTrue(sql.contains("i.chain_status"), "别名必须落到每个列引用: " + sql);
        String withDelta = SalesOrderChainSql.chainStatusCaseSql(
                SalesOrderChainSql.ChainStatusInputs.of("").reservedDelta(" - :q"));
        assertTrue(withDelta.contains("(COALESCE(reserved_qty,0) - :q)"), withDelta);
        assertTrue(SalesOrderChainSql.unplannedQtySql("i").startsWith("GREATEST("));
        assertTrue(SalesOrderChainSql.pendingPlanLinePredicate("i").contains("BETWEEN 1 AND 8"));
        // EXISTS 子查询里裸写 id 会绑到 plan_order_item_links.id：不带别名直接拒绝。
        assertTrue(SalesOrderChainSql.hasReportedQtySql("order_item")
                .contains("chain_link.order_item_id = order_item.id"));
        org.junit.jupiter.api.Assertions.assertThrows(IllegalArgumentException.class,
                () -> SalesOrderChainSql.hasReportedQtySql(""));
    }

    static BigDecimal bd(String value) {
        return value == null ? null : new BigDecimal(value);
    }
}
