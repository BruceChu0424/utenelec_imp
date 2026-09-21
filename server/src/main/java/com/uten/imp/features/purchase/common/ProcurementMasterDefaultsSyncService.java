package com.uten.imp.features.purchase.common;

import lombok.RequiredArgsConstructor;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Propagation;
import org.springframework.transaction.annotation.Transactional;

import java.util.UUID;

/**
 * 保存订货单后在同一事务学习主档默认值。单价与供应商、颜色、单位、币种、税率成组保存，
 * 不能把箱价、外币价或另一供应商的价格解释成当前行价。查询只读主档，不扫描历史订单。
 * 调用方必须先 flush 单头和明细；业务权限与审计上下文由单据命令绑定。
 */
@Service
@RequiredArgsConstructor
public class ProcurementMasterDefaultsSyncService {
    private final JdbcTemplate jdbc;

    @Transactional(propagation = Propagation.MANDATORY)
    public void syncFromPurchaseOrder(UUID orderId) {
        sync(orderId, "purchase");
    }

    @Transactional(propagation = Propagation.MANDATORY)
    public void syncFromSubcontractOrder(UUID orderId) {
        sync(orderId, "subcontract");
        syncSubcontractAllowedLoss(orderId);
    }

    /**
     * ADR-098 允许损耗记忆：委外订货明细填了允许损耗的行, 把该货品主档默认值改成最近一次填写值
     * (同货品多行取行号最大的一行; 值相同不写)。空行不清主档——用户没填就沿用上次记忆。
     */
    private void syncSubcontractAllowedLoss(UUID orderId) {
        jdbc.update("""
                UPDATE goods g
                SET subcontract_allowed_loss_pct = line.allowed_loss_pct,
                    version = g.version + 1,
                    updated_at = now(),
                    updated_by = NULLIF(current_setting('app.actor_id', true), '')::uuid
                FROM (
                    SELECT DISTINCT ON (i.goods_id) i.goods_id, i.allowed_loss_pct
                    FROM subcontract_order_items i
                    JOIN subcontract_orders o ON o.id = i.order_id
                    WHERE i.order_id = ? AND NOT i.is_deleted AND NOT o.is_deleted
                      AND o.status IN (0,1) AND i.allowed_loss_pct IS NOT NULL
                    ORDER BY i.goods_id, i.line_no DESC NULLS LAST, i.created_at DESC, i.id DESC
                ) line
                WHERE g.id = line.goods_id AND NOT g.is_deleted
                  AND g.subcontract_allowed_loss_pct IS DISTINCT FROM line.allowed_loss_pct
                """, orderId);
    }

    // Identifiers come only from the two fixed callers above, never from request input.
    private void sync(UUID orderId, String kind) {
        if (orderId == null) return;
        // 同批货品按 UUID 锁定，避免用户在两个订单里以相反行序保存时交叉持锁。
        jdbc.queryForList("""
                SELECT g.id FROM goods g
                WHERE NOT g.is_deleted AND EXISTS (
                    SELECT 1 FROM %1$s_order_items i JOIN %1$s_orders o ON o.id=i.order_id
                    WHERE i.order_id=? AND NOT i.is_deleted AND NOT o.is_deleted
                      AND o.status IN (0,1) AND i.goods_id=g.id)
                ORDER BY g.id FOR UPDATE
                """.formatted(kind), UUID.class, orderId);
        jdbc.update("""
                UPDATE goods g
                SET default_supplier_id = o.supplier_id,
                    default_%1$s_price = COALESCE(line.price, g.default_%1$s_price),
                    default_%1$s_price_supplier_id = CASE WHEN line.price IS NOT NULL
                        THEN o.supplier_id ELSE g.default_%1$s_price_supplier_id END,
                    default_%1$s_price_color_id = CASE WHEN line.price IS NOT NULL
                        THEN line.color_id ELSE g.default_%1$s_price_color_id END,
                    default_%1$s_price_unit_id = CASE WHEN line.price IS NOT NULL
                        THEN line.unit_id ELSE g.default_%1$s_price_unit_id END,
                    default_%1$s_price_currency_id = CASE WHEN line.price IS NOT NULL
                        THEN o.currency_id ELSE g.default_%1$s_price_currency_id END,
                    default_%1$s_price_tax_rate = CASE WHEN line.price IS NOT NULL
                        THEN o.tax_rate ELSE g.default_%1$s_price_tax_rate END,
                    version = g.version + 1,
                    updated_at = now(),
                    updated_by = NULLIF(current_setting('app.actor_id', true), '')::uuid
                FROM (
                    SELECT DISTINCT ON (i.goods_id) i.order_id, i.goods_id, i.price,
                           i.color_id, i.unit_id
                    FROM %1$s_order_items i
                    WHERE i.order_id = ? AND NOT i.is_deleted AND i.goods_id IS NOT NULL
                    ORDER BY i.goods_id, i.line_no DESC NULLS LAST, i.created_at DESC, i.id DESC
                ) line
                JOIN %1$s_orders o ON o.id = line.order_id
                WHERE o.supplier_id IS NOT NULL AND NOT o.is_deleted AND o.status IN (0,1)
                  AND g.id = line.goods_id AND NOT g.is_deleted
                  AND (g.default_supplier_id IS DISTINCT FROM o.supplier_id
                       OR (line.price IS NOT NULL AND
                           (g.default_%1$s_price, g.default_%1$s_price_supplier_id,
                            g.default_%1$s_price_color_id, g.default_%1$s_price_unit_id,
                            g.default_%1$s_price_currency_id, g.default_%1$s_price_tax_rate)
                           IS DISTINCT FROM
                           (line.price, o.supplier_id, line.color_id, line.unit_id,
                            o.currency_id, o.tax_rate)))
                """.formatted(kind), orderId);
        jdbc.update("""
                UPDATE suppliers s
                SET default_settlement_method_id = CASE WHEN active.id IS NOT NULL
                        THEN active.id ELSE s.default_settlement_method_id END,
                    price_style = CASE WHEN active.id IS NOT NULL
                        THEN active.legacy_id ELSE s.price_style END,
                    default_currency_id = COALESCE(o.currency_id, s.default_currency_id),
                    default_tax_rate = COALESCE(o.tax_rate, s.default_tax_rate),
                    version = s.version + 1,
                    updated_at = now(),
                    updated_by = NULLIF(current_setting('app.actor_id', true), '')::uuid
                FROM %1$s_orders o
                LEFT JOIN settlement_methods active ON active.id = o.settlement_method_id
                    AND active.status = '使用' AND NOT active.is_deleted
                WHERE o.id = ? AND NOT o.is_deleted AND o.status IN (0,1)
                  AND s.id = o.supplier_id AND NOT s.is_deleted
                  AND (s.default_settlement_method_id IS DISTINCT FROM
                            CASE WHEN active.id IS NOT NULL
                                 THEN active.id ELSE s.default_settlement_method_id END
                       OR s.price_style IS DISTINCT FROM
                            CASE WHEN active.id IS NOT NULL THEN active.legacy_id ELSE s.price_style END
                       OR s.default_currency_id IS DISTINCT FROM COALESCE(o.currency_id, s.default_currency_id)
                       OR s.default_tax_rate IS DISTINCT FROM COALESCE(o.tax_rate, s.default_tax_rate))
                """.formatted(kind), orderId);
    }
}
