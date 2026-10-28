package com.uten.imp.features.finance.report;

import jakarta.persistence.EntityManager;
import lombok.RequiredArgsConstructor;
import lombok.extern.slf4j.Slf4j;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Propagation;
import org.springframework.transaction.annotation.Transactional;

import java.math.BigDecimal;
import java.sql.Date;
import java.time.LocalDate;
import java.util.List;

/**
 * 客户/供应商往来月度汇总的脏期间重算（B2 期初快照）。
 *
 * <p>{@code party_monthly_summaries} 是 {@link FinancePartyStatementSql} 事件流的
 * 可重建月粒度投影；源表触发器（V950）在业务事务内把（side, party, 业务月）登记进
 * {@code party_month_dirty}。本服务按脏键在一致快照中从权威事件重算该单元并删除
 * 脏键（同事务）：崩溃可重试、重复消费幂等，不依赖任何最大 ID / created_at 水位，
 * 迟到提交、乱序提交、旧单改月、跨月红冲、抵销反转各自落进自己的脏期间。
 *
 * <p>两条消费路径：
 * <ul>
 *   <li><b>读自愈</b>：对账单/年表读取前先 {@link #reconcileNow} 同步重算该单位的
 *       脏键——读取永远精确，不存在读过期汇总的问题；</li>
 *   <li><b>后台排水</b>：{@code PartyMonthlySummaryScheduler} 每隔数秒按
 *       (side, party, month) 全序批量排水，预热其余单位并收敛积压。</li>
 * </ul>
 * {@code month_start='1900-01-01''} 是哨兵：整单位全量重建（迁移种子与运维重建用它）。
 * 重算只从权威事实覆盖投影单元格，不做任何「调平」；发现差异的唯一修复路径是重建。
 */
@Slf4j
@Service
@RequiredArgsConstructor
public class PartyMonthlySummaryService {

    static final Date FULL_REBUILD_SENTINEL = Date.valueOf("1900-01-01");

    private final EntityManager em;

    /** 读路径自愈：同步重算该单位的全部脏键（通常为 0～少数几个单元）。 */
    @Transactional(propagation = Propagation.REQUIRES_NEW)
    public void reconcileNow(String side, java.util.UUID partyId) {
        if (side == null || partyId == null) {
            return;
        }
        List<?> months = em.createNativeQuery(
                        "SELECT month_start FROM party_month_dirty WHERE side=:side AND party_id=:pid "
                                + "ORDER BY month_start")
                .setParameter("side", side).setParameter("pid", partyId)
                .getResultList();
        if (months.isEmpty()) {
            return;
        }
        // 与读路径完全同源的事件 SQL（公司全域口径），保证投影与查询逐字同义。
        String events = eventsSql(side, partyId);
        for (Object month : months) {
            process(events, side, partyId, asLocalDate(month));
        }
    }

    /** 后台排水：按 (side, party, month) 全序处理最旧的至多 limit 个脏键，返回处理数。 */
    @Transactional(propagation = Propagation.REQUIRES_NEW)
    public int drain(int limit) {
        int safeLimit = Math.max(1, Math.min(limit, 200));
        @SuppressWarnings("unchecked")
        List<Object[]> rows = em.createNativeQuery(
                        "SELECT side,party_id,month_start FROM party_month_dirty "
                                + "ORDER BY side,party_id,month_start LIMIT " + safeLimit)
                .getResultList();
        for (Object[] row : rows) {
            process(eventsSql((String) row[0], (java.util.UUID) row[1]), (String) row[0],
                    (java.util.UUID) row[1], asLocalDate(row[2]));
        }
        return rows.size();
    }

