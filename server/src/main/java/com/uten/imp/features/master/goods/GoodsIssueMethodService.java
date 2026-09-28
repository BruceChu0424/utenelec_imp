package com.uten.imp.features.master.goods;

import com.uten.imp.application.port.MasterReferenceValidationPort;
import com.uten.imp.application.port.WorkshopMaterialChoicePort;
import com.uten.imp.common.web.ApiError;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.master.goods.dto.GoodsPeriodicMaterialDtos.ActiveChoice;
import com.uten.imp.features.master.goods.dto.GoodsPeriodicMaterialDtos.AffectedBomRow;
import com.uten.imp.features.master.goods.dto.GoodsPeriodicMaterialDtos.BinBalance;
import com.uten.imp.features.master.goods.dto.GoodsPeriodicMaterialDtos.InProgressSegment;
import com.uten.imp.features.master.goods.dto.GoodsPeriodicMaterialDtos.IssueMethodBatchRequest;
import com.uten.imp.features.master.goods.dto.GoodsPeriodicMaterialDtos.IssueMethodBatchResult;
import com.uten.imp.features.master.goods.dto.GoodsPeriodicMaterialDtos.IssueMethodItem;
import com.uten.imp.features.master.goods.dto.GoodsPeriodicMaterialDtos.IssueMethodItemResult;
import com.uten.imp.features.master.goods.dto.GoodsPeriodicMaterialDtos.IssueMethodPreview;
import com.uten.imp.features.master.goods.dto.GoodsPeriodicMaterialDtos.OpenPeriodUsage;
import com.uten.imp.features.master.goods.dto.GoodsPeriodicMaterialDtos.UnclearedDemand;
import com.uten.imp.features.master.goods.dto.GoodsPeriodicMaterialDtos.UnsettledTheory;
import com.uten.imp.security.SecurityContextCurrentUser;
import com.uten.imp.security.TxSessionVars;
import org.springframework.jdbc.core.namedparam.MapSqlParameterSource;
import org.springframework.jdbc.core.namedparam.NamedParameterJdbcTemplate;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.math.BigDecimal;
import java.math.MathContext;
import java.sql.Date;
import java.time.LocalDate;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.Objects;
import java.util.Set;
import java.util.UUID;

/**
 * 发料方式与分摊方式切换 (ADR-131 §4.1、§5.1 第 1 步; 规格 §1.2、§2.1)。
 *
 * <p>货品的发料方式 ({@code goods.issue_method}) 与分摊方式 ({@code periodic_cost_basis}) 只能经这里改:
 * 先预览 (受影响的 BOM 行、没清账的工单、内料仓账面、没结算期间的用量、在做的工单、会作废的认料),
 * 确认后一个事务完成: 设会话标记 {@code app.workshop_material_issue_method_switch} → <b>先改货品,
 * 再转换 BOM 行</b> (这样每条转换出来的行当场经过期间边形状守卫) → 需要时经认料端口作废认料 →
 * 当场核对数据库的切换断言 (提交时才查的延迟断言提前到这里, 拒绝原因原样交给员工)。
 *
 * <p>BOM 行怎么转换: 改为整批领料的主料 → 按每件的行改成单个重量 (开工前、基准产量 1、不设齐套门槛;
 * 基准产量不是 1 的折成每件用量), 按包装或固定批耗的要先人工改; 改为辅料或记车间费用 → 辅料不写进 BOM,
 * 这些行从 BOM 里去掉; 改回按工单领料 → 期间边恢复为开工前的齐套门槛。转换时把组件列列进 SET,
 * 让 BOM 接管触发器照常作废这些产品的认料 (产品第一次有期间边)。本服务不读写 BOM 学习表与学习列 (§1.20)。
 */
@Service
public class GoodsIssueMethodService {

    private static final String ACTION_CONVERT = "CONVERT";
    private static final String ACTION_KEEP = "KEEP";
    private static final String ACTION_REMOVE = "REMOVE";
    private static final String ACTION_RESTORE = "RESTORE";
    private static final String ACTION_BLOCKED = "BLOCKED";
    private static final Set<String> GATE_STAGES = Set.of("START", "ASSEMBLY", "FINISH");
    /** 预览里各清单最多列这么多条 (全量计数另算); 切换前提按全量判定。 */
    private static final int LIST_LIMIT = 200;

    private final NamedParameterJdbcTemplate db;
    private final TxSessionVars tx;
    private final SecurityContextCurrentUser currentUser;
    private final MasterReferenceValidationPort references;
    private final WorkshopMaterialChoicePort choices;
    private final GoodsPeriodicCommandLedger commands;
    private final GoodsBomService bom;
    private final GoodsRepository goodsRepo;

    public GoodsIssueMethodService(NamedParameterJdbcTemplate db, TxSessionVars tx,
                                   SecurityContextCurrentUser currentUser, MasterReferenceValidationPort references,
                                   WorkshopMaterialChoicePort choices, GoodsPeriodicCommandLedger commands,
                                   GoodsBomService bom, GoodsRepository goodsRepo) {
        this.db = db;
        this.tx = tx;
        this.currentUser = currentUser;
        this.references = references;
        this.choices = choices;
        this.commands = commands;
        this.bom = bom;
        this.goodsRepo = goodsRepo;
    }

