package com.uten.imp.features.subcontract.kit;

import com.uten.imp.application.port.SubcontractOutboundWakePort;
import com.uten.imp.common.storage.ImmutableDocumentStore;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.subcontract.order.dto.OrderSaveRequest;
import lombok.RequiredArgsConstructor;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Propagation;
import org.springframework.transaction.annotation.Transactional;

import java.math.BigDecimal;
import java.math.RoundingMode;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.Collection;
import java.util.HashMap;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;
import java.util.UUID;

/**
 * ADR-156 委外申请物料齐套才解锁下单。
 *
 * <p>委外加工价每天不一样, 直属物料不齐时不让生成委外订货单; 现有物料够做一部分或全部时才解锁,
 * 而且只能按现有物料够做的套数下单。齐套数量只在库里算一处(V868 批量物料池权威; 旧单条入口 {@code fn_subcontract_application_kit_facts}
 * / {@code fn_subcontract_order_kit_shortages}), 这里只读:
 * <ul>
 *   <li>{@link #requireOrderKit}: 建单、改单、送审、批准、批准后加量的守卫, 不够就 409 点名缺哪种物料;</li>
 *   <li>{@link #applicationKit}: 任务中心「物料齐套情况」;</li>
 *   <li>{@link #orderableForSelection}: 从任务中心带单下单时, 所选申请按需求日期先后共用公共库存,
 *       算出每条申请这次最多能下多少(预填数量)。</li>
 * </ul>
 * 订货单变动(建、改、删、红冲、改量)会改变别的申请能下多少, 由 {@link #enqueueRecheckForOrder}
 * 按本单用到的直属物料追加「领料重算」outbox 事件, 投递时顺带重算这些物料相关申请的可下单提醒。
 */
@Service
@RequiredArgsConstructor
public class SubcontractKitService {

    private static final int SCALE = 4;

    private final JdbcTemplate jdbc;
    private final SubcontractOutboundWakePort drawRecheck;

    /** 一张委外申请明细逐种直属物料的齐套事实。 */
    public record MaterialFact(UUID goodsId, String goodsCode, String goodsName, UUID colorId, String colorName,
                               String unitName, BigDecimal bomUnitQty, BigDecimal neededQty,
                               BigDecimal exactQty, BigDecimal exactClaimedQty, BigDecimal exactFreeQty,
                               BigDecimal publicQty, BigDecimal publicClaimedQty, BigDecimal publicFreeQty,
                               BigDecimal freeQty, BigDecimal shortQty, BigDecimal kitQty) {
    }

    /**
     * 委外申请明细的齐套情况: 剩余未下单数量、现有物料够做的套数、这次可下单数量(两者取小)
     * 与逐种物料明细。{@code bomMissing} 时没有物料行, 可下单为 0(ADR-143 §二.3 另行锁住)。
     */
    public record ApplicationKit(UUID applicationItemId, UUID applicationId, String applicationNo,
                                 UUID goodsId, String goodsCode, String goodsName, String colorName, String unitName,
                                 BigDecimal openQty, BigDecimal kitQty, BigDecimal orderableQty,
                                 boolean bomMissing, List<MaterialFact> materials) {
        public ApplicationKit {
            materials = List.copyOf(materials);
        }
    }

    /** 带单下单的一条所选申请明细: 剩余未下单数量(调用方已按申请、已下单、在审算好)。 */
    public record SelectionLine(UUID applicationItemId, BigDecimal openQty) {
    }

    /**
     * 一种直属物料在一条申请明细上的备料事实(任务中心「物料」列逐种计数用)。
     * needed 与「齐套情况」弹窗同一口径 = ceil4(剩余未下单 × 每套用量)。
     */
    public record ApplicationKitKindFact(UUID applicationItemId, UUID goodsId, UUID colorId,
                                         BigDecimal neededQty, BigDecimal exactFreeQty,
                                         BigDecimal publicFreeQty) {
    }

    /** 一行(可能归组多条申请明细)按物料种数的备料汇总: 备齐/缺的种数, 每种物料只计一次。 */
    public record ApplicationKitKindCounts(int kindCount, int readyKindCount, int shortKindCount) {
    }

