package com.uten.imp.features.warehouse.materialbin.close;

import com.fasterxml.jackson.core.JsonProcessingException;
import com.fasterxml.jackson.core.type.TypeReference;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.application.port.WorkshopMaterialNoticePort;
import com.uten.imp.application.port.WorkshopMaterialNoticePort.Blocker;
import com.uten.imp.common.util.NativeValueConverters;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.stock.valuation.WorkshopMaterialCostService;
import com.uten.imp.features.warehouse.materialbin.WorkshopMaterialCommandLedger;
import com.uten.imp.features.warehouse.materialbin.WorkshopMaterialCommandLedger.Outcome;
import com.uten.imp.features.warehouse.materialbin.WorkshopMaterialPermissions;
import com.uten.imp.features.warehouse.materialbin.WorkshopMaterialScope;
import com.uten.imp.features.warehouse.materialbin.close.WorkshopMaterialAllocationCalculator.Basis;
import com.uten.imp.features.warehouse.materialbin.close.WorkshopMaterialAllocationCalculator.Share;
import com.uten.imp.features.warehouse.materialbin.close.WorkshopMaterialCloseDtos.CloseStatusView;
import com.uten.imp.features.warehouse.materialbin.close.WorkshopMaterialCloseDtos.LastClose;
import com.uten.imp.features.warehouse.materialbin.close.WorkshopMaterialCloseDtos.ReopenRequest;
import com.uten.imp.features.warehouse.materialbin.close.WorkshopMaterialCloseDtos.RetryRequest;
import com.uten.imp.security.SecurityContextCurrentUser;
import com.uten.imp.security.TxSessionVars;
import lombok.extern.slf4j.Slf4j;
import org.postgresql.util.PSQLException;
import org.springframework.jdbc.core.namedparam.MapSqlParameterSource;
import org.springframework.jdbc.core.namedparam.NamedParameterJdbcTemplate;
import org.springframework.stereotype.Service;
import org.springframework.transaction.PlatformTransactionManager;
import org.springframework.transaction.TransactionDefinition;
import org.springframework.transaction.annotation.Transactional;
import org.springframework.transaction.support.TransactionTemplate;

import java.math.BigDecimal;
import java.sql.Types;
import java.time.LocalDate;
import java.time.OffsetDateTime;
import java.time.ZoneOffset;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.LinkedHashMap;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Map;
import java.util.Objects;
import java.util.Set;
import java.util.TreeSet;
import java.util.UUID;
import java.util.stream.Collectors;

/**
 * 车间内料仓按期自动结算 (ADR-131 §5.8、§5.9; 规格 §2.5)。
 *
 * <p>{@link #attempt} 是单次结算尝试, 在自己的新事务里以指定操作人执行: 期间行排他锁 (取不到说明别处在结,
 * 直接返回) → 复核状态与保留期 → 三种拦结算的情况 (外加"等上一期结算") 有任一就标为被拦、通知该补的人 →
 * 否则写结算结果 (理论明细、每种料的处理方式、按成本范围分摊) → 价值移动 → 按成本范围刷新生产成本 →
 * 期间改为已结算。任何异常整体回滚后另起事务记失败; 连续失败 3 次通知设置负责人, 之后每天重试一次。
 *
 * <p>{@link #retry} ("立即重试"/"重新结算") 与 {@link #reopen} (撤销结算, 只撤成本不动数量) 是员工命令,
 * 走幂等账本; 结算本身一律在提交后由后台执行, 不在请求线程里同步结算。
 */
@Slf4j
@Service
public class WorkshopMaterialCloseService {

    /** 触发来源 (记在结算结果上)。 */
    public enum TriggerKind { AFTER_COUNT, SCHEDULED, MANUAL }

    /** 单次尝试的结果 (定时任务日志与测试用)。 */
    public enum Result { SKIPPED, BLOCKED, CLOSED, FAILED }

    /** 连续失败达到这个次数后通知设置负责人, 定时任务改为每天重试一次。 */
    static final int FAILURE_BACKOFF = 3;

    private static final TypeReference<List<Map<String, Object>>> BLOCKERS = new TypeReference<>() {};
    private static final List<String> BLOCKER_ORDER = List.of(
            WorkshopMaterialNoticePort.BLOCKER_PREVIOUS_PERIOD_OPEN, WorkshopMaterialNoticePort.BLOCKER_DRAFT_REPORT,
            WorkshopMaterialNoticePort.BLOCKER_MISSING_WEIGHT, WorkshopMaterialNoticePort.BLOCKER_THEORY_WITHOUT_STOCK);
    private static final int SAMPLE_LIMIT = 5;
    private static final String GENERIC_FAILURE = "结算时出现系统错误, 系统会自动重试";

    /** 一期 (结算只读这些列)。 */
    /** holding = 撤销结算后的 24 小时保留期还没到 (按库里时钟判断)。 */
    private record Period(UUID id, UUID binWarehouseId, UUID workshopDepartmentId, int no, LocalDate startDate,
                          LocalDate endDate, String status, String closeState, boolean holding,
                          long rowVersion) {}

    /** 期间用量行。 */
    private record Line(UUID id, UUID goodsId, UUID colorId, String costBasis, BigDecimal actualQty) {}

    /** 一行理论明细 (数量已按表列取 6 位)。 */
    private record Theory(UUID reportItemId, UUID reportId, LocalDate businessDate, UUID executionSegmentId,
                          UUID costScopeSegmentId, UUID productGoodsId, UUID periodicRowId, UUID materialGoodsId,
                          UUID materialColorId, BigDecimal outputQty, BigDecimal unitWeight, String weightSource,
                          BigDecimal theoryQty) {
        /** 零理论: 产量为 0 (例如返工补产), 这一行没有要记的理论用量。 */
        boolean zero() {
            return outputQty != null && outputQty.signum() == 0 || theoryQty != null && theoryQty.signum() == 0;
        }
    }

