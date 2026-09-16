package com.uten.imp.features.purchase.common;

import lombok.RequiredArgsConstructor;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Propagation;
import org.springframework.transaction.annotation.Transactional;

import java.util.UUID;

/**
 * 采购/委外链「主档默认值」下单写回（V593 单一事实源，与货品归属仓/客户条款同一模式）：
 * 每次保存采购/委外订货单，把本次选择写回主档——
 *
 * <ul>
 *   <li>货品：默认供应商（复用 goods.default_supplier_id）+ 采购单价/委外加工单价
 *       （本次单上该货品最后一个有效行价；空价保值）；</li>
 *   <li>供应商：默认条款 币种/税率/结账方式（结账方式复用 V452 既有列）。</li>
 * </ul>
 *
 * <p>结账方式必须过 {@code fn_sync_supplier_default_settlement_method_reference()}
 * 触发器（V452，与客户侧 V285 同款契约）：① 只写「使用中且未软删」的字典值
 * （订单可能记着停用值，直接写会被触发器整单打回——V592 客户侧生产事故同款）；
 * ② UUID 与 price_style 旧快照按字典 legacy_id 成对写入。空项保值、值没变不落盘
 * （幂等守卫）。调用方在单据保存的同一事务内、orderRepo.save 之后按订单 id 调用
 * （按 id 查库取事实，不依赖调用方内存态）。
 */
@Service
@RequiredArgsConstructor
public class ProcurementMasterDefaultsSyncService {

    private final JdbcTemplate jdbc;

    /** 保存采购单后写回：行货品 → 默认供应商 + 采购单价；单头 → 供应商默认条款。 */
    @Transactional(propagation = Propagation.MANDATORY)
    public void syncFromPurchaseOrder(UUID orderId) {
        if (orderId == null) return;

        jdbc.update(
                """
                UPDATE goods g
                SET default_supplier_id = o.supplier_id,
                    default_purchase_price =
                        COALESCE(line.price, g.default_purchase_price)
                FROM (
                    SELECT DISTINCT ON (i.goods_id)
                           i.order_id, i.goods_id, i.price
                    FROM purchase_order_items i
                    WHERE i.order_id = ? AND i.is_deleted = false
                      AND i.goods_id IS NOT NULL
                    ORDER BY i.goods_id, i.id DESC
                ) line
                JOIN purchase_orders o ON o.id = line.order_id
                WHERE o.supplier_id IS NOT NULL
                  AND g.id = line.goods_id
                  AND (g.default_supplier_id IS DISTINCT FROM o.supplier_id
                       OR g.default_purchase_price IS DISTINCT FROM
                            COALESCE(line.price, g.default_purchase_price))
                """,
                orderId);

        syncSupplierTermsPurchase(orderId);
    }

    /** 保存委外单后写回：行货品 → 默认供应商 + 委外加工单价；单头 → 供应商默认条款。 */
    @Transactional(propagation = Propagation.MANDATORY)
    public void syncFromSubcontractOrder(UUID orderId) {
        if (orderId == null) return;

        jdbc.update(
                """
                UPDATE goods g
                SET default_supplier_id = o.supplier_id,
                    default_subcontract_price =
                        COALESCE(line.price, g.default_subcontract_price)
                FROM (
                    SELECT DISTINCT ON (i.goods_id)
                           i.order_id, i.goods_id, i.price
                    FROM subcontract_order_items i
                    WHERE i.order_id = ? AND i.is_deleted = false
                      AND i.goods_id IS NOT NULL
                    ORDER BY i.goods_id, i.id DESC
                ) line
                JOIN subcontract_orders o ON o.id = line.order_id
                WHERE o.supplier_id IS NOT NULL
                  AND g.id = line.goods_id
                  AND (g.default_supplier_id IS DISTINCT FROM o.supplier_id
                       OR g.default_subcontract_price IS DISTINCT FROM
                            COALESCE(line.price, g.default_subcontract_price))
                """,
                orderId);

        syncSupplierTermsSubcontract(orderId);
    }


    /** 供应商默认条款写回（采购单头条款；结账方式成对过 V452 触发器）。 */
    private void syncSupplierTermsPurchase(UUID orderId) {
        jdbc.update(SUPPLIER_TERMS_PURCHASE_SQL, orderId);
    }

    /** 供应商默认条款写回（委外单头条款；同上）。 */
    private void syncSupplierTermsSubcontract(UUID orderId) {
        jdbc.update(SUPPLIER_TERMS_SUBCONTRACT_SQL, orderId);
    }

    private static final String SUPPLIER_TERMS_PURCHASE_SQL = """
            UPDATE suppliers s
            SET default_settlement_method_id =
                    CASE WHEN active.id IS NOT NULL
                         THEN active.id ELSE s.default_settlement_method_id END,
                price_style =
                    CASE WHEN active.id IS NOT NULL
                         THEN active.legacy_id ELSE s.price_style END,
                default_currency_id = COALESCE(o.currency_id, s.default_currency_id),
                default_tax_rate = COALESCE(o.tax_rate, s.default_tax_rate)
            FROM purchase_orders o
            LEFT JOIN settlement_methods active
              ON active.id = o.settlement_method_id
             AND active.status = '使用'
             AND COALESCE(active.is_deleted, FALSE) = FALSE
            WHERE o.id = ?
              AND o.supplier_id IS NOT NULL
              AND s.id = o.supplier_id
              AND (s.default_settlement_method_id IS DISTINCT FROM
                        CASE WHEN active.id IS NOT NULL
                             THEN active.id ELSE s.default_settlement_method_id END
                   OR s.price_style IS DISTINCT FROM
                        CASE WHEN active.id IS NOT NULL
                             THEN active.legacy_id ELSE s.price_style END
                   OR s.default_currency_id IS DISTINCT FROM
                        COALESCE(o.currency_id, s.default_currency_id)
                   OR s.default_tax_rate IS DISTINCT FROM
                        COALESCE(o.tax_rate, s.default_tax_rate))
            """;

    private static final String SUPPLIER_TERMS_SUBCONTRACT_SQL = """
            UPDATE suppliers s
            SET default_settlement_method_id =
                    CASE WHEN active.id IS NOT NULL
                         THEN active.id ELSE s.default_settlement_method_id END,
                price_style =
                    CASE WHEN active.id IS NOT NULL
                         THEN active.legacy_id ELSE s.price_style END,
                default_currency_id = COALESCE(o.currency_id, s.default_currency_id),
                default_tax_rate = COALESCE(o.tax_rate, s.default_tax_rate)
            FROM subcontract_orders o
            LEFT JOIN settlement_methods active
              ON active.id = o.settlement_method_id
             AND active.status = '使用'
             AND COALESCE(active.is_deleted, FALSE) = FALSE
            WHERE o.id = ?
              AND o.supplier_id IS NOT NULL
              AND s.id = o.supplier_id
              AND (s.default_settlement_method_id IS DISTINCT FROM
                        CASE WHEN active.id IS NOT NULL
                             THEN active.id ELSE s.default_settlement_method_id END
                   OR s.price_style IS DISTINCT FROM
                        CASE WHEN active.id IS NOT NULL
                             THEN active.legacy_id ELSE s.price_style END
                   OR s.default_currency_id IS DISTINCT FROM
                        COALESCE(o.currency_id, s.default_currency_id)
                   OR s.default_tax_rate IS DISTINCT FROM
                        COALESCE(o.tax_rate, s.default_tax_rate))
            """;
}