    /** 一条所选申请明细这次能下的数量: 现有物料够做的套数(按先后共用公共库存)与预填数量。 */
    public record SelectionKit(BigDecimal kitQty, BigDecimal orderableQty) {
    }

    // ==================== 守卫 ====================

    /**
     * 订货单齐套守卫(调用方事务内, 明细已落库): 本单每种直属物料先用所属申请的专属批次, 剩下的
     * 必须够公共库存扣掉其它还在办的委外单之后的剩余; 不够就 409 点名。先按物料货色排序加事务级
     * 咨询锁, 让同时下单的两张单串行判定、不会都按同一批公共库存放行。没有可发外直属物料的明细不在
     * 这里拦(缺 BOM 由 ADR-143 §二.3 的守卫转研发并拒绝)。
     *
     * @param action 拒绝文案里的动作, 如「生成委外订货单」「提交财务」「批准」「加量」
     * @param hint   拒绝文案末尾告诉操作人下一步怎么办
     */
    @Transactional(propagation = Propagation.MANDATORY)
    public void requireOrderKit(UUID orderId, String action, String hint) {
        if (orderId == null) {
            return;
        }
        if (!lockOrderComponents(orderId.toString())) {
            return;
        }
        List<Map<String, Object>> shortages = jdbc.queryForList("""
                SELECT shortage.need_qty, shortage.exact_free_qty, shortage.public_free_qty,
                       goods.code AS goods_code, goods.name AS goods_name, color.name AS color_name,
                       unit.name AS unit_name
                FROM fn_subcontract_order_kit_shortages(?) shortage
                JOIN goods ON goods.id = shortage.goods_id
                LEFT JOIN colors color ON color.id = shortage.color_id
                LEFT JOIN units unit ON unit.id = goods.unit_id
                ORDER BY goods.code, goods.id
                """, orderId);
        if (shortages.isEmpty()) {
            return;
        }
        List<String> parts = new ArrayList<>();
        for (Map<String, Object> shortage : shortages) {
            BigDecimal need = decimal(shortage.get("need_qty"));
            BigDecimal available = decimal(shortage.get("exact_free_qty")).add(decimal(shortage.get("public_free_qty")));
            String unit = Objects.toString(shortage.get("unit_name"), "");
            parts.add("「" + materialLabel(shortage) + "」本单需要 " + plain(need) + unit
                    + "，现在能用的只有 " + plain(available) + unit);
        }
        throw new ApiException(ErrorCode.CONFLICT, "直属物料还没齐套，不能" + action + "：" + String.join("；", parts)
                + "(已扣掉其它还在办的委外单要领的量)。委外价格每天不一样，物料齐了才解锁下单；"
                + hint + "。");
    }