    /** 料的身份 (货品 + 颜色)。 */
    private record Material(UUID goodsId, UUID colorId) {}

    private final NamedParameterJdbcTemplate db;
    private final TransactionTemplate transactions;
    private final TxSessionVars session;
    private final WorkshopMaterialCostService costs;
    private final WorkshopMaterialNoticePort notices;
    private final WorkshopMaterialCommandLedger commands;
    private final WorkshopMaterialScope scope;
    private final WorkshopMaterialPermissions permissions;
    private final SecurityContextCurrentUser currentUser;
    private final WorkshopMaterialCloseTrigger trigger;
    private final ObjectMapper json;

    public WorkshopMaterialCloseService(NamedParameterJdbcTemplate db, PlatformTransactionManager transactionManager,
                                        TxSessionVars session, WorkshopMaterialCostService costs,
                                        WorkshopMaterialNoticePort notices, WorkshopMaterialCommandLedger commands,
                                        WorkshopMaterialScope scope, WorkshopMaterialPermissions permissions,
                                        SecurityContextCurrentUser currentUser, WorkshopMaterialCloseTrigger trigger,
                                        ObjectMapper json) {
        this.db = db;
        this.transactions = new TransactionTemplate(transactionManager);
        this.transactions.setPropagationBehavior(TransactionDefinition.PROPAGATION_REQUIRES_NEW);
        this.transactions.setTimeout(120);
        this.session = session;
        this.costs = costs;
        this.notices = notices;
        this.commands = commands;
        this.scope = scope;
        this.permissions = permissions;
        this.currentUser = currentUser;
        this.trigger = trigger;
        this.json = json;
    }

    // ================================================================== 单次结算尝试 (后台)

    /**
     * 单次结算尝试; 自开新事务, 以 actorUserId 为操作人。结算成功后若下一期已盘点、正排队或被"等上一期"
     * 拦着, 接着尝试下一期 (期间必须按顺序结算)。
     */
    public Result attempt(UUID periodId, TriggerKind triggerKind, UUID actorUserId) {
        if (periodId == null || actorUserId == null) return Result.SKIPPED;
        TriggerKind kind = triggerKind == null ? TriggerKind.SCHEDULED : triggerKind;
        Result result;
        try {
            result = transactions.execute(status -> attemptInTransaction(periodId, kind, actorUserId));
        } catch (RuntimeException error) {
            recordFailure(periodId, actorUserId, error);
            return Result.FAILED;
        }
        if (result == Result.CLOSED) {
            Map<String, Object> next = nextWaiting(periodId);
            if (next != null) {
                UUID nextActor = next.get("actor") == null ? actorUserId : (UUID) next.get("actor");
                attempt((UUID) next.get("id"), kind == TriggerKind.MANUAL ? TriggerKind.AFTER_COUNT : kind, nextActor);
            }
        }
        return result == null ? Result.SKIPPED : result;
    }

    private Result attemptInTransaction(UUID periodId, TriggerKind kind, UUID actor) {
        session.bindActor(actor);
        List<Period> locked = periods("period.id = :id", Map.of("id", periodId), " FOR UPDATE SKIP LOCKED");
        if (locked.isEmpty()) return Result.SKIPPED;
        Period period = locked.getFirst();
        if (!"COUNTED".equals(period.status())) return Result.SKIPPED;
        if (period.holding() && kind != TriggerKind.MANUAL) return Result.SKIPPED;
        List<Blocker> blockers = blockers(period.id());
        if (!blockers.isEmpty()) {
            db.update("""
                    UPDATE workshop_material_periods
                    SET close_state = 'BLOCKED', close_blockers = CAST(:blockers AS jsonb), close_failures = 0,
                        close_attempts = close_attempts + 1, close_attempted_at = now(), close_last_error = NULL,
                        held_until = NULL, row_version = row_version + 1
                    WHERE id = :id
                    """, new MapSqlParameterSource("blockers", blockersJson(blockers)).addValue("id", period.id()));
            notices.closeBlocked(period.id(), blockers);
            return Result.BLOCKED;
        }
        close(period, kind, actor);
        return Result.CLOSED;
    }

