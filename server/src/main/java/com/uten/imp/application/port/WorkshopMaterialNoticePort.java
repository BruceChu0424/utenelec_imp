package com.uten.imp.application.port;

import java.util.List;
import java.util.UUID;

/**
 * 车间内料仓通知端口 (ADR-131 §5.8; ADR-017 跨 feature 只经 Port)。
 *
 * <p>领料/退料待办与自动结算被拦、连续失败的提醒。实现方 {@code features.notice.WorkshopMaterialNoticeService}
 * 与业务同事务 (失败随业务回滚); 收件人、文案与去重都在实现方, 调用方只报事实。
 */
public interface WorkshopMaterialNoticePort {

    /** 拦结算的原因: 还有报工没审核。 */
    String BLOCKER_DRAFT_REPORT = "DRAFT_REPORT";
    /** 拦结算的原因: 有产量的产品没填单个重量。 */
    String BLOCKER_MISSING_WEIGHT = "MISSING_WEIGHT";
    /** 拦结算的原因: 有产品用到某种料, 这一期却没有发料记录。 */
    String BLOCKER_THEORY_WITHOUT_STOCK = "THEORY_WITHOUT_STOCK";
    /** 等上一期结算 (不发通知, 只在页面上显示)。 */
    String BLOCKER_PREVIOUS_PERIOD_OPEN = "PREVIOUS_PERIOD_OPEN";

    /**
     * 一类拦截。
     *
     * @param kind    取值见本接口 BLOCKER_ 常量
     * @param count   条数 (报工张数、产品个数、料种数)
     * @param samples 前几个样例 (单号、产品名或料名), 给通知正文用
     */
    record Blocker(String kind, int count, List<String> samples) {
        public Blocker {
            samples = samples == null ? List.of() : List.copyOf(samples);
        }
    }

    /** 车间提交了领料或退料申请: 通知仓库 (按申请种类区分待发料 / 待收退回)。 */
    void requisitionPending(UUID requisitionId);

    /** 申请已发完、收完或取消: 撤回待办。 */
    void requisitionResolved(UUID requisitionId);

    /** 自动结算被拦: 按拦截种类通知该补的人 (同一期同一种类条数不变时不重发)。 */
    void closeBlocked(UUID periodId, List<Blocker> blockers);

    /** 这一期已结算或已撤销: 撤回全部拦截与失败提醒。 */
    void closeResolved(UUID periodId);

    /** 连续失败达到上限: 通知设置负责人; businessMessage 只含业务文案, 不含程序信息。 */
    void closeFailing(UUID periodId, String businessMessage);
}
