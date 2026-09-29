package com.uten.imp.features.stock.valuation;

import com.uten.imp.application.port.InventoryPositionPort;
import com.uten.imp.application.port.InventoryPositionPort.Move;
import com.uten.imp.application.port.InventoryPositionPort.Owner;
import com.uten.imp.application.port.InventoryPositionPort.PositionValue;
import com.uten.imp.application.port.InventoryPositionPort.PositionView;
import com.uten.imp.application.port.InventoryPositionPort.ReturnConsumed;
import com.uten.imp.application.port.InventoryPositionPort.Slice;
import com.uten.imp.application.port.InventoryValuationPort.PoolKey;
import com.uten.imp.features.stock.InventoryKey;
import com.uten.imp.features.stock.InventoryMutationLock;
import org.springframework.jdbc.core.namedparam.MapSqlParameterSource;
import org.springframework.jdbc.core.namedparam.NamedParameterJdbcTemplate;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Propagation;
import org.springframework.transaction.annotation.Transactional;

import java.math.BigDecimal;
import java.nio.charset.StandardCharsets;
import java.time.OffsetDateTime;
import java.util.ArrayDeque;
import java.util.ArrayList;
import java.util.Collection;
import java.util.Comparator;
import java.util.Deque;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Map;
import java.util.Objects;
import java.util.Set;
import java.util.UUID;
import java.util.stream.Collectors;

import static com.uten.imp.features.stock.valuation.ValueMath.conflict;

/**
 * 车间内料仓按期结算的价值移动 (ADR-131 §4.5、§4.6、§5.8、§5.9)。
 *
 * <p>盘点提交时 21 型耗用出库已把价值冻结在在制 (去向 = 期间用量行); 结算只做价值归属, 不产生实物流水:
 * 每一行分摊按精确区间从在制移到成本在制 (成本范围根工单), 有实际没理论的部分移到损失。移完核验
 * 在制里这一期不留余量, 再按成本范围逐个刷新生产成本对象 (期间分摊切片由统一的投入发现视图登记)。
 * 撤销结算只撤成本: 分摊用实耗纠正原路退回在制, 损失移回在制; 数量不动。
 *
 * <p>调用方 (结算服务) 持有本事务, 并先用 {@link #lockForClose} 一次锁定全部库存维度。
 */
@Service
@Transactional(propagation = Propagation.MANDATORY)
public class WorkshopMaterialCostService {

    /** 分摊进产品成本的价值事件来源 (投入发现视图与投入守卫按它认)。 */
    public static final String SOURCE_ALLOCATION = "WORKSHOP_PERIOD_ALLOCATION";
    /** 有实际没理论、移到损失的价值事件来源 (报表现值按它认)。 */
    public static final String SOURCE_LOSS = "WORKSHOP_PERIOD_LOSS";
    static final String SOURCE_ALLOCATION_REVERSE = "WORKSHOP_PERIOD_ALLOCATION_REVERSE";
    static final String SOURCE_LOSS_REVERSE = "WORKSHOP_PERIOD_LOSS_REVERSE";

    private static final int MAX_SLICES = 100;

    /** 在制里一个价值位置 (根) 的剩余数量。 */
    private static final class Held {
        final UUID rootId;
        BigDecimal remaining;

        Held(UUID rootId, BigDecimal remaining) {
            this.rootId = rootId;
            this.remaining = remaining;
        }
    }

    private final NamedParameterJdbcTemplate db;
    private final InventoryPositionPort positions;
    private final InventoryMutationLock mutex;
    private final InventoryBusinessValueSupport support;
    private final ProductionInventoryValueService production;

    public WorkshopMaterialCostService(NamedParameterJdbcTemplate db, InventoryPositionPort positions,
                                       InventoryMutationLock mutex, InventoryBusinessValueSupport support,
                                       ProductionInventoryValueService production) {
        this.db = db;
        this.positions = positions;
        this.mutex = mutex;
        this.support = support;
        this.production = production;
    }