    /** 结算事务内容 (ADR-131 §5.8): 结果只追加, 提交时由库里的延迟断言整体核对。 */
    private void close(Period period, TriggerKind kind, UUID actor) {
        UUID closeId = UUID.randomUUID();
        Integer latest = db.queryForObject(
                "SELECT max(close_no) FROM workshop_material_period_closes WHERE period_id = :period",
                Map.of("period", period.id()), Integer.class);
        db.update("""
                INSERT INTO workshop_material_period_closes(id, period_id, close_no, trigger_kind, closed_by)
                VALUES (:id, :period, :no, :trigger, :actor)
                """, new MapSqlParameterSource("id", closeId).addValue("period", period.id())
                .addValue("no", (latest == null ? 0 : latest) + 1).addValue("trigger", kind.name())
                .addValue("actor", actor));

        List<Line> lines = lines(period.id());
        Map<Material, Line> lineByMaterial = new HashMap<>();
        for (Line line : lines) lineByMaterial.put(new Material(line.goodsId(), line.colorId()), line);
        List<Theory> theory = theory(period);

        // 每种料的理论合计与按成本范围的理论; 主料理论按成本范围合计是辅料的分摊基数。
        Map<UUID, BigDecimal> theoryByLine = new HashMap<>();
        Map<UUID, Map<UUID, BigDecimal>> theoryByLineScope = new HashMap<>();
        Map<UUID, BigDecimal> ownTheoryByScope = new LinkedHashMap<>();
        Set<UUID> scopes = new TreeSet<>((left, right) -> left.toString().compareTo(right.toString()));
        for (Theory row : theory) {
            Line line = lineByMaterial.get(new Material(row.materialGoodsId(), row.materialColorId()));
            // 零理论且这一期没盘到这种料: 没有可挂的结算料行, 也没有要记的理论 (与库里的覆盖核对同口径)。
            if (line == null && row.zero()) continue;
            if (line == null) {
                throw new ApiException(ErrorCode.CONFLICT, "「" + goodsLabel(row.materialGoodsId())
                        + "」有报工用到, 但这一期的盘点里没有这种料, 请更正盘点补上这种料的实盘数");
            }
            if (row.unitWeight() == null) {
                throw new ApiException(ErrorCode.CONFLICT, "「" + goodsLabel(row.productGoodsId())
                        + "」还没有填单个重量, 补好后系统会自动结算");
            }
            if (row.costScopeSegmentId() == null) {
                throw new ApiException(ErrorCode.CONFLICT, "有报工对应的工单找不到成本归属, 请联系系统管理员");
            }
            scopes.add(row.costScopeSegmentId());
            theoryByLine.merge(line.id(), row.theoryQty(), BigDecimal::add);
            theoryByLineScope.computeIfAbsent(line.id(), ignored -> new LinkedHashMap<>())
                    .merge(row.costScopeSegmentId(), row.theoryQty(), BigDecimal::add);
            if ("OWN".equals(line.costBasis())) {
                ownTheoryByScope.merge(row.costScopeSegmentId(), row.theoryQty(), BigDecimal::add);
            }
        }
        BigDecimal ownTheoryTotal = ownTheoryByScope.values().stream().reduce(BigDecimal.ZERO, BigDecimal::add);

        Map<UUID, UUID> materialByLine = new HashMap<>();
        Set<UUID> allocatedScopes = new TreeSet<>((left, right) -> left.toString().compareTo(right.toString()));
        for (Line line : lines) {
            UUID materialId = UUID.randomUUID();
            materialByLine.put(line.id(), materialId);
            BigDecimal actual = line.actualQty();
            BigDecimal theoryQty = null;
            BigDecimal basisQty = null;
            String outcome;
            BigDecimal consumed = BigDecimal.ZERO;
            BigDecimal loss = BigDecimal.ZERO;
            List<String> flags = new ArrayList<>();
            List<Basis> bases = new ArrayList<>();
            switch (line.costBasis()) {
                case "EXPENSE" -> outcome = "EXPENSED";
                case "SHARED" -> {
                    basisQty = ownTheoryTotal;
                    ownTheoryByScope.forEach((scopeId, qty) -> bases.add(new Basis(scopeId, qty)));
                    outcome = outcomeOf(actual, ownTheoryTotal);
                }
                default -> {
                    theoryQty = theoryByLine.getOrDefault(line.id(), BigDecimal.ZERO);
                    theoryByLineScope.getOrDefault(line.id(), Map.of())
                            .forEach((scopeId, qty) -> bases.add(new Basis(scopeId, qty)));
                    outcome = outcomeOf(actual, theoryQty);
                }
            }
            if ("ALLOCATED".equals(outcome)) consumed = actual;
            if ("UNALLOCATED_LOSS".equals(outcome)) {
                loss = actual;
                flags.add("ACTUAL_WITHOUT_THEORY");
            }
            insertMaterial(materialId, closeId, line, theoryQty, basisQty, outcome, consumed, loss, flags);
            if ("ALLOCATED".equals(outcome)) {
                List<Share> shares = WorkshopMaterialAllocationCalculator.allocate(consumed, bases);
                if (shares.isEmpty()) {
                    throw new ApiException(ErrorCode.CONFLICT, "「" + goodsLabel(line.goodsId())
                            + "」有理论用量却找不到可分摊的工单, 请联系系统管理员");
                }
                for (Share share : shares) {
                    allocatedScopes.add(share.costScopeSegmentId());
                    db.update("""
                            INSERT INTO workshop_material_close_allocations(
                                close_material_id, cost_scope_segment_id, basis_qty, allocated_qty, is_tail)
                            VALUES (:material, :scope, :basis, :allocated, :tail)
                            """, new MapSqlParameterSource("material", materialId)
                            .addValue("scope", share.costScopeSegmentId()).addValue("basis", share.basisQty())
                            .addValue("allocated", share.allocatedQty()).addValue("tail", share.tail()));
                }
            }
        }
        insertTheory(closeId, theory, lineByMaterial, materialByLine);

        // 刷新只对本次有分摊行的成本范围: 库里的刷新来源守卫只认"本次结算对这个成本范围有分摊"。
        costs.lockForClose(period.id(), scopes);
        costs.allocate(closeId, actor);
        costs.refresh(allocatedScopes, closeId, actor);

        db.update("""
                UPDATE workshop_material_periods
                SET status = 'CLOSED', close_state = 'NONE', close_blockers = '[]'::jsonb, close_failures = 0,
                    close_attempts = close_attempts + 1, close_attempted_at = now(), close_last_error = NULL,
                    held_until = NULL, row_version = row_version + 1
                WHERE id = :id
                """, Map.of("id", period.id()));
        notices.closeResolved(period.id());
    }

