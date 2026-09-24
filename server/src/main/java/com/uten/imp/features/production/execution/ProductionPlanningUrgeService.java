package com.uten.imp.features.production.execution;

import com.uten.imp.application.port.BusinessEventPublisher;
import com.uten.imp.application.port.WorkshopPlanningGapReadPort;
import com.uten.imp.application.port.WorkshopPlanningGapReadPort.Gap;
import com.uten.imp.common.util.NativeQueryResults;
import com.uten.imp.common.util.NativeValueConverters;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.notice.ChainNoticeService;
import com.uten.imp.features.production.ProductionWorkshopMembership;
import com.uten.imp.security.AuthUser;
import com.uten.imp.security.SecurityContextCurrentUser;
import com.uten.imp.security.TxSessionVars;
import jakarta.persistence.EntityManager;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.math.BigDecimal;
import java.time.Duration;
import java.time.OffsetDateTime;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;
import java.util.Set;
import java.util.UUID;

/**
 * 车间催计划下单子层物料(ADR-117)。
 *
 * <p>车间任务缺料、且计划那边还没下够单时(判据见 {@link WorkshopPlanningGapReadPort})，车间可以一键
 * 催计划：记一条「在催」、给计划员发一张居中待办卡。同一个任务 30 分钟内再点只回报「刚催过」，
 * 不重复打扰计划员；过了 30 分钟再催，次数加一、卡片换成最新一张。
 *
 * <p>计划员下够单(缺口归零)或任务结束，由 {@link #reconcileAnalysis} / {@link #reconcileUrges}
 * 办结在催记录并撤回卡片：计划员在物料分析页下单后页面会立即请求核对一次，后台核对任务每 5 分钟
 * 兜底一次(采购 / 委外模块里直接改单、仓库到货等不经物料分析页的变化)。
 *
 * <p>本服务不改任何需求、库存或单据数量，只是提醒。
 */
@Service
@RequiredArgsConstructor
public class ProductionPlanningUrgeService {

    /** 同一个车间任务两次催计划之间至少隔这么久(期间再点只回报「刚催过」)。 */
    public static final Duration COOLDOWN = Duration.ofMinutes(30);
    public static final String EVENT_URGED = "PRODUCTION_PLANNING_URGED";
    public static final String AGGREGATE_KIND = "PRODUCTION_PLANNING_URGE";
    static final Set<String> ACTIVE_SEGMENT_STATUSES = Set.of("WAITING", "READY", "DISPATCHED", "IN_PROGRESS");
    /** 通知正文里点名的物料种数上限，其余写「等 N 种」。 */
    private static final int SUMMARY_NAMES = 3;

    private final EntityManager em;
    private final SecurityContextCurrentUser currentUser;
    private final TxSessionVars tx;
    private final ProductionWorkshopMembership membership;
    private final ProductionExecutionWorkbenchService workbench;
    private final WorkshopPlanningGapReadPort gaps;
    private final BusinessEventPublisher events;
    private final ChainNoticeService notices;