    /** 全量重建入口（运维/测试）：为所有出现过往来事件的单位登记哨兵，由排水收敛。 */
    @Transactional(propagation = Propagation.REQUIRES_NEW)
    public int seedFullRebuild() {
        int seeded = em.createNativeQuery("""
                INSERT INTO party_month_dirty(side,party_id,month_start,reason)
                SELECT DISTINCT 'AR',ledger.client_id,DATE '1900-01-01','MANUAL_REBUILD'
                FROM ar_ap_ledger ledger WHERE ledger.client_id IS NOT NULL AND ledger.direction='AR'
                UNION
                SELECT DISTINCT 'AR',receipt.client_id,DATE '1900-01-01','MANUAL_REBUILD'
                FROM finance_receipts receipt WHERE receipt.client_id IS NOT NULL
                UNION
                SELECT DISTINCT 'AR',allocation.client_id,DATE '1900-01-01','MANUAL_REBUILD'
                FROM customer_open_item_offsets allocation WHERE allocation.client_id IS NOT NULL
                UNION
                SELECT DISTINCT 'AP',ledger.supplier_id,DATE '1900-01-01','MANUAL_REBUILD'
                FROM ar_ap_ledger ledger WHERE ledger.supplier_id IS NOT NULL AND ledger.direction='AP'
                UNION
                SELECT DISTINCT 'AP',payment.supplier_id,DATE '1900-01-01','MANUAL_REBUILD'
                FROM finance_payments payment WHERE payment.supplier_id IS NOT NULL
                UNION
                SELECT DISTINCT 'AP',allocation.supplier_id,DATE '1900-01-01','MANUAL_REBUILD'
                FROM supplier_open_item_offsets allocation WHERE allocation.supplier_id IS NOT NULL
                ON CONFLICT DO NOTHING
                """).executeUpdate();
        return seeded;
    }

    /** 待处理脏键数（新鲜度可见：积压与最旧登记时间）。 */
    @Transactional(readOnly = true)
    public long pendingCount() {
        return ((Number) em.createNativeQuery("SELECT COUNT(*) FROM party_month_dirty")
                .getSingleResult()).longValue();
    }

    /** Hibernate 6 对 DATE 列返回 LocalDate；驱动路径下可能仍是 java.sql.Date。 */
    private static LocalDate asLocalDate(Object value) {
        if (value instanceof java.sql.Date date) return date.toLocalDate();
        if (value instanceof LocalDate date) return date;
        return LocalDate.parse(value.toString());
    }

    /**
     * 服务端把单位身份内联为 UUID 字面量（side 已限定 AR/AP、pid 为 UUID 对象，
     * 无外部输入拼接面）：Hibernate 6 对原生查询中大量同名 :pid 的绑定不可依赖，
     * 内联后事件 SQL 的每个分支都精确锁定该单位。
     */
    private static String eventsSql(String side, java.util.UUID partyId) {
        return FinancePartyStatementSql.events("AR".equals(side), "1=1")
                .replace(":pid", "'" + partyId + "'::uuid");
    }

