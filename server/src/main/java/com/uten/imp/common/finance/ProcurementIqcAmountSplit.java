package com.uten.imp.common.finance;

import com.uten.imp.common.util.NativeQueryResults;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import jakarta.persistence.EntityManager;

import java.math.BigDecimal;
import java.util.List;
import java.util.UUID;

/**
 * 同一条待检明细的 IQC 处置金额口径(ADR-112): 合格/不合格事件按发生顺序, 用
 * {@link MoneyPolicy#amountSlice} 对收货金额做累计切片; 处置完整条收货时各片之和恰好等于收货金额。
 *
 * <p>仓库合格放行的价值切片、财务不合格金额、退货可退额度都从这一个口径取数:
 * 合格金额 = 收货金额 − 不合格金额, 可退额度 = 合格金额中仓库已实收的累计份额, 全部实收时就是合格金额本身。
 * 这样「不合格 + 全部合格件退货」恰好冲平收货应付, 原币与本币都不留尾差。
 */
public final class ProcurementIqcAmountSplit {

    private ProcurementIqcAmountSplit() {
    }

    /** 一个处置事件: 合格或不合格, 基本单位数量。 */
    public record Event(boolean pass, BigDecimal baseQty) {
    }

    /** 原币/本币金额对; 某一边为空表示该币种没有可无损保存的有限值(由财务按实际贷项确认)。 */
    public record Amounts(BigDecimal original, BigDecimal local) {
    }

    /** 这条待检明细的全部合格/不合格事件, 与写入时同一顺序(发生时间, 事件主键)。 */
    public static List<Event> events(EntityManager em, UUID inspectionItemId) {
        return NativeQueryResults.objectArrayRows(em.createNativeQuery("""
                        SELECT action, base_qty
                        FROM procurement_inspection_events
                        WHERE inspection_item_id = :inspectionItemId
                          AND action IN ('PASS', 'FAIL')
                        ORDER BY occurred_at, id
                        """).setParameter("inspectionItemId", inspectionItemId))
                .stream()
                .map(row -> new Event("PASS".equals(String.valueOf(row[0])), decimal(row[1])))
                .toList();
    }

    /**
     * 事件序列里不合格事件的金额合计(每个事件 = 累计份额差)。
     * 事件累计超过收货量、或不合格累计与冻结行的不合格量不一致时拒绝, 不猜金额。
     */
    public static BigDecimal failedSlices(
            BigDecimal total, BigDecimal receivedBase, List<Event> events, BigDecimal expectedFailedBase) {
        if (total == null) return null;
        BigDecimal resolved = BigDecimal.ZERO;
        BigDecimal failedBase = BigDecimal.ZERO;
        BigDecimal failed = BigDecimal.ZERO;
        for (Event event : events) {
            BigDecimal next = resolved.add(event.baseQty());
            if (event.baseQty().signum() <= 0 || next.compareTo(receivedBase) > 0) {
                throw conflict("IQC处置事件累计超过冻结收货基本量");
            }
            if (!event.pass()) {
                failed = failed.add(MoneyPolicy.amountSlice(total, receivedBase, resolved, event.baseQty()));
                failedBase = failedBase.add(event.baseQty());
            }
            resolved = next;
        }
        if (expectedFailedBase != null && failedBase.compareTo(expectedFailedBase) != 0) {
            throw conflict("IQC失败事件累计与权威质检失败量不一致");
        }
        return MoneyPolicy.canonical(failed);
    }

    /**
     * 已冻结的品质资金分项里不合格事件的金额(不合格任务与供应商贷项用的同一份事实);
     * 没有冻结分项(旧收货)返回 null。某一币种按数量比例除不尽时该边为空。
     */
    public static Amounts frozenFailed(EntityManager em, UUID inspectionItemId) {
        Object[] row = NativeQueryResults.objectArrayRows(em.createNativeQuery("""
                SELECT COUNT(*),
                       CASE WHEN BOOL_AND(quality.amount_original IS NOT NULL) FILTER (WHERE event.action = 'FAIL')
                            THEN SUM(quality.amount_original) FILTER (WHERE event.action = 'FAIL') END,
                       CASE WHEN BOOL_AND(quality.amount_local IS NOT NULL) FILTER (WHERE event.action = 'FAIL')
                            THEN SUM(quality.amount_local) FILTER (WHERE event.action = 'FAIL') END
                FROM procurement_iqc_quality_consideration_parts quality
                JOIN procurement_inspection_events event ON event.id = quality.inspection_event_id
                WHERE event.inspection_item_id = :id
                  AND fn_procurement_consideration_active('QUALITY', quality.id)
                """).setParameter("id", inspectionItemId)).getFirst();
        if (decimal(row[0]).signum() == 0) return null;
        return new Amounts(nullableDecimal(row[1]), nullableDecimal(row[2]));
    }

    /**
     * 退货限额用的不合格金额: 冻结分项有有限值就取冻结值, 否则(旧收货, 或该币种除不尽)按事件切片。
     * 退货可退额度由收货金额减去它得到, 与不合格金额互为补数。
     */
    public static Amounts failedForReturnLimit(
            EntityManager em, UUID inspectionItemId, BigDecimal receivedBase, BigDecimal failedBase,
            BigDecimal receiptOriginal, BigDecimal receiptLocal) {
        if (failedBase.signum() == 0) return new Amounts(BigDecimal.ZERO, BigDecimal.ZERO);
        Amounts frozen = frozenFailed(em, inspectionItemId);
        if (frozen != null && frozen.original() != null && frozen.local() != null) return frozen;
        List<Event> events = events(em, inspectionItemId);
        return new Amounts(
                frozen != null && frozen.original() != null ? frozen.original()
                        : failedSlices(receiptOriginal, receivedBase, events, failedBase),
                frozen != null && frozen.local() != null ? frozen.local()
                        : failedSlices(receiptLocal, receivedBase, events, failedBase));
    }

    private static BigDecimal decimal(Object value) {
        return value == null ? BigDecimal.ZERO : value instanceof BigDecimal decimal
                ? decimal : new BigDecimal(value.toString());
    }

    private static BigDecimal nullableDecimal(Object value) {
        return value == null ? null : decimal(value);
    }

    private static ApiException conflict(String message) {
        return new ApiException(ErrorCode.CONFLICT, message);
    }
}