    /** 货品当前的发料设置。 */
    private record GoodsRow(UUID id, String code, String name, long version, String issueMethod, String costBasis,
                            BigDecimal bulkPackageQty, boolean recycled, BigDecimal orderMultipleQty,
                            String unitName, boolean massUnit) {
        String label() {
            String text = ((code == null ? "" : code.strip()) + " " + (name == null ? "" : name.strip())).strip();
            return text.isEmpty() ? "这种料" : text;
        }
    }

    /** 一种料切换到目标设置时的完整核对结果 (预览与确认同一条路径)。 */
    private record Evaluation(GoodsRow goods, String targetMethod, String targetBasis,
                              List<AffectedBomRow> bomRows, List<UnclearedDemand> demands, int demandCount,
                              List<BinBalance> balances, List<OpenPeriodUsage> openPeriods,
                              List<UnsettledTheory> theory, List<InProgressSegment> inProgress, int inProgressCount,
                              List<ActiveChoice> activeChoices, List<String> blockers) {
        boolean toPeriodic() {
            return GoodsPeriodicMaterialRules.PERIODIC.equals(targetMethod)
                    && !GoodsPeriodicMaterialRules.PERIODIC.equals(goods.issueMethod());
        }

        boolean toOrder() {
            return GoodsPeriodicMaterialRules.ORDER.equals(targetMethod)
                    && GoodsPeriodicMaterialRules.PERIODIC.equals(goods.issueMethod());
        }

        boolean basisChanges() {
            return !Objects.equals(targetBasis, goods.costBasis());
        }

        /** 切换后是辅料或记车间费用 (而原来不是): BOM 行去掉、认料作废。 */
        boolean toShared() {
            return GoodsPeriodicMaterialRules.isSharedBasis(targetBasis) && basisChanges();
        }
    }

    // ================================================================ 预览

    /**
     * 切换预览。{@code costBasis} 为空时: 目标是整批领料且原来就是整批领料 → 沿用原分摊方式, 否则按主料。
     */
    @PreAuthorize("hasAuthority('goods:view')")
    @Transactional(readOnly = true)
    public IssueMethodPreview preview(UUID goodsId, String target, String costBasis) {
        references.requireVisibleGoods(goodsId);
        GoodsRow goods = goodsRows(List.of(goodsId), false).get(goodsId);
        if (goods == null) throw new ApiException(ErrorCode.NOT_FOUND, "货品不存在");
        String targetMethod = requireMethod(target);
        String targetBasis = targetBasis(goods, targetMethod, costBasis);
        Evaluation evaluation = evaluate(goods, targetMethod, targetBasis);
        return new IssueMethodPreview(goods.id(), goods.code(), goods.name(), goods.version(),
                goods.issueMethod(), goods.costBasis(), targetMethod, targetBasis,
                goods.unitName(), goods.massUnit(), goods.bulkPackageQty(), suggestedBulkPackageQty(goods),
                goods.recycled(), evaluation.bomRows(), evaluation.demands(), evaluation.balances(),
                evaluation.openPeriods(), evaluation.theory(), evaluation.inProgress(), evaluation.activeChoices(),
                evaluation.blockers(), evaluation.blockers().isEmpty());
    }

    // ================================================================ 确认切换

    /** 确认切换: 一次原子请求, 任何一种料不满足前提整批不改。 */
    @PreAuthorize("hasAuthority('goods:edit') and hasAuthority('goods:bom:edit')")
    @Transactional
    public IssueMethodBatchResult batch(IssueMethodBatchRequest request) {
        tx.bind();
        GoodsPeriodicCommandLedger.requireKey(request.idempotencyKey());
        return commands.execute("GOODS_ISSUE_METHOD", request.idempotencyKey(), request,
                IssueMethodBatchResult.class, () -> switchAll(request.items()));
    }

