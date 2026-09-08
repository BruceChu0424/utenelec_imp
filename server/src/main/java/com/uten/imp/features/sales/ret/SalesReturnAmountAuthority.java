package com.uten.imp.features.sales.ret;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import jakarta.persistence.EntityManager;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Propagation;
import org.springframework.transaction.annotation.Transactional;

import java.math.BigDecimal;
import java.math.RoundingMode;
import java.util.HashSet;
import java.util.List;
import java.util.Objects;
import java.util.Set;
import java.util.UUID;

/** New sales-return credits are derived from shipped commercial and receivable facts. */
@Service
@RequiredArgsConstructor
public class SalesReturnAmountAuthority {
    private final EntityManager em;
    private final SalesReturnItemRepository itemRepo;

    @Transactional(propagation = Propagation.MANDATORY)
    public boolean apply(SalesReturn document, List<SalesReturnItem> items) {
        Set<UUID> sourceIds = new HashSet<>();
        for (SalesReturnItem item : items) {
            if (item.getOutItemId() == null || !sourceIds.add(item.getOutItemId())) {
                throw conflict("销售退货每行须关联唯一的原出货明细；历史无来源单据请先核对并补齐来源");
            }
        }
        @SuppressWarnings("unchecked")
        List<Object[]> rows = em.createNativeQuery("""
                SELECT item.id, shipment.id, shipment.client_id, shipment.currency_id,
                       shipment.exchange_rate, shipment.settlement_method_id, shipment.tax_rate,
                       shipment.status, shipment.warehouse_work_status, shipment.ar_posted,
                       shipment.total_original, shipment.total_local,
                       item.qty, item.price, item.discount, item.amount_original, item.amount_local,
                       item.returned_qty, item.returned_amount, item.order_item_id,
                       shipment.shipment_kind,shipment.billing_mode,shipment.finance_gate_version,shipment.finance_release_event_id
                FROM sales_shipment_items item
                JOIN sales_shipments shipment ON shipment.id = item.shipment_id
                WHERE item.id IN (:ids) AND NOT item.is_deleted AND NOT shipment.is_deleted
                ORDER BY shipment.id, item.id FOR UPDATE OF shipment, item
                """).setParameter("ids", sourceIds).getResultList();
        if (rows.size() != sourceIds.size()) throw conflict("原出货明细不存在或已删除");
        var byId = new java.util.HashMap<UUID, Object[]>();
        Set<UUID> validatedShipments = new HashSet<>();
        for (Object[] row : rows) {
            byId.put((UUID) row[0], row);
            requireSourceHeader(document, row);
            UUID shipmentId = (UUID) row[1];
            if (validatedShipments.add(shipmentId)) validateReceivable(row);
        }
        if (validatedShipments.size() != 1) throw conflict("一张销售退货单只能引用同一张实际出货单");
        var priorBySource = loadPriorReturns(document, sourceIds);
        BigDecimal totalOriginal = BigDecimal.ZERO;
        BigDecimal totalLocal = BigDecimal.ZERO;
        for (SalesReturnItem item : items) {
            Object[] row = byId.get(item.getOutItemId());
            if (!Objects.equals(item.getOrderItemId(), row[19])) {
                throw conflict("销售退货订单行必须与实际出货来源一致");
            }
            Object[] prior = priorBySource.getOrDefault(item.getOutItemId(),
                    new Object[]{BigDecimal.ZERO, BigDecimal.ZERO, BigDecimal.ZERO, true, 0L, 0L});
            if (!Boolean.TRUE.equals(prior[3])) {
                throw conflict("历史退货存在不同客户、币种、汇率或结算方式，请先财务对账");
            }
            if (!same(decimal(row[17]), decimal(prior[0])) || !same(decimal(row[18]), decimal(prior[2]))) {
                throw conflict("原出货累计退货量或金额与有效退货单不一致，请先核对历史累计");
            }
            Amounts amounts = amounts(item.getQty(), decimal(row[12]), decimal(row[15]),
                    decimal(row[16]), decimal(prior[0]), decimal(prior[1]), decimal(prior[2]),
                    ((Number) prior[4]).longValue(), ((Number) prior[5]).longValue());
            item.setPrice(decimal(row[13]));
            item.setDiscount(decimal(row[14]));
            item.setAmountOriginal(amounts.original());
            item.setAmountLocal(amounts.local());
            totalOriginal = totalOriginal.add(amounts.original());
            totalLocal = totalLocal.add(amounts.local());
        }
        itemRepo.saveAll(items);
        itemRepo.flush();
        document.setTotalOriginal(totalOriginal);
        document.setTotalLocal(totalLocal);
        return isExplicitFreeSource(rows.getFirst());
    }