    /**
     * Validate all newly staged order rows as one request, including orders split
     * by commercial terms. Recompute the preview under the same kit locks on retry.
     */
    @Transactional(propagation = Propagation.MANDATORY)
    public void chooseOrderMaterialBudget(List<UUID> orderIds, OrderSaveRequest request, String action) {
        String ids = orderIds.stream().map(UUID::toString).collect(java.util.stream.Collectors.joining(","));
        BigDecimal factor = BigDecimal.ONE;
        BigDecimal fundedFactor = null;
        if (lockOrderComponents(ids)) {
            List<Map<String, Object>> facts = jdbc.queryForList("""
                    WITH scope AS MATERIALIZED (
                        SELECT CAST(string_to_array(CAST(? AS text), ',') AS uuid[]) AS ids
                    ), snapshot AS MATERIALIZED (
                        SELECT scope.ids, fn_subcontract_order_budget_pool_snapshot(scope.ids) AS pools FROM scope
                    ), full_budget AS MATERIALIZED (
                        SELECT fact.* FROM snapshot
                        CROSS JOIN LATERAL fn_subcontract_order_budget_facts(snapshot.ids, 1, snapshot.pools) fact
                    ), shortage_scope AS MATERIALIZED (
                        SELECT * FROM snapshot WHERE EXISTS (SELECT 1 FROM full_budget WHERE short_qty > 0)
                    ), base_budget AS MATERIALIZED (
                        SELECT fact.* FROM shortage_scope
                        CROSS JOIN LATERAL fn_subcontract_order_budget_facts(shortage_scope.ids, 0, shortage_scope.pools) fact
                    ), choice AS MATERIALIZED (
                        SELECT shortage_scope.*, CASE WHEN NOT EXISTS (
                            SELECT 1 FROM base_budget WHERE short_qty > 0
                        ) THEN fn_subcontract_order_budget_cap_factor(shortage_scope.ids, shortage_scope.pools) END AS cap_factor
                        FROM shortage_scope
                    ), capped AS MATERIALIZED (
                        SELECT fact.* FROM choice
                        CROSS JOIN LATERAL fn_subcontract_order_budget_facts(choice.ids, choice.cap_factor, choice.pools) fact
                        WHERE choice.cap_factor IS NOT NULL
                    )
                    SELECT budget.goods_id, budget.color_id, goods.code AS goods_code, goods.name AS goods_name,
                           color.name AS color_name, unit.name AS unit_name,
                           budget.need_qty, budget.available_qty, budget.short_qty, base.need_qty AS base_qty,
                           capped.need_qty AS capped_qty, choice.cap_factor
                    FROM choice CROSS JOIN full_budget budget
                    JOIN goods ON goods.id = budget.goods_id
                    LEFT JOIN colors color ON color.id = budget.color_id
                    LEFT JOIN units unit ON unit.id = goods.unit_id
                    LEFT JOIN base_budget base ON base.goods_id = budget.goods_id
                         AND base.color_id IS NOT DISTINCT FROM budget.color_id
                    LEFT JOIN capped ON capped.goods_id = budget.goods_id
                         AND capped.color_id IS NOT DISTINCT FROM budget.color_id
                    WHERE budget.short_qty > 0 OR capped.need_qty < budget.need_qty
                    ORDER BY budget.goods_id, budget.color_id NULLS FIRST
                    """, ids);
            if (!facts.isEmpty()) {
                BigDecimal capFactor = (BigDecimal) facts.getFirst().get("cap_factor");
                var shortage = new MaterialShortageException(facts, request, action);
                if (capFactor == null || request.getMaterialShortageChoice() == null
                        || !shortage.token().equals(request.getMaterialShortageToken())) {
                    throw shortage;
                }
                if (request.getMaterialShortageChoice() == OrderSaveRequest.MaterialShortageChoice.USE_AVAILABLE) {
                    factor = capFactor;
                } else {
                    fundedFactor = capFactor;
                }
            }
        }
        if (request.getMaterialShortageChoice() == OrderSaveRequest.MaterialShortageChoice.USE_AVAILABLE
                && factor.compareTo(BigDecimal.ONE) == 0) {
            throw new ApiException(ErrorCode.CONFLICT, "库存已补足，请核对领料数量后重新保存");
        }
        jdbc.update("""
                UPDATE subcontract_order_items
                SET material_supply_loss_factor = ?, material_supply_funded_loss_factor = ?
                WHERE order_id = ANY(CAST(string_to_array(CAST(? AS text), ',') AS uuid[]))
                  AND NOT is_deleted AND (material_supply_loss_factor IS DISTINCT FROM ?
                       OR material_supply_funded_loss_factor IS DISTINCT FROM ?)
                """, factor, fundedFactor, ids, factor, fundedFactor);
    }

    private boolean lockOrderComponents(String orderIds) {
        List<Map<String, Object>> components = jdbc.queryForList("""
                WITH scope AS (SELECT CAST(string_to_array(CAST(? AS text), ',') AS uuid[]) AS ids)
                SELECT DISTINCT edge.component_goods_id AS goods_id, edge.color_id
                FROM scope
                JOIN subcontract_order_items item ON item.order_id = ANY(scope.ids)
                CROSS JOIN LATERAL fn_subcontract_draw_edges(item.goods_id) edge
                WHERE NOT item.is_deleted AND COALESCE(item.qty, 0) > 0
                UNION
                SELECT line.goods_id, line.color_id
                FROM scope
                JOIN subcontract_order_items item ON item.order_id = ANY(scope.ids)
                JOIN subcontract_material_plan_items line ON line.order_item_id = item.id AND NOT line.is_deleted
                WHERE NOT item.is_deleted
                ORDER BY 1, 2 NULLS FIRST
                """, orderIds);
        for (Map<String, Object> component : components) {
            jdbc.queryForObject("SELECT pg_advisory_xact_lock(hashtextextended(?, 0))::text", String.class,
                    "subcontract-kit:" + component.get("goods_id") + ':' + Objects.toString(component.get("color_id"), "-"));
        }
        return !components.isEmpty();
    }

