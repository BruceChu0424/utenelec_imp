package com.uten.imp.features.workbench.badge;

import java.time.Instant;
import java.util.List;
import java.util.Map;

/**
 * 工作台徽章汇总(GET /api/workbench/badges, ADR-108)。
 *
 * @param generatedAt  服务端算出这份汇总的时刻
 * @param entries      入口 → 红黄两个数; 只含当前主体有权访问的入口
 * @param modules      容器(hub / 工作台模块卡) → 其入口之和
 * @param total        导航「工作台」Tab 的红黄总数 = 全部容器之和
 * @param facts        来源原始事实数(页内分段用, 如各类草稿、品质结果分来源、未读摘要)
 * @param staleEntries 本次有来源没算出来的入口: 前端对这些入口保留上一次的数, 容器与总数按差额修正
 *                     (减去本次残缺的数、加回上一次的数), 其它健康入口的变化照常反映
 * @param staleSources 本次没算出来的来源键: 前端对这些来源的事实数(页内分段)保留上一次的数
 */
public record WorkbenchBadgeSummary(
        Instant generatedAt,
        Map<String, Counts> entries,
        Map<String, Counts> modules,
        Counts total,
        Map<String, Long> facts,
        List<String> staleEntries,
        List<String> staleSources) {

    /** 红(待办)与黄(进行中)两个数。 */
    public record Counts(long todo, long inProgress) {
        static final Counts ZERO = new Counts(0, 0);

        Counts plus(Counts other) {
            return new Counts(todo + other.todo, inProgress + other.inProgress);
        }
    }
}
