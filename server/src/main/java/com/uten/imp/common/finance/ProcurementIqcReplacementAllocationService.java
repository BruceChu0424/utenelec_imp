package com.uten.imp.common.finance;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.security.SecurityContextCurrentUser;
import jakarta.persistence.EntityManager;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Propagation;
import org.springframework.transaction.annotation.Transactional;

import java.math.BigDecimal;
import java.util.List;
import java.util.ArrayList;
import java.util.Set;
import java.util.UUID;

/**
 * Explicitly consumes the receipt capacity released by a physically returned
 * IQC-failed slice.  It never writes ordinary receipt returned_qty.
 *
 * <p>ADR-144: arrival capacity is split into owed (the original normal remainder, without the
 * purchase over-receipt tolerance), tolerance (what is left of T) and replacement. Only
 * owed &gt; 0 together with replacement &gt; 0 is ambiguous; under the automatic source a receipt
 * with nothing owed takes the replacement first, then the tolerance. Consumption order is
 * replacement, owed, tolerance.
 */
@Service
@RequiredArgsConstructor
public class ProcurementIqcReplacementAllocationService {
    private static final Set<String> TYPES=Set.of("PURCHASE","SUBCONTRACT");

    private final EntityManager em;
    private final SecurityContextCurrentUser currentUser;

    @Transactional(propagation=Propagation.MANDATORY)
    public ReleasedCapacity releasedCapacity(String rawType,UUID orderItemId){
        String type=type(rawType);
        Object[] row=(Object[])em.createNativeQuery("""
                SELECT COALESCE(SUM(failed_qty),0),
                       COALESCE(SUM(failed_base_qty),0),
                       CASE WHEN COUNT(*)=COUNT(failed_amount_original) THEN COALESCE(SUM(failed_amount_original),0) END,
                       CASE WHEN COUNT(*)=COUNT(failed_amount_local) THEN COALESCE(SUM(failed_amount_local),0) END
                FROM procurement_iqc_rejection_cases rejection
                WHERE receipt_type=:type AND order_item_id=:orderItemId
                  AND NOT EXISTS(SELECT 1 FROM procurement_inspection_items gift WHERE gift.id=rejection.inspection_item_id AND gift.quantity_tranche='GIFT')
                  AND is_deleted=FALSE AND return_recorded_at IS NOT NULL
                  AND status IN(
                      'RETURN_RECORDED','CREDIT_CONFIRMED',
                      'CLOSED_NO_CREDIT','FINANCE_EXCEPTION')
                """).setParameter("type",type)
                .setParameter("orderItemId",orderItemId).getSingleResult();
        return new ReleasedCapacity(
                decimal(row[0]),decimal(row[1]),money(row[2]),money(row[3]));
    }

    /** Free physical failures release only the separate gift capacity, with zero commercial amounts. */
    @Transactional(propagation=Propagation.MANDATORY)
    public ReleasedCapacity releasedGiftCapacity(String rawType,UUID orderItemId) {
        String type=type(rawType);
        if(!"PURCHASE".equals(type)) return new ReleasedCapacity(BigDecimal.ZERO,BigDecimal.ZERO,BigDecimal.ZERO,BigDecimal.ZERO);
        Object[] row=(Object[])em.createNativeQuery("""
                SELECT COALESCE(SUM(rejection.failed_qty),0),COALESCE(SUM(rejection.failed_base_qty),0),
                       COALESCE(SUM(rejection.failed_amount_original),0),COALESCE(SUM(rejection.failed_amount_local),0)
                FROM procurement_iqc_rejection_cases rejection
                JOIN procurement_inspection_items inspection ON inspection.id=rejection.inspection_item_id
                WHERE rejection.receipt_type=:type AND rejection.order_item_id=:orderItemId
                  AND inspection.quantity_tranche='GIFT'
                  AND rejection.is_deleted=FALSE AND rejection.return_recorded_at IS NOT NULL
                  AND rejection.status IN ('RETURN_RECORDED','CREDIT_CONFIRMED','CLOSED_NO_CREDIT','FINANCE_EXCEPTION')
                """).setParameter("type",type).setParameter("orderItemId",orderItemId).getSingleResult();
        if(decimal(row[2]).signum()!=0 || decimal(row[3]).signum()!=0)
            throw conflict("赠品退回容量包含非零货款，请核对原质检分项");
        return new ReleasedCapacity(decimal(row[0]),decimal(row[1]),BigDecimal.ZERO,BigDecimal.ZERO);
    }