    private static final class MaterialShortageException extends ApiException {
        private final String token;
        private final Map<String, Object> details;

        MaterialShortageException(List<Map<String, Object>> rows, OrderSaveRequest request, String action) {
            super(ErrorCode.CONFLICT, "直属物料还没齐套，不能" + action + "：" + rows.stream()
                    .filter(row -> decimal(row.get("short_qty")).signum() > 0)
                    .map(row -> "「" + materialLabel(row) + "」本单需要 " + plain(decimal(row.get("need_qty")))
                            + Objects.toString(row.get("unit_name"), "") + "，现在能用的只有 "
                            + plain(decimal(row.get("available_qty"))) + Objects.toString(row.get("unit_name"), ""))
                    .collect(java.util.stream.Collectors.joining("；")));
            boolean baseCovered = rows.getFirst().get("cap_factor") != null;
            // Stable across rolled-back draft IDs; quantities, source choices and review facts bind the retry.
            var requestedLines = request.getItems().stream().map(line -> java.util.Arrays.asList(
                    line.getGoodsId(), line.getColorId(), line.getUnitId(), line.getUnitRate(), line.getQty(),
                    line.getAllowedLossPct(), line.resolvedApplicationItemIds())).toList();
            var evidence = java.util.Arrays.asList(request.getWarehouseId(), requestedLines, rows);
            token = ImmutableDocumentStore.digest(evidence.toString().getBytes(StandardCharsets.UTF_8));
            details = Map.of(
                    "kind", "SUBCONTRACT_MATERIAL_SHORTAGE",
                    "token", token,
                    "canContinueFull", baseCovered,
                    "canUseAvailable", baseCovered,
                    "materials", rows.stream().map(MaterialShortageException::displayMaterial).toList());
        }

        String token() {
            return token;
        }

        @Override
        public Map<String, Object> details() {
            return details;
        }

        private static Map<String, Object> displayMaterial(Map<String, Object> row) {
            Map<String, Object> material = new LinkedHashMap<>();
            material.put("goodsCode", row.get("goods_code"));
            material.put("goodsName", row.get("goods_name"));
            material.put("colorName", row.get("color_name"));
            material.put("unitName", row.get("unit_name"));
            BigDecimal base = decimal(row.get("base_qty"));
            BigDecimal required = decimal(row.get("need_qty"));
            material.put("baseQtyExact", plain(base));
            material.put("requiredLossQtyExact", plain(required.subtract(base)));
            material.put("requiredQtyExact", plain(required));
            material.put("availableQtyExact", plain(decimal(row.get("available_qty"))));
            if (row.get("capped_qty") != null) {
                BigDecimal capped = decimal(row.get("capped_qty"));
                material.put("cappedQtyExact", plain(capped));
                material.put("cappedLossQtyExact", plain(capped.subtract(base)));
            }
            return material;
        }
    }

    // ==================== 读模型 ====================

    /** 委外申请明细的齐套情况(任务中心「物料齐套情况」)。 */
    @Transactional(readOnly = true)
    public ApplicationKit applicationKit(UUID applicationItemId) {
        if (applicationItemId == null) throw new ApiException(ErrorCode.NOT_FOUND, "委外申请明细不存在");
        ApplicationKit result = applicationKits(List.of(applicationItemId))
                .get(applicationItemId);
        if (result == null) throw new ApiException(ErrorCode.NOT_FOUND, "委外申请明细不存在");
        return result;
    }