    /** 有实际有理论 → 分摊; 有实际没理论 → 损失; 实盘比账上多 → 盘盈; 正好用完 → 无。 */
    private static String outcomeOf(BigDecimal actual, BigDecimal basis) {
        if (actual.signum() > 0) return basis != null && basis.signum() > 0 ? "ALLOCATED" : "UNALLOCATED_LOSS";
        return actual.signum() < 0 ? "GAIN" : "NOTHING";
    }

    /**
     * 写一种料的结算结果。浪费率只算主料 (= (实际 - 理论) / 理论, 6 位) 并在库里算, 超出 [-30%, +50%] 标红;
     * 其它耗用超过期初加领入的一成标红; 盘盈按 0 核定价入库的标红。记车间费用与盘盈的结算时金额取盘点过账
     * 当时的价值; 分摊与损失的结算时金额由价值移动回写。
     */
    private void insertMaterial(UUID materialId, UUID closeId, Line line, BigDecimal theoryQty, BigDecimal basisQty,
                                String outcome, BigDecimal consumed, BigDecimal loss, List<String> flags) {
        MapSqlParameterSource params = new MapSqlParameterSource("id", materialId).addValue("close", closeId)
                .addValue("line", line.id()).addValue("outcome", outcome).addValue("consumed", consumed)
                .addValue("loss", loss).addValue("flags", String.join(",", flags));
        params.addValue("theory", theoryQty, Types.NUMERIC);
        params.addValue("basis", basisQty, Types.NUMERIC);
        db.update("""
                INSERT INTO workshop_material_close_materials(
                    id, close_id, period_line_id, cost_basis, theory_qty, allocation_basis_qty, outcome,
                    consumed_qty, loss_qty, waste_rate, flags, value_at_close)
                SELECT :id, :close, line.id, line.cost_basis, CAST(:theory AS numeric), CAST(:basis AS numeric),
                       :outcome, :consumed, :loss, computed.waste,
                       CAST(string_to_array(:flags, ',') AS text[])
                         || CASE WHEN computed.waste IS NOT NULL AND (computed.waste < -0.3 OR computed.waste > 0.5)
                                 THEN ARRAY['WASTE_OUT_OF_RANGE']::text[] ELSE ARRAY[]::text[] END
                         || CASE WHEN line.other_issue_qty > 0
                                      AND line.other_issue_qty > 0.1 * (line.opening_qty + line.transfer_in_qty)
                                 THEN ARRAY['OTHER_ISSUE_LARGE']::text[] ELSE ARRAY[]::text[] END
                         || CASE WHEN :outcome = 'GAIN' AND EXISTS (
                                     SELECT 1 FROM workshop_material_count_postings posting
                                     JOIN stock_value_events event
                                       ON event.movement_id = posting.movement_id AND event.operation = 'RECEIVE'
                                     WHERE posting.period_line_id = line.id AND posting.kind = 'GAIN'
                                       AND event.known_value_local = 0)
                                 THEN ARRAY['GAIN_PRICE_ZERO']::text[] ELSE ARRAY[]::text[] END,
                       CASE WHEN :outcome IN ('EXPENSED', 'GAIN') THEN (
                           SELECT COALESCE(sum(CASE WHEN posting.kind IN ('CONSUME', 'GAIN') THEN event.known_value_local
                                                    ELSE -event.known_value_local END), 0)
                           FROM workshop_material_count_postings posting
                           JOIN stock_value_events event
                             ON event.movement_id = posting.movement_id
                            AND event.operation IN ('ISSUE', 'RETURN_ISSUE', 'RECEIVE')
                           WHERE posting.period_line_id = line.id
                             AND posting.kind IN (CASE WHEN :outcome = 'GAIN' THEN 'GAIN' ELSE 'CONSUME' END,
                                                  CASE WHEN :outcome = 'GAIN' THEN 'GAIN_REVERSE' ELSE 'CONSUME_REVERSE' END))
                       END
                FROM workshop_material_period_lines line
                CROSS JOIN LATERAL (
                    SELECT CASE WHEN line.cost_basis = 'OWN' AND CAST(:theory AS numeric) > 0
                                THEN round((line.actual_qty - CAST(:theory AS numeric)) / CAST(:theory AS numeric), 6)
                           END AS waste) computed
                WHERE line.id = :line
                """, params);
    }

    /** 理论明细逐行写入 (可追到每行报工); 数量与表列同为 6 位, 与表上的核对式一致。 */
    private void insertTheory(UUID closeId, List<Theory> theory, Map<Material, Line> lineByMaterial,
                              Map<UUID, UUID> materialByLine) {
        List<MapSqlParameterSource> batch = new ArrayList<>(theory.size());
        for (Theory row : theory) {
            Line line = lineByMaterial.get(new Material(row.materialGoodsId(), row.materialColorId()));
            if (line == null) continue; // 零理论且没盘到这种料 (上面已核过, 其余没有料行的早已中止)
            batch.add(new MapSqlParameterSource("close", closeId)
                    .addValue("material", materialByLine.get(line.id()))
                    .addValue("item", row.reportItemId()).addValue("report", row.reportId())
                    .addValue("businessDate", row.businessDate()).addValue("segment", row.executionSegmentId())
                    .addValue("scope", row.costScopeSegmentId()).addValue("product", row.productGoodsId())
                    .addValue("row", row.periodicRowId()).addValue("output", row.outputQty())
                    .addValue("weight", row.unitWeight()).addValue("source", row.weightSource())
                    .addValue("theory", row.theoryQty()));
        }
        if (batch.isEmpty()) return;
        db.batchUpdate("""
                INSERT INTO workshop_material_close_theory_lines(
                    close_id, close_material_id, report_item_id, report_id, business_date, execution_segment_id,
                    cost_scope_segment_id, product_goods_id, periodic_row_id, output_qty_base, unit_weight,
                    weight_source, theory_qty)
                VALUES (:close, :material, :item, :report, :businessDate, :segment, :scope, :product, :row, :output,
                        :weight, :source, :theory)
                """, batch.toArray(new MapSqlParameterSource[0]));
    }

