package com.uten.imp.application.port;

import java.math.BigDecimal;
import java.time.LocalDate;
import java.util.List;
import java.util.UUID;

/**
 * ADR-098 委外回厂短交：仓库到货登记与委外案件之间的应用端口(ADR-017 跨 feature 只经 port)。
 *
 * <p>登记前 {@link #evaluateArrival} 只读评估本次登记涉及的委外订货行, 累计回厂(登记后)仍少于
 * 订货量的行返回一条 {@link ShortDeliveryFinding}; 低于允许损耗下限的行要求仓库先确认
 * (409 逐行明细)。收货单审核送检成功后 {@link #recordArrival} 在同一事务里按库里的最新事实
 * 开立/刷新案件、完成自然到齐的案件并发通知。
 */
public interface SubcontractShortDeliveryPort {

    /** 本次登记里某一订货行申报的数量(同一订货行多行登记时调用方先合并)。 */
    record ArrivalQuantity(UUID orderItemId, BigDecimal qty) {}

    /**
     * 一行订货明细的短交评估结果。数量全部按订货单位; severity 取值
     * SEVERE / BELOW_FLOOR / WITHIN_TOLERANCE / UNSET_TOLERANCE。
     *
     * @param waitingMoreActive 该行已有「分批到货·继续等」判定且未过预计到齐日
     */
    record ShortDeliveryFinding(
            UUID orderItemId,
            String orderBillNo,
            String goodsLabel,
            String unitName,
            BigDecimal orderedQty,
            BigDecimal allowedLossPct,
            BigDecimal floorQty,
            BigDecimal deliveredBefore,
            BigDecimal declaredNow,
            BigDecimal deliveredAfter,
            BigDecimal shortfallQty,
            BigDecimal shortfallPct,
            String severity,
            boolean waitingMoreActive,
            LocalDate expectedCompleteBy) {

        /** 低于允许下限的两档要仓库看过弹窗再登记; 容差内/未设两档静默开中性案件。 */
        public boolean requiresAcknowledgement() {
            return "SEVERE".equals(severity) || "BELOW_FLOOR".equals(severity);
        }
    }

    List<ShortDeliveryFinding> evaluateArrival(List<ArrivalQuantity> lines);

    void recordArrival(UUID receiptId, String receiptBillNo, boolean acknowledged);
}