    private IssueMethodBatchResult switchAll(List<IssueMethodItem> items) {
        Map<UUID, IssueMethodItem> byGoods = new LinkedHashMap<>();
        for (IssueMethodItem item : items) {
            if (item == null || item.goodsId() == null) {
                throw new ApiException(ErrorCode.VALIDATION_FAILED, "请选择要切换的货品");
            }
            if (byGoods.putIfAbsent(item.goodsId(), item) != null) {
                throw new ApiException(ErrorCode.VALIDATION_FAILED, "同一个货品填了两次, 请合并");
            }
        }
        for (UUID id : byGoods.keySet()) references.requireVisibleGoods(id);
        // 锁序同 BOM 维护 (先父件、后组件): 先锁用到这些料的产品, 再按 id 顺序锁料本身; 料的行锁与
        // BOM 维护对组件的 KEY SHARE 锁互斥, 切换期间没人能往 BOM 里加这种料。
        List<UUID> parents = db.queryForList("""
                SELECT DISTINCT goods_id FROM goods_bom_items
                WHERE component_goods_id IN (:ids) AND is_deleted = FALSE
                """, Map.of("ids", List.copyOf(byGoods.keySet())), UUID.class);
        if (!parents.isEmpty()) goodsRepo.lockBomParents(parents);
        Map<UUID, GoodsRow> current = goodsRows(byGoods.keySet(), true);
        UUID actor = currentUser.requireId();

        List<Evaluation> evaluations = new ArrayList<>();
        List<ApiError.FieldError> problems = new ArrayList<>();
        for (IssueMethodItem item : byGoods.values()) {
            GoodsRow goods = current.get(item.goodsId());
            if (goods == null) throw new ApiException(ErrorCode.NOT_FOUND, "货品不存在或已删除");
            if (item.expectedVersion() == null || item.expectedVersion() != goods.version()) {
                throw new ApiException(ErrorCode.CONFLICT, "「" + goods.label() + "」已被别人改过, 请刷新后重试");
            }
            String targetMethod = requireMethod(item.issueMethod());
            String targetBasis = requestedBasis(goods, targetMethod, item.periodicCostBasis());
            requireBulkPackageQty(goods, item.bulkPackageQty());
            Evaluation evaluation = evaluate(goods, targetMethod, targetBasis);
            for (String blocker : evaluation.blockers()) {
                problems.add(new ApiError.FieldError(goods.label(), blocker));
            }
            evaluations.add(evaluation);
        }
        if (!problems.isEmpty()) {
            throw new ApiException(ErrorCode.CONFLICT, problems.size() == 1 ? problems.getFirst().message()
                    : "有 " + problems.size() + " 处不满足切换条件, 没有任何改动", problems);
        }

        db.queryForObject("SELECT set_config('app.workshop_material_issue_method_switch', 'on', true)",
                Map.of(), String.class);
        List<IssueMethodItemResult> results = new ArrayList<>();
        Set<UUID> recalcParents = new LinkedHashSet<>();
        for (Evaluation evaluation : evaluations) {
            results.add(apply(evaluation, byGoods.get(evaluation.goods().id()), actor, recalcParents));
        }
        // 提交时才查的切换断言提前到这里查, 拒绝原因原样交给员工。
        guarded(() -> db.getJdbcTemplate().execute("SET CONSTRAINTS trg_assert_goods_issue_method_switch IMMEDIATE"));
        // 用量变了 (折成每件) 或去掉了行的产品重算材料合计 (与 BOM 维护同一口径, 并通知等 BOM 的人)。
        if (!recalcParents.isEmpty()) goodsRepo.findAllById(recalcParents).forEach(bom::recalcSourceE);
        return new IssueMethodBatchResult(List.copyOf(results));
    }

    private IssueMethodItemResult apply(Evaluation evaluation, IssueMethodItem item, UUID actor,
                                        Set<UUID> recalcParents) {
        GoodsRow goods = evaluation.goods();
        BigDecimal bulk = item.bulkPackageQty() != null ? item.bulkPackageQty()
                : evaluation.toPeriodic() && goods.bulkPackageQty() == null
                ? suggestedBulkPackageQty(goods) : goods.bulkPackageQty();
        boolean recycled = item.isRecycledMaterial() == null ? goods.recycled() : item.isRecycledMaterial();
        // 先改货品: 之后转换出来的 BOM 行当场按整批领料的形状守卫核对。
        guarded(() -> db.update("""
                UPDATE goods
                SET issue_method = :method, periodic_cost_basis = :basis, bulk_package_qty = :bulk,
                    is_recycled_material = :recycled, version = version + 1,
                    updated_at = now(), updated_by = :actor
                WHERE id = :id
                """, new MapSqlParameterSource()
                .addValue("method", evaluation.targetMethod())
                .addValue("basis", evaluation.targetBasis())
                .addValue("bulk", bulk)
                .addValue("recycled", recycled)
                .addValue("actor", actor)
                .addValue("id", goods.id())));
        int superseded = 0;
        if (evaluation.toOrder() || evaluation.toShared()) {
            superseded = evaluation.activeChoices().size();
            guarded(() -> choices.supersedeForMaterial(goods.id(), WorkshopMaterialChoicePort.SUPERSEDE_ISSUE_METHOD_SWITCH));
        }
        int converted = 0;
        int removed = 0;
        int restored = 0;
        MapSqlParameterSource params = new MapSqlParameterSource("id", goods.id()).addValue("actor", actor);
        if (GoodsPeriodicMaterialRules.PERIODIC.equals(evaluation.targetMethod()) && evaluation.toShared()) {
            // 辅料不写进 BOM: 用到它的行从 BOM 里去掉。
            List<UUID> parents = guarded(() -> db.queryForList("""
                    UPDATE goods_bom_items
                    SET is_deleted = TRUE, deleted_at = now(), updated_at = now(), updated_by = :actor
                    WHERE component_goods_id = :id AND is_deleted = FALSE
                    RETURNING goods_id
                    """, params, UUID.class));
            removed = parents.size();
            recalcParents.addAll(parents);
        } else if (evaluation.toPeriodic()) {
            // 组件列列进 SET (值不变): 让 BOM 接管触发器照常作废这些产品的认料 (产品第一次有期间边)。
            List<Map<String, Object>> rows = guarded(() -> db.queryForList("""
                    UPDATE goods_bom_items
                    SET component_goods_id = component_goods_id,
                        control_stage = 'START', consumption_basis = 'PER_UNIT',
                        qty = round(qty / basis_output_qty, 5), basis_output_qty = 1,
                        hard_gate = FALSE, allow_partial_package = TRUE,
                        audited_at = NULL, audited_by = NULL,
                        updated_at = now(), updated_by = :actor
                    WHERE component_goods_id = :id AND is_deleted = FALSE
                    RETURNING goods_id
                    """, params));
            converted = rows.size();
            for (AffectedBomRow row : evaluation.bomRows()) {
                if (row.basisOutputQty() != null && row.basisOutputQty().compareTo(BigDecimal.ONE) != 0) {
                    recalcParents.add(row.productGoodsId());
                }
            }
        } else if (evaluation.toOrder()) {
            List<UUID> parents = guarded(() -> db.queryForList("""
                    UPDATE goods_bom_items
                    SET hard_gate = TRUE, audited_at = NULL, audited_by = NULL,
                        updated_at = now(), updated_by = :actor
                    WHERE component_goods_id = :id AND is_deleted = FALSE AND hard_gate = FALSE
                      AND control_stage IN ('START', 'ASSEMBLY', 'FINISH')
                    RETURNING goods_id
                    """, params, UUID.class));
            restored = parents.size();
        }
        return new IssueMethodItemResult(goods.id(), evaluation.targetMethod(), evaluation.targetBasis(), bulk,
                recycled, converted, removed, restored, superseded);
    }