    private List<Theory> theory(Period period) {
        return db.query("""
                SELECT used.report_item_id, used.report_id, used.business_date, used.execution_segment_id,
                       used.cost_scope_segment_id, used.product_goods_id, used.periodic_row_id,
                       used.material_goods_id, used.material_color_id,
                       round(used.output_qty_base, 6) AS output_qty, round(used.unit_weight, 6) AS unit_weight,
                       used.weight_source,
                       round(round(used.output_qty_base, 6) * round(used.unit_weight, 6), 6) AS theory_qty
                FROM fn_workshop_material_period_theory(:bin, :from, :to) used
                ORDER BY used.material_goods_id, used.report_item_id, used.periodic_row_id
                """, new MapSqlParameterSource("bin", period.binWarehouseId()).addValue("from", period.startDate())
                .addValue("to", period.endDate()), (rs, index) -> new Theory(
                rs.getObject("report_item_id", UUID.class), rs.getObject("report_id", UUID.class),
                rs.getObject("business_date", LocalDate.class), rs.getObject("execution_segment_id", UUID.class),
                rs.getObject("cost_scope_segment_id", UUID.class), rs.getObject("product_goods_id", UUID.class),
                rs.getObject("periodic_row_id", UUID.class), rs.getObject("material_goods_id", UUID.class),
                rs.getObject("material_color_id", UUID.class), rs.getBigDecimal("output_qty"),
                rs.getBigDecimal("unit_weight"), rs.getString("weight_source"), rs.getBigDecimal("theory_qty")));
    }

    private List<Line> lines(UUID periodId) {
        return db.query("""
                SELECT line.id, line.goods_id, line.color_id, line.cost_basis, line.actual_qty
                FROM workshop_material_period_lines line
                WHERE line.period_id = :period
                ORDER BY line.id
                """, Map.of("period", periodId), (rs, index) -> new Line(rs.getObject("id", UUID.class),
                rs.getObject("goods_id", UUID.class), rs.getObject("color_id", UUID.class),
                rs.getString("cost_basis"), rs.getBigDecimal("actual_qty")));
    }

    // ================================================================== 拦结算的情况

    /** 拦结算的情况按种类汇总: 条数、前 5 个样例名称、责任人种类。 */
    private List<Blocker> blockers(UUID periodId) {
        List<Map<String, Object>> rows = db.queryForList("""
                SELECT blocker.kind, blocker.report_id, blocker.product_goods_id, blocker.material_goods_id,
                       blocker.material_color_id
                FROM fn_workshop_material_close_blockers(:period) blocker
                """, Map.of("period", periodId));
        if (rows.isEmpty()) return List.of();
        Map<String, Set<Object>> keys = new LinkedHashMap<>();
        for (Map<String, Object> row : rows) {
            String kind = (String) row.get("kind");
            Object key = switch (kind) {
                case WorkshopMaterialNoticePort.BLOCKER_DRAFT_REPORT -> row.get("report_id");
                case WorkshopMaterialNoticePort.BLOCKER_MISSING_WEIGHT -> row.get("product_goods_id");
                case WorkshopMaterialNoticePort.BLOCKER_THEORY_WITHOUT_STOCK ->
                        new Material((UUID) row.get("material_goods_id"), (UUID) row.get("material_color_id"));
                default -> kind;
            };
            keys.computeIfAbsent(kind, ignored -> new LinkedHashSet<>()).add(key);
        }
        List<Blocker> out = new ArrayList<>();
        for (String kind : BLOCKER_ORDER) {
            Set<Object> found = keys.get(kind);
            if (found == null || found.isEmpty()) continue;
            List<String> samples = switch (kind) {
                case WorkshopMaterialNoticePort.BLOCKER_DRAFT_REPORT -> reportNumbers(found);
                case WorkshopMaterialNoticePort.BLOCKER_MISSING_WEIGHT -> goodsNames(found);
                case WorkshopMaterialNoticePort.BLOCKER_THEORY_WITHOUT_STOCK -> materialNames(found);
                default -> List.of();
            };
            out.add(new Blocker(kind, found.size(), samples));
        }
        return out;
    }

    private List<String> reportNumbers(Set<Object> reports) {
        return db.queryForList("""
                SELECT COALESCE(NULLIF(btrim(report.bill_no), ''), '未编号')
                FROM production_daily_reports report
                WHERE report.id = ANY(CAST(string_to_array(:ids, ',') AS uuid[]))
                ORDER BY report.bill_date, report.bill_no
                LIMIT 5
                """, Map.of("ids", joined(reports)), String.class);
    }

    private List<String> goodsNames(Set<Object> goods) {
        return db.queryForList("""
                SELECT COALESCE(NULLIF(btrim(goods.name), ''), goods.code)
                FROM goods
                WHERE goods.id = ANY(CAST(string_to_array(:ids, ',') AS uuid[]))
                ORDER BY goods.code
                LIMIT 5
                """, Map.of("ids", joined(goods)), String.class);
    }

    private List<String> materialNames(Set<Object> materials) {
        List<String> out = new ArrayList<>();
        for (Object key : materials) {
            if (out.size() >= SAMPLE_LIMIT) break;
            Material material = (Material) key;
            MapSqlParameterSource params = new MapSqlParameterSource("goods", material.goodsId());
            params.addValue("color", material.colorId(), Types.OTHER);
            out.add(db.queryForObject("""
                    SELECT COALESCE(NULLIF(btrim(goods.name), ''), goods.code)
                           || COALESCE(' ' || (SELECT color.name FROM colors color
                                               WHERE color.id = CAST(:color AS uuid)), '')
                    FROM goods WHERE goods.id = :goods
                    """, params, String.class));
        }
        return out;
    }

