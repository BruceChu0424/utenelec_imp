package com.uten.imp.features.purchase.ret;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.common.finance.ProcurementReturnQualityPolicy;
import com.uten.imp.common.finance.ProcurementReturnPayableAuthority;
import jakarta.persistence.EntityManager;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Propagation;
import org.springframework.transaction.annotation.Transactional;

import java.math.BigDecimal;
import java.math.RoundingMode;
import java.util.Comparator;
import java.util.HashSet;
import java.util.List;
import java.util.Objects;
import java.util.UUID;

/** Derives purchase-return credit and stock value from locked receipt facts. */
@Service
@RequiredArgsConstructor
public class PurchaseReturnAmountAuthority {
    private static final short APPROVED = 1;

    private final EntityManager em;
    private final PurchaseReturnItemRepository itemRepo;

    @Transactional(propagation = Propagation.MANDATORY)
    public void apply(PurchaseReturn purchaseReturn, List<PurchaseReturnItem> items) {
        List<UUID> sourceIds = items.stream().map(PurchaseReturnItem::getReceiptItemId).toList();
        requireDistinctReceiptItems(sourceIds);
        List<PurchaseReturnItem> ordered = items.stream()
                .sorted(Comparator.comparing(PurchaseReturnItem::getReceiptItemId))
                .toList();
        BigDecimal totalOriginal = BigDecimal.ZERO;
        BigDecimal totalLocal = BigDecimal.ZERO;
        java.util.Set<UUID> validatedReceipts = new java.util.HashSet<>();
        for (PurchaseReturnItem item : ordered) {
            @SuppressWarnings("unchecked")
            List<Object[]> rows = em.createNativeQuery("""
                    SELECT source_item.price, source_item.unit_rate,source_receipt.id,
                           source_receipt.supplier_id,
                           source_receipt.currency_id, source_receipt.exchange_rate,
                           source_receipt.settlement_method_id, source_receipt.tax_rate,
                           source_item.order_item_id, source_receipt.status,
                           TRUE,source_receipt.total_original,source_receipt.total_local,
                           source_item.qty, source_item.amount_original, source_item.amount_local
                    FROM purchase_receipt_items source_item
                    JOIN purchase_receipts source_receipt
                      ON source_receipt.id=source_item.receipt_id
                    WHERE source_item.id=:itemId
                      AND COALESCE(source_item.is_deleted,FALSE)=FALSE
                      AND COALESCE(source_receipt.is_deleted,FALSE)=FALSE
                    FOR UPDATE OF source_item, source_receipt
                    """).setParameter("itemId", item.getReceiptItemId()).getResultList();
            if (rows.size() != 1) {
                throw conflict("采购退货来源收货明细不存在、已删除或重复");
            }
            Object[] source = rows.getFirst();
            BigDecimal sourcePrice = decimal(source[0]);
            BigDecimal sourceUnitRate = decimal(source[1]);
            UUID sourceReceiptId = (UUID) source[2];
            UUID sourceSupplierId = (UUID) source[3];
            UUID sourceCurrencyId = (UUID) source[4];
            BigDecimal sourceRate = decimal(source[5]);
            UUID sourceSettlementMethodId = (UUID) source[6];
            BigDecimal sourceTaxRate = decimal(source[7]);
            UUID sourceOrderItemId = (UUID) source[8];
            short sourceStatus = ((Number) source[9]).shortValue();
            boolean sourceApPosted = Boolean.TRUE.equals(source[10]);
            BigDecimal sourceReceiptOriginal = decimal(source[11]);
            BigDecimal sourceReceiptLocal = decimal(source[12]);
            BigDecimal sourceQty = decimal(source[13]);
            BigDecimal sourceOriginal = decimal(source[14]);
            BigDecimal sourceLocal = decimal(source[15]);
            if (sourceStatus != APPROVED || sourcePrice == null || sourcePrice.signum() < 0
                    || sourceCurrencyId == null || sourceRate == null || sourceRate.signum() <= 0
                    || sourceSettlementMethodId == null
                    || sourceTaxRate == null || sourceTaxRate.signum() < 0
                    || sourceTaxRate.compareTo(new BigDecimal("100")) > 0
                    || sourceUnitRate == null || sourceUnitRate.signum() <= 0
                    || sourceQty == null || sourceOriginal == null || sourceLocal == null) {
                throw conflict("采购退货来源收货的状态、数量、单价、币种、汇率、税率、结算方式或金额不完整，禁止生成应付贷项");
            }
            if (!Objects.equals(purchaseReturn.getSupplierId(), sourceSupplierId)
                    || !Objects.equals(purchaseReturn.getCurrencyId(), sourceCurrencyId)
                    || purchaseReturn.getExchangeRate() == null
                    || purchaseReturn.getExchangeRate().compareTo(sourceRate) != 0
                    || !Objects.equals(purchaseReturn.getSettlementMethodId(), sourceSettlementMethodId)
                    || purchaseReturn.getTaxRate() == null
                    || purchaseReturn.getTaxRate().compareTo(sourceTaxRate) != 0
                    || !Objects.equals(item.getOrderItemId(), sourceOrderItemId)) {
                throw conflict("采购退货供应商、币种、汇率、税率、结算方式或订单来源与收货事实不一致");
            }
            if (validatedReceipts.add(sourceReceiptId)) {
                ProcurementReturnPayableAuthority.lockAndValidate(
                        em, "PURCHASE", sourceReceiptId, sourceSupplierId,
                        sourceCurrencyId, sourceRate, sourceSettlementMethodId,
                        sourceReceiptOriginal, sourceReceiptLocal, sourceApPosted);
            }
            ProcurementReturnQualityPolicy.ReturnableSource returnable =
                    ProcurementReturnQualityPolicy.lockAndLimit(
                            em, "PURCHASE", item.getReceiptItemId(),
                            sourceQty, sourceUnitRate, sourceOriginal, sourceLocal);
            Object[] prior = (Object[]) em.createNativeQuery("""
                    SELECT COALESCE(SUM(return_item.qty),0),
                           COALESCE(SUM(return_item.amount_original),0),
                           COALESCE(SUM(return_item.amount_local),0)
                    FROM purchase_return_items return_item
                    JOIN purchase_returns return_doc ON return_doc.id=return_item.return_id
                    WHERE return_item.receipt_item_id=:itemId
                      AND return_doc.id<>:currentReturnId
                      AND return_doc.status=1
                      AND COALESCE(return_item.is_deleted,FALSE)=FALSE
                      AND COALESCE(return_doc.is_deleted,FALSE)=FALSE
                    """).setParameter("itemId", item.getReceiptItemId())
                    .setParameter("currentReturnId", purchaseReturn.getId()).getSingleResult();
            ReturnAmounts amounts = sourceAmounts(
                    item.getQty(), sourcePrice, sourceRate,
                    returnable.qty(), returnable.amountOriginal(), returnable.amountLocal(),
                    decimal(prior[0]), decimal(prior[1]), decimal(prior[2]));
            item.setPrice(sourcePrice);
            item.setAmountOriginal(amounts.original());
            item.setAmountLocal(amounts.local());
            totalOriginal = totalOriginal.add(amounts.original());
            totalLocal = totalLocal.add(amounts.local());
        }
        itemRepo.saveAll(items);
        itemRepo.flush();
        purchaseReturn.setTotalOriginal(money(totalOriginal));
        purchaseReturn.setTotalLocal(money(totalLocal));
    }