    /** Complete detail facts for existing visible heads, using one shared material-pool projection. */
    @Transactional(readOnly = true)
    public Map<UUID, ApplicationKit> applicationKits(Collection<UUID> applicationItemIds) {
        if (applicationItemIds == null || applicationItemIds.isEmpty()) return Map.of();
        String ids = applicationItemIds.stream().filter(Objects::nonNull).distinct().sorted()
                .map(UUID::toString).collect(java.util.stream.Collectors.joining(","));
        if (ids.isEmpty()) return Map.of();
        List<Map<String, Object>> heads = jdbc.queryForList("""
                SELECT item.id, application.id AS application_id, application.bill_no,
                       item.goods_id, goods.code AS goods_code, goods.name AS goods_name,
                       color.name AS color_name, unit.name AS unit_name,
                       fn_subcontract_application_open_qty(item.id) AS open_qty
                FROM subcontract_application_items item
                JOIN subcontract_applications application ON application.id = item.application_id
                JOIN goods ON goods.id = item.goods_id
                LEFT JOIN colors color ON color.id = item.color_id
                LEFT JOIN units unit ON unit.id = item.unit_id
                WHERE item.id = ANY(CAST(string_to_array(CAST(? AS text), ',') AS uuid[])) AND NOT item.is_deleted AND NOT application.is_deleted
                """, ids);
        if (heads.isEmpty()) return Map.of();
        Map<UUID, List<Map<String, Object>>> facts = new HashMap<>();
        for (Map<String, Object> fact : jdbc.queryForList("""
                SELECT fact.*, goods.code AS goods_code, goods.name AS goods_name,
                       color.name AS color_name, unit.name AS unit_name
                FROM fn_subcontract_application_kit_facts_batch(CAST(string_to_array(CAST(? AS text), ',') AS uuid[]), NULL) fact
                JOIN goods ON goods.id = fact.component_goods_id
                LEFT JOIN colors color ON color.id = fact.color_id
                LEFT JOIN units unit ON unit.id = goods.unit_id
                ORDER BY fact.application_item_id, fact.sort_order, fact.edge_id
                """, ids)) {
            facts.computeIfAbsent((UUID) fact.get("application_item_id"), ignored -> new ArrayList<>()).add(fact);
        }
        Map<UUID, ApplicationKit> result = new LinkedHashMap<>();
        for (Map<String, Object> head : heads) {
            UUID id = (UUID) head.get("id");
            result.put(id, applicationKit(head, facts.getOrDefault(id, List.of())));
        }
        return result;
    }

    private ApplicationKit applicationKit(Map<String, Object> head, List<Map<String, Object>> factRows) {
        BigDecimal openQty = decimal(head.get("open_qty"));
        List<MaterialFact> materials = new ArrayList<>();
        BigDecimal kit = null;
        for (Map<String, Object> row : factRows) {
            BigDecimal bomUnitQty = decimal(row.get("bom_unit_qty"));
            BigDecimal needed = ceil4(openQty.multiply(bomUnitQty));
            BigDecimal free = decimal(row.get("free_qty"));
            BigDecimal kitQty = decimal(row.get("kit_qty"));
            kit = kit == null ? kitQty : kit.min(kitQty);
            materials.add(new MaterialFact((UUID) row.get("component_goods_id"),
                    (String) row.get("goods_code"), (String) row.get("goods_name"),
                    (UUID) row.get("color_id"), (String) row.get("color_name"), (String) row.get("unit_name"),
                    bomUnitQty, needed,
                    decimal(row.get("exact_qty")), decimal(row.get("exact_claimed_qty")), decimal(row.get("exact_free_qty")),
                    decimal(row.get("public_qty")), decimal(row.get("public_claimed_qty")), decimal(row.get("public_free_qty")),
                    free, needed.subtract(free).max(BigDecimal.ZERO), kitQty));
        }
        boolean bomMissing = materials.isEmpty();
        BigDecimal kitQty = kit == null ? BigDecimal.ZERO : kit;
        return new ApplicationKit((UUID) head.get("id"), (UUID) head.get("application_id"),
                (String) head.get("bill_no"), (UUID) head.get("goods_id"), (String) head.get("goods_code"),
                (String) head.get("goods_name"), (String) head.get("color_name"), (String) head.get("unit_name"),
                openQty, kitQty, bomMissing ? BigDecimal.ZERO : openQty.min(kitQty), bomMissing, materials);
    }