    private void process(String events, String side, java.util.UUID partyId, LocalDate month) {
        boolean wholeParty = FULL_REBUILD_SENTINEL.toLocalDate().equals(month);
        if (wholeParty) {
            em.createNativeQuery(
                            "DELETE FROM party_monthly_summaries WHERE side=:side AND party_id=:pid")
                    .setParameter("side", side).setParameter("pid", partyId)
                    .executeUpdate();
        } else {
            em.createNativeQuery("""
                            DELETE FROM party_monthly_summaries
                            WHERE side=:side AND party_id=:pid AND month_start=:month
                            """)
                    .setParameter("side", side).setParameter("pid", partyId)
                    .setParameter("month", month)
                    .executeUpdate();
        }
        // events() 是 WITH 前缀而非完整语句——按 running()/annual() 的续写形态追加
        // recompute CTE 取回聚合行，再用普通参数化 INSERT 落格（避免把事件流包进
        // 嵌套子查询；INSERT...SELECT 形态在 Hibernate executeUpdate 下不可依赖）。
        String aggregation = (wholeParty ? """
                        %s
                        , recompute AS (
                            SELECT event.currency_id,
                                   date_trunc('month',event.event_date)::DATE AS month_start,
                                   SUM(event.posted_original-event.settled_original) AS net_original,
                                   SUM(event.posted_local) AS posted_local_sum,
                                   SUM(event.settled_local) AS settled_local_sum,
                                   SUM(event.posted_local-event.settled_local) AS net_local,
                                   COUNT(*) AS event_count,
                                   COUNT(*) FILTER(WHERE event.posted_original IS NULL
                                       OR event.settled_original IS NULL
                                       OR event.currency_id IS NULL) AS null_original_count
                            FROM party_events event
                            GROUP BY event.currency_id,date_trunc('month',event.event_date)::DATE
                        )
                        SELECT * FROM recompute ORDER BY month_start,currency_id NULLS LAST
                        """
                : """
                        %s
                        , recompute AS (
                            SELECT event.currency_id,
                                   SUM(event.posted_original-event.settled_original) AS net_original,
                                   SUM(event.posted_local) AS posted_local_sum,
                                   SUM(event.settled_local) AS settled_local_sum,
                                   SUM(event.posted_local-event.settled_local) AS net_local,
                                   COUNT(*) AS event_count,
                                   COUNT(*) FILTER(WHERE event.posted_original IS NULL
                                       OR event.settled_original IS NULL
                                       OR event.currency_id IS NULL) AS null_original_count
                            FROM party_events event
                            WHERE event.event_date>=CAST(:month AS date) AND event.event_date<CAST(:nextMonth AS date)
                            GROUP BY event.currency_id
                        )
                        SELECT * FROM recompute ORDER BY currency_id NULLS LAST
                        """).formatted(events);
        var aggregationQuery = em.createNativeQuery(aggregation);
        if (!wholeParty) {
            aggregationQuery.setParameter("month", month.toString())
                    .setParameter("nextMonth", month.plusMonths(1).toString());
        }
        @SuppressWarnings("unchecked")
        List<Object[]> rows = aggregationQuery.getResultList();

        for (Object[] row : rows) {
            em.createNativeQuery("""
                            INSERT INTO party_monthly_summaries(
                                side,party_id,currency_id,currency_key,month_start,
                                net_original,posted_local_sum,settled_local_sum,net_local,
                                event_count,null_original_count,
                                last_rebuilt_at,created_at,updated_at)
                            VALUES(:side,:pid,:currency,
                                   COALESCE(:currency,'00000000-0000-0000-0000-000000000000'::uuid),
                                   :cellMonth,:netOriginal,
                                   :postedLocal,:settledLocal,:netLocal,
                                   :eventCount,:nullOriginalCount,now(),now(),now())
                            """)
                    .setParameter("side", side).setParameter("pid", partyId)
                    .setParameter("currency", asUuid(row[0]))
                    .setParameter("cellMonth", java.sql.Date.valueOf(wholeParty ? asLocalDate(row[1]) : month))
                    .setParameter("netOriginal", asDecimal(row, wholeParty ? 2 : 1))
                    .setParameter("postedLocal", asDecimal(row, wholeParty ? 3 : 2))
                    .setParameter("settledLocal", asDecimal(row, wholeParty ? 4 : 3))
                    .setParameter("netLocal", asDecimal(row, wholeParty ? 5 : 4))
                    .setParameter("eventCount", ((Number) row[wholeParty ? 6 : 5]).longValue())
                    .setParameter("nullOriginalCount", ((Number) row[wholeParty ? 7 : 6]).longValue())
                    .executeUpdate();
        }
        em.createNativeQuery("""
                        DELETE FROM party_month_dirty
                        WHERE side=:side AND party_id=:pid AND month_start=:month
                        """)
                .setParameter("side", side).setParameter("pid", partyId)
                .setParameter("month", month)
                .executeUpdate();
    }

    private static java.util.UUID asUuid(Object value) {
        return value == null ? null : java.util.UUID.fromString(value.toString());
    }

    private static BigDecimal asDecimal(Object[] row, int index) {
        Object value = row[index];
        return value == null ? null : new BigDecimal(value.toString());
    }
}
