package com.uten.imp.security;

import jakarta.servlet.http.HttpServletRequest;

/**
 * 判断一次请求是不是「人不在场时」发出的 (ADR-110)。这类请求不续期服务端会话的 last_seen_at,
 * 否则角标轮询、页面定时刷新、任务心跳会让会话永远不空闲, 「自动退出登录」形同虚设。
 *
 * <p>判定只看客户端声明的请求头 {@value #HEADER}: 前端按「最近一次键盘/鼠标/触摸输入」给每个请求打标,
 * 距上次输入超过 30 秒才发出的请求 (不管是哪个端点、哪种轮询) 一律带 {@code 1}。按「人在不在场」判定,
 * 而不是按端点名单判定: 新增任何轮询都不需要登记, 也就不会漏登 (按路径命名约定判定时, 服务器状态、
 * 未读分来源计数、审核心跳等常驻轮询都漏过, 最高权限账号开着工作台就永不超时)。</p>
 *
 * <p>信任客户端声明是安全的: 这个头只能让会话更早过期, 持有令牌的一方随时可以发一个不带头的请求续期,
 * 伪造没有好处。服务端空闲超时防的是「人离开了、页面还开着」与「令牌泄露后被搁置」, 这两种情况下
 * 诚实的客户端都会带头。请求审计是否降噪是另一个问题, 由服务端按端点声明, 不看本请求头。</p>
 */
public final class AutomaticRequestPolicy {

    /** 客户端声明「本请求发出时用户已有一段时间没有操作」的请求头, 值为 {@code 1}。 */
    public static final String HEADER = "X-Uten-Automatic";

    private AutomaticRequestPolicy() {}

    public static boolean isAutomatic(HttpServletRequest request) {
        return isAutomatic(request.getHeader(HEADER));
    }

    public static boolean isAutomatic(String headerValue) {
        return headerValue != null && "1".equals(headerValue.strip());
    }
}