    /**
     * 催计划。任务必须是本人车间的(与车间任务列表同一范围)、还在进行(未完工 / 未取消)，
     * 而且此刻确实有计划还没下单的物料——计划已经下过单、只是在等到货的，不必催。
     */
    @Transactional
    public UrgeResult urge(UUID segmentId) {
        tx.bind();
        membership.requireActiveOperator();
        workbench.requireVisibleWorkshopTask(segmentId);
        Object[] segment = segmentRow(segmentId);
        if (segment == null) throw new ApiException(ErrorCode.NOT_FOUND, "车间任务不存在");
        String status = (String) segment[1];
        UUID analysisId = (UUID) segment[2];
        if (!ACTIVE_SEGMENT_STATUSES.contains(status)) {
            throw new ApiException(ErrorCode.CONFLICT, "这个任务已经结束，不用再催计划");
        }
        if (analysisId == null) {
            throw new ApiException(ErrorCode.CONFLICT, "这个任务不是从物料分析下达的，缺料请直接联系计划员");
        }
        WorkshopPlanningGapReadPort.PlanningGaps fresh = gaps.freshPlanningGaps(List.of(segmentId));
        if (fresh.isUnknown(segmentId)) {
            throw new ApiException(ErrorCode.CONFLICT,
                    "物料分析暂时读不出来(可能要计划员重新分析)，这次没法判断缺什么，请直接联系计划员");
        }
        List<Gap> current = fresh.of(segmentId);
        if (current.isEmpty()) {
            throw new ApiException(ErrorCode.CONFLICT, "计划已经为缺的料下过单了，正在等到货，不用再催");
        }
        String summary = summary(current);
        UUID actor = currentUser.requireId();
        String actorName = operatorName();
        // 同一任务同时两次点击：部分唯一索引兜住「只有一条在催」，后到的那次落到下面的再催分支。
        // 在催记录刚好被核对任务办结时(插入撞上、再读又没了)，重来一次就是一条新的在催。
        UUID urgeId = null;
        for (int attempt = 0; attempt < 2 && urgeId == null; attempt++) {
            UUID candidate = UUID.randomUUID();
            int inserted = em.createNativeQuery("""
                    INSERT INTO production_planning_urges(id, execution_segment_id, material_analysis_id,
                        gap_kind_count, gap_summary, first_urged_by, last_urged_by, last_urged_by_name)
                    VALUES (:id, :segment, :analysis, :kinds, :summary, :actor, :actor, :name)
                    ON CONFLICT (execution_segment_id) WHERE status = 'OPEN' DO NOTHING
                    """).setParameter("id", candidate).setParameter("segment", segmentId)
                    .setParameter("analysis", analysisId).setParameter("kinds", current.size())
                    .setParameter("summary", summary).setParameter("actor", actor)
                    .setParameter("name", actorName).executeUpdate();
            if (inserted == 1) {
                urgeId = candidate;
                break;
            }
            // 冷却按数据库时钟比较(last_urged_at 也是数据库 now())，不受应用服务器时钟偏差影响。
            List<Object[]> open = NativeQueryResults.objectArrayRows(em.createNativeQuery("""
                    SELECT id, last_urged_at + make_interval(mins => :cooldown) > now()
                    FROM production_planning_urges
                    WHERE execution_segment_id = :segment AND status = 'OPEN'
                    FOR UPDATE
                    """).setParameter("segment", segmentId)
                    .setParameter("cooldown", (int) COOLDOWN.toMinutes()));
            if (open.isEmpty()) continue;
            UUID existing = (UUID) open.getFirst()[0];
            if (Boolean.TRUE.equals(open.getFirst()[1])) {
                // 刚催过：不再打扰计划员，如实告诉车间什么时候可以再催。
                return result(existing, false);
            }
            em.createNativeQuery("""
                    UPDATE production_planning_urges
                    SET urge_count = urge_count + 1, gap_kind_count = :kinds, gap_summary = :summary,
                        last_urged_by = :actor, last_urged_by_name = :name,
                        last_urged_at = now(), updated_at = now()
                    WHERE id = :id AND status = 'OPEN'
                    """).setParameter("kinds", current.size()).setParameter("summary", summary)
                    .setParameter("actor", actor).setParameter("name", actorName)
                    .setParameter("id", existing).executeUpdate();
            urgeId = existing;
        }
        if (urgeId == null) {
            throw new ApiException(ErrorCode.CONFLICT, "刚好有人在同时处理这条催办，请稍后再试");
        }
        Number count = (Number) em.createNativeQuery(
                "SELECT urge_count FROM production_planning_urges WHERE id = :id")
                .setParameter("id", urgeId).getSingleResult();
        // 每一次有效的催都要送到计划员：去重键带上次数，重放同一次不会发两遍。
        events.publishOnce(EVENT_URGED, AGGREGATE_KIND, urgeId, Map.of("urgeCount", count.intValue()),
                EVENT_URGED + ":" + urgeId + ":" + count.intValue());
        return result(urgeId, true);
    }

    /** 本分析上的在催记录逐条核对一次(计划员下单后由物料分析页触发)。返回办结条数。 */
    @Transactional
    public int reconcileAnalysis(UUID analysisId) {
        tx.bind();
        return reconcile(openUrges("urge.material_analysis_id = :scope", analysisId, 200));
    }

