package com.uten.imp.features.org.hrtask;

import java.time.LocalDate;
import java.util.List;
import java.util.UUID;

/**
 * HR 任务中心汇总读模型（全部按「今天」动态计算，不落库、无任务表）。
 *
 * @param generatedAt            计算基准日（服务端当天）
 * @param probationMonths        转正视窗月数（默认 3，见 HrTaskService 注释）
 * @param confirmToday           今日到预计转正日（仍未登记转正）
 * @param confirmUpcoming        30 天内到预计转正日（days = 剩余天数）
 * @param confirmOverdue         已过预计转正日仍未办理（days = 逾期天数；只跟踪近 12 个月入职）
 * @param unconfirmedLegacyCount 入职超过 12 个月仍未登记转正日期的人数（数据补录提示，不逐人列）
 * @param birthdayToday          今日生日（days = 周岁）
 * @param birthdayUpcoming       30 天内生日（days = 剩余天数）
 * @param anniversaryToday       今日入职周年（days = 满年数）
 * @param newHires               近 30 天新入职（days = 已入职天数）
 * @param badgeCount             工作台徽标数 = 今日转正 + 逾期转正 + 今日生日 + 今日周年（生日/周年中已祝福的不计入）
 */
public record HrTaskSummary(
        LocalDate generatedAt,
        int probationMonths,
        List<Item> confirmToday,
        List<Item> confirmUpcoming,
        List<Item> confirmOverdue,
        long unconfirmedLegacyCount,
        List<Item> birthdayToday,
        List<Item> birthdayUpcoming,
        List<Item> anniversaryToday,
        List<Item> newHires,
        long badgeCount) {

    /**
     * 单条提醒。
     *
     * @param date 相关日期（预计转正日 / 生日（今年或明年落在）/ 入职日期）
     * @param days 语义随区块：剩余天数 / 逾期天数 / 周岁 / 满年数 / 已入职天数
     * @param note 补充说明（如「入职满 1 年」），可为 null
     * @param claimedByName 软认领人姓名（ADR-021：任务不隐藏，显示「XXX 处理中」），null = 未认领
     * @param claimedByMe   是否当前用户认领（本人可继续/释放，他人快捷操作禁用）
     * @param claimLeaseUntil 认领租约到期时间（过期自动失效）
     * @param blessed       仅生日/周年条目有意义：本类型本年是否已发布过庆典祝福通知；
     *                      已祝福的不计入徽标（HR 发布祝福后角标即减），列表仍保留以便查看
     */
    public record Item(
            UUID employeeId,
            String code,
            String name,
            String deptName,
            String positionName,
            LocalDate date,
            int days,
            String note,
            String claimedByName,
            boolean claimedByMe,
            java.time.OffsetDateTime claimLeaseUntil,
            boolean blessed) {

        /** 附加认领信息（summary 装配后统一贴上）。 */
        Item withClaim(String byName, boolean byMe, java.time.OffsetDateTime leaseUntil) {
            return new Item(employeeId, code, name, deptName, positionName, date, days, note,
                    byName, byMe, leaseUntil, blessed);
        }

        /** 标记本条对应的员工本类型本年是否已祝福（用于把已祝福条目从徽标剔除）。 */
        Item withBlessed(boolean b) {
            return new Item(employeeId, code, name, deptName, positionName, date, days, note,
                    claimedByName, claimedByMe, claimLeaseUntil, b);
        }
    }
}
