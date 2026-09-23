package com.uten.imp.application.port;

import java.util.UUID;

/**
 * 账号安全事件告知本人 (ADR-110; security-02): 密码被重置、账号被解锁/锁定/停用/启用时,
 * 给目标员工发一条系统通知, 让本人第一时间知道「有人动了我的账号」。
 * 实现方在通知模块, 与业务同事务 (失败随业务回滚)。
 */
public interface AccountSecurityNoticePort {

    /**
     * @param targetUserId 被操作的登录账号
     * @param title        通知标题 (中文大白话)
     * @param content      通知正文 (中文大白话, 不含密码等敏感值)
     */
    void notifyAccountHolder(UUID targetUserId, String title, String content);

    /**
     * 同一事件告知其他在用的超级管理员 (不含 {@code actorUserId} 本人)。用于账号支持人员 (非超管)
     * 重置别人密码时: 目标本人所有设备已退出、也不知道新密码, 看不到提醒, 需要另有人知情。
     */
    void notifySuperAdministrators(UUID actorUserId, String title, String content);
}
