package com.uten.imp.audit;

import java.time.Clock;
import java.util.HashMap;
import java.util.HashSet;
import java.util.Map;
import java.util.Set;

/**
 * 拒绝类事件与匿名失败请求的落库节流(ADR-105, security-11)。
 *
 * <p>令牌失效后前端轮询会反复撞 401, 匿名请求还可以每次换一个路径不设上限地触发审计写入;
 * 逐条落库既没有新的取证价值, 又是审计写放大的入口。按固定的一分钟窗口计:
 * <ul>
 *   <li>同一个键一分钟只放行第一条。已登录会话的键含完整路径(同会话同路径每分钟一条);
 *       匿名来源的键只到「IP + 动作 + 结果 + 状态码」, 换路径不会换出新键, 第一条会带上当时的路径;</li>
 *   <li>同一来源每分钟最多落库 {@value #SESSION_ROWS_PER_MINUTE} 条(会话)
 *       或 {@value #ANONYMOUS_ROWS_PER_IP_PER_MINUTE} 条(匿名 IP), 挡住换路径、换动作的刷写;</li>
 *   <li>全部匿名来源合计每分钟最多 {@value #ANONYMOUS_ROWS_PER_MINUTE} 条, 挡住换 IP 的分布式刷写。</li>
 * </ul>
 * 窗口到点整体换新, 不会因为有人刷键把常用键的窗口提前清掉; 一分钟内最多记住
 * {@value #MAX_KEYS_PER_MINUTE} 个键, 超出的新键直接不落库。每个窗口里第一条总会落库。
 */
final class AuditEventThrottle {

    static final long WINDOW_MILLIS = 60_000L;
    static final int SESSION_ROWS_PER_MINUTE = 20;
    static final int ANONYMOUS_ROWS_PER_IP_PER_MINUTE = 5;
    static final int ANONYMOUS_ROWS_PER_MINUTE = 120;
    static final int MAX_KEYS_PER_MINUTE = 20_000;

    private final Clock clock;
    private long windowIndex = Long.MIN_VALUE;
    private final Set<String> admittedKeys = new HashSet<>();
    private final Map<String, Integer> rowsByOrigin = new HashMap<>();
    private int anonymousRows;

    AuditEventThrottle(Clock clock) {
        this.clock = clock;
    }

    /**
     * 这一条是否应该落库。
     *
     * @param origin    来源: 会话 {@code s:<id>} / 操作人 {@code u:<id>} / 匿名 {@code ip:<地址>}
     * @param anonymous 是否没有已验证的会话或操作人
     * @param key       去重键(已含来源)
     */
    synchronized boolean admit(String origin, boolean anonymous, String key) {
        long window = Math.floorDiv(clock.millis(), WINDOW_MILLIS);
        if (window != windowIndex) {
            windowIndex = window;
            admittedKeys.clear();
            rowsByOrigin.clear();
            anonymousRows = 0;
        }
        if (admittedKeys.contains(key) || admittedKeys.size() >= MAX_KEYS_PER_MINUTE) {
            return false;
        }
        int originRows = rowsByOrigin.getOrDefault(origin, 0);
        if (originRows >= (anonymous ? ANONYMOUS_ROWS_PER_IP_PER_MINUTE : SESSION_ROWS_PER_MINUTE)) {
            return false;
        }
        if (anonymous && anonymousRows >= ANONYMOUS_ROWS_PER_MINUTE) {
            return false;
        }
        admittedKeys.add(key);
        rowsByOrigin.put(origin, originRows + 1);
        if (anonymous) {
            anonymousRows++;
        }
        return true;
    }
}
