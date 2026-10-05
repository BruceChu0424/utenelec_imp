package com.uten.imp.application.port;

import java.util.Collection;
import java.util.UUID;

/**
 * ADR-143 委外领料「可领 N」提醒的重算端口: outbox 投递 {@code SUBCONTRACT_DRAW_RECHECK} 时
 * (原事务已提交)由通知侧调用, 实现在委外领料模块。
 *
 * <p>事件载荷: {@code goodsId}(必有, UUID 文本)、{@code colorId}(无颜色时不出现该键)。
 * 投递方读到 goodsId 调 {@link #recheckForMaterial}; 本端口不依赖通知模块的任何类。
 *
 * <p>重算规则(高水位, 表 {@code subcontract_draw_notice_marks}): 订货明细此刻可领量
 * 大于上次提醒时的量 → 发/更新「委外可领料」行动卡并把水位抬到当前值; 小于 → 水位降到当前值、
 * epoch+1, 不提醒; 降到 0 → 收回行动卡。只锁水位行, 不锁任何业务单据。
 */
public interface SubcontractDrawRecheckPort {

    /** outbox 事件类型(内部事件, 不产生通知卡本身)。 */
    String EVENT_TYPE = "SUBCONTRACT_DRAW_RECHECK";

    /** 用到这个物料货色(开放计划行)的订货明细, 以及曾经提醒过且用到它的订货明细, 全部重算一遍。 */
    void recheckForMaterial(UUID goodsId, UUID colorId);

    /** 指定订货明细重算(不存在或已不在领料范围内的按可领 0 处理)。 */
    void recheckForOrderItems(Collection<UUID> orderItemIds);
}