    // ================================================================ 核对

    private Evaluation evaluate(GoodsRow goods, String targetMethod, String targetBasis) {
        boolean periodicTarget = GoodsPeriodicMaterialRules.PERIODIC.equals(targetMethod);
        boolean toPeriodic = periodicTarget && !GoodsPeriodicMaterialRules.PERIODIC.equals(goods.issueMethod());
        boolean toOrder = !periodicTarget && GoodsPeriodicMaterialRules.PERIODIC.equals(goods.issueMethod());
        boolean basisChanges = !Objects.equals(targetBasis, goods.costBasis());
        boolean toShared = GoodsPeriodicMaterialRules.isSharedBasis(targetBasis) && basisChanges;
        boolean anyChange = toPeriodic || toOrder || basisChanges;
        String material = goods.label();
        List<String> blockers = new ArrayList<>();

        if (toPeriodic && !goods.massUnit()) {
            blockers.add("「" + material + "」的基本单位是「" + Objects.toString(goods.unitName(), "未设置")
                    + "」, 不是重量单位。整批领料的料按重量记账, 请先把基本单位改成千克等重量单位");
        }

        List<AffectedBomRow> bomRows = (toPeriodic || toOrder || toShared)
                ? bomRows(goods, periodicTarget, toShared) : List.of();
        long blockedRows = bomRows.stream().filter(row -> ACTION_BLOCKED.equals(row.action())).count();
        if (blockedRows > 0) {
            blockers.add("有 " + blockedRows + " 行 BOM 里「" + material
                    + "」按包装、按批计量或基准产量折不成每件用量 (见标红的行), 请先把这些行改成按每件填单个重量");
        }

        List<UnclearedDemand> demands = List.of();
        int demandCount = 0;
        if (toPeriodic) {
            demands = unclearedDemands(goods.id());
            demandCount = countUnclearedDemands(goods.id());
            if (demandCount > 0) {
                blockers.add("还有 " + demandCount + " 张工单按工单领了「" + material
                        + "」、没有清账 (见下表), 请先做完这些工单或退料清账, 再改为整批领料");
            }
        }

        List<BinBalance> balances = anyChange ? binBalances(goods.id()) : List.of();
        if (!balances.isEmpty()) {
            BigDecimal total = balances.stream().map(BinBalance::qty).reduce(BigDecimal.ZERO, BigDecimal::add);
            blockers.add("车间内料仓里还有「" + material + "」" + total.stripTrailingZeros().toPlainString()
                    + Objects.toString(goods.unitName(), "") + ", 等内料仓用完、盘点结算后账面为 0 再改");
        }
        List<OpenPeriodUsage> openPeriods = anyChange ? openPeriods(goods.id()) : List.of();
        if (!openPeriods.isEmpty()) {
            blockers.add("「" + material + "」在还没结算的内料仓期间里有进出或盘点, 等这些期间结算后再改");
        }
        List<UnsettledTheory> theory = toOrder ? unsettledTheory(goods.id()) : List.of();
        if (!theory.isEmpty()) {
            blockers.add("还没结算的日子里有产品按「" + material + "」算了理论用量, 等这些期间结算后再改");
        }
        List<InProgressSegment> inProgress = List.of();
        int inProgressCount = 0;
        if (toOrder || toShared) {
            inProgress = inProgressSegments(goods.id());
            inProgressCount = countInProgressSegments(goods.id());
            if (inProgressCount > 0) {
                blockers.add("还有 " + inProgressCount + " 张在做的工单按整批领料用着「" + material
                        + "」, 做完或换料后再改");
            }
        }
        List<ActiveChoice> activeChoices = (toOrder || toShared) ? activeChoices(goods.id()) : List.of();
        return new Evaluation(goods, targetMethod, targetBasis, bomRows, demands, demandCount, balances,
                openPeriods, theory, inProgress, inProgressCount, activeChoices, List.copyOf(blockers));
    }

