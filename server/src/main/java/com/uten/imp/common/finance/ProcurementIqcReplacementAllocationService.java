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
import java.math.RoundingMode;
import java.util.List;
import java.util.Set;
import java.util.UUID;

/**
 * Explicitly consumes the receipt capacity released by a physically returned
 * IQC-failed slice.  It never writes ordinary receipt returned_qty.
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
                       COALESCE(SUM(failed_amount_original),0),
                       COALESCE(SUM(failed_amount_local),0)
                FROM procurement_iqc_rejection_cases
                WHERE receipt_type=:type AND order_item_id=:orderItemId
                  AND is_deleted=FALSE AND return_recorded_at IS NOT NULL
                  AND status IN(
                      'RETURN_RECORDED','CREDIT_CONFIRMED',
                      'CLOSED_NO_CREDIT','FINANCE_EXCEPTION')
                """).setParameter("type",type)
                .setParameter("orderItemId",orderItemId).getSingleResult();
        return new ReleasedCapacity(
                decimal(row[0]),decimal(row[1]),money(row[2]),money(row[3]));
    }

    @Transactional(propagation=Propagation.MANDATORY)
    public void allocateForReceiptItem(
            String rawType,UUID receiptId,UUID receiptItemId,UUID orderItemId,
            BigDecimal receiptQty,BigDecimal receiptUnitRate,
            BigDecimal receiptOriginal,BigDecimal receiptLocal,
            BigDecimal authorizedQty,BigDecimal authorizedOriginal,
            BigDecimal authorizedLocal,BigDecimal rawPriorQty,
            BigDecimal rawPriorOriginal,BigDecimal rawPriorLocal){
        String type=type(rawType);
        BigDecimal neededQty=incrementalExcess(
                rawPriorQty,receiptQty,authorizedQty);
        BigDecimal neededOriginal=incrementalExcess(
                rawPriorOriginal,receiptOriginal,authorizedOriginal);
        BigDecimal neededLocal=incrementalExcess(
                rawPriorLocal,receiptLocal,authorizedLocal);
        if(neededQty.signum()==0){
            if(neededOriginal.signum()!=0||neededLocal.signum()!=0){
                throw conflict("补货收货数量与金额释放额度不一致");
            }
            return;
        }
        if(receiptUnitRate==null||receiptUnitRate.signum()<=0){
            throw conflict("补货收货单位换算率无效");
        }
        @SuppressWarnings("unchecked")
        List<UUID> caseIds=em.createNativeQuery("""
                SELECT id FROM procurement_iqc_rejection_cases
                WHERE receipt_type=:type AND order_item_id=:orderItemId
                  AND is_deleted=FALSE AND return_recorded_at IS NOT NULL
                  AND status IN(
                      'RETURN_RECORDED','CREDIT_CONFIRMED',
                      'CLOSED_NO_CREDIT','FINANCE_EXCEPTION')
                ORDER BY return_date,id FOR UPDATE
                """).setParameter("type",type)
                .setParameter("orderItemId",orderItemId).getResultList();
        BigDecimal qtyLeft=neededQty;
        BigDecimal originalLeft=money(neededOriginal);
        BigDecimal localLeft=money(neededLocal);
        UUID actor=currentUser.requireId();
        for(UUID caseId:caseIds){
            if(qtyLeft.signum()<=0)break;
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
            BigDecimal caseOriginal=money(
                    decimal(available[2]).subtract(decimal(available[6])));
            BigDecimal caseLocal=money(
                    decimal(available[3]).subtract(decimal(available[7])));
            if(caseQty.signum()<=0)continue;
            BigDecimal takeQty=qtyLeft.min(caseQty);
            boolean last=takeQty.compareTo(qtyLeft)==0;
            BigDecimal takeBase=last
                    ? money(neededQty.multiply(receiptUnitRate)
                        .subtract(neededQty.subtract(qtyLeft).multiply(receiptUnitRate)))
                    : quantity(caseBase.multiply(takeQty)
                        .divide(caseQty,12,RoundingMode.HALF_UP));
            BigDecimal takeOriginal=last?originalLeft:money(
                    caseOriginal.multiply(takeQty)
                            .divide(caseQty,12,RoundingMode.HALF_UP));
            BigDecimal takeLocal=last?localLeft:money(
                    caseLocal.multiply(takeQty)
                            .divide(caseQty,12,RoundingMode.HALF_UP));
            if(takeBase.signum()<=0||takeBase.compareTo(caseBase)>0
                    ||takeOriginal.compareTo(caseOriginal)>0
                    ||takeLocal.compareTo(caseLocal)>0){
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
            originalLeft=money(originalLeft.subtract(takeOriginal));
            localLeft=money(localLeft.subtract(takeLocal));
        }
        if(qtyLeft.signum()!=0||originalLeft.signum()!=0||localLeft.signum()!=0){
            throw conflict("已退IQC失败切片不足，无法覆盖本次补货收货数量或金额");
        }
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
                FROM procurement_iqc_replacement_allocations
                WHERE replacement_receipt_type=:type
                  AND replacement_receipt_item_id=:receiptItemId
                  AND status='ACTIVE'
                """).setParameter("type",type(rawType))
                .setParameter("receiptItemId",receiptItemId).getSingleResult());
    }

    static BigDecimal incrementalExcess(
            BigDecimal prior,BigDecimal current,BigDecimal authorized){
        if(prior==null||current==null||authorized==null
                ||prior.signum()<0||current.signum()<0||authorized.signum()<0){
            throw conflict("补货收货额度输入无效");
        }
        return prior.add(current).subtract(authorized).max(BigDecimal.ZERO)
                .subtract(prior.subtract(authorized).max(BigDecimal.ZERO));
    }

    private static String type(String value){
        String normalized=value==null?null:value.trim().toUpperCase();
        if(!TYPES.contains(normalized))throw conflict("补货收货类型无效");
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
        return decimal(value).setScale(4,RoundingMode.HALF_UP);
    }

    private static BigDecimal quantity(BigDecimal value){
        return value.setScale(4,RoundingMode.HALF_UP);
    }

    private static ApiException conflict(String message){
        return new ApiException(ErrorCode.CONFLICT,message);
    }

    public record ReleasedCapacity(
            BigDecimal qty,BigDecimal baseQty,
            BigDecimal amountOriginal,BigDecimal amountLocal){}
}