    /**
     * 一次锁定结算或撤销会动到的全部库存维度: 这一期的全部料、所涉成本范围的产品, 以及这些成本范围刷新时
     * 会登记的其它投入料 (与成本刷新自己取的锁同一集合, 不在持锁后补拿新维度)。
     */
    public void lockForClose(UUID periodId, Collection<UUID> costScopes) {
        MapSqlParameterSource params = new MapSqlParameterSource("period", periodId)
                .addValue("scopes", joined(costScopes));
        List<InventoryKey> keys = new ArrayList<>();
        for (Map<String, Object> row : db.queryForList("""
                SELECT DISTINCT dimension.goods_id, dimension.color_id FROM (
                    SELECT line.goods_id, line.color_id
                    FROM workshop_material_period_lines line
                    WHERE line.period_id = :period
                    UNION ALL
                    SELECT pool.goods_id, pool.color_id
                    FROM stock_value_production_cost_objects cost_object
                    JOIN stock_value_pools pool ON pool.id = cost_object.product_pool_id
                    WHERE cost_object.execution_segment_id = ANY(CAST(string_to_array(:scopes, ',') AS uuid[]))
                    UNION ALL
                    SELECT candidate.goods_id, candidate.color_id
                    FROM v_production_cost_input_candidates candidate
                    WHERE candidate.node_active
                      AND candidate.member_segment_id IN (
                          SELECT member.segment_id
                          FROM unnest(CAST(string_to_array(:scopes, ',') AS uuid[])) scope(id)
                          CROSS JOIN LATERAL fn_production_execution_cost_members(scope.id) member)
                      AND NOT EXISTS (SELECT 1 FROM stock_value_production_cost_inputs registered
                                      WHERE registered.approved_posting_id = candidate.approved_posting_id)
                ) dimension
                """, params)) {
            keys.add(new InventoryKey((UUID) row.get("goods_id"), (UUID) row.get("color_id")));
        }
        mutex.lockAll(keys);
    }

    /**
     * 结算的价值移动: 每行分摊从在制 (期间用量行) 移到成本在制 (成本范围), 损失移到损失; 回写分摊行与
     * 每种料的结算时金额; 最后核验在制里这一期不留余量 (有余量说明计入量与盘点过账对不上, 整体回滚)。
     */
    public void allocate(UUID closeId, UUID actor) {
        OffsetDateTime at = now();
        UUID periodId = db.queryForObject("SELECT period_id FROM workshop_material_period_closes WHERE id = :close",
                Map.of("close", closeId), UUID.class);
        for (Map<String, Object> material : db.queryForList("""
                SELECT material.id, material.period_line_id, material.consumed_qty, material.loss_qty
                FROM workshop_material_close_materials material
                WHERE material.close_id = :close AND (material.consumed_qty > 0 OR material.loss_qty > 0)
                ORDER BY material.period_line_id
                """, Map.of("close", closeId))) {
            UUID materialId = (UUID) material.get("id");
            UUID lineId = (UUID) material.get("period_line_id");
            Deque<Held> held = wipRoots(lineId);
            if (held.isEmpty()) throw conflict("这一期的料在在制里没有可分摊的价值, 请核对盘点过账");
            PoolKey pool = poolOf(held.peekFirst().rootId);
            BigDecimal value = BigDecimal.ZERO;
            List<Map<String, Object>> allocations = db.queryForList("""
                    SELECT allocation.id, allocation.cost_scope_segment_id, allocation.allocated_qty
                    FROM workshop_material_close_allocations allocation
                    WHERE allocation.close_material_id = :material AND allocation.allocated_qty > 0
                    """, Map.of("material", materialId));
            allocations.sort(Comparator.comparing(row -> row.get("cost_scope_segment_id").toString()));
            for (Map<String, Object> allocation : allocations) {
                UUID allocationId = (UUID) allocation.get("id");
                BigDecimal qty = (BigDecimal) allocation.get("allocated_qty");
                PositionValue moved = positions.move(new Move(
                        support.context(SOURCE_ALLOCATION, allocationId, closeId, allocationId, actor, at),
                        pool, Owner.COST_WIP, (UUID) allocation.get("cost_scope_segment_id"), take(held, qty)));
                db.update("""
                        UPDATE workshop_material_close_allocations
                        SET value_node_id = :node, value_at_close = :value
                        WHERE id = :id AND value_node_id IS NULL
                        """, new MapSqlParameterSource("node", moved.positionRootId())
                        .addValue("value", moved.knownValueLocal()).addValue("id", allocationId));
                value = value.add(zero(moved.knownValueLocal()));
            }
            BigDecimal loss = (BigDecimal) material.get("loss_qty");
            if (loss.signum() > 0) {
                PositionValue moved = positions.move(new Move(
                        support.context(SOURCE_LOSS, materialId, closeId, materialId, actor, at),
                        pool, Owner.LOSS, materialId, take(held, loss)));
                value = value.add(zero(moved.knownValueLocal()));
            }
            db.update("""
                    UPDATE workshop_material_close_materials SET value_at_close = :value
                    WHERE id = :id AND value_at_close IS NULL
                    """, new MapSqlParameterSource("value", value).addValue("id", materialId));
        }
        requireNoWipLeft(periodId);
    }

