package com.uten.imp.features.purchase.ret;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.common.finance.MoneyPolicy;
import com.uten.imp.common.finance.ProcurementReturnQualityPolicy;
import com.uten.imp.common.finance.ProcurementReturnPayableAuthority;
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
                           source_item.qty, source_item.amount_original, source_item.amount_local,
                           source_item.quantity_semantics,source_item.gift_qty,source_item.gift_base_qty,source_item.charged_base_qty
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
            if (item.getQty().signum()>0 && validatedReceipts.add(sourceReceiptId)) {
                ProcurementReturnPayableAuthority.lockAndValidate(
                        em, "PURCHASE", sourceReceiptId, sourceSupplierId,
                        sourceCurrencyId, sourceRate, sourceSettlementMethodId,
                        sourceReceiptOriginal, sourceReceiptLocal, sourceApPosted);
            }
            ProcurementReturnQualityPolicy.ReturnableSource returnable = item.getQty().signum()==0
                    ?new ProcurementReturnQualityPolicy.ReturnableSource(BigDecimal.ZERO,BigDecimal.ZERO,BigDecimal.ZERO,false)
                    :ProcurementReturnQualityPolicy.lockAndLimit(
                            em, "PURCHASE", item.getReceiptItemId(),
                            sourceQty, sourceUnitRate, sourceOriginal, sourceLocal);
            Object[] prior = (Object[]) em.createNativeQuery("""
                    SELECT COALESCE(SUM(return_item.qty),0),
                           COALESCE(SUM(return_item.amount_original),0),
                           COALESCE(SUM(return_item.amount_local),0),
                           COALESCE(SUM(return_item.charged_base_qty),0),
                           COALESCE(SUM(return_item.gift_qty),0),
                           COALESCE(SUM(return_item.gift_base_qty),0)
                    FROM purchase_return_items return_item
                    JOIN purchase_returns return_doc ON return_doc.id=return_item.return_id
                    WHERE return_item.receipt_item_id=:itemId
                      AND return_doc.id<>:currentReturnId
                      AND return_doc.status=1
                      AND COALESCE(return_item.is_deleted,FALSE)=FALSE
                      AND COALESCE(return_doc.is_deleted,FALSE)=FALSE
                    """).setParameter("itemId", item.getReceiptItemId())
                    .setParameter("currentReturnId", purchaseReturn.getId()).getSingleResult();
            if(com.uten.imp.common.finance.ProcurementQuantities.isExtraGift(item.getQuantitySemantics()) && item.getGiftQty().signum()>0){
                if(!com.uten.imp.common.finance.ProcurementQuantities.isExtraGift((String)source[16]))throw conflict("旧来源赠品记录不是额外实物，不能生成赠品退货");
                BigDecimal giftAvailable=ProcurementReturnQualityPolicy.lockGiftAndLimit(em,item.getReceiptItemId(),decimal(source[17]),decimal(source[18]));
                BigDecimal giftPrior=(BigDecimal)em.createNativeQuery("SELECT COALESCE(SUM(ri.gift_qty),0) FROM purchase_return_items ri JOIN purchase_returns rd ON rd.id=ri.return_id WHERE ri.receipt_item_id=:id AND rd.id<>:current AND rd.status=1 AND NOT ri.is_deleted AND NOT rd.is_deleted AND ri.quantity_semantics='CHARGED_PLUS_GIFT_V1'").setParameter("id",item.getReceiptItemId()).setParameter("current",purchaseReturn.getId()).getSingleResult();
                if(item.getGiftQty().add(giftPrior).compareTo(giftAvailable)>0)throw conflict("赠品退回超过已实收未退的赠品数量");
            }
            ReturnAmounts amounts = item.getQty().signum()==0?new ReturnAmounts(BigDecimal.ZERO,BigDecimal.ZERO):sourceAmounts(
                    item.getQty(), sourcePrice, sourceRate,
                    returnable.qty(), returnable.amountOriginal(), returnable.amountLocal(),
                    decimal(prior[0]), decimal(prior[1]), decimal(prior[2]));
            if(com.uten.imp.common.finance.ProcurementQuantities.isExtraGift(item.getQuantitySemantics())) {
                if(com.uten.imp.common.finance.ProcurementQuantities.isExtraGift((String)source[16])) {
                    item.setChargedBaseQty(returnedBase(item.getQty(),sourceQty,decimal(source[19]),decimal(prior[0]),decimal(prior[3])));
                    item.setGiftBaseQty(returnedBase(item.getGiftQty(),decimal(source[17]),decimal(source[18]),decimal(prior[4]),decimal(prior[5])));
                } else {
                    var quantities=com.uten.imp.common.finance.ProcurementQuantities.of(item.getQuantitySemantics(),item.getQty(),item.getGiftQty(),item.getUnitRate());
                    item.setChargedBaseQty(quantities.chargedBase());item.setGiftBaseQty(quantities.giftBase());
                }
            }
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

    /** Allocate each physical tranche from its source fact; the last return owns the residual. */
    private static BigDecimal returnedBase(BigDecimal requested,BigDecimal sourceQty,BigDecimal sourceBase,
            BigDecimal priorQty,BigDecimal priorBase) {
        if(requested==null || requested.signum()<0)throw conflict("退货分量不合法");
        if(requested.signum()==0)return BigDecimal.ZERO;
        if(sourceQty==null || sourceQty.signum()<=0 || sourceBase==null || sourceBase.signum()<=0
                || priorQty==null || priorQty.signum()<0 || priorBase==null || priorBase.signum()<0)
            throw conflict("退货来源缺少有效冻结基本量，不能重算原实物");
        BigDecimal remainingQty=sourceQty.subtract(priorQty),remainingBase=sourceBase.subtract(priorBase);
        if(requested.compareTo(remainingQty)>0 || remainingBase.signum()<=0)
            throw conflict("退货超过来源剩余原单位量或基本量");
        BigDecimal base=requested.compareTo(remainingQty)==0 ? remainingBase
                :sourceBase.multiply(requested).divide(sourceQty,4,java.math.RoundingMode.DOWN);
        base=com.uten.imp.common.util.FinancialExactAmount.quantity(base,"退货冻结基本量");
        if(base.signum()<=0 || base.compareTo(remainingBase)>0)throw conflict("退货分量小于可记录精度或超过冻结实物余量");
        return base;
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
            throw conflict("采购退货的来源数量、单价、汇率或历史退货累计不正确，请刷新后重试");
        }
        BigDecimal remainingQty = sourceQty.subtract(priorQty);
        BigDecimal remainingOriginal = sourceOriginal.subtract(priorOriginal);
        BigDecimal remainingLocal = sourceLocal.subtract(priorLocal);
        if (remainingQty.signum() < 0 || remainingOriginal.signum() < 0
                || remainingLocal.signum() < 0 || returnQty.compareTo(remainingQty) > 0) {
            throw conflict("采购退货数量或金额超过来源收货行可退余额");
        }
        // 累计退货量对应的来源金额 − 已退金额; 全部退完时取来源全部剩余, 应付原币与本币同时归零。
        MoneyPolicy.LineAmounts amounts = MoneyPolicy.prorateBatch(
                returnQty, priorQty, sourceQty, sourceOriginal, sourceLocal, priorOriginal, priorLocal);
        return new ReturnAmounts(money(amounts.original()), money(amounts.local()));
    }

    private static BigDecimal decimal(Object value) {
        return value == null ? null : value instanceof BigDecimal decimal
                ? decimal : new BigDecimal(value.toString());
    }

    private static BigDecimal money(BigDecimal value) {
        return com.uten.imp.common.util.FinancialExactAmount.canonicalMoney(value, "采购退货金额");
    }

    private static ApiException conflict(String message) {
        return new ApiException(ErrorCode.CONFLICT, message);
    }

    record ReturnAmounts(BigDecimal original, BigDecimal local) {}
}