    static void requireDistinctReceiptItems(List<UUID> sourceIds) {
        if (sourceIds == null || sourceIds.stream().anyMatch(Objects::isNull)
                || new HashSet<>(sourceIds).size() != sourceIds.size()) {
            throw conflict("同一采购收货明细不能在一张退货单中重复引用，且来源不能为空");
        }
    }

    static ReturnAmounts sourceAmounts(
            BigDecimal returnQty, BigDecimal sourcePrice, BigDecimal sourceRate,
            BigDecimal sourceQty, BigDecimal sourceOriginal, BigDecimal sourceLocal,
            BigDecimal priorQty, BigDecimal priorOriginal, BigDecimal priorLocal) {
        if (returnQty == null || returnQty.signum() <= 0
                || sourcePrice == null || sourcePrice.signum() < 0
                || sourceRate == null || sourceRate.signum() <= 0
                || sourceQty == null || sourceQty.signum() <= 0
                || sourceOriginal == null || sourceOriginal.signum() < 0
                || sourceLocal == null || sourceLocal.signum() < 0
                || priorQty == null || priorQty.signum() < 0
                || priorOriginal == null || priorOriginal.signum() < 0
                || priorLocal == null || priorLocal.signum() < 0) {
            throw conflict("采购退货来源数量、单价、汇率或历史退货累计无效");
        }
        BigDecimal remainingQty = sourceQty.subtract(priorQty);
        BigDecimal remainingOriginal = money(sourceOriginal.subtract(priorOriginal));
        BigDecimal remainingLocal = money(sourceLocal.subtract(priorLocal));
        if (remainingQty.signum() < 0 || remainingOriginal.signum() < 0
                || remainingLocal.signum() < 0 || returnQty.compareTo(remainingQty) > 0) {
            throw conflict("采购退货数量或金额超过来源收货行可退余额");
        }
        if (returnQty.compareTo(remainingQty) == 0) {
            return new ReturnAmounts(remainingOriginal, remainingLocal);
        }
        BigDecimal original = money(returnQty.multiply(sourcePrice));
        BigDecimal local = money(original.multiply(sourceRate));
        if (original.compareTo(remainingOriginal) > 0 || local.compareTo(remainingLocal) > 0) {
            throw conflict("采购退货标准金额超过来源收货行剩余金额");
        }
        return new ReturnAmounts(original, local);
    }

    private static BigDecimal decimal(Object value) {
        return value == null ? null : value instanceof BigDecimal decimal
                ? decimal : new BigDecimal(value.toString());
    }

    private static BigDecimal money(BigDecimal value) {
        return value.setScale(4, RoundingMode.HALF_UP);
    }

    private static ApiException conflict(String message) {
        return new ApiException(ErrorCode.CONFLICT, message);
    }

    record ReturnAmounts(BigDecimal original, BigDecimal local) {}
}