    /** 页面与通知共用的 JSON: [{kind, count, responsible, samples}]。 */
    private String blockersJson(List<Blocker> blockers) {
        List<Map<String, Object>> rows = new ArrayList<>();
        for (Blocker blocker : blockers) {
            Map<String, Object> row = new LinkedHashMap<>();
            row.put("kind", blocker.kind());
            row.put("count", blocker.count());
            row.put("responsible", responsibleOf(blocker.kind()));
            row.put("samples", blocker.samples());
            rows.add(row);
        }
        try {
            return json.writeValueAsString(rows);
        } catch (JsonProcessingException error) {
            throw new IllegalStateException("结算拦截项无法记录", error);
        }
    }

    /** 谁来补 (页面直接显示给员工, 写人话); 等上一期结算不需要谁来补。 */
    private static String responsibleOf(String kind) {
        return switch (kind) {
            case WorkshopMaterialNoticePort.BLOCKER_DRAFT_REPORT -> "报工审核人或制单人";
            case WorkshopMaterialNoticePort.BLOCKER_MISSING_WEIGHT -> "BOM 维护人";
            case WorkshopMaterialNoticePort.BLOCKER_THEORY_WITHOUT_STOCK -> "仓库发料人或本车间认料的人";
            default -> null;
        };
    }

    // ================================================================== 失败记录

    /** 回滚后另起事务记失败; 连续失败刚到 3 次时通知设置负责人。记失败本身出错只写日志。 */
    private void recordFailure(UUID periodId, UUID actor, RuntimeException error) {
        String message = businessMessage(error);
        log.warn("车间内料仓结算未完成, 期间 {}, 错误类型 {}: {}", periodId, error.getClass().getSimpleName(), message);
        String stored = error.getClass().getSimpleName() + "|" + message;
        String truncated = stored.length() > 500 ? stored.substring(0, 500) : stored;
        try {
            transactions.executeWithoutResult(status -> {
                if (Boolean.TRUE.equals(db.queryForObject("SELECT EXISTS (SELECT 1 FROM users WHERE id = :id)",
                        Map.of("id", actor), Boolean.class))) {
                    session.bindActor(actor);
                }
                List<Integer> failures = db.queryForList("""
                        UPDATE workshop_material_periods
                        SET close_state = 'FAILED', close_last_error = :error, close_blockers = '[]'::jsonb,
                            close_attempts = close_attempts + 1, close_failures = close_failures + 1,
                            close_attempted_at = now(), held_until = NULL, row_version = row_version + 1
                        WHERE id = :id AND status = 'COUNTED'
                        RETURNING close_failures
                        """, new MapSqlParameterSource("error", truncated).addValue("id", periodId), Integer.class);
                if (!failures.isEmpty() && failures.getFirst() == FAILURE_BACKOFF) {
                    notices.closeFailing(periodId, message);
                }
            });
        } catch (RuntimeException recordError) {
            log.warn("车间内料仓结算失败未能记录, 期间 {}, 错误类型 {}", periodId,
                    recordError.getClass().getSimpleName());
        }
    }

    /** 只取给员工看的业务文案 (本功能的中文守卫与业务拒绝), 其余一律用通用文案, 不带程序信息。 */
    static String businessMessage(Throwable error) {
        int depth = 0;
        for (Throwable cause = error; cause != null && depth < 16; cause = cause.getCause(), depth++) {
            if (cause instanceof ApiException api && api.getMessage() != null && !api.getMessage().isBlank()) {
                return api.getMessage();
            }
            if (cause instanceof PSQLException postgres && "23514".equals(postgres.getSQLState())
                    && postgres.getServerErrorMessage() != null) {
                String constraint = postgres.getServerErrorMessage().getConstraint();
                String message = postgres.getServerErrorMessage().getMessage();
                if (message != null && constraint != null && (constraint.startsWith("workshop_material")
                        || constraint.startsWith("periodic_"))) {
                    return message;
                }
            }
        }
        return GENERIC_FAILURE;
    }

    // ================================================================== 员工命令: 立即重试 / 撤销结算

    /** "立即重试" / "重新结算": 标为排队, 本事务提交后在后台尝试 (不受每天一次的退避与 24 小时保留限制)。 */
    @Transactional
    public CloseStatusView retry(UUID periodId, RetryRequest request) {
        String key = request == null ? null : request.idempotencyKey();
        return commands.execute("CLOSE_RETRY", key, List.of(periodId, key == null ? "" : key), CloseStatusView.class,
                () -> {
                    Period loose = period(periodId);
                    scope.requireWorkshop(loose.workshopDepartmentId());
                    Period period = periods("period.id = :id", Map.of("id", periodId), " FOR UPDATE").getFirst();
                    if ("CLOSED".equals(period.status())) {
                        throw new ApiException(ErrorCode.CONFLICT, "这一期已经结算了");
                    }
                    if (!"COUNTED".equals(period.status())) {
                        throw new ApiException(ErrorCode.CONFLICT, "这一期还没提交盘点, 盘点提交后系统会自动结算");
                    }
                    db.update("""
                            UPDATE workshop_material_periods
                            SET close_state = 'QUEUED', held_until = NULL, row_version = row_version + 1
                            WHERE id = :id
                            """, Map.of("id", periodId));
                    trigger.request(periodId, currentUser.requireId(), TriggerKind.MANUAL);
                    return new Outcome<>(periodId, statusOf(periodId));
                });
    }