    /**
     * 撤销结算的价值回退 (只撤成本、不动数量): 每行分摊用实耗纠正原路退回在制, 损失移回在制。
     * 回到在制的价值仍挂在同一期间用量行名下, 重新结算时照常分摊。
     */
    public void reverse(UUID closeId, UUID reversalEventId, UUID actor) {
        OffsetDateTime at = now();
        for (Map<String, Object> allocation : db.queryForList("""
                SELECT allocation.id, allocation.value_node_id, allocation.allocated_qty, material.period_line_id
                FROM workshop_material_close_allocations allocation
                JOIN workshop_material_close_materials material ON material.id = allocation.close_material_id
                WHERE material.close_id = :close AND allocation.value_node_id IS NOT NULL
                  AND allocation.reversed_at IS NULL
                ORDER BY allocation.id
                """, Map.of("close", closeId))) {
            UUID allocationId = (UUID) allocation.get("id");
            UUID node = (UUID) allocation.get("value_node_id");
            positions.returnConsumed(new ReturnConsumed(
                    support.context(SOURCE_ALLOCATION_REVERSE, derived(SOURCE_ALLOCATION_REVERSE, allocationId),
                            reversalEventId, allocationId, actor, at),
                    poolOf(node), node, (BigDecimal) allocation.get("allocated_qty"), Owner.WIP,
                    (UUID) allocation.get("period_line_id")));
        }
        for (Map<String, Object> loss : db.queryForList("""
                SELECT material.id, material.loss_qty, material.period_line_id, event.result_node_id
                FROM workshop_material_close_materials material
                JOIN stock_value_events event
                  ON event.source_event_id = material.id AND event.source_doc_type = 'WORKSHOP_PERIOD_LOSS'
                 AND event.operation = 'POSITION_MOVE'
                WHERE material.close_id = :close AND material.loss_qty > 0
                ORDER BY material.id
                """, Map.of("close", closeId))) {
            UUID materialId = (UUID) loss.get("id");
            UUID root = (UUID) loss.get("result_node_id");
            positions.move(new Move(
                    support.context(SOURCE_LOSS_REVERSE, derived(SOURCE_LOSS_REVERSE, materialId), reversalEventId,
                            materialId, actor, at),
                    poolOf(root), Owner.WIP, (UUID) loss.get("period_line_id"),
                    List.of(new Slice(root, (BigDecimal) loss.get("loss_qty"), root))));
        }
    }

    /** 按成本范围 id 顺序逐个刷新生产成本对象 (期间分摊切片随之登记为投入, 完整性门随之重算)。 */
    public void refresh(Collection<UUID> costScopes, UUID eventId, UUID actor) {
        List<UUID> ordered = costScopes.stream().filter(Objects::nonNull).distinct()
                .sorted(Comparator.comparing(UUID::toString)).toList();
        for (UUID scope : ordered) {
            production.refresh(scope, eventId, actor);
        }
    }