    /**
     * 待分解委外申请明细的逐种备料事实(任务中心「物料」列: 没下单也要看到到齐没有, 2026-11-09
     * 用户口径「委外要知道物料到齐了才下单, 不然价格是随时变动的」)。一次批量读取剩余未下单与
     * 逐种直属物料的「现在能用」(专属剩余 + 公共剩余), needed 口径与 {@link #applicationKit} 相同;
     * 缺 BOM / 剩余 0 的明细不返回行。键 = 申请明细 id。
     */
    @Transactional(readOnly = true)
    public Map<UUID, List<ApplicationKitKindFact>> applicationKitKindFacts(Collection<UUID> applicationItemIds) {
        if (applicationItemIds == null || applicationItemIds.isEmpty()) return Map.of();
        String ids = applicationItemIds.stream().filter(Objects::nonNull).distinct().sorted()
                .map(UUID::toString).collect(java.util.stream.Collectors.joining(","));
        if (ids.isEmpty()) return Map.of();
        Map<UUID, List<ApplicationKitKindFact>> result = new LinkedHashMap<>();
        jdbc.query("""
                WITH open_quantities AS (
                    SELECT quantity.application_item_id, quantity.open_qty
                    FROM fn_subcontract_application_orderable_batch(
                        CAST(string_to_array(CAST(? AS text), ',') AS uuid[])) quantity
                )
                SELECT fact.application_item_id, fact.component_goods_id, fact.color_id,
                       fact.bom_unit_qty, fact.exact_free_qty, fact.public_free_qty, open.open_qty
                FROM open_quantities open
                JOIN fn_subcontract_application_kit_facts_batch(
                    CAST(string_to_array(CAST(? AS text), ',') AS uuid[]), NULL) fact
                  ON fact.application_item_id = open.application_item_id
                WHERE open.open_qty > 0
                ORDER BY fact.application_item_id, fact.sort_order, fact.edge_id
                """, rs -> {
            UUID applicationItemId = rs.getObject(1, UUID.class);
            BigDecimal needed = ceil4(decimal(rs.getBigDecimal(7)).multiply(decimal(rs.getBigDecimal(4))));
            result.computeIfAbsent(applicationItemId, ignored -> new ArrayList<>())
                    .add(new ApplicationKitKindFact(applicationItemId, rs.getObject(2, UUID.class),
                            rs.getObject(3, UUID.class), needed,
                            decimal(rs.getBigDecimal(5)), decimal(rs.getBigDecimal(6))));
        }, ids, ids);
        return result;
    }

    /**
     * 一行(可能归组多条申请明细)的逐种计数: 每种物料需要 = Σ各明细需要, 可用 = Σ各明细专属剩余 +
     * 公共剩余——同种物料的公共池是共享的, 整行只计一次, 不能按明细重复加; 缺 = 可用不够需要。
     */
    public static ApplicationKitKindCounts applicationKitKindCounts(Collection<ApplicationKitKindFact> facts) {
        if (facts == null || facts.isEmpty()) return new ApplicationKitKindCounts(0, 0, 0);
        record Kind(UUID goodsId, UUID colorId) {
        }
        Map<Kind, BigDecimal> needed = new LinkedHashMap<>();
        Map<Kind, BigDecimal> exactFree = new LinkedHashMap<>();
        Map<Kind, BigDecimal> publicFree = new LinkedHashMap<>();
        for (ApplicationKitKindFact fact : facts) {
            Kind kind = new Kind(fact.goodsId(), fact.colorId());
            needed.merge(kind, fact.neededQty(), BigDecimal::add);
            exactFree.merge(kind, fact.exactFreeQty(), BigDecimal::add);
            publicFree.merge(kind, fact.publicFreeQty(), BigDecimal::max);
        }
        int ready = 0;
        for (Map.Entry<Kind, BigDecimal> entry : needed.entrySet()) {
            BigDecimal available = exactFree.getOrDefault(entry.getKey(), BigDecimal.ZERO)
                    .add(publicFree.getOrDefault(entry.getKey(), BigDecimal.ZERO));
            if (entry.getValue().subtract(available).max(BigDecimal.ZERO).signum() == 0) ready++;
        }
        return new ApplicationKitKindCounts(needed.size(), ready, needed.size() - ready);
    }