    /** Gift replacement owns a physical/zero-funding share; it never consumes a charged allocation. */
    @Transactional(propagation=Propagation.MANDATORY)
    public String allocateGiftForReceiptItem(String rawType,UUID receiptId,UUID receiptItemId,UUID orderItemId,
            BigDecimal giftQty,BigDecimal frozenGiftBaseQty,BigDecimal unitRate,
            BigDecimal authorizedGiftQty,BigDecimal rawPriorGiftQty,String requestedIntent) {
        String type=type(rawType);
        if(giftQty==null || giftQty.signum()==0)return "NORMAL";
        if(!"PURCHASE".equals(type) || giftQty.signum()<0 || frozenGiftBaseQty==null || frozenGiftBaseQty.signum()<=0
                || unitRate==null || unitRate.signum()<=0)
            throw conflict("赠品补回缺少可核对的冻结实物数量");
        com.uten.imp.common.util.FinancialExactAmount.quantity(giftQty,"赠品数量");
        com.uten.imp.common.util.FinancialExactAmount.quantity(frozenGiftBaseQty,"冻结赠品基本量");
        @SuppressWarnings("unchecked")
        List<UUID> caseIds=em.createNativeQuery("""
                SELECT rejection.id FROM procurement_iqc_rejection_cases rejection
                JOIN procurement_inspection_items inspection ON inspection.id=rejection.inspection_item_id
                WHERE rejection.receipt_type=:type AND rejection.order_item_id=:orderItemId
                  AND inspection.quantity_tranche='GIFT'
                  AND rejection.is_deleted=FALSE AND rejection.return_recorded_at IS NOT NULL
                  AND rejection.status IN ('RETURN_RECORDED','CREDIT_CONFIRMED','CLOSED_NO_CREDIT','FINANCE_EXCEPTION')
                ORDER BY rejection.return_date,rejection.id FOR UPDATE OF rejection,inspection
                """).setParameter("type",type).setParameter("orderItemId",orderItemId).getResultList();
        List<ReturnedShare> availableShares=new ArrayList<>();
        BigDecimal availableGift=BigDecimal.ZERO;
        for(UUID caseId:caseIds) {
            Object[] row=(Object[])em.createNativeQuery("""
                    SELECT rejection.failed_qty,rejection.failed_base_qty,rejection.failed_amount_original,rejection.failed_amount_local,
                           COALESCE(SUM(allocation.allocated_qty) FILTER(WHERE allocation.status='ACTIVE'),0),
                           COALESCE(SUM(allocation.allocated_base_qty) FILTER(WHERE allocation.status='ACTIVE'),0),
                           COALESCE(SUM(allocation.allocated_amount_original) FILTER(WHERE allocation.status='ACTIVE'),0),
                           COALESCE(SUM(allocation.allocated_amount_local) FILTER(WHERE allocation.status='ACTIVE'),0)
                    FROM procurement_iqc_rejection_cases rejection
                    LEFT JOIN procurement_iqc_replacement_allocations allocation ON allocation.case_id=rejection.id
                    WHERE rejection.id=:caseId GROUP BY rejection.id
                    """).setParameter("caseId",caseId).getSingleResult();
            if(decimal(row[2]).signum()!=0 || decimal(row[3]).signum()!=0 || decimal(row[6]).signum()!=0 || decimal(row[7]).signum()!=0)
                throw conflict("赠品品质失败和补回分项必须为零货款");
            BigDecimal left=decimal(row[0]).subtract(decimal(row[4]));
            BigDecimal leftBase=decimal(row[1]).subtract(decimal(row[5]));
            if(left.signum()<0 || leftBase.signum()<0)throw conflict("赠品补回分项数量超出原失败切片");
            if(left.signum()>0) {
                availableShares.add(new ReturnedShare(caseId,left,leftBase,BigDecimal.ZERO,BigDecimal.ZERO));
                availableGift=availableGift.add(left);
            }
        }
        BigDecimal ordinaryReturned=decimal(em.createNativeQuery("SELECT COALESCE(gift_returned_qty,0) FROM purchase_order_items WHERE id=:id")
                .setParameter("id",orderItemId).getSingleResult());
        BigDecimal priorAllocated=decimal(em.createNativeQuery("""
                SELECT COALESCE(SUM(allocation.allocated_qty),0) FROM procurement_iqc_replacement_allocations allocation
                JOIN procurement_iqc_rejection_cases rejection ON rejection.id=allocation.case_id
                JOIN procurement_inspection_items inspection ON inspection.id=rejection.inspection_item_id
                WHERE rejection.receipt_type=:type AND rejection.order_item_id=:id AND inspection.quantity_tranche='GIFT'
                  AND allocation.status='ACTIVE' AND allocation.replacement_receipt_id<>:receipt
                """).setParameter("type",type).setParameter("id",orderItemId).setParameter("receipt",receiptId).getSingleResult());
        BigDecimal owed=authorizedGiftQty.subtract(rawPriorGiftQty).add(priorAllocated).add(ordinaryReturned).max(BigDecimal.ZERO);
        String intent=resolveIntent(requestedIntent,availableGift,owed);
        BigDecimal replacement="RETURN_REPLACEMENT".equals(intent)?giftQty.min(availableGift):BigDecimal.ZERO;
        if(giftQty.subtract(replacement).compareTo(owed)>0)throw conflict("赠品正常到货超过订单尚未到货的赠品份额");
        if(replacement.signum()==0)return intent;
        BigDecimal left=replacement,allocatedBase=BigDecimal.ZERO;
        UUID actor=currentUser.requireId();
        for(ReturnedShare share:availableShares) {
            if(left.signum()<=0)break;
            BigDecimal take=left.min(share.qty());
            BigDecimal base=take.compareTo(share.qty())==0?share.baseQty():MoneyPolicy.quantityShare(share.baseQty(),take,share.qty());
            if(base.signum()<=0 || base.compareTo(share.baseQty())>0)throw conflict("赠品补回不能无损匹配原退回基本量");
            allocatedBase=allocatedBase.add(base);
            if(allocatedBase.compareTo(frozenGiftBaseQty)>0)throw conflict("赠品补回单位换算与原失败实物份额不一致");
            em.createNativeQuery("""
                    INSERT INTO procurement_iqc_replacement_allocations(id,case_id,replacement_receipt_type,replacement_receipt_id,
                        replacement_receipt_item_id,allocated_base_qty,allocated_qty,allocated_amount_original,allocated_amount_local,status,row_version,created_by)
                    VALUES(:id,:caseId,:type,:receiptId,:receiptItemId,:base,:qty,0,0,'ACTIVE',1,:actor)
                    """).setParameter("id",UUID.randomUUID()).setParameter("caseId",share.caseId()).setParameter("type",type)
                    .setParameter("receiptId",receiptId).setParameter("receiptItemId",receiptItemId)
                    .setParameter("base",base).setParameter("qty",take).setParameter("actor",actor).executeUpdate();
            em.createNativeQuery("""
                    INSERT INTO procurement_iqc_rejection_events(id,case_id,event_type,actor_user_id,reference,reason)
                    VALUES(:id,:caseId,'REPLACEMENT_ALLOCATED',:actor,:reference,'零货款赠品实物份额已被补回占用')
                    """).setParameter("id",UUID.randomUUID()).setParameter("caseId",share.caseId()).setParameter("actor",actor)
                    .setParameter("reference",receiptItemId.toString()).executeUpdate();
            left=left.subtract(take);
        }
        if(left.signum()!=0 || (replacement.compareTo(giftQty)==0 && allocatedBase.compareTo(frozenGiftBaseQty)!=0))
            throw conflict("赠品补回基本量与原失败切片无法无损守恒，请核对单位换算");
        return intent;
    }

