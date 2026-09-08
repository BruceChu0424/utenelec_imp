package com.uten.imp.features.subcontract.receipt;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.common.finance.ProcurementIqcReplacementAllocationService;
import jakarta.persistence.EntityManager;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Propagation;
import org.springframework.transaction.annotation.Transactional;

import java.math.BigDecimal;
import java.util.Comparator;
import java.util.HashSet;
import java.util.List;
import java.util.Objects;
import java.util.UUID;

/** Derives subcontract receipt AP and stock values from finance-approved order facts. */
@Service
@RequiredArgsConstructor
public class SubcontractReceiptAmountAuthority {
    private static final short APPROVED = 1;

    private final EntityManager em;
    private final SubcontractReceiptItemRepository itemRepo;
    private final ProcurementIqcReplacementAllocationService replacementAllocation;

    @Transactional(propagation = Propagation.MANDATORY)
    public void apply(SubcontractReceipt receipt, List<SubcontractReceiptItem> items) {
        List<UUID> sourceIds = items.stream().map(SubcontractReceiptItem::getOrderItemId).toList();
        requireDistinctOrderItems(sourceIds);
        List<SubcontractReceiptItem> ordered = items.stream()
                .sorted(Comparator.comparing(SubcontractReceiptItem::getOrderItemId))
                .toList();
        BigDecimal totalOriginal = BigDecimal.ZERO;
        BigDecimal totalLocal = BigDecimal.ZERO;
        for (SubcontractReceiptItem item : ordered) {
            @SuppressWarnings("unchecked")
            List<Object[]> rows = em.createNativeQuery("""
                    SELECT source_item.price, source_order.supplier_id,
                           source_order.currency_id, source_order.exchange_rate,
                           source_order.settlement_method_id, source_order.tax_rate,
                           source_order.status,
                           COALESCE(source_item.arrival_overage_posted_qty,0),
                           source_item.qty, source_item.amount_original, source_item.amount_local
                    FROM subcontract_order_items source_item
                    JOIN subcontract_orders source_order ON source_order.id=source_item.order_id
                    WHERE source_item.id=:itemId
                      AND COALESCE(source_item.is_deleted,FALSE)=FALSE
                      AND COALESCE(source_order.is_deleted,FALSE)=FALSE
                    FOR UPDATE OF source_item, source_order
                    """).setParameter("itemId", item.getOrderItemId()).getResultList();
            if (rows.size() != 1) throw conflict("委外进仓来源订单明细不存在、已删除或重复");
            Object[] source = rows.getFirst();
            BigDecimal sourcePrice = decimal(source[0]);
            UUID sourceSupplierId = (UUID) source[1];
            UUID sourceCurrencyId = (UUID) source[2];
            BigDecimal sourceRate = decimal(source[3]);
            UUID sourceSettlementMethodId = (UUID) source[4];
            BigDecimal sourceTaxRate = decimal(source[5]);
            short sourceStatus = ((Number) source[6]).shortValue();
            BigDecimal postedOverageQty = decimal(source[7]);
            BigDecimal sourceQty = decimal(source[8]);
            BigDecimal sourceOriginal = decimal(source[9]);
            BigDecimal sourceLocal = decimal(source[10]);
            if (sourceStatus != APPROVED || sourcePrice == null || sourcePrice.signum() < 0
                    || sourceCurrencyId == null || sourceRate == null || sourceRate.signum() <= 0
                    || sourceSettlementMethodId == null || sourceQty == null || sourceQty.signum() <= 0
                    || sourceTaxRate == null || sourceTaxRate.signum() < 0
                    || sourceTaxRate.compareTo(new BigDecimal("100")) > 0
                    || sourceOriginal == null || sourceOriginal.signum() < 0
                    || sourceLocal == null || sourceLocal.signum() < 0) {
                throw conflict("委外进仓来源订单未财务批准或商业快照不完整；历史空结算方式必须先专项核验");
            }
            requireHeaderMatches(receipt.getSupplierId(), receipt.getCurrencyId(),
                    receipt.getExchangeRate(), receipt.getSettlementMethodId(), receipt.getTaxRate(),
                    sourceSupplierId, sourceCurrencyId, sourceRate, sourceSettlementMethodId,
                    sourceTaxRate);
            @SuppressWarnings("unchecked")
            List<BigDecimal> currentAllowance = em.createNativeQuery("""
                    SELECT approved_excess_qty FROM procurement_arrival_exceptions
                    WHERE order_type='SUBCONTRACT' AND receipt_id=:receiptId
                      AND receipt_item_id=:receiptItemId AND order_item_id=:itemId
                      AND status='RECEIPT_ADJUSTED'
                      AND decision IN('APPROVE_ALL','APPROVE_CUSTOM')
                      AND approved_excess_qty>0
                    ORDER BY id FOR UPDATE
                    """).setParameter("receiptId", receipt.getId())
                    .setParameter("receiptItemId", item.getId())
                    .setParameter("itemId", item.getOrderItemId()).getResultList();
            if (currentAllowance.size() > 1) throw conflict("委外到货超量财务授权缺失或重复");
            BigDecimal currentApproved = currentAllowance.isEmpty()
                    ? BigDecimal.ZERO : decimal(currentAllowance.getFirst());
            AuthorizedSource authorized = authorizedSource(
                    sourceQty, sourceOriginal, sourceLocal, sourcePrice, sourceRate,
                    postedOverageQty, currentApproved);
            Object[] prior = (Object[]) em.createNativeQuery("""
                    SELECT COALESCE(SUM(receipt_item.qty),0),
                           COALESCE(SUM(receipt_item.amount_original),0),
                           COALESCE(SUM(receipt_item.amount_local),0),
                           COUNT(*) FILTER(WHERE receipt_item.qty IS NULL OR receipt_item.qty<=0
                             OR receipt_item.amount_original IS NULL OR receipt_item.amount_original<0
                             OR receipt_item.amount_local IS NULL OR receipt_item.amount_local<0)
                    FROM subcontract_receipt_items receipt_item
                    JOIN subcontract_receipts receipt_doc ON receipt_doc.id=receipt_item.receipt_id
                    WHERE receipt_item.order_item_id=:itemId
                      AND receipt_doc.id<>:currentReceiptId AND receipt_doc.status=1
                      AND COALESCE(receipt_item.is_deleted,FALSE)=FALSE
                      AND COALESCE(receipt_doc.is_deleted,FALSE)=FALSE
                    """).setParameter("itemId", item.getOrderItemId())
                    .setParameter("currentReceiptId", receipt.getId()).getSingleResult();
            if (((Number) prior[3]).longValue() != 0) {
                throw conflict("委外订单历史有效进仓数量或金额不完整，必须先专项核对");
            }
            BigDecimal rawPriorQty=decimal(prior[0]);
            BigDecimal rawPriorOriginal=decimal(prior[1]);
            BigDecimal rawPriorLocal=decimal(prior[2]);
            var released=replacementAllocation.releasedCapacity(
                    "SUBCONTRACT",item.getOrderItemId());
            BigDecimal effectivePriorQty=rawPriorQty.subtract(released.qty());
            boolean exactPriceBasis=sourceQty.multiply(sourcePrice).compareTo(sourceOriginal)==0
                    &&sourceOriginal.multiply(sourceRate).compareTo(sourceLocal)==0;
            if(!exactPriceBasis&&(released.amountOriginal()==null||released.amountLocal()==null))
                throw conflict("历史原单金额与单价不一致且退回金额没有有限表示，请保留来源待核对");
            BigDecimal effectivePriorOriginal=exactPriceBasis?money(effectivePriorQty.multiply(sourcePrice))
                    :money(rawPriorOriginal.subtract(released.amountOriginal()));
            BigDecimal effectivePriorLocal=exactPriceBasis?money(effectivePriorOriginal.multiply(sourceRate))
                    :money(rawPriorLocal.subtract(released.amountLocal()));
            if(effectivePriorQty.signum()<0||effectivePriorOriginal.signum()<0
                    ||effectivePriorLocal.signum()<0){
                throw conflict("委外IQC失败退回释放额度超过历史有效进仓累计");
            }
            ReceiptAmounts amounts = sourceAmounts(
                    item.getQty(), sourcePrice, sourceRate,
                    authorized.qty(), authorized.original(), authorized.local(),
                    effectivePriorQty,effectivePriorOriginal,effectivePriorLocal);
            item.setPrice(sourcePrice);
            item.setAmountOriginal(amounts.original());
            item.setAmountLocal(amounts.local());
            itemRepo.saveAndFlush(item);
            item.setReplacementIntent(replacementAllocation.allocateForReceiptItem(
                    "SUBCONTRACT",receipt.getId(),item.getId(),item.getOrderItemId(),
                    item.getQty(),item.getUnitRate(),amounts.original(),amounts.local(),
                    authorized.qty(),rawPriorQty,item.getReplacementIntent()));
            totalOriginal = totalOriginal.add(amounts.original());
            totalLocal = totalLocal.add(amounts.local());
        }
        itemRepo.saveAll(items);
        itemRepo.flush();
        receipt.setTotalOriginal(money(totalOriginal));
        receipt.setTotalLocal(money(totalLocal));
    }