    // ------------------------------------------------------------------ 在制位置

    /** 期间用量行名下还有剩余的在制位置, 先进先出。 */
    private Deque<Held> wipRoots(UUID periodLineId) {
        Deque<Held> out = new ArrayDeque<>();
        for (Map<String, Object> row : db.queryForList("""
                SELECT root.id, head.range_to - head.range_from AS remaining
                FROM stock_value_nodes root
                JOIN stock_value_nodes head ON head.id = root.return_head_id
                WHERE root.kind = 'ISSUE_POSITION' AND root.root_issue_id = root.id
                  AND head.owner_kind = 'WIP' AND head.owner_id = :line AND head.active
                  AND head.range_to > head.range_from
                ORDER BY root.created_at, root.id
                """, Map.of("line", periodLineId))) {
            out.addLast(new Held((UUID) row.get("id"), (BigDecimal) row.get("remaining")));
        }
        return out;
    }

    /** 从在制位置里先进先出取 qty; 一次移动最多 100 个来源切片。 */
    private static List<Slice> take(Deque<Held> held, BigDecimal qty) {
        List<Slice> slices = new ArrayList<>();
        BigDecimal left = qty;
        while (left.signum() > 0) {
            Held head = held.peekFirst();
            if (head == null) throw conflict("在制里这一期的料少于要分摊的数量, 请核对盘点过账");
            BigDecimal part = head.remaining.min(left);
            slices.add(new Slice(head.rootId, part, head.rootId));
            head.remaining = head.remaining.subtract(part);
            if (head.remaining.signum() == 0) held.removeFirst();
            left = left.subtract(part);
            if (slices.size() > MAX_SLICES) throw conflict("这一期的盘点过账笔数太多, 一次分摊不完, 请联系系统管理员");
        }
        return slices;
    }

    /** 核验: 这一期每个期间用量行名下的在制都已全部移走 (每个位置根的剩余数量为 0)。 */
    private void requireNoWipLeft(UUID periodId) {
        for (UUID root : db.queryForList("""
                SELECT root.id
                FROM stock_value_nodes root
                JOIN stock_value_nodes head ON head.id = root.return_head_id
                WHERE root.kind = 'ISSUE_POSITION' AND root.root_issue_id = root.id
                  AND head.owner_kind = 'WIP'
                  AND head.owner_id IN (SELECT line.id FROM workshop_material_period_lines line
                                        WHERE line.period_id = :period)
                ORDER BY root.id
                """, Map.of("period", periodId), UUID.class)) {
            PositionView view = positions.position(root);
            if (view.remainingQtyBase() != null && view.remainingQtyBase().signum() != 0) {
                throw conflict("结算后在制里还留有这一期的料, 计入量与盘点过账对不上, 已整体撤回");
            }
        }
    }

    private PoolKey poolOf(UUID node) {
        Map<String, Object> row = db.queryForMap("""
                SELECT pool.warehouse_id, pool.goods_id, pool.color_id
                FROM stock_value_nodes node JOIN stock_value_pools pool ON pool.id = node.pool_id
                WHERE node.id = :node
                """, Map.of("node", node));
        return InventoryBusinessValueSupport.pool(row);
    }

    private OffsetDateTime now() {
        return db.queryForObject("SELECT transaction_timestamp()", Map.of(), OffsetDateTime.class);
    }

    /** 撤销动作自己的来源事件 id (与原动作不同, 不会被当成原动作的重放)。 */
    private static UUID derived(String kind, UUID fact) {
        return UUID.nameUUIDFromBytes((kind + ":" + fact).getBytes(StandardCharsets.UTF_8));
    }

    private static BigDecimal zero(BigDecimal value) {
        return value == null ? BigDecimal.ZERO : value;
    }

    private static String joined(Collection<UUID> ids) {
        Set<UUID> distinct = new LinkedHashSet<>();
        if (ids != null) ids.stream().filter(Objects::nonNull).forEach(distinct::add);
        return distinct.stream().map(UUID::toString).collect(Collectors.joining(","));
    }
}