    /** Subcontract (and any line without an over-receipt tolerance). */
    @Transactional(propagation=Propagation.MANDATORY)
    public String allocateForReceiptItem(
            String rawType,UUID receiptId,UUID receiptItemId,UUID orderItemId,
            BigDecimal receiptQty,BigDecimal receiptUnitRate,
            BigDecimal receiptOriginal,BigDecimal receiptLocal,
            BigDecimal authorizedQty,BigDecimal rawPriorQty,String requestedIntent){
        return allocateForReceiptItem(rawType,receiptId,receiptItemId,orderItemId,receiptQty,receiptUnitRate,
                receiptOriginal,receiptLocal,authorizedQty,BigDecimal.ZERO,rawPriorQty,requestedIntent);
    }

    /**
     * @param authorizedQty order qty + posted and receipt-approved excess, never the tolerance
     * @param toleranceQty  the line's full over-receipt tolerance T(order qty, pct); 0 for subcontract
     */
    @Transactional(propagation=Propagation.MANDATORY)
    public String allocateForReceiptItem(
            String rawType,UUID receiptId,UUID receiptItemId,UUID orderItemId,
            BigDecimal receiptQty,BigDecimal receiptUnitRate,
            BigDecimal receiptOriginal,BigDecimal receiptLocal,
            BigDecimal authorizedQty,BigDecimal toleranceQty,BigDecimal rawPriorQty,String requestedIntent){
        String type=type(rawType);
        if(toleranceQty==null||toleranceQty.signum()<0){
            throw conflict("允许超收数量无效");
        }
        if(receiptUnitRate==null||receiptUnitRate.signum()<=0){
            throw conflict("补货收货单位换算率无效");
        }
        @SuppressWarnings("unchecked")
        List<UUID> caseIds=em.createNativeQuery("""
                SELECT id FROM procurement_iqc_rejection_cases rejection
                WHERE receipt_type=:type AND order_item_id=:orderItemId
                  AND NOT EXISTS(SELECT 1 FROM procurement_inspection_items gift WHERE gift.id=rejection.inspection_item_id AND gift.quantity_tranche='GIFT')
                  AND is_deleted=FALSE AND return_recorded_at IS NOT NULL
                  AND status IN(
                      'RETURN_RECORDED','CREDIT_CONFIRMED',
                      'CLOSED_NO_CREDIT','FINANCE_EXCEPTION')
                ORDER BY return_date,id FOR UPDATE
                """).setParameter("type",type)
                .setParameter("orderItemId",orderItemId).getResultList();
        List<ReturnedShare> availableShares=new ArrayList<>();
        BigDecimal replacementAvailable=BigDecimal.ZERO;
        for(UUID caseId:caseIds){
            Object[] available=(Object[])em.createNativeQuery("""
                    SELECT rejection.failed_qty,
                           rejection.failed_base_qty,
                           rejection.failed_amount_original,
                           rejection.failed_amount_local,
                           COALESCE(SUM(allocation.allocated_qty)
                               FILTER(WHERE allocation.status='ACTIVE'),0),
                           COALESCE(SUM(allocation.allocated_base_qty)
                               FILTER(WHERE allocation.status='ACTIVE'),0),
                           COALESCE(SUM(allocation.allocated_amount_original)
                               FILTER(WHERE allocation.status='ACTIVE'),0),
                           COALESCE(SUM(allocation.allocated_amount_local)
                               FILTER(WHERE allocation.status='ACTIVE'),0)
                    FROM procurement_iqc_rejection_cases rejection
                    LEFT JOIN procurement_iqc_replacement_allocations allocation
                      ON allocation.case_id=rejection.id
                    WHERE rejection.id=:caseId
                    GROUP BY rejection.id
                    """).setParameter("caseId",caseId).getSingleResult();
            BigDecimal caseQty=decimal(available[0]).subtract(decimal(available[4]));
            BigDecimal caseBase=decimal(available[1]).subtract(decimal(available[5]));
            BigDecimal caseOriginal=available[2]==null?null:money(decimal(available[2]).subtract(decimal(available[6])));
            BigDecimal caseLocal=available[3]==null?null:money(decimal(available[3]).subtract(decimal(available[7])));
            if(caseQty.signum()<=0)continue;
            availableShares.add(new ReturnedShare(caseId,caseQty,caseBase,caseOriginal,caseLocal));
            replacementAvailable=replacementAvailable.add(caseQty);
        }
        String orderTable="PURCHASE".equals(type)?"purchase_order_items":"subcontract_order_items";
        BigDecimal ordinaryReturned=decimal(em.createNativeQuery(
                "SELECT COALESCE(returned_qty,0) FROM "+orderTable+" WHERE id=:id")
                .setParameter("id",orderItemId).getSingleResult());
        BigDecimal priorAllocated=decimal(em.createNativeQuery("""
                SELECT COALESCE(SUM(allocation.allocated_qty),0)
                FROM procurement_iqc_replacement_allocations allocation
                JOIN procurement_iqc_rejection_cases rejection ON rejection.id=allocation.case_id
                WHERE rejection.receipt_type=:type AND rejection.order_item_id=:id
                  AND NOT EXISTS(SELECT 1 FROM procurement_inspection_items gift WHERE gift.id=rejection.inspection_item_id AND gift.quantity_tranche='GIFT')
                  AND allocation.status='ACTIVE' AND allocation.replacement_receipt_id<>:receipt
                """).setParameter("type",type).setParameter("id",orderItemId)
                .setParameter("receipt",receiptId).getSingleResult());
        BigDecimal owedRaw=authorizedQty.subtract(rawPriorQty).add(priorAllocated).add(ordinaryReturned);
        BigDecimal owed=owedRaw.max(BigDecimal.ZERO);
        BigDecimal toleranceRemaining=toleranceQty.add(owedRaw.min(BigDecimal.ZERO)).max(BigDecimal.ZERO);
        String intent=resolveIntent(requestedIntent,replacementAvailable,owed);
        BigDecimal neededQty="RETURN_REPLACEMENT".equals(intent)
                ?receiptQty.min(replacementAvailable):BigDecimal.ZERO;
        if(receiptQty.subtract(neededQty).compareTo(owed.add(toleranceRemaining))>0){
            throw conflict(toleranceQty.signum()>0
                    ?"本次正常到货超过原订单尚未到货数量与允许超收数量之和，请确认补回来源或先完成超到审批"
                    :"本次正常到货超过原订单尚未到货的数量，请确认补回来源或先完成超到审批");
        }
        if(neededQty.signum()==0)return intent;
        BigDecimal qtyLeft=neededQty;
        BigDecimal allocatedOriginal=BigDecimal.ZERO;
        BigDecimal allocatedLocal=BigDecimal.ZERO;
        UUID actor=currentUser.requireId();
        for(ReturnedShare share:availableShares){
            if(qtyLeft.signum()<=0)break;
            UUID caseId=share.caseId();
            BigDecimal caseQty=share.qty();
            BigDecimal caseBase=share.baseQty();
            BigDecimal caseOriginal=share.original();
            BigDecimal caseLocal=share.local();
            BigDecimal takeQty=qtyLeft.min(caseQty);
            boolean finishesShare=takeQty.compareTo(caseQty)==0;
            BigDecimal takeBase=finishesShare?MoneyPolicy.quantity(caseBase)
                    :MoneyPolicy.quantityShare(caseBase,takeQty,caseQty);
            BigDecimal takeOriginal=ProcurementConsiderationBasis.finitePortion(receiptOriginal,takeQty,receiptQty);
            BigDecimal takeLocal=ProcurementConsiderationBasis.finiteBookPortion(receiptLocal,takeQty,receiptQty);
            if(takeBase.signum()<=0||takeBase.compareTo(caseBase)>0){
                throw conflict("补货分配超过IQC失败退回切片的剩余数量或金额");
            }
            UUID allocationId=UUID.randomUUID();
            em.createNativeQuery("""
                    INSERT INTO procurement_iqc_replacement_allocations(
                        id,case_id,replacement_receipt_type,
                        replacement_receipt_id,replacement_receipt_item_id,
                        allocated_base_qty,allocated_qty,
                        allocated_amount_original,allocated_amount_local,
                        status,row_version,created_by)
                    VALUES(:id,:caseId,:type,:receiptId,:receiptItemId,
                           :baseQty,:qty,:original,:local,'ACTIVE',1,:actor)
                    """).setParameter("id",allocationId)
                    .setParameter("caseId",caseId)
                    .setParameter("type",type)
                    .setParameter("receiptId",receiptId)
                    .setParameter("receiptItemId",receiptItemId)
                    .setParameter("baseQty",takeBase)
                    .setParameter("qty",takeQty)
                    .setParameter("original",takeOriginal)
                    .setParameter("local",takeLocal)
                    .setParameter("actor",actor).executeUpdate();
            em.createNativeQuery("""
                    INSERT INTO procurement_iqc_rejection_events(
                        id,case_id,event_type,actor_user_id,reference,reason)
                    VALUES(:id,:caseId,'REPLACEMENT_ALLOCATED',:actor,
                           :reference,'IQC失败退回额度已被补货收货占用')
                    """).setParameter("id",UUID.randomUUID())
                    .setParameter("caseId",caseId)
                    .setParameter("actor",actor)
                    .setParameter("reference",receiptItemId.toString())
                    .executeUpdate();
            qtyLeft=qtyLeft.subtract(takeQty);
        }
        if(qtyLeft.signum()!=0){
            throw conflict("已退IQC失败切片不足，无法覆盖本次补货收货数量或金额");
        }
        return intent;
    }