    /** 用到这种料的 BOM 行及切换时的处理。 */
    private List<AffectedBomRow> bomRows(GoodsRow goods, boolean periodicTarget, boolean toShared) {
        BigDecimal gramsPerUnit = GoodsPeriodicMaterialRules.gramsPerUnit(goods.unitName());
        List<AffectedBomRow> out = new ArrayList<>();
        for (Map<String, Object> row : db.queryForList("""
                SELECT bom.id, bom.goods_id, parent.code, parent.name, bom.qty, bom.basis_output_qty,
                       bom.control_stage, bom.consumption_basis, bom.hard_gate
                FROM goods_bom_items bom
                JOIN goods parent ON parent.id = bom.goods_id
                WHERE bom.component_goods_id = :id AND bom.is_deleted = FALSE
                ORDER BY parent.code, bom.id
                """, Map.of("id", goods.id()))) {
            BigDecimal qty = decimal(row.get("qty"));
            BigDecimal basis = decimal(row.get("basis_output_qty"));
            String stage = (String) row.get("control_stage");
            String consumption = (String) row.get("consumption_basis");
            boolean hardGate = Boolean.TRUE.equals(row.get("hard_gate"));
            String action;
            String note;
            BigDecimal each = qty;
            BigDecimal converted = periodicTarget && "PER_UNIT".equals(consumption) ? perUnit(qty, basis) : null;
            if (periodicTarget && toShared) {
                action = ACTION_REMOVE;
                note = "辅料不写进 BOM, 切换时从这个产品的 BOM 里去掉, 按当期主料用量分到各产品";
            } else if (periodicTarget) {
                if (!"PER_UNIT".equals(consumption)) {
                    action = ACTION_BLOCKED;
                    note = "按包装或固定批耗计量, 请先在这个产品的 BOM 里改成按每件填单个重量";
                } else if (converted == null) {
                    action = ACTION_BLOCKED;
                    note = "基准产量折不成每件用量, 请先在这个产品的 BOM 里改成按每件填单个重量";
                } else if ("START".equals(stage) && !hardGate && basis.compareTo(BigDecimal.ONE) == 0) {
                    action = ACTION_KEEP;
                    note = "已经是单个重量, 不用改";
                } else {
                    action = ACTION_CONVERT;
                    note = "改成开工前按每件的单个重量, 不设齐套门槛";
                    each = converted;
                }
            } else if (GATE_STAGES.contains(stage) && !hardGate) {
                action = ACTION_RESTORE;
                note = "改回按工单领料, 恢复为开工前的齐套门槛";
            } else {
                action = ACTION_KEEP;
                note = "不用改";
            }
            out.add(new AffectedBomRow((UUID) row.get("id"), (UUID) row.get("goods_id"), (String) row.get("code"),
                    (String) row.get("name"), qty, basis, stage, consumption, hardGate,
                    GoodsPeriodicMaterialRules.toGrams(each, gramsPerUnit), action, note));
        }
        return out;
    }

    /** 每件用量 = 用量 / 基准产量; 5 位小数内除不尽返回 null (要人工改)。 */
    private static BigDecimal perUnit(BigDecimal qty, BigDecimal basis) {
        if (qty == null || basis == null || basis.signum() <= 0) return null;
        BigDecimal value = qty.divide(basis, MathContext.DECIMAL128).stripTrailingZeros();
        if (value.signum() <= 0 || value.scale() > GoodsPeriodicMaterialRules.QTY_SCALE) return null;
        return value;
    }

