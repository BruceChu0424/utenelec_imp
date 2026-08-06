package com.uten.imp.features.notice.dto;

import java.util.UUID;

/**
 * 当前登录员工「今日庆典」条目（登录弹窗 / 今日概览庆典卡片用）。
 *
 * <p>覆盖四类庆典：生日 / 入职周年（服务端按 birth_date、hire_date 月日判定）、
 * 新婚 / 新生儿（按今日发布且本人为祝福对象的庆典通知判定）。
 *
 * <p><b>PII</b>：birth_date / hire_date 仅服务端读取，本 DTO 绝不含任何日期原值，
 * 只暴露姓名快照与节日标签（与庆典通知一致）。
 *
 * @param type        庆典类型：birthday / anniversary / wedding / newborn
 * @param subjectName 被祝福者姓名（即当前用户本人）
 * @param eventLabel  节日标签：生日快乐 / 入职N周年 / 新婚快乐 / 喜添新丁
 * @param noticeId    对应庆典通知 ID（可能尚未发布，如调度器关闭且 HR 未手动发），可空
 */
public record MyCelebrationTodayDto(
        String type,
        String subjectName,
        String eventLabel,
        UUID noticeId) {}