    private java.util.Map<UUID, Object[]> loadPriorReturns(SalesReturn returned, Set<UUID> sourceIds) {
        @SuppressWarnings("unchecked")
        List<Object[]> rows = em.createNativeQuery("""
                SELECT item.out_item_id, COALESCE(SUM(item.qty) FILTER (WHERE document.status=1), 0),
                       COALESCE(SUM(item.amount_original) FILTER (WHERE document.status=1), 0),
                       COALESCE(SUM(item.amount_local) FILTER (WHERE document.status=1), 0),
                       COALESCE(bool_and(document.client_id = :clientId
                           AND document.currency_id IS NOT DISTINCT FROM CAST(:currencyId AS uuid)
                           AND document.exchange_rate IS NOT DISTINCT FROM :rate
                           AND document.tax_rate IS NOT DISTINCT FROM :taxRate
                           AND document.settlement_method_id IS NOT DISTINCT FROM CAST(:settlementId AS uuid)
                           AND item.qty>0 AND item.amount_original>=0 AND item.amount_local>=0)
                           FILTER (WHERE document.status=1), TRUE),
                       COUNT(*), COUNT(*) FILTER (WHERE document.status=-1)
                FROM sales_return_items item
                JOIN sales_returns document ON document.id = item.return_id
                WHERE item.out_item_id IN (:sourceIds) AND document.id <> :returnId
                  AND document.status IN (1,-1) AND NOT item.is_deleted AND NOT document.is_deleted
                GROUP BY item.out_item_id
                """).setParameter("sourceIds", sourceIds).setParameter("returnId", returned.getId())
                .setParameter("clientId", returned.getClientId()).setParameter("currencyId", returned.getCurrencyId())
                .setParameter("rate", returned.getExchangeRate()).setParameter("taxRate", returned.getTaxRate())
                .setParameter("settlementId", returned.getSettlementMethodId())
                .getResultList();
        var bySource = new java.util.HashMap<UUID, Object[]>();
        for (Object[] row : rows) bySource.put((UUID) row[0], new Object[]{row[1], row[2], row[3], row[4], row[5], row[6]});
        return bySource;
    }

    private static void requireSourceHeader(SalesReturn document, Object[] row) {
        boolean free=isExplicitFreeSource(row);
        BigDecimal rate = decimal(row[4]);
        BigDecimal tax = decimal(row[6]);
        if (row[7] == null || ((Number) row[7]).intValue() != 1
                || !"SHIPPED".equals(row[8]) || (!free && !Boolean.TRUE.equals(row[9]))
                || (free && Boolean.TRUE.equals(row[9]))
                || row[3] == null || rate == null || rate.signum() <= 0
                || tax == null || tax.signum() < 0 || tax.compareTo(new BigDecimal("100")) > 0
                || decimal(row[13]) == null || decimal(row[13]).signum() < 0) {
            throw conflict("来源须为已实际发运的有效收费或明确免费出货单，且原币种、汇率、税率和单价完整");
        }
        if (!Objects.equals(document.getClientId(), row[2])
                || (document.getCurrencyId() != null && !Objects.equals(document.getCurrencyId(), row[3]))
                || (document.getExchangeRate() != null && !same(document.getExchangeRate(), rate))
                || (document.getSettlementMethodId() != null && !Objects.equals(document.getSettlementMethodId(), row[5]))
                || (document.getTaxRate() != null && !same(document.getTaxRate(), tax))) {
            throw conflict("退货客户、币种、汇率、税率或结算方式与原发运事实不一致");
        }
        document.setCurrencyId((UUID) row[3]);
        document.setExchangeRate(rate);
        document.setSettlementMethodId((UUID) row[5]);
        document.setTaxRate(tax);
    }