    /**
     * 撤销结算 (只能撤最近一期, 下一期还开着或正在盘点): 只撤成本、不动数量 — 分摊原路退回在制, 损失移回在制,
     * 按成本范围刷新; 本次结算标为已撤销; 期间回到已盘点并保留 24 小时 (期间不自动重结), 之后可更正盘点、
     * 补审或红冲报工、改单重, 改完点"重新结算"。
     */
    @Transactional
    public CloseStatusView reopen(UUID periodId, ReopenRequest request) {
        if (request == null) throw new ApiException(ErrorCode.VALIDATION_FAILED, "请写明撤销原因");
        String reason = request.reason() == null ? "" : request.reason().strip();
        if (reason.length() < 2 || reason.length() > 500) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "请写明撤销原因 (2 到 500 个字)");
        }
        return commands.execute("CLOSE_REOPEN", request.idempotencyKey(), List.of(periodId, request),
                CloseStatusView.class, () -> {
                    Period loose = period(periodId);
                    scope.requireWorkshop(loose.workshopDepartmentId());
                    db.queryForList("""
                            SELECT workshop_department_id FROM workshop_material_settings
                            WHERE workshop_department_id = :workshop FOR UPDATE
                            """, Map.of("workshop", loose.workshopDepartmentId()));
                    Period period = periods("period.id = :id", Map.of("id", periodId), " FOR UPDATE").getFirst();
                    if (request.expectedVersion() == null || request.expectedVersion() != period.rowVersion()) {
                        throw new ApiException(ErrorCode.CONFLICT, "这一期已被别人改过, 请刷新后再试");
                    }
                    if (!"CLOSED".equals(period.status())) {
                        throw new ApiException(ErrorCode.CONFLICT, "这一期还没有结算, 不用撤销");
                    }
                    if (!reopenable(period)) {
                        throw new ApiException(ErrorCode.CONFLICT,
                                "只能撤销最近一期的结算, 而且下一期还要是开着或正在盘点的");
                    }
                    UUID closeId = db.queryForObject("""
                            SELECT id FROM workshop_material_period_closes WHERE period_id = :period AND status = 'ACTIVE'
                            """, Map.of("period", periodId), UUID.class);
                    // 刷新来源守卫只认"这次结算对这个成本范围有分摊", 所以只刷新有分摊行的成本范围。
                    List<UUID> scopes = db.queryForList("""
                            SELECT DISTINCT allocation.cost_scope_segment_id
                            FROM workshop_material_close_allocations allocation
                            JOIN workshop_material_close_materials material
                              ON material.id = allocation.close_material_id
                            WHERE material.close_id = :close
                            """, Map.of("close", closeId), UUID.class);
                    UUID actor = currentUser.requireId();
                    UUID reversal = UUID.randomUUID();
                    costs.lockForClose(periodId, scopes);
                    costs.reverse(closeId, reversal, actor);
                    db.update("""
                            UPDATE workshop_material_close_allocations SET reversed_at = now()
                            WHERE reversed_at IS NULL AND close_material_id IN (
                                SELECT material.id FROM workshop_material_close_materials material
                                WHERE material.close_id = :close)
                            """, Map.of("close", closeId));
                    db.update("""
                            UPDATE workshop_material_period_closes
                            SET status = 'REVERSED', reversal_event_id = :reversal, reversed_by = :actor,
                                reversed_at = now(), reverse_reason = :reason
                            WHERE id = :close
                            """, new MapSqlParameterSource("reversal", reversal).addValue("actor", actor)
                            .addValue("reason", reason).addValue("close", closeId));
                    db.update("""
                            UPDATE workshop_material_periods
                            SET status = 'COUNTED', close_state = 'HELD', held_until = now() + interval '24 hours',
                                close_blockers = '[]'::jsonb, close_failures = 0, close_last_error = NULL,
                                row_version = row_version + 1
                            WHERE id = :id
                            """, Map.of("id", periodId));
                    costs.refresh(scopes, reversal, actor);
                    notices.closeResolved(periodId);
                    return new Outcome<>(periodId, statusOf(periodId));
                });
    }

    // ================================================================== 结算状态

    @Transactional(readOnly = true)
    public CloseStatusView status(UUID periodId) {
        Period period = period(periodId);
        scope.requireWorkshop(period.workshopDepartmentId());
        return statusOf(periodId);
    }

    private CloseStatusView statusOf(UUID periodId) {
        Map<String, Object> row = db.queryForMap("""
                SELECT period.id, period.bin_warehouse_id, period.workshop_department_id, period.period_no,
                       period.start_date, period.end_date, period.status, period.close_state, period.close_attempts,
                       period.close_failures, period.close_attempted_at, period.close_last_error,
                       CAST(period.close_blockers AS text) AS close_blockers, period.held_until, period.row_version
                FROM workshop_material_periods period WHERE period.id = :id
                """, Map.of("id", periodId));
        List<Map<String, Object>> closes = db.queryForList("""
                SELECT period_close.close_no, period_close.closed_at, period_close.trigger_kind,
                       COALESCE(employee.full_name, account.login_account) AS closed_by_name
                FROM workshop_material_period_closes period_close
                LEFT JOIN users account ON account.id = period_close.closed_by
                LEFT JOIN employees employee ON employee.id = account.employee_id
                WHERE period_close.period_id = :id AND period_close.status = 'ACTIVE'
                """, Map.of("id", periodId));
        LastClose last = closes.isEmpty() ? null : new LastClose(((Number) closes.getFirst().get("close_no")).intValue(),
                offset(closes.getFirst().get("closed_at")), (String) closes.getFirst().get("closed_by_name"),
                (String) closes.getFirst().get("trigger_kind"));
        String status = (String) row.get("status");
        Period period = period(periodId);
        List<String> actions = new ArrayList<>();
        if ("COUNTED".equals(status) && permissions.has(WorkshopMaterialPermissions.COUNT)) actions.add("CLOSE_RETRY");
        if ("CLOSED".equals(status) && permissions.has(WorkshopMaterialPermissions.REOPEN) && reopenable(period)) {
            actions.add("REOPEN");
        }
        String error = (String) row.get("close_last_error");
        String errorMessage = error == null ? null : error.substring(error.indexOf('|') + 1);
        return new CloseStatusView((UUID) row.get("id"), (UUID) row.get("bin_warehouse_id"),
                (UUID) row.get("workshop_department_id"), ((Number) row.get("period_no")).intValue(),
                NativeValueConverters.toLocalDate(row.get("start_date")), NativeValueConverters.toLocalDate(row.get("end_date")), status, (String) row.get("close_state"),
                ((Number) row.get("close_attempts")).intValue(), ((Number) row.get("close_failures")).intValue(),
                offset(row.get("close_attempted_at")), errorMessage, blockersOf((String) row.get("close_blockers")),
                offset(row.get("held_until")), last, ((Number) row.get("row_version")).longValue(), actions);
    }

    /** 最近一个已结算的期间, 且下一期还开着或正在盘点。 */
    private boolean reopenable(Period period) {
        Boolean ok = db.queryForObject("""
                SELECT NOT EXISTS (SELECT 1 FROM workshop_material_periods later
                                   WHERE later.bin_warehouse_id = :bin AND later.period_no > :no
                                     AND later.status IN ('COUNTED', 'CLOSED'))
                   AND EXISTS (SELECT 1 FROM workshop_material_periods following
                               WHERE following.bin_warehouse_id = :bin AND following.period_no = :no + 1
                                 AND following.status IN ('OPEN', 'COUNTING'))
                """, new MapSqlParameterSource("bin", period.binWarehouseId()).addValue("no", period.no()),
                Boolean.class);
        return Boolean.TRUE.equals(ok);
    }

    private List<Map<String, Object>> blockersOf(String stored) {
        if (stored == null || stored.isBlank()) return List.of();
        try {
            return json.readValue(stored, BLOCKERS);
        } catch (Exception error) {
            return List.of();
        }
    }

    // ================================================================== 读期间

    private Period period(UUID periodId) {
        if (periodId == null) throw new ApiException(ErrorCode.VALIDATION_FAILED, "请选择期间");
        List<Period> rows = periods("period.id = :id", Map.of("id", periodId), "");
        if (rows.isEmpty()) throw new ApiException(ErrorCode.NOT_FOUND, "这一期不存在");
        return rows.getFirst();
    }

    /** 下一期已盘点、正排队或被拦着 (多半是在等本期结算) 时返回它与它最新盘点单的提交人。 */
    private Map<String, Object> nextWaiting(UUID periodId) {
        List<Map<String, Object>> rows = db.queryForList("""
                SELECT following.id,
                       (SELECT counted.submitted_by FROM workshop_material_counts counted
                        WHERE counted.period_id = following.id AND counted.status = 'SUBMITTED'
                        ORDER BY counted.version DESC LIMIT 1) AS actor
                FROM workshop_material_periods current_period
                JOIN workshop_material_periods following
                  ON following.bin_warehouse_id = current_period.bin_warehouse_id
                 AND following.period_no = current_period.period_no + 1
                WHERE current_period.id = :id AND current_period.status = 'CLOSED'
                  AND following.status = 'COUNTED' AND following.close_state IN ('QUEUED', 'BLOCKED')
                """, Map.of("id", periodId));
        return rows.isEmpty() ? null : rows.getFirst();
    }

    private List<Period> periods(String where, Map<String, Object> params, String lock) {
        return db.query("""
                SELECT period.id, period.bin_warehouse_id, period.workshop_department_id, period.period_no,
                       period.start_date, period.end_date, period.status, period.close_state,
                       (period.close_state = 'HELD' AND period.held_until > now()) AS holding, period.row_version
                FROM workshop_material_periods period
                """ + " WHERE " + where + " " + lock, params, (rs, index) -> new Period(rs.getObject("id", UUID.class),
                rs.getObject("bin_warehouse_id", UUID.class), rs.getObject("workshop_department_id", UUID.class),
                rs.getInt("period_no"), rs.getObject("start_date", LocalDate.class),
                rs.getObject("end_date", LocalDate.class), rs.getString("status"), rs.getString("close_state"),
                rs.getBoolean("holding"), rs.getLong("row_version")));
    }

    private String goodsLabel(UUID goodsId) {
        List<String> names = db.queryForList(
                "SELECT COALESCE(NULLIF(btrim(name), ''), code) FROM goods WHERE id = :id",
                Map.of("id", goodsId), String.class);
        return names.isEmpty() ? "这种料" : names.getFirst();
    }

    private static String joined(Set<Object> ids) {
        return ids.stream().filter(Objects::nonNull).map(Object::toString).collect(Collectors.joining(","));
    }

    private static OffsetDateTime offset(Object value) {
        if (value == null) return null;
        if (value instanceof OffsetDateTime time) return time;
        if (value instanceof java.sql.Timestamp stamp) return stamp.toInstant().atOffset(ZoneOffset.UTC);
        if (value instanceof java.time.Instant instant) return instant.atOffset(ZoneOffset.UTC);
        return OffsetDateTime.parse(value.toString());
    }
}