    private static final String UNCLEARED_DEMANDS_FROM = """
            FROM production_material_demands demand
            JOIN production_plans plan ON plan.id = demand.plan_id
            LEFT JOIN production_execution_segments segment ON segment.id = demand.execution_segment_id
            LEFT JOIN goods product ON product.id = segment.product_goods_id
            """;
    private static final String UNCLEARED_DEMANDS_WHERE = """
            WHERE demand.goods_id = :id AND demand.is_deleted = FALSE
              AND demand.status NOT IN ('RELEASED', 'REVERSED')
              AND fn_material_demand_uncleared(demand.id)
            """;
    /** 已领、已退、已清账、在制: 聚合口径与 fn_material_demand_uncleared 相同。 */
    private static final String DEMAND_POSTINGS = """
            LEFT JOIN LATERAL (
                SELECT sum(CASE posting_type WHEN 'ISSUE' THEN qty_base WHEN 'ISSUE_REVERSE' THEN -qty_base ELSE 0 END) AS issued,
                       sum(CASE posting_type WHEN 'GOOD_RETURN' THEN qty_base WHEN 'GOOD_RETURN_REVERSE' THEN -qty_base ELSE 0 END) AS returned
                FROM production_material_stock_postings
                WHERE demand_id = demand.id) stock ON TRUE
            LEFT JOIN LATERAL (
                SELECT sum(CASE WHEN posting.settlement_type = 'CONSUMED' THEN CASE event.event_type WHEN 'POST' THEN posting.qty_base ELSE -posting.qty_base END ELSE 0 END) AS consumed,
                       sum(CASE WHEN posting.settlement_type = 'APPROVED_LOSS' THEN CASE event.event_type WHEN 'POST' THEN posting.qty_base ELSE -posting.qty_base END ELSE 0 END) AS loss,
                       sum(CASE WHEN posting.settlement_type = 'LEGAL_WIP' THEN CASE event.event_type WHEN 'POST' THEN posting.qty_base ELSE -posting.qty_base END ELSE 0 END) AS wip
                FROM production_material_settlement_postings posting
                JOIN production_material_settlement_events event ON event.id = posting.event_id
                WHERE posting.demand_id = demand.id) settled ON TRUE
            """;

    /** 没核清的按单需求 (口径只认 fn_material_demand_uncleared), 逐条列工单号、差多少没清。 */
    private List<UnclearedDemand> unclearedDemands(UUID goodsId) {
        List<UnclearedDemand> out = new ArrayList<>();
        String sql = """
                SELECT demand.id, demand.status, demand.required_qty, plan.bill_no, segment.segment_code,
                       product.code AS product_code, product.name AS product_name,
                       COALESCE(stock.issued, 0) AS issued, COALESCE(stock.returned, 0) AS returned,
                       COALESCE(settled.consumed, 0) + COALESCE(settled.loss, 0) AS settled,
                       COALESCE(settled.wip, 0) AS wip
                """ + UNCLEARED_DEMANDS_FROM + DEMAND_POSTINGS + UNCLEARED_DEMANDS_WHERE
                + "ORDER BY plan.bill_no, segment.segment_code, demand.id LIMIT " + LIST_LIMIT;
        for (Map<String, Object> row : db.queryForList(sql, Map.of("id", goodsId))) {
            String status = (String) row.get("status");
            BigDecimal issued = decimal(row.get("issued"));
            BigDecimal returned = decimal(row.get("returned"));
            BigDecimal settled = decimal(row.get("settled"));
            BigDecimal wip = decimal(row.get("wip"));
            BigDecimal uncleared = issued.subtract(returned).subtract(settled);
            String note;
            if (!"FULFILLED".equals(status)) {
                note = "这张工单的料还没领齐或还在备料, 做完或撤销后才算清账";
            } else if (uncleared.signum() != 0) {
                note = "已领 " + plain(issued) + "、已退 " + plain(returned) + "、已清账 " + plain(settled)
                        + ", 还有 " + plain(uncleared) + " 没清账, 请退料或完工清账";
            } else if (wip.signum() != 0) {
                note = "还有 " + plain(wip) + " 算在在制里, 请完工清账";
            } else {
                note = "还有待退回的料, 请先办完退料";
            }
            out.add(new UnclearedDemand((UUID) row.get("id"), (String) row.get("bill_no"),
                    (String) row.get("segment_code"), (String) row.get("product_code"),
                    (String) row.get("product_name"), status, decimal(row.get("required_qty")), issued, returned,
                    settled, wip, uncleared, note));
        }
        return out;
    }

    private int countUnclearedDemands(UUID goodsId) {
        Integer count = db.queryForObject("SELECT count(*) " + UNCLEARED_DEMANDS_FROM + UNCLEARED_DEMANDS_WHERE,
                Map.of("id", goodsId), Integer.class);
        return count == null ? 0 : count;
    }

    /** 车间内料仓 (线边仓) 里这种料的账面, 不为 0 的仓。 */
    private List<BinBalance> binBalances(UUID goodsId) {
        List<BinBalance> out = new ArrayList<>();
        for (Map<String, Object> row : db.queryForList("""
                SELECT warehouse.id, warehouse.name, sum(balance.qty) AS qty
                FROM stock_balances balance
                JOIN warehouses warehouse ON warehouse.id = balance.warehouse_id AND warehouse.is_line_side
                WHERE balance.goods_id = :id AND balance.qty <> 0
                GROUP BY warehouse.id, warehouse.name
                ORDER BY warehouse.name, warehouse.id
                """, Map.of("id", goodsId))) {
            out.add(new BinBalance((UUID) row.get("id"), (String) row.get("name"), decimal(row.get("qty"))));
        }
        return out;
    }