    /**
     * 带单下单的预填: 所选申请明细按传入顺序(调用方按需求日期、id 排好)依次分配——每条先用自己的专属
     * 批次, 不够的部分占公共库存, 后面的申请只能用前面分剩的公共库存。返回键 = 申请明细 id。
     * 结果与订货单齐套守卫同一口径: 按预填数量下单一定通过。
     */
    @Transactional(readOnly = true)
    public Map<UUID, SelectionKit> orderableForSelection(List<SelectionLine> lines) {
        Map<UUID, SelectionKit> result = new LinkedHashMap<>();
        if (lines == null || lines.isEmpty()) {
            return result;
        }
        String ids = lines.stream().map(SelectionLine::applicationItemId).filter(Objects::nonNull)
                .distinct().sorted().map(UUID::toString).collect(java.util.stream.Collectors.joining(","));
        Map<UUID, List<Map<String, Object>>> factsByApplication = new HashMap<>();
        for (Map<String, Object> fact : jdbc.queryForList("""
                SELECT application_item_id, component_goods_id, color_id, bom_unit_qty, exact_free_qty, public_free_qty
                FROM fn_subcontract_application_kit_facts_batch(
                    CAST(string_to_array(CAST(? AS text), ',') AS uuid[]), NULL)
                ORDER BY application_item_id, sort_order, edge_id
                """, ids)) {
            factsByApplication.computeIfAbsent((UUID) fact.get("application_item_id"), ignored -> new ArrayList<>()).add(fact);
        }
        Map<String, BigDecimal> publicLeft = new HashMap<>();
        for (SelectionLine line : lines) {
            List<Map<String, Object>> facts = factsByApplication.getOrDefault(line.applicationItemId(), List.of());
            if (facts.isEmpty()) {
                result.put(line.applicationItemId(), new SelectionKit(BigDecimal.ZERO, BigDecimal.ZERO));
                continue;
            }
            BigDecimal sets = null;
            for (Map<String, Object> fact : facts) {
                String key = fact.get("component_goods_id") + "|" + Objects.toString(fact.get("color_id"), "-");
                BigDecimal left = publicLeft.computeIfAbsent(key, ignored -> decimal(fact.get("public_free_qty")));
                BigDecimal available = decimal(fact.get("exact_free_qty")).add(left);
                BigDecimal edgeSets = sets(available, decimal(fact.get("bom_unit_qty")));
                sets = sets == null ? edgeSets : sets.min(edgeSets);
            }
            BigDecimal open = line.openQty() == null ? BigDecimal.ZERO : line.openQty().max(BigDecimal.ZERO);
            BigDecimal orderable = open.min(sets).setScale(SCALE, RoundingMode.DOWN);
            for (Map<String, Object> fact : facts) {
                String key = fact.get("component_goods_id") + "|" + Objects.toString(fact.get("color_id"), "-");
                BigDecimal used = ceil4(orderable.multiply(decimal(fact.get("bom_unit_qty"))));
                BigDecimal fromPublic = used.subtract(decimal(fact.get("exact_free_qty"))).max(BigDecimal.ZERO);
                publicLeft.put(key, publicLeft.get(key).subtract(fromPublic).max(BigDecimal.ZERO));
            }
            result.put(line.applicationItemId(), new SelectionKit(sets, orderable));
        }
        return result;
    }

    // ==================== 提醒重算 ====================

    /**
     * 订货单建、改、删、红冲、改量之后: 按本单委外件的直属物料追加「领料重算」outbox 事件。投递时
     * 除了重算用到这些物料的订货明细可领量, 也重算这些物料相关的委外申请可下单量(释放出来的物料
     * 能让别的申请解锁并提醒; 被占走的把旧提醒水位降下来)。
     */
    @Transactional(propagation = Propagation.MANDATORY)
    public void enqueueRecheckForOrder(UUID orderId) {
        if (orderId == null) {
            return;
        }
        List<SubcontractOutboundWakePort.StockedDimension> dimensions = new ArrayList<>();
        for (Map<String, Object> row : jdbc.queryForList("""
                SELECT DISTINCT edge.component_goods_id AS goods_id, edge.color_id
                FROM subcontract_order_items item
                CROSS JOIN LATERAL fn_subcontract_draw_edges(item.goods_id) edge
                WHERE item.order_id = ?
                UNION
                SELECT line.goods_id, line.color_id
                FROM subcontract_order_items item
                JOIN subcontract_material_plan_items line ON line.order_item_id = item.id
                WHERE item.order_id = ?
                ORDER BY 1, 2 NULLS FIRST
                """, orderId, orderId)) {
            dimensions.add(new SubcontractOutboundWakePort.StockedDimension(
                    (UUID) row.get("goods_id"), (UUID) row.get("color_id"), null));
        }
        drawRecheck.enqueueDrawRecheck(dimensions);
    }

