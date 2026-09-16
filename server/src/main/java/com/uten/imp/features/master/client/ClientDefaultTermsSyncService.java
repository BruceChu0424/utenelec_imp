package com.uten.imp.features.master.client;

import lombok.RequiredArgsConstructor;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Propagation;
import org.springframework.transaction.annotation.Transactional;

import java.util.UUID;

/**
 * 客户「默认销售条款」下单写回（V592 单一事实源，与货品归属仓同思路）：
 * 每次保存/修改销售订货单，把单头条款记到客户行——下次新建单预填即最新。
 *
 * <p>结账方式一列必须过 {@code fn_sync_client_default_settlement_method_reference()}
 * 触发器（V285）的闸：① 指向的结账方式必须「使用中」且未软删——订单可能记着已
 * 停用的字典值（订单 FK 不拦停用），直接写会被触发器整单打回；② UUID 与 price_style
 * 旧快照必须成对一致——这里按字典的 legacy_id 成对写入，不依赖触发器重算。
 * 货运策略/币种没有触发器约束：空项保持原值（历史单未必三项全填）。
 * 值没变不落盘（幂等守卫，防无谓审计/版本行）。
 */
@Service
@RequiredArgsConstructor
public class ClientDefaultTermsSyncService {

    private final JdbcTemplate jdbc;

    /**
     * 写回某客户最近一次订货条款。失败安全：客户为空时静默跳过（订单过账本身
     * 已成功，条款记忆绝不反过来阻断下单）。
     */
    @Transactional(propagation = Propagation.MANDATORY)
    public void syncOnOrderTerms(
            UUID clientId,
            UUID settlementMethodId,
            String shipmentPolicy,
            UUID currencyId) {
        if (clientId == null) {
            return;
        }
        String shipment = shipmentPolicy == null || shipmentPolicy.isBlank()
                ? null
                : shipmentPolicy.trim();
        jdbc.update(
                """
                UPDATE clients c
                SET default_settlement_method_id = CASE WHEN sm.id IS NOT NULL
                        THEN sm.id ELSE c.default_settlement_method_id END,
                    price_style = CASE WHEN sm.id IS NOT NULL
                        THEN sm.legacy_id ELSE c.price_style END,
                    default_shipment_policy =
                        COALESCE(CAST(? AS text), c.default_shipment_policy),
                    default_currency_id =
                        COALESCE(CAST(? AS uuid), c.default_currency_id)
                FROM (SELECT CAST(? AS uuid) AS wanted) w
                LEFT JOIN settlement_methods sm
                  ON sm.id = w.wanted
                 AND sm.status = '使用'
                 AND COALESCE(sm.is_deleted, FALSE) = FALSE
                WHERE c.id = CAST(? AS uuid)
                  AND (
                        c.default_settlement_method_id IS DISTINCT FROM
                            CASE WHEN sm.id IS NOT NULL
                                 THEN sm.id ELSE c.default_settlement_method_id END
                     OR c.price_style IS DISTINCT FROM
                            CASE WHEN sm.id IS NOT NULL
                                 THEN sm.legacy_id ELSE c.price_style END
                     OR c.default_shipment_policy IS DISTINCT FROM
                            COALESCE(CAST(? AS text), c.default_shipment_policy)
                     OR c.default_currency_id IS DISTINCT FROM
                            COALESCE(CAST(? AS uuid), c.default_currency_id))
                """,
                shipment,
                currencyId,
                settlementMethodId,
                clientId,
                shipment,
                currencyId);
    }
}