    /**
     * 后台兜底的候选：最久没核对的一批在催记录，按物料分析分组——核对任务每组开一个事务，
     * 一份分析算不出来或太慢，只影响这一组，不拖住整批。
     */
    @Transactional(readOnly = true)
    public List<List<UUID>> openUrgeBatches(int limit) {
        Map<UUID, List<UUID>> byAnalysis = new LinkedHashMap<>();
        for (Object[] row : NativeQueryResults.objectArrayRows(em.createNativeQuery("""
                SELECT urge.id, urge.material_analysis_id
                FROM production_planning_urges urge
                WHERE urge.status = 'OPEN'
                ORDER BY urge.updated_at, urge.id
                LIMIT :limit
                """).setParameter("limit", Math.max(1, limit)))) {
            byAnalysis.computeIfAbsent((UUID) row[1], ignored -> new ArrayList<>()).add((UUID) row[0]);
        }
        return List.copyOf(byAnalysis.values());
    }

    /** 核对指定的几条在催记录(同一份分析)。返回办结条数。 */
    @Transactional
    public int reconcileUrges(List<UUID> urgeIds) {
        tx.bind();
        if (urgeIds == null || urgeIds.isEmpty()) return 0;
        return reconcile(openUrges("urge.id IN (:scope)", urgeIds, urgeIds.size()));
    }

    /** 这几条这轮没核对成(分析算不出来 / 超时)：排到队尾，下一轮先看别的。 */
    @Transactional
    public void deferUrges(List<UUID> urgeIds) {
        if (urgeIds == null || urgeIds.isEmpty()) return;
        em.createNativeQuery("UPDATE production_planning_urges SET updated_at = now() WHERE id IN (:ids) AND status = 'OPEN'")
                .setParameter("ids", urgeIds).executeUpdate();
    }

    private List<OpenUrge> openUrges(String predicate, Object scope, int limit) {
        var query = em.createNativeQuery("""
                SELECT urge.id, urge.execution_segment_id,
                       segment.status, segment.is_deleted
                FROM production_planning_urges urge
                JOIN production_execution_segments segment ON segment.id = urge.execution_segment_id
                WHERE urge.status = 'OPEN' AND %s
                ORDER BY urge.updated_at, urge.id
                LIMIT :limit
                """.formatted(predicate)).setParameter("limit", limit);
        if (scope != null) query.setParameter("scope", scope);
        List<OpenUrge> result = new ArrayList<>();
        for (Object[] row : NativeQueryResults.objectArrayRows(query)) {
            boolean active = !Boolean.TRUE.equals(row[3]) && ACTIVE_SEGMENT_STATUSES.contains((String) row[2]);
            result.add(new OpenUrge((UUID) row[0], (UUID) row[1], active));
        }
        return result;
    }

    private int reconcile(List<OpenUrge> urges) {
        if (urges.isEmpty()) return 0;
        List<UUID> activeSegments = urges.stream().filter(OpenUrge::active).map(OpenUrge::segmentId).toList();
        WorkshopPlanningGapReadPort.PlanningGaps current = activeSegments.isEmpty()
                ? WorkshopPlanningGapReadPort.PlanningGaps.NONE : gaps.freshPlanningGaps(activeSegments);
        int resolved = 0;
        List<UUID> stillOpen = new ArrayList<>();
        for (OpenUrge urge : urges) {
            // 分析读不出来 = 不知道计划下没下单：保持在催，不当成「已下够单」撤卡。
            String resolution = !urge.active() ? "TASK_CLOSED"
                    : current.isUnknown(urge.segmentId()) ? null
                    : current.of(urge.segmentId()).isEmpty() ? "ARRANGED" : null;
            if (resolution == null) {
                stillOpen.add(urge.id());
                continue;
            }
            int updated = em.createNativeQuery("""
                    UPDATE production_planning_urges
                    SET status = 'RESOLVED', resolution = :resolution, resolved_at = now(), updated_at = now()
                    WHERE id = :id AND status = 'OPEN'
                    """).setParameter("resolution", resolution).setParameter("id", urge.id()).executeUpdate();
            if (updated == 1) {
                notices.resolveReviewNotices(AGGREGATE_KIND, urge.id(), resolution);
                resolved++;
            }
        }
        if (!stillOpen.isEmpty()) {
            // 核对过、仍在催的排到队尾，后台下一轮先看别的。
            em.createNativeQuery("UPDATE production_planning_urges SET updated_at = now() WHERE id IN (:ids) AND status = 'OPEN'")
                    .setParameter("ids", stillOpen).executeUpdate();
        }
        return resolved;
    }

