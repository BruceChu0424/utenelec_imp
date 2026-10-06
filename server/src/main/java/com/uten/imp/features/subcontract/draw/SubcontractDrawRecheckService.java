package com.uten.imp.features.subcontract.draw;

import com.uten.imp.application.port.SubcontractChainNoticePort;
import com.uten.imp.application.port.SubcontractDrawRecheckPort;
import lombok.RequiredArgsConstructor;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.core.RowCallbackHandler;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.math.BigDecimal;
import java.util.Collection;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;
import java.util.UUID;
import java.util.stream.Collectors;

/**
 * ADR-143 §4.4「委外可领料」提醒的重算(outbox 投递时调用, 原事务已提交)。
 *
 * <p>高水位 {@code subcontract_draw_notice_marks}: 可领量比上次提醒时增加才提醒(行动卡按订货明细
 * 一张, 由通知侧按实时可领量更新); 减少只把水位降下来并 epoch+1, 不打扰人; 降到 0 收回行动卡。
 * 已结清、结束领料、计划关闭或订货红冲的明细一律按可领 0 处理。只锁水位行, 不锁任何业务单据。
 *
 * <p>按物料重算时也重算用到这种物料的委外申请可下单量(ADR-156, 见 SubcontractApplicationKitRecheckService)。
 *
 * <p>水位行的外键检查会给订货明细加 KEY SHARE 行锁(与 FOR UPDATE 冲突)。领料提交、财务批准、改量等命令按
 * 统一锁序(订货单头, 再按 order_id, id 锁订货明细)加 FOR UPDATE; 本重算必须按同一顺序拿这些 KEY SHARE,
 * 所以先用一条语句按 (order_id, id) 插齐缺的水位行, 再逐行处理。按明细 id 逐行插入会与刚批准就领料的
 * 提交交叉等待而死锁(2026-10-05 全链路回归: 两张订货单联合领料撞上批准后的重算)。
 */
@Service
@RequiredArgsConstructor
public class SubcontractDrawRecheckService implements SubcontractDrawRecheckPort {

    private final JdbcTemplate jdbc;
    private final SubcontractChainNoticePort chainNotice;
    /** ADR-156: 同一次物料重算顺带重算用到它的委外申请可下单量(到货解锁、被占走降水位)。 */
    private final com.uten.imp.features.subcontract.kit.SubcontractApplicationKitRecheckService applicationKitRecheck;

    @Override
    @Transactional
    public void recheckForMaterial(UUID goodsId, UUID colorId) {
        if (goodsId == null) {
            return;
        }
        List<UUID> orderItemIds = jdbc.queryForList("""
                SELECT line.order_item_id
                FROM subcontract_material_plan_items line
                JOIN subcontract_material_plans plan ON plan.id = line.plan_id
                 AND plan.status = 'OPEN' AND NOT plan.is_deleted
                WHERE line.goods_id = CAST(? AS uuid)
                  AND line.color_id IS NOT DISTINCT FROM CAST(? AS uuid)
                  AND NOT line.is_deleted AND line.draw_closed_at IS NULL
                UNION
                SELECT mark.order_item_id
                FROM subcontract_draw_notice_marks mark
                JOIN subcontract_material_plan_items line ON line.order_item_id = mark.order_item_id
                WHERE mark.notified_drawable > 0
                  AND line.goods_id = CAST(? AS uuid)
                  AND line.color_id IS NOT DISTINCT FROM CAST(? AS uuid)
                """, UUID.class, goodsId, colorId, goodsId, colorId);
        recheckForOrderItems(orderItemIds);
        applicationKitRecheck.recheckForMaterial(goodsId, colorId);
    }

    @Override
    @Transactional
    public void recheckForOrderItems(Collection<UUID> orderItemIds) {
        if (orderItemIds == null || orderItemIds.isEmpty()) {
            return;
        }
        List<UUID> ids = orderItemIds.stream().filter(Objects::nonNull).distinct().sorted().toList();
        if (ids.isEmpty()) {
            return;
        }
        String idList = ids.stream().map(UUID::toString).collect(Collectors.joining(","));
        jdbc.update("""
                INSERT INTO subcontract_draw_notice_marks(order_item_id)
                SELECT item.id FROM subcontract_order_items item
                WHERE item.id = ANY(CAST(string_to_array(CAST(? AS text), ',') AS uuid[]))
                ORDER BY item.order_id, item.id
                ON CONFLICT (order_item_id) DO NOTHING
                """, idList);
        Map<UUID, BigDecimal> drawable = new HashMap<>();
        jdbc.query("""
                SELECT oi.id,
                       CASE WHEN p.id IS NOT NULL AND (""" + SubcontractDrawSql.OPEN_ITEM_PREDICATE + """
                       ) THEN summary.drawable_qty ELSE 0 END
                FROM subcontract_order_items oi
                JOIN subcontract_orders o ON o.id = oi.order_id
                LEFT JOIN subcontract_material_plans p ON p.order_id = o.id AND NOT p.is_deleted
                CROSS JOIN LATERAL fn_subcontract_draw_summary(oi.id) summary
                WHERE oi.id = ANY(CAST(string_to_array(CAST(? AS text), ',') AS uuid[]))
                """, (RowCallbackHandler) rs -> drawable.put(rs.getObject(1, UUID.class), rs.getBigDecimal(2)),
                idList);
        for (UUID orderItemId : ids) {
            if (!drawable.containsKey(orderItemId)) {
                continue;
            }
            BigDecimal now = drawable.get(orderItemId) == null
                    ? BigDecimal.ZERO : drawable.get(orderItemId).max(BigDecimal.ZERO);
            BigDecimal mark = jdbc.queryForObject("""
                    SELECT notified_drawable FROM subcontract_draw_notice_marks
                    WHERE order_item_id = ? FOR UPDATE
                    """, BigDecimal.class, orderItemId);
            BigDecimal previous = mark == null ? BigDecimal.ZERO : mark;
            if (now.compareTo(previous) > 0) {
                chainNotice.notifySubcontractDrawAvailable(orderItemId);
                jdbc.update("""
                        UPDATE subcontract_draw_notice_marks
                        SET notified_drawable = ?, updated_at = now()
                        WHERE order_item_id = ?
                        """, now, orderItemId);
            } else if (now.compareTo(previous) < 0) {
                jdbc.update("""
                        UPDATE subcontract_draw_notice_marks
                        SET notified_drawable = ?, epoch = epoch + 1, updated_at = now()
                        WHERE order_item_id = ?
                        """, now, orderItemId);
                if (now.signum() == 0) {
                    chainNotice.resolveSubcontractDrawAvailable(orderItemId);
                }
            }
        }
    }
}
