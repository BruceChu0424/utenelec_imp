package com.uten.imp.application.port;

import java.util.Map;
import java.util.Set;

/**
 * 工作台徽章的只读端口(ADR-108, permissions-08)。
 *
 * <p>按当前主体<b>只算指定入口</b>, 口径与 GET /api/workbench/badges 完全相同: 同一张入口目录、
 * 同一批来源、同一资格判定(各来源原计数端点的 {@code @PreAuthorize})。工作台「今日概览」的
 * 本部门待办从这里取数——此前概览按「部门 + 权限码」另写一套计数, 与红徽章是两套规则。
 */
public interface WorkbenchBadgeReadPort {

    /**
     * 指定入口的红数与其引用来源的事实数。
     *
     * @param entryNames 入口键(与前端 BadgeEntry / 服务端入口目录逐字一致); 未知键直接报错
     * @return 当前主体无权访问的入口不出现; 本次有来源没算出的入口列在 {@code staleEntries}
     */
    Entries entries(Set<String> entryNames);

    /**
     * @param todo         入口键 → 红数
     * @param facts        事实数(来源键.字段 → 数), 只含所请求入口引用的来源
     * @param staleEntries 本次有来源没算出的入口(其红数残缺, 调用方不应据此展示)
     */
    record Entries(Map<String, Long> todo, Map<String, Long> facts, Set<String> staleEntries) {

        public static final Entries NONE = new Entries(Map.of(), Map.of(), Set.of());

        public long fact(String key) {
            Long value = facts.get(key);
            return value == null ? 0 : value;
        }
    }
}