    @Transactional(propagation=Propagation.MANDATORY)
    public void reverseForReceipt(String rawType,UUID receiptId,String reason){
        String type=type(rawType);
        @SuppressWarnings("unchecked")
        List<Object[]> rows=em.createNativeQuery("""
                SELECT id,case_id,row_version
                FROM procurement_iqc_replacement_allocations
                WHERE replacement_receipt_type=:type
                  AND replacement_receipt_id=:receiptId
                  AND status='ACTIVE'
                ORDER BY id FOR UPDATE
                """).setParameter("type",type)
                .setParameter("receiptId",receiptId).getResultList();
        UUID actor=currentUser.requireId();
        for(Object[] row:rows){
            UUID allocationId=(UUID)row[0];
            UUID caseId=(UUID)row[1];
            long version=((Number)row[2]).longValue();
            int updated=em.createNativeQuery("""
                    UPDATE procurement_iqc_replacement_allocations
                    SET status='REVERSED',row_version=row_version+1,
                        reversed_by=:actor,reversed_at=now(),reverse_reason=:reason
                    WHERE id=:id AND status='ACTIVE' AND row_version=:version
                    """).setParameter("actor",actor)
                    .setParameter("reason",bounded(reason))
                    .setParameter("id",allocationId)
                    .setParameter("version",version).executeUpdate();
            if(updated!=1)throw conflict("补货收货分配版本已变化，请刷新重试");
            em.createNativeQuery("""
                    INSERT INTO procurement_iqc_rejection_events(
                        id,case_id,event_type,actor_user_id,reference,reason)
                    VALUES(:id,:caseId,'REPLACEMENT_ALLOCATION_REVERSED',
                           :actor,:reference,:reason)
                    """).setParameter("id",UUID.randomUUID())
                    .setParameter("caseId",caseId)
                    .setParameter("actor",actor)
                    .setParameter("reference",allocationId.toString())
                    .setParameter("reason",bounded(reason)).executeUpdate();
        }
    }