    /** 某种物料到货或被释放后, 受影响的委外申请明细(还有未下单数量、BOM 用到它, 或曾经提醒过)。 */
    @Transactional(readOnly = true)
    public List<UUID> applicationItemsUsingMaterial(UUID goodsId, UUID colorId) {
        return jdbc.queryForList("""
                SELECT item.id
                FROM subcontract_application_items item
                JOIN subcontract_applications application ON application.id = item.application_id
                 AND application.status = 1 AND NOT application.is_deleted AND NOT application.is_closed
                WHERE NOT item.is_deleted
                  AND COALESCE(item.qty, 0) - COALESCE(item.ordered_qty, 0) > 0
                  AND EXISTS (SELECT 1 FROM fn_subcontract_draw_edges(item.goods_id) edge
                              WHERE edge.component_goods_id = CAST(? AS uuid)
                                AND edge.color_id IS NOT DISTINCT FROM CAST(? AS uuid))
                UNION
                SELECT mark.application_item_id
                FROM subcontract_application_kit_notice_marks mark
                JOIN subcontract_application_items item ON item.id = mark.application_item_id
                WHERE mark.notified_orderable > 0
                  AND EXISTS (SELECT 1 FROM fn_subcontract_draw_edges(item.goods_id) edge
                              WHERE edge.component_goods_id = CAST(? AS uuid)
                                AND edge.color_id IS NOT DISTINCT FROM CAST(? AS uuid))
                ORDER BY 1
                """, UUID.class, goodsId, colorId, goodsId, colorId);
    }

    /**
     * 委外申请明细此刻还能下单的数量: 未结案的已审核申请, 剩余(申请 − 已下单 − 在审)与现有物料够做的
     * 套数取小; 申请已关闭、删除、缺 BOM 时为 0。键 = 申请明细 id(不存在的不出现)。
     */
    @Transactional(readOnly = true)
    public Map<UUID, BigDecimal> orderableNow(Collection<UUID> applicationItemIds) {
        Map<UUID, BigDecimal> result = new LinkedHashMap<>();
        if (applicationItemIds == null || applicationItemIds.isEmpty()) {
            return result;
        }
        String ids = applicationItemIds.stream().filter(Objects::nonNull).distinct().sorted()
                .map(UUID::toString).reduce((a, b) -> a + "," + b).orElse("");
        if (ids.isEmpty()) {
            return result;
        }
        jdbc.query("""
                SELECT quantity.application_item_id, quantity.orderable_qty
                FROM fn_subcontract_application_orderable_batch(
                    CAST(string_to_array(CAST(? AS text), ',') AS uuid[])) quantity
                """, rs -> {
            result.put(rs.getObject(1, UUID.class), decimal(rs.getBigDecimal(2)).max(BigDecimal.ZERO));
        }, ids);
        return result;
    }

    // ==================== 小工具 ====================

    private static String materialLabel(Map<String, Object> row) {
        String code = Objects.toString(row.get("goods_code"), "");
        String name = Objects.toString(row.get("goods_name"), "");
        String color = Objects.toString(row.get("color_name"), "");
        String label = (code.isBlank() ? "" : code + " ") + name;
        return color.isBlank() ? label.trim() : label.trim() + "(" + color + ")";
    }

    static BigDecimal sets(BigDecimal qty, BigDecimal bomUnitQty) {
        if (bomUnitQty == null || bomUnitQty.signum() <= 0) {
            return BigDecimal.ZERO;
        }
        BigDecimal safe = qty == null ? BigDecimal.ZERO : qty.max(BigDecimal.ZERO);
        return safe.divide(bomUnitQty, SCALE, RoundingMode.DOWN);
    }

    static BigDecimal ceil4(BigDecimal value) {
        return value == null ? BigDecimal.ZERO : value.setScale(SCALE, RoundingMode.CEILING);
    }

    private static BigDecimal decimal(Object value) {
        if (value == null) {
            return BigDecimal.ZERO;
        }
        return value instanceof BigDecimal decimal ? decimal : new BigDecimal(value.toString());
    }

    private static String plain(BigDecimal value) {
        return value == null ? "0" : value.stripTrailingZeros().toPlainString();
    }
}