    static void requireDistinctOrderItems(List<UUID> sourceIds) {
        if (sourceIds == null || sourceIds.stream().anyMatch(Objects::isNull)
                || new HashSet<>(sourceIds).size() != sourceIds.size()) {
            throw conflict("同一委外订单明细不能在一张进仓单中重复引用，且来源不能为空");
        }
    }

    static void requireHeaderMatches(
            UUID supplierId, UUID currencyId, BigDecimal rate, UUID settlementMethodId,
            BigDecimal taxRate,
            UUID sourceSupplierId, UUID sourceCurrencyId, BigDecimal sourceRate,
            UUID sourceSettlementMethodId, BigDecimal sourceTaxRate) {
        if (!Objects.equals(supplierId, sourceSupplierId)
                || !Objects.equals(currencyId, sourceCurrencyId)
                || rate == null || sourceRate == null || rate.compareTo(sourceRate) != 0
                || !Objects.equals(settlementMethodId, sourceSettlementMethodId)
                || taxRate == null || sourceTaxRate == null
                || taxRate.compareTo(sourceTaxRate) != 0) {
            throw conflict("委外进仓委外商、币种、汇率、税率或结算方式与财务批准订单不一致");
        }
    }

    static AuthorizedSource authorizedSource(
            BigDecimal baseQty, BigDecimal baseOriginal, BigDecimal baseLocal,
            BigDecimal sourcePrice, BigDecimal sourceRate,
            BigDecimal postedOverageQty, BigDecimal currentApprovedOverageQty) {
        if (baseQty == null || baseQty.signum() <= 0
                || baseOriginal == null || baseOriginal.signum() < 0
                || baseLocal == null || baseLocal.signum() < 0
                || sourcePrice == null || sourcePrice.signum() < 0
                || sourceRate == null || sourceRate.signum() <= 0
                || postedOverageQty == null || postedOverageQty.signum() < 0
                || currentApprovedOverageQty == null || currentApprovedOverageQty.signum() < 0) {
            throw conflict("委外到货授权数量或金额快照无效");
        }
        BigDecimal overageQty = postedOverageQty.add(currentApprovedOverageQty);
        BigDecimal overageOriginal = money(overageQty.multiply(sourcePrice));
        BigDecimal overageLocal = money(overageOriginal.multiply(sourceRate));
        return new AuthorizedSource(baseQty.add(overageQty),
                money(baseOriginal.add(overageOriginal)), money(baseLocal.add(overageLocal)));
    }

