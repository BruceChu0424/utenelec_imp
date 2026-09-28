package com.uten.imp.features.production.analysis;

import org.springframework.jdbc.core.JdbcTemplate;

import java.util.List;
import java.util.Map;

import static org.junit.jupiter.api.Assertions.assertTrue;

/**
 * 守住 {@link AggregatePrivateIntentReader#ALLOCATION_PENDING_CTES} (集合写法) 与库函数
 * fn_preplan_aggregate_allocation_pending_qty / fn_preplan_allocation_received_qty 逐条一致.
 *
 * <p>在跑过采购/自制/委外/合单/撤销/到货/在途转拨等场景的端到端测试收尾时调用, 对库里「全部」
 * 分配比对一次 (不只本测试造的), 分支覆盖随场景累积. 库函数改了口径而读取器没跟上, 这里先红.
 */
public final class AggregateAllocationPendingParity {
    private AggregateAllocationPendingParity() {}

    public static void assertMatchesDatabaseFunctions(JdbcTemplate db) {
        List<Map<String, Object>> mismatches = db.queryForList("""
                WITH scoped_actions AS (
                  SELECT action.id AS action_id FROM preplan_supply_actions action
                ), %s
                SELECT pending.id, pending.status, pending.pending_qty,
                       fn_preplan_aggregate_allocation_pending_qty(pending.id) AS expected_pending,
                       pending.received_qty, fn_preplan_allocation_received_qty(pending.id) AS expected_received
                FROM allocation_pending pending
                WHERE pending.pending_qty IS DISTINCT FROM fn_preplan_aggregate_allocation_pending_qty(pending.id)
                   OR (pending.status<>'CANCELLED'
                       AND pending.received_qty IS DISTINCT FROM fn_preplan_allocation_received_qty(pending.id))
                """.formatted(AggregatePrivateIntentReader.ALLOCATION_PENDING_CTES.strip()));
        assertTrue(mismatches.isEmpty(),
                "set-based allocation pending/received drifted from the database functions: " + mismatches);
    }
}