    private UrgeResult result(UUID urgeId, boolean notified) {
        Object[] row = (Object[]) em.createNativeQuery("""
                SELECT execution_segment_id, urge_count, last_urged_at, gap_kind_count, gap_summary
                FROM production_planning_urges WHERE id = :id
                """).setParameter("id", urgeId).getSingleResult();
        OffsetDateTime last = NativeValueConverters.toOffsetDateTime(row[2]);
        return new UrgeResult(urgeId, (UUID) row[0], notified, ((Number) row[1]).intValue(), last,
                last == null ? null : last.plus(COOLDOWN), ((Number) row[3]).intValue(), (String) row[4]);
    }

    private Object[] segmentRow(UUID segmentId) {
        List<Object[]> rows = NativeQueryResults.objectArrayRows(em.createNativeQuery("""
                SELECT segment.id, segment.status, plan.material_analysis_id
                FROM production_execution_segments segment
                JOIN production_plans plan ON plan.id = segment.plan_id AND NOT plan.is_deleted
                WHERE segment.id = :id AND NOT segment.is_deleted
                """).setParameter("id", segmentId));
        return rows.isEmpty() ? null : rows.getFirst();
    }

    /** 「铜片 800 个、弹簧 1000 个等 5 种」：给计划员的通知正文用，只是快照。 */
    static String summary(List<Gap> current) {
        Map<String, String> named = new LinkedHashMap<>();
        for (Gap gap : current) {
            String name = gap.goodsName() == null || gap.goodsName().isBlank()
                    ? Objects.toString(gap.goodsCode(), "物料") : gap.goodsName().strip();
            String colour = gap.colorName() == null || gap.colorName().isBlank() ? "" : "(" + gap.colorName().strip() + ")";
            named.putIfAbsent(name + colour, name + colour + " " + quantity(gap.gapQty())
                    + Objects.toString(gap.unitName(), ""));
        }
        List<String> parts = new ArrayList<>(named.values());
        String text = String.join("、", parts.subList(0, Math.min(SUMMARY_NAMES, parts.size())));
        if (parts.size() > SUMMARY_NAMES) text += " 等 " + parts.size() + " 种";
        return text.length() > 480 ? text.substring(0, 480) + "…" : text;
    }

    /** 数量本身是 numeric(18,4)：只去掉末尾的 0，不做任何舍入。 */
    private static String quantity(BigDecimal value) {
        if (value == null || value.signum() == 0) return "0";
        return value.stripTrailingZeros().toPlainString();
    }

    private String operatorName() {
        UUID employeeId = currentUser.employeeId().orElse(null);
        if (employeeId != null) {
            List<String> names = NativeQueryResults.typedRows(em.createNativeQuery(
                    "SELECT full_name FROM employees WHERE id = :id AND NOT is_deleted")
                    .setParameter("id", employeeId), String.class);
            if (!names.isEmpty() && names.getFirst() != null && !names.getFirst().isBlank()) {
                return truncate(names.getFirst().strip());
            }
        }
        return truncate(currentUser.get().map(AuthUser::getLoginAccount)
                .filter(account -> account != null && !account.isBlank()).orElse("管理员"));
    }

    private static String truncate(String value) {
        return value.length() > 100 ? value.substring(0, 100) : value;
    }

    private record OpenUrge(UUID id, UUID segmentId, boolean active) {
    }

    /**
     * 催计划的结果。
     *
     * @param notified false = 30 分钟内刚催过，本次没有再打扰计划员
     */
    public record UrgeResult(UUID urgeId, UUID segmentId, boolean notified, int urgeCount,
                             OffsetDateTime lastUrgedAt, OffsetDateTime nextUrgeAllowedAt,
                             int gapKindCount, String gapSummary) {
    }
}