    private void validateReceivable(Object[] source) {
        @SuppressWarnings("unchecked")
        List<Object[]> ledgers = em.createNativeQuery("""
                SELECT client_id, currency_id, exchange_rate, settlement_type_id,
                       amount_original, amount_original_local
                FROM ar_ap_ledger
                WHERE source_doc_type = 'SALES_SHIPMENT' AND source_doc_id = :id
                  AND direction = 'AR' AND status = 1 AND NOT is_deleted
                ORDER BY id FOR UPDATE
                """).setParameter("id", source[1]).getResultList();
        if (isExplicitFreeSource(source)) {
            if (!ledgers.isEmpty() || decimal(source[10]).signum()!=0 || decimal(source[11]).signum()!=0
                    || decimal(source[13]).signum()!=0 || decimal(source[15]).signum()!=0 || decimal(source[16]).signum()!=0) {
                throw conflict("免费出货的原货款或应收事实不一致，请先财务核对");
            }
            return;
        }
        if (ledgers.size() != 1) throw conflict("原出货有效应收缺失或重复，禁止无债权生成退货贷项");
        Object[] ar = ledgers.getFirst();
        if (!Objects.equals(ar[0], source[2]) || !Objects.equals(ar[1], source[3])
                || !same(decimal(ar[2]), decimal(source[4])) || !Objects.equals(ar[3], source[5])
                || !same(decimal(ar[4]), decimal(source[10])) || !same(decimal(ar[5]), decimal(source[11]))) {
            throw conflict("原出货与正式应收的客户、币种、汇率、结算或双币金额不一致");
        }
    }

    private static boolean isExplicitFreeSource(Object[] row) {
        return row.length>=24 && "DIRECT_CUSTOMER".equals(row[20]) && "FREE".equals(row[21])
                && row[22] instanceof Number version && version.intValue()>=2 && row[23]!=null;
    }

    static Amounts amounts(BigDecimal quantity, BigDecimal sourceQuantity,
            BigDecimal sourceOriginal, BigDecimal sourceLocal, BigDecimal priorQuantity,
            BigDecimal priorOriginal, BigDecimal priorLocal) {
        return amounts(quantity, sourceQuantity, sourceOriginal, sourceLocal,
                priorQuantity, priorOriginal, priorLocal, 0, 0);
    }

    static Amounts amounts(BigDecimal quantity, BigDecimal sourceQuantity,
            BigDecimal sourceOriginal, BigDecimal sourceLocal, BigDecimal priorQuantity,
            BigDecimal priorOriginal, BigDecimal priorLocal, long historicalAllocations, long reversedAllocations) {
        if (quantity == null || quantity.signum() <= 0 || sourceQuantity == null || sourceQuantity.signum() <= 0
                || sourceOriginal == null || sourceOriginal.signum() < 0 || sourceLocal == null || sourceLocal.signum() < 0
                || priorQuantity == null || priorQuantity.signum() < 0 || priorOriginal == null || priorOriginal.signum() < 0
                || priorLocal == null || priorLocal.signum() < 0 || priorQuantity.add(quantity).compareTo(sourceQuantity) > 0
                || priorOriginal.compareTo(sourceOriginal) > 0 || priorLocal.compareTo(sourceLocal) > 0
                || historicalAllocations < 0 || reversedAllocations < 0 || reversedAllocations > historicalAllocations) {
            throw conflict("退货数量或来源累计无效，不能超过实际发运剩余可退量");
        }
        // Reversing an earlier slice leaves the later slice's immutable rounding
        // increment intact. Only actual reversal history enables a bounded rounding
        // allowance; it never excuses an arbitrary historical credit or over-credit.
        BigDecimal roundingAllowance = reversedAllocations == 0 ? BigDecimal.ZERO
                : new BigDecimal("0.0001").multiply(BigDecimal.valueOf(historicalAllocations));
        if (prorate(sourceOriginal, priorQuantity, sourceQuantity).subtract(priorOriginal).abs()
                    .compareTo(roundingAllowance) > 0
                || prorate(sourceLocal, priorQuantity, sourceQuantity).subtract(priorLocal).abs()
                    .compareTo(roundingAllowance) > 0) {
            throw conflict("历史退货累计金额与原发运分摊不一致，请财务先核对，不能自动补猜差额");
        }
        BigDecimal cumulative = priorQuantity.add(quantity);
        return new Amounts(prorate(sourceOriginal, cumulative, sourceQuantity).subtract(priorOriginal).max(BigDecimal.ZERO),
                prorate(sourceLocal, cumulative, sourceQuantity).subtract(priorLocal).max(BigDecimal.ZERO));
    }

    private static BigDecimal prorate(BigDecimal amount, BigDecimal quantity, BigDecimal sourceQuantity) {
        return amount.multiply(quantity).divide(sourceQuantity, 4, RoundingMode.HALF_UP);
    }
    private static BigDecimal decimal(Object value) { return value == null ? null : (BigDecimal) value; }
    private static boolean same(BigDecimal left, BigDecimal right) {
        return left != null && right != null && left.compareTo(right) == 0;
    }
    private static ApiException conflict(String message) { return new ApiException(ErrorCode.CONFLICT, message); }
    record Amounts(BigDecimal original, BigDecimal local) {}
}