    /** 还没结算、有这种料的期间行或进出的内料仓期间。 */
    private List<OpenPeriodUsage> openPeriods(UUID goodsId) {
        List<OpenPeriodUsage> out = new ArrayList<>();
        for (Map<String, Object> row : db.queryForList("""
                SELECT period.id, period.bin_warehouse_id, warehouse.name, period.period_no,
                       period.start_date, period.end_date, period.status
                FROM workshop_material_periods period
                JOIN warehouses warehouse ON warehouse.id = period.bin_warehouse_id
                WHERE period.status <> 'CLOSED'
                  AND (EXISTS (SELECT 1 FROM workshop_material_period_lines line
                               WHERE line.period_id = period.id AND line.goods_id = :id)
                       OR EXISTS (SELECT 1 FROM v_workshop_material_bin_ledger ledger
                                  WHERE ledger.period_id = period.id AND ledger.goods_id = :id))
                ORDER BY warehouse.name, period.period_no
                """, Map.of("id", goodsId))) {
            out.add(new OpenPeriodUsage((UUID) row.get("id"), (UUID) row.get("bin_warehouse_id"),
                    (String) row.get("name"), ((Number) row.get("period_no")).intValue(),
                    date(row.get("start_date")), date(row.get("end_date")), (String) row.get("status")));
        }
        return out;
    }

    /** 各开启的内料仓已结算截止日之后, 按这种料算了理论用量的产品 (口径只认 fn_workshop_material_period_theory)。 */
    private List<UnsettledTheory> unsettledTheory(UUID goodsId) {
        List<UnsettledTheory> out = new ArrayList<>();
        for (Map<String, Object> row : db.queryForList("""
                SELECT settings.periodic_bin_warehouse_id AS bin, warehouse.name,
                       count(DISTINCT theory.product_goods_id) AS products,
                       COALESCE(sum(theory.theory_qty), 0) AS theory_qty
                FROM workshop_material_settings settings
                JOIN warehouses warehouse ON warehouse.id = settings.periodic_bin_warehouse_id
                CROSS JOIN LATERAL fn_workshop_material_period_theory(
                    settings.periodic_bin_warehouse_id,
                    fn_workshop_material_closed_through(settings.periodic_bin_warehouse_id) + 1,
                    'infinity'::date) theory
                WHERE settings.periodic_enabled AND theory.material_goods_id = :id
                GROUP BY settings.periodic_bin_warehouse_id, warehouse.name
                ORDER BY warehouse.name
                """, Map.of("id", goodsId))) {
            out.add(new UnsettledTheory((UUID) row.get("bin"), (String) row.get("name"),
                    ((Number) row.get("products")).intValue(), decimal(row.get("theory_qty"))));
        }
        return out;
    }

    private static final String IN_PROGRESS_FROM = """
            FROM production_execution_periodic_materials material_row
            JOIN production_execution_segments segment ON segment.id = material_row.execution_segment_id
            WHERE material_row.material_goods_id = :id AND material_row.effective_to IS NULL
              AND segment.status = 'IN_PROGRESS'
            """;

    private List<InProgressSegment> inProgressSegments(UUID goodsId) {
        List<InProgressSegment> out = new ArrayList<>();
        String sql = "SELECT segment.id, segment.segment_code, product.code, product.name "
                + "FROM (SELECT DISTINCT segment.id " + IN_PROGRESS_FROM + ") used "
                + "JOIN production_execution_segments segment ON segment.id = used.id "
                + "JOIN goods product ON product.id = segment.product_goods_id "
                + "ORDER BY segment.segment_code, segment.id LIMIT " + LIST_LIMIT;
        for (Map<String, Object> row : db.queryForList(sql, Map.of("id", goodsId))) {
            out.add(new InProgressSegment((UUID) row.get("id"), (String) row.get("segment_code"),
                    (String) row.get("code"), (String) row.get("name")));
        }
        return out;
    }

    private int countInProgressSegments(UUID goodsId) {
        Integer count = db.queryForObject("SELECT count(DISTINCT segment.id) " + IN_PROGRESS_FROM,
                Map.of("id", goodsId), Integer.class);
        return count == null ? 0 : count;
    }

    /** 认了这种料 (还有效) 的产品。 */
    private List<ActiveChoice> activeChoices(UUID goodsId) {
        List<ActiveChoice> out = new ArrayList<>();
        for (Map<String, Object> row : db.queryForList("""
                SELECT choice.product_goods_id, product.code, product.name, choice.also_order_materials
                FROM goods_periodic_material_choices choice
                JOIN goods product ON product.id = choice.product_goods_id
                WHERE choice.material_goods_id = :id AND choice.kind = 'MATERIAL' AND choice.superseded_at IS NULL
                ORDER BY product.code, choice.id
                """, Map.of("id", goodsId))) {
            out.add(new ActiveChoice((UUID) row.get("product_goods_id"), (String) row.get("code"),
                    (String) row.get("name"), Boolean.TRUE.equals(row.get("also_order_materials"))));
        }
        return out;
    }

    // ================================================================ 读取与校验