    @Transactional(propagation=Propagation.MANDATORY,readOnly=true)
    public BigDecimal activeAllocatedQty(String rawType,UUID receiptItemId){
        return decimal(em.createNativeQuery("""
                SELECT COALESCE(SUM(allocated_qty),0)
                FROM procurement_iqc_replacement_allocations allocation
                WHERE replacement_receipt_type=:type
                  AND replacement_receipt_item_id=:receiptItemId
                  AND status='ACTIVE'
                  AND NOT EXISTS(SELECT 1 FROM procurement_iqc_rejection_cases rejection
                        JOIN procurement_inspection_items inspection ON inspection.id=rejection.inspection_item_id
                        WHERE rejection.id=allocation.case_id AND inspection.quantity_tranche='GIFT')
                """).setParameter("type",type(rawType))
                .setParameter("receiptItemId",receiptItemId).getSingleResult());
    }

    /** Ambiguity is judged on the owed remainder only; the optional tolerance never makes it ambiguous. */
    static String resolveIntent(String requested,BigDecimal replacementAvailable,BigDecimal owedRemaining){
        if(requested!=null&&!Set.of("NORMAL","RETURN_REPLACEMENT").contains(requested)){
            throw conflict("请选择退回补回或本次正常到货");
        }
        if(requested==null){
            if(replacementAvailable.signum()>0&&owedRemaining.signum()>0){
                throw conflict("该订单同时存在正常待到货和已退未补数量，请明确选择退回补回或本次正常到货");
            }
            requested=replacementAvailable.signum()>0?"RETURN_REPLACEMENT":"NORMAL";
        }
        if("RETURN_REPLACEMENT".equals(requested)&&replacementAvailable.signum()<=0){
            throw conflict("该订单目前没有已实际退回且未补回的份额，请刷新后确认到货来源");
        }
        return requested;
    }

    private static String type(String value){
        String normalized=value==null?null:value.trim().toUpperCase();
        if(normalized==null||!TYPES.contains(normalized))throw conflict("补货收货类型无效");
        return normalized;
    }

    private static String bounded(String value){
        if(value==null||value.isBlank())throw conflict("补货反向原因不能为空");
        String trimmed=value.trim();
        return trimmed.length()<=2000?trimmed:trimmed.substring(0,2000);
    }

    private static BigDecimal decimal(Object value){
        return value==null?BigDecimal.ZERO:
                value instanceof BigDecimal number?number:new BigDecimal(value.toString());
    }

    private static BigDecimal money(Object value){
        return value==null?null:com.uten.imp.common.util.FinancialExactAmount.canonicalMoney(decimal(value),"补回名义金额");
    }

    private static ApiException conflict(String message){
        return new ApiException(ErrorCode.CONFLICT,message);
    }

    public record ReleasedCapacity(
            BigDecimal qty,BigDecimal baseQty,
            BigDecimal amountOriginal,BigDecimal amountLocal){}

    private record ReturnedShare(UUID caseId,BigDecimal qty,BigDecimal baseQty,
                                 BigDecimal original,BigDecimal local){}
}