    static ReceiptAmounts sourceAmounts(
            BigDecimal receiptQty, BigDecimal sourcePrice, BigDecimal sourceRate,
            BigDecimal sourceQty, BigDecimal sourceOriginal, BigDecimal sourceLocal,
            BigDecimal priorQty, BigDecimal priorOriginal, BigDecimal priorLocal) {
        if (receiptQty == null || receiptQty.signum() <= 0 || sourcePrice == null || sourcePrice.signum() < 0
                || sourceRate == null || sourceRate.signum() <= 0 || sourceQty == null || sourceQty.signum() <= 0
                || sourceOriginal == null || sourceOriginal.signum() < 0
                || sourceLocal == null || sourceLocal.signum() < 0
                || priorQty == null || priorQty.signum() < 0
                || priorOriginal == null || priorOriginal.signum() < 0
                || priorLocal == null || priorLocal.signum() < 0) {
            throw conflict("委外进仓来源数量、加工单价、汇率或历史进仓累计无效");
        }
        BigDecimal remainingQty = sourceQty.subtract(priorQty);
        BigDecimal remainingOriginal = money(sourceOriginal.subtract(priorOriginal));
        BigDecimal remainingLocal = money(sourceLocal.subtract(priorLocal));
        if (remainingQty.signum() < 0 || remainingOriginal.signum() < 0
                || remainingLocal.signum() < 0 || receiptQty.compareTo(remainingQty) > 0) {
            throw conflict("委外进仓数量或金额超过财务批准订单行剩余额度");
        }
        if (receiptQty.compareTo(remainingQty) == 0) {
            return new ReceiptAmounts(remainingOriginal, remainingLocal);
        }
        BigDecimal original = money(receiptQty.multiply(sourcePrice));
        BigDecimal local = money(original.multiply(sourceRate));
        if (original.compareTo(remainingOriginal) > 0 || local.compareTo(remainingLocal) > 0) {
            throw conflict("委外进仓标准金额超过财务批准订单行剩余金额");
        }
        return new ReceiptAmounts(original, local);
    }

    private static BigDecimal decimal(Object value) {
        return value == null ? null : value instanceof BigDecimal decimal
                ? decimal : new BigDecimal(value.toString());
    }

    private static BigDecimal money(BigDecimal value) {
        return com.uten.imp.common.util.FinancialExactAmount.canonicalMoney(value,"委外收货金额");
    }

    private static ApiException conflict(String message) {
        return new ApiException(ErrorCode.CONFLICT, message);
    }

    record ReceiptAmounts(BigDecimal original, BigDecimal local) {}

    record AuthorizedSource(BigDecimal qty, BigDecimal original, BigDecimal local) {}
}