    private Map<UUID, GoodsRow> goodsRows(java.util.Collection<UUID> ids, boolean lock) {
        Map<UUID, GoodsRow> out = new LinkedHashMap<>();
        for (Map<String, Object> row : db.queryForList("""
                SELECT goods.id, goods.code, goods.name, goods.version, goods.issue_method, goods.periodic_cost_basis,
                       goods.bulk_package_qty, goods.is_recycled_material, goods.order_multiple_qty,
                       unit.name AS unit_name,
                       EXISTS (SELECT 1 FROM unit_measurement_profiles profile
                               WHERE profile.unit_id = goods.unit_id
                                 AND profile.measurement_dimension = 'MASS') AS mass_unit
                FROM goods goods
                LEFT JOIN units unit ON unit.id = goods.unit_id
                WHERE goods.id IN (:ids) AND goods.is_deleted = FALSE
                ORDER BY goods.id
                """ + (lock ? "FOR UPDATE OF goods" : ""), Map.of("ids", List.copyOf(ids)))) {
            UUID id = (UUID) row.get("id");
            out.put(id, new GoodsRow(id, (String) row.get("code"), (String) row.get("name"),
                    ((Number) row.get("version")).longValue(), (String) row.get("issue_method"),
                    (String) row.get("periodic_cost_basis"), (BigDecimal) row.get("bulk_package_qty"),
                    Boolean.TRUE.equals(row.get("is_recycled_material")),
                    (BigDecimal) row.get("order_multiple_qty"), (String) row.get("unit_name"),
                    Boolean.TRUE.equals(row.get("mass_unit"))));
        }
        return out;
    }

    private static String requireMethod(String value) {
        String method = value == null ? "" : value.strip().toUpperCase(Locale.ROOT);
        if (!GoodsPeriodicMaterialRules.ORDER.equals(method) && !GoodsPeriodicMaterialRules.PERIODIC.equals(method)) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "发料方式只能选按工单领料或整批领到车间内料仓");
        }
        return method;
    }

    /** 预览的目标分摊方式: 没指定时沿用原分摊方式 (原来就是整批领料), 否则按主料。 */
    private static String targetBasis(GoodsRow goods, String targetMethod, String costBasis) {
        if (!GoodsPeriodicMaterialRules.PERIODIC.equals(targetMethod)) return null;
        if (costBasis == null || costBasis.isBlank()) {
            return goods.costBasis() != null ? goods.costBasis() : GoodsPeriodicMaterialRules.OWN;
        }
        return requireBasis(costBasis);
    }

    /** 确认请求里的分摊方式: 整批领料必填, 按工单领料必须为空。 */
    private static String requestedBasis(GoodsRow goods, String targetMethod, String costBasis) {
        if (GoodsPeriodicMaterialRules.PERIODIC.equals(targetMethod)) {
            if (costBasis == null || costBasis.isBlank()) {
                throw new ApiException(ErrorCode.VALIDATION_FAILED,
                        "「" + goods.label() + "」改为整批领料, 请选分摊方式 (主料、辅料或记车间费用)");
            }
            return requireBasis(costBasis);
        }
        if (costBasis != null && !costBasis.isBlank()) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED,
                    "「" + goods.label() + "」按工单领料, 不用选分摊方式");
        }
        return null;
    }

    private static String requireBasis(String value) {
        String basis = value.strip().toUpperCase(Locale.ROOT);
        if (!GoodsPeriodicMaterialRules.COST_BASES.contains(basis)) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "分摊方式只能选主料、辅料或记车间费用");
        }
        return basis;
    }

    private static void requireBulkPackageQty(GoodsRow goods, BigDecimal value) {
        if (value == null) return;
        if (value.signum() <= 0 || value.stripTrailingZeros().scale() > 4 || value.precision() - value.scale() > 14) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED,
                    "「" + goods.label() + "」的每袋净重必须大于 0, 最多 4 位小数");
        }
    }

    /** 每袋净重预填: 已填的每袋净重, 没填时取整包装量 (订货倍数)。 */
    private static BigDecimal suggestedBulkPackageQty(GoodsRow goods) {
        if (goods.bulkPackageQty() != null) return goods.bulkPackageQty();
        BigDecimal multiple = goods.orderMultipleQty();
        return multiple != null && multiple.signum() > 0 ? multiple : null;
    }

    private static <T> T guarded(java.util.function.Supplier<T> action) {
        try {
            return action.get();
        } catch (RuntimeException error) {
            throw GoodsPeriodicMaterialRules.translate(error);
        }
    }

    private static void guarded(Runnable action) {
        guarded(() -> {
            action.run();
            return null;
        });
    }

    private static BigDecimal decimal(Object value) {
        if (value == null) return BigDecimal.ZERO;
        if (value instanceof BigDecimal decimal) return decimal;
        return new BigDecimal(value.toString());
    }

    private static LocalDate date(Object value) {
        if (value == null) return null;
        if (value instanceof LocalDate local) return local;
        if (value instanceof Date sql) return sql.toLocalDate();
        return LocalDate.parse(value.toString());
    }

    private static String plain(BigDecimal value) {
        return value.stripTrailingZeros().toPlainString();
    }
}
