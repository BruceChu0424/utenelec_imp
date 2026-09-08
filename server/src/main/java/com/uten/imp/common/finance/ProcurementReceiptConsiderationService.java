package com.uten.imp.common.finance;

import com.uten.imp.application.port.ProcurementReceiptConsiderationPort;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.security.SecurityContextCurrentUser;
import jakarta.persistence.EntityManager;
import jakarta.persistence.Query;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Propagation;
import org.springframework.transaction.annotation.Transactional;

import java.math.BigDecimal;

import java.time.LocalDate;
import java.util.ArrayList;
import java.util.List;
import java.util.Map;

import java.util.Optional;
import java.util.UUID;

/** Exact supplier consideration; physical custody cost belongs to inventory valuation. */
@Service
@RequiredArgsConstructor
@Transactional(propagation = Propagation.MANDATORY)
public class ProcurementReceiptConsiderationService implements ProcurementReceiptConsiderationPort {
    private final EntityManager em;
    private final SecurityContextCurrentUser currentUser;
    private final com.uten.imp.application.port.ProcurementCreditBookAllocationPort creditBook;

    public record Amounts(BigDecimal original, BigDecimal local) {
        public static Amounts zero() {
            return new Amounts(BigDecimal.ZERO, BigDecimal.ZERO);
        }
    }

    public record CreditPart(
            UUID id, UUID fundingSliceId, UUID sourceApId,
            BigDecimal baseQty, BigDecimal original, BigDecimal local) {
    }

    public record CaseCreditInput(UUID caseId,long caseVersion,BigDecimal baseQty,BigDecimal amountOriginal) {}
    public record CaseBookAllocation(CaseCreditInput input,BigDecimal amountLocal,
            BigDecimal beforeOriginal,BigDecimal beforeLocal,BigDecimal afterOriginal,BigDecimal afterLocal) {}

    public record CreditDocumentQuote(UUID documentId,UUID sourceApId,String kind,
            String sourceVersion,String sourceHash,List<CreditPart> parts,Amounts amounts,
            com.uten.imp.application.port.ProcurementCreditBookAllocationPort.BookAllocationPlan bookPlan) {
    }

    public record CreditQuote(List<CreditDocumentQuote> documents,List<CreditPart> parts,Amounts amounts) {
    }

    public record Resolution(BigDecimal creditableBaseQty,BigDecimal replacementPendingBaseQty,
            BigDecimal replacementStockedBaseQty,BigDecimal creditedBaseQty,BigDecimal unresolvedBaseQty,
            BigDecimal unresolvedOriginal,BigDecimal unresolvedLocal,String state,boolean legacyUnclassified) {
    }

    /** Called after the frozen receipt amounts and physical replacement allocations exist. */
    public Amounts freezeReceipt(String rawType, UUID receiptId) {
        String type = type(rawType);
        em.flush();
        String table = type.equals("PURCHASE") ? "purchase_receipt_items" : "subcontract_receipt_items";
        List<Object[]> items = rows("""
                SELECT id,qty*unit_rate,amount_original,amount_local
                FROM %s WHERE receipt_id=:id AND is_deleted=FALSE ORDER BY id
                """.formatted(table), Map.of("id", receiptId));
        if (items.isEmpty()) throw conflict("收货计款缺少有效明细");
        for (Object[] item : items) {
            UUID itemId = uuid(item[0]);
            if (number("""
                    SELECT COUNT(*) FROM procurement_receipt_consideration_parts
                    WHERE receipt_item_id=:id AND receipt_type=:type
                      AND fn_procurement_consideration_active('CONSIDERATION',id)
                    """, Map.of("id", itemId, "type", type)).signum() > 0) {
                throw conflict("该收货明细已冻结计款份额，不能重复建立或更改");
            }
            BigDecimal replacementBase = BigDecimal.ZERO;
            for (Object[] allocation : rows("""
                    SELECT id,case_id,allocated_base_qty,allocated_amount_original,allocated_amount_local
                    FROM procurement_iqc_replacement_allocations
                    WHERE replacement_receipt_type=:type AND replacement_receipt_item_id=:id
                      AND status='ACTIVE' ORDER BY id
                    """, Map.of("type", type, "id", itemId))) {
                freezeReplacement(type, receiptId, itemId, allocation);
                replacementBase = replacementBase.add(decimal(allocation[2]));
            }
            BigDecimal base = decimal(item[1]).subtract(replacementBase);
            BigDecimal original = portion(decimal(item[2]), base, decimal(item[1]));
            BigDecimal local = ProcurementConsiderationBasis.finiteBookPortion(decimal(item[3]), base, decimal(item[1]));
            if (base.signum() < 0 || original==null || local==null || original.signum() < 0 || local.signum() < 0
                    || (base.signum() == 0 && (original.signum() != 0 || local.signum() != 0))) {
                throw conflict("正常收货与补回的数量及计款份额不守恒");
            }
            if (base.signum() > 0) insertPart(type, receiptId, itemId, BillingMode.STANDARD,
                    null, null, null, base, original, local);
        }
        return payable(type, receiptId);
    }

    private void freezeReplacement(String type, UUID receiptId, UUID itemId, Object[] allocation) {
        UUID allocationId = uuid(allocation[0]);
        UUID caseId = uuid(allocation[1]);
        // The caller holds the full commercial prefix, then this exact physical case.
        List<Object[]> caseRows = rows("""
                SELECT id FROM procurement_iqc_rejection_cases
                WHERE id=:id AND is_deleted=FALSE AND return_recorded_at IS NOT NULL
                  AND status IN ('RETURN_RECORDED','CREDIT_CONFIRMED','CLOSED_NO_CREDIT','FINANCE_EXCEPTION')
                FOR UPDATE
                """, Map.of("id", caseId));
        if (caseRows.size() != 1) throw conflict("补回必须对应本次已经实际退回的质量失败份额");
        List<Object[]> funding = funding(caseId);
        if (funding.isEmpty()) throw conflict("旧IQC补回尚未核对资金来源，请先完成历史资金份额核对");
        BigDecimal left = decimal(allocation[2]);
        String itemTable=type.equals("PURCHASE")?"purchase_receipt_items":"subcontract_receipt_items";
        Object[] nominal=rows("SELECT amount_original,amount_local,qty*unit_rate FROM "+itemTable+" WHERE id=:id",
                Map.of("id",itemId)).getFirst();
        for (Object[] fund : funding) {
            if (left.signum() <= 0) break;
            UUID fundingId = uuid(fund[0]);
            // A credited share is repurchased at the approved price. Its credit is
            // still resolved, and only this exact unused credit share may be reused.
            for (Object[] credit : rows("""
                    SELECT credit.id,credit.base_qty-COALESCE(used.qty,0),
                           credit.amount_original-COALESCE(used.original,0),
                           credit.amount_local-COALESCE(used.local,0)
                    FROM procurement_iqc_credit_slices credit
                    LEFT JOIN LATERAL (
                        SELECT SUM(base_qty) qty,SUM(nominal_original) original,SUM(nominal_local) local
                        FROM procurement_receipt_consideration_parts part
                        WHERE part.credit_slice_id=credit.id
                          AND fn_procurement_consideration_active('CONSIDERATION',part.id)
                    ) used ON TRUE
                    WHERE credit.funding_slice_id=:id
                      AND fn_procurement_consideration_active('CREDIT',credit.id)
                    ORDER BY credit.created_at,credit.id
                    """, Map.of("id", fundingId))) {
                BigDecimal available = decimal(credit[1]);
                if (available.signum() <= 0 || left.signum() <= 0) continue;
                BigDecimal take = left.min(available);
                BigDecimal original=portion(decimal(nominal[0]),take,decimal(nominal[2]));
                BigDecimal local=ProcurementConsiderationBasis.finiteBookPortion(decimal(nominal[1]),take,decimal(nominal[2]));
                if(original==null||local==null)throw conflict("重新计款补回须有可无损保存的实际单据分项金额");
                insertPart(type, receiptId, itemId, BillingMode.CREDIT_REPURCHASE,
                        allocationId, fundingId, uuid(credit[0]), take, original, local);
                left = left.subtract(take);
            }
            if (left.signum() <= 0) break;
            Object[] free = uncommittedFunding(fundingId);
            BigDecimal available = decimal(free[0]);
            if (available.signum() <= 0) continue;
            BigDecimal take = left.min(available);
            BigDecimal original=portion(decimal(nominal[0]),take,decimal(nominal[2]));
            BigDecimal local=ProcurementConsiderationBasis.finiteBookPortion(decimal(nominal[1]),take,decimal(nominal[2]));
            insertPart(type, receiptId, itemId, BillingMode.NO_CHARGE,
                    allocationId, fundingId, null, take, original, local);
            left = left.subtract(take);
        }
        if (left.signum() != 0) {
            throw conflict("补回数量超过原失败资金份额的剩余额度");
        }
    }

    private void insertPart(String type, UUID receiptId, UUID itemId, BillingMode mode,
            UUID allocationId, UUID fundingId, UUID creditId,
            BigDecimal base, BigDecimal original, BigDecimal local) {
        em.createNativeQuery("""
                INSERT INTO procurement_receipt_consideration_parts(
                    id,receipt_type,receipt_id,receipt_item_id,billing_mode,replacement_allocation_id,
                    funding_slice_id,credit_slice_id,base_qty,nominal_original,nominal_local,
                    payable_original,payable_local,created_by)
                VALUES(:id,:type,:receiptId,:itemId,:mode,:allocationId,:fundingId,:creditId,
                    :base,:original,:local,:payableOriginal,:payableLocal,:actor)
                """).setParameter("id", UUID.randomUUID()).setParameter("type", type)
                .setParameter("receiptId", receiptId).setParameter("itemId", itemId)
                .setParameter("mode", mode.name()).setParameter("allocationId", allocationId)
                .setParameter("fundingId", fundingId).setParameter("creditId", creditId)
                .setParameter("base", base).setParameter("original", original).setParameter("local", local)
                .setParameter("payableOriginal", mode == BillingMode.NO_CHARGE ? BigDecimal.ZERO : original)
                .setParameter("payableLocal", mode == BillingMode.NO_CHARGE ? BigDecimal.ZERO : local)
                .setParameter("actor", currentUser.requireId()).executeUpdate();
    }

    public Amounts payable(String rawType, UUID receiptId) {
        Object[] amounts = rows("""
                SELECT COALESCE(SUM(payable_original),0),COALESCE(SUM(payable_local),0)
                FROM procurement_receipt_consideration_parts
                WHERE receipt_type=:type AND receipt_id=:id
                  AND fn_procurement_consideration_active('CONSIDERATION',id)
                """, Map.of("type", type(rawType), "id", receiptId)).getFirst();
        return new Amounts(decimal(amounts[0]), decimal(amounts[1]));
    }

    @Transactional(propagation=Propagation.MANDATORY,readOnly=true)
    public boolean hasReceipt(String rawType,UUID receiptId) {
        return number("""
                SELECT COUNT(*) FROM procurement_receipt_consideration_parts
                WHERE receipt_type=:type AND receipt_id=:id
                  AND fn_procurement_consideration_active('CONSIDERATION',id)
                """,Map.of("type",type(rawType),"id",receiptId)).signum()>0;
    }

    @Transactional(propagation=Propagation.MANDATORY,readOnly=true)
    public Amounts failedAmounts(UUID inspectionItemId) {
        Object[] result=rows("""
                SELECT COUNT(*),CASE WHEN BOOL_AND(quality.amount_original IS NOT NULL) FILTER(WHERE event.action='FAIL')
                           THEN SUM(quality.amount_original) FILTER(WHERE event.action='FAIL') END,
                       CASE WHEN BOOL_AND(quality.amount_local IS NOT NULL) FILTER(WHERE event.action='FAIL')
                           THEN SUM(quality.amount_local) FILTER(WHERE event.action='FAIL') END
                FROM procurement_iqc_quality_consideration_parts quality
                JOIN procurement_inspection_events event ON event.id=quality.inspection_event_id
                WHERE event.inspection_item_id=:id AND fn_procurement_consideration_active('QUALITY',quality.id)
                """,Map.of("id",inspectionItemId)).getFirst();
        return decimal(result[0]).signum()==0?null:new Amounts(nullableDecimal(result[1]),nullableDecimal(result[2]));
    }

    /** Freeze each real quality event against the remaining exact receipt parts. */
    public void freezeQuality(UUID inspectionItemId) {
        freezeQuality(inspectionItemId,currentUser.requireId());
    }

    private void freezeQuality(UUID inspectionItemId,UUID actorId) {
        List<Object[]> parts = rows("""
                SELECT part.id,part.base_qty,part.nominal_original,part.nominal_local,
                       COALESCE(used.qty,0)
                FROM procurement_inspection_items inspection
                JOIN procurement_receipt_consideration_parts part
                  ON part.receipt_type=inspection.receipt_type AND part.receipt_item_id=inspection.receipt_item_id
                LEFT JOIN LATERAL (
                    SELECT SUM(base_qty) qty FROM procurement_iqc_quality_consideration_parts quality
                    WHERE quality.consideration_part_id=part.id
                      AND fn_procurement_consideration_active('QUALITY',quality.id)
                ) used ON TRUE
                WHERE inspection.id=:id AND fn_procurement_consideration_active('CONSIDERATION',part.id)
                ORDER BY part.id
                """, Map.of("id", inspectionItemId));
        if (parts.isEmpty()) return; // Legacy evidence is diagnosed, never guessed.
        List<Object[]> qualityEvents = rows("""
                SELECT event.id,event.base_qty FROM procurement_inspection_events event
                WHERE event.inspection_item_id=:id AND event.action IN ('PASS','FAIL')
                  AND NOT EXISTS(SELECT 1 FROM procurement_iqc_quality_consideration_parts frozen
                    WHERE frozen.inspection_event_id=event.id)
                ORDER BY event.occurred_at,event.id
                """, Map.of("id", inspectionItemId));
        for (Object[] event : qualityEvents) {
            BigDecimal left = decimal(event[1]);
            BigDecimal available = parts.stream()
                    .map(part -> decimal(part[1]).subtract(decimal(part[4])))
                    .reduce(BigDecimal.ZERO, BigDecimal::add);
            if (left.signum() <= 0 || left.compareTo(available) > 0) {
                throw conflict("品质事件与收货资金份额的数量不守恒");
            }
            for (Object[] part : parts) {
                BigDecimal capacity = decimal(part[1]).subtract(decimal(part[4]));
                if (capacity.signum() <= 0) continue;
                BigDecimal take = left.min(capacity);
                available = available.subtract(capacity);
                if (take.signum() <= 0) continue;
                BigDecimal used = decimal(part[4]);
                BigDecimal original = portion(nullableDecimal(part[2]), take, decimal(part[1]));
                BigDecimal local = ProcurementConsiderationBasis.finiteBookPortion(nullableDecimal(part[3]), take, decimal(part[1]));
                em.createNativeQuery("""
                        INSERT INTO procurement_iqc_quality_consideration_parts(
                            id,inspection_event_id,consideration_part_id,base_qty,
                            amount_original,amount_local,created_by)
                        VALUES(:id,:event,:part,:qty,:original,:local,:actor)
                        """).setParameter("id", UUID.randomUUID()).setParameter("event", uuid(event[0]))
                        .setParameter("part", uuid(part[0])).setParameter("qty", take)
                        .setParameter("original", original).setParameter("local", local)
                        .setParameter("actor", actorId).executeUpdate();
                part[4] = used.add(take);
                left = left.subtract(take);
            }
            if (left.signum() != 0) throw conflict("品质事件的最后一个资金份额未完全分配");
        }
    }

    /** Each FAIL slice gets one generation; free replacement keeps its existing root. */
    public Amounts freezeFailure(UUID caseId, UUID inspectionItemId,UUID actorId) {
        if(actorId==null)throw conflict("质量失败资金分配缺少真实事件操作人");
        freezeQuality(inspectionItemId,actorId);
        for (Object[] row : rows("""
                SELECT quality.id,quality.base_qty,quality.amount_original,quality.amount_local,
                       part.billing_mode,part.funding_slice_id,part.receipt_item_id,
                       parent.root_funding_slice_id,parent.root_case_id,parent.root_receipt_item_id,
                       COALESCE(parent.source_ap_ledger_id,ledger.id)
                FROM procurement_iqc_quality_consideration_parts quality
                JOIN procurement_inspection_events event ON event.id=quality.inspection_event_id
                JOIN procurement_receipt_consideration_parts part ON part.id=quality.consideration_part_id
                LEFT JOIN procurement_iqc_funding_slices parent ON parent.id=part.funding_slice_id
                  AND part.billing_mode='NO_CHARGE'
                LEFT JOIN ar_ap_ledger ledger ON ledger.source_doc_id=part.receipt_id
                  AND ledger.source_doc_type=part.receipt_type||'_RECEIPT'
                  AND ledger.direction='AP' AND ledger.status=1 AND ledger.is_deleted=FALSE
                  AND part.billing_mode<>'NO_CHARGE'
                WHERE event.inspection_item_id=:id AND event.action='FAIL'
                  AND fn_procurement_consideration_active('QUALITY',quality.id)
                  AND NOT EXISTS(SELECT 1 FROM procurement_iqc_funding_slices funding
                    WHERE funding.quality_part_id=quality.id)
                ORDER BY event.occurred_at,event.id,quality.id
                """, Map.of("id", inspectionItemId))) {
            boolean carried = "NO_CHARGE".equals(row[4]);
            UUID fundingId = UUID.randomUUID();
            UUID sourceApId = uuid(row[10]);
            if (sourceApId == null && (decimal(row[2]).signum() > 0 || decimal(row[3]).signum() > 0)) {
                throw conflict("质量失败的资金份额缺少对应正应付，不能猜测新索赔来源");
            }
            em.createNativeQuery("""
                    INSERT INTO procurement_iqc_funding_slices(id,case_id,quality_part_id,
                        parent_funding_slice_id,root_funding_slice_id,root_case_id,root_receipt_item_id,
                        source_ap_ledger_id,base_qty,amount_original,amount_local,created_by)
                    VALUES(:id,:caseId,:quality,:parent,:root,:rootCase,:rootItem,:ap,:qty,:original,:local,:actor)
                    """).setParameter("id", fundingId).setParameter("caseId", caseId)
                    .setParameter("quality", uuid(row[0])).setParameter("parent", carried ? uuid(row[5]) : null)
                    .setParameter("root", carried ? uuid(row[7]) : fundingId)
                    .setParameter("rootCase", carried ? uuid(row[8]) : caseId)
                    .setParameter("rootItem", carried ? uuid(row[9]) : uuid(row[6]))
                    .setParameter("ap", sourceApId).setParameter("qty", decimal(row[1]))
                    .setParameter("original", nullableDecimal(row[2])).setParameter("local", nullableDecimal(row[3]))
                    .setParameter("actor", actorId).executeUpdate();
        }
        Object[] total = rows("""
                SELECT CASE WHEN BOOL_AND(amount_original IS NOT NULL) THEN SUM(amount_original) END,
                       CASE WHEN BOOL_AND(amount_local IS NOT NULL) THEN SUM(amount_local) END
                FROM procurement_iqc_funding_slices
                WHERE case_id=:id AND fn_procurement_consideration_active('FUNDING',id)
                """, Map.of("id", caseId)).getFirst();
        return new Amounts(nullableDecimal(total[0]), nullableDecimal(total[1]));
    }

    public CreditQuote prepareCredit(UUID anchorCaseId,long anchorVersion,UUID commandId,
            UUID sourceApId,BigDecimal actualOriginal,List<CaseCreditInput> allocations,
            String reference,LocalDate date,String reason,String expectedBookAllocationHash) {
        if(sourceApId==null||actualOriginal==null||allocations==null||allocations.isEmpty())
            throw conflict("请按实际供应商贷项填写原币金额、来源应付和明确的案件分项");
        BigDecimal original=com.uten.imp.common.util.FinancialExactAmount.require(actualOriginal,"实际供应商贷项金额");
        if(original.signum()<=0)throw conflict("实际供应商贷项金额必须大于零");
        BigDecimal allocated=BigDecimal.ZERO;
        BigDecimal totalQty=BigDecimal.ZERO;
        java.util.Set<UUID> seen=new java.util.HashSet<>();
        for(CaseCreditInput input:allocations){
            if(input==null||input.caseId()==null||!seen.add(input.caseId())||input.baseQty()==null
                    ||input.baseQty().signum()<=0||input.baseQty().stripTrailingZeros().scale()>4)
                throw conflict("供应商贷项案件必须唯一且明确填写四位以内的实际退货基本量");
            BigDecimal amount=com.uten.imp.common.util.FinancialExactAmount.require(input.amountOriginal(),"案件实际分项金额");
            if(amount.signum()<=0)throw conflict("每个案件实际分项金额必须大于零");
            allocated=allocated.add(amount);
            totalQty=totalQty.add(input.baseQty());
        }
        if(!seen.contains(anchorCaseId)||allocated.compareTo(original)!=0)
            throw conflict("案件实际分项必须包含当前任务，并精确合计到供应商贷项原始金额");
        List<Object[]> aps=rows("""
                SELECT amount_original,amount_original_local FROM ar_ap_ledger WHERE id=:id
                  AND direction='AP' AND status=1 AND is_deleted=FALSE AND amount_original>0 FOR UPDATE
                """,Map.of("id",sourceApId));
        if(aps.size()!=1)throw conflict("实际供应商贷项的原应付不存在或已反向");
        BigDecimal sourceOriginal=decimal(aps.getFirst()[0]);
        BigDecimal alreadyCredited=number("""
                SELECT COALESCE(SUM(document.amount_original),0) FROM procurement_iqc_credit_documents document
                WHERE source_ap_ledger_id=:id AND EXISTS(SELECT 1 FROM procurement_iqc_credit_slices slice
                    WHERE slice.credit_document_id=document.id AND fn_procurement_consideration_active('CREDIT',slice.id))
                """,Map.of("id",sourceApId));
        if(original.compareTo(sourceOriginal.subtract(alreadyCredited))>0)
            throw conflict("实际供应商贷项超过同一原应付尚未贷项的原币余额");
        var bookPlan=creditBook.plan(sourceApId,original);
        if(bookPlan==null||!sourceApId.equals(bookPlan.sourceApLedgerId())
                ||original.compareTo(bookPlan.amountOriginal())!=0)throw conflict("实际供应商贷项缺少同源账面分配计划");
        BigDecimal local=com.uten.imp.common.util.FinancialExactAmount.book(bookPlan.amountLocal(),"实际贷项账面分配额");
        String bookPlanJson=bookPlanJson(bookPlan);
        if(expectedBookAllocationHash==null||!creditApprovalHash(bookPlan,allocations).equals(expectedBookAllocationHash))
            throw conflict("原应付账面分配或余额已变化，请重新预览本币分配额和剩余金额后确认");
        String sourceVersion="IQC_CREDIT/"+commandId;
        List<String> fingerprint=new ArrayList<>(List.of(sourceVersion,"sourceAP="+sourceApId,
                "original="+original.toPlainString(),"local="+local.toPlainString(),"date="+date,
                "reference="+reference,"reason="+reason,"bookPlan="+bookPlanJson));
        List<CaseCreditInput> ordered=allocations.stream().sorted(CASE_DATABASE_ORDER).toList();
        for(CaseCreditInput input:ordered)fingerprint.add("case="+input.caseId()+"/"+input.caseVersion()+"/"
                +input.baseQty().stripTrailingZeros().toPlainString()+"/"+input.amountOriginal().stripTrailingZeros().toPlainString());
        String hash=com.uten.imp.common.util.CanonicalFingerprint.sha256(fingerprint);
        UUID actor=currentUser.requireId();
        em.createNativeQuery("""
                INSERT INTO procurement_iqc_credit_documents(id,command_id,case_id,case_version,
                    source_ap_ledger_id,document_kind,approved_source_version,approved_source_hash,
                    base_qty,amount_original,amount_local,book_allocation_plan,effective_date,credit_reference,reason,approved_by)
                VALUES(:id,:id,:caseId,:version,:ap,'SUPPLIER_CREDIT',:sourceVersion,:hash,
                    :qty,:original,:local,CAST(:bookPlan AS jsonb),:date,:reference,:reason,:actor)
                """).setParameter("id",commandId).setParameter("caseId",anchorCaseId).setParameter("version",anchorVersion)
                .setParameter("ap",sourceApId).setParameter("sourceVersion",sourceVersion).setParameter("hash",hash)
                .setParameter("qty",totalQty).setParameter("original",original).setParameter("local",local)
                .setParameter("bookPlan",bookPlanJson)
                .setParameter("date",date).setParameter("reference",reference).setParameter("reason",reason)
                .setParameter("actor",actor).executeUpdate();
        List<CreditPart> parts=new ArrayList<>();
        for(CaseBookAllocation caseBook:caseBookAllocations(original,local,ordered)){
            CaseCreditInput input=caseBook.input();
            UUID allocationId=UUID.randomUUID();
            em.createNativeQuery("""
                    INSERT INTO procurement_iqc_credit_case_allocations(id,credit_document_id,case_id,case_version,
                        base_qty,amount_original,amount_local,book_before_original,book_before_local,
                        book_after_original,book_after_local,created_by)
                    VALUES(:id,:document,:caseId,:version,:qty,:amount,:local,:beforeOriginal,:beforeLocal,:afterOriginal,:afterLocal,:actor)
                    """).setParameter("id",allocationId).setParameter("document",commandId).setParameter("caseId",input.caseId())
                    .setParameter("version",input.caseVersion()).setParameter("qty",input.baseQty())
                    .setParameter("amount",input.amountOriginal()).setParameter("local",caseBook.amountLocal())
                    .setParameter("beforeOriginal",caseBook.beforeOriginal()).setParameter("beforeLocal",caseBook.beforeLocal())
                    .setParameter("afterOriginal",caseBook.afterOriginal()).setParameter("afterLocal",caseBook.afterLocal())
                    .setParameter("actor",actor).executeUpdate();
            BigDecimal left=input.baseQty();
            BigDecimal caseLocal=caseBook.amountLocal();
            for(Object[] fund:funding(input.caseId())){
                if(left.signum()==0)break;
                if(!sourceApId.equals(uuid(fund[4])))continue;
                BigDecimal capacity=decimal(uncommittedFunding(uuid(fund[0]))[0]);
                BigDecimal take=capacity.min(left);
                if(take.signum()<=0)continue;
                UUID sliceId=UUID.randomUUID();
                BigDecimal sliceOriginal=ProcurementConsiderationBasis.finitePortion(input.amountOriginal(),take,input.baseQty());
                BigDecimal sliceLocal=ProcurementConsiderationBasis.finiteBookPortion(caseLocal,take,input.baseQty());
                em.createNativeQuery("""
                        INSERT INTO procurement_iqc_credit_slices(id,command_id,case_id,funding_slice_id,credit_document_id,
                            case_allocation_id,base_qty,amount_original,amount_local,credit_reference,credit_date,reason,created_by)
                        VALUES(:id,:document,:caseId,:fund,:document,:allocation,:qty,:original,:local,:reference,:date,:reason,:actor)
                        """).setParameter("id",sliceId).setParameter("document",commandId).setParameter("caseId",input.caseId())
                        .setParameter("fund",fund[0]).setParameter("allocation",allocationId).setParameter("qty",take)
                        .setParameter("original",sliceOriginal).setParameter("local",sliceLocal).setParameter("reference",reference)
                        .setParameter("date",date).setParameter("reason",reason).setParameter("actor",actor).executeUpdate();
                parts.add(new CreditPart(sliceId,uuid(fund[0]),sourceApId,take,sliceOriginal,sliceLocal));
                left=left.subtract(take);
            }
            if(left.signum()!=0)throw conflict("案件分项超过该原应付尚未被免费补回或实际贷项占用的退货基本量");
        }
        var amounts=new Amounts(original,local);
        var document=new CreditDocumentQuote(commandId,sourceApId,"SUPPLIER_CREDIT",sourceVersion,hash,List.copyOf(parts),amounts,bookPlan);
        return new CreditQuote(List.of(document),List.copyOf(parts),amounts);
    }

    public static String bookPlanJson(com.uten.imp.application.port.ProcurementCreditBookAllocationPort.BookAllocationPlan plan){
        try{return new com.fasterxml.jackson.databind.ObjectMapper().writeValueAsString(plan);}
        catch(com.fasterxml.jackson.core.JsonProcessingException error){throw new IllegalStateException("贷项账面分配计划无法冻结",error);}
    }
    public static String bookPlanHash(com.uten.imp.application.port.ProcurementCreditBookAllocationPort.BookAllocationPlan plan){
        return com.uten.imp.common.util.CanonicalFingerprint.sha256(List.of(bookPlanJson(plan)));
    }
    public static String creditApprovalHash(com.uten.imp.application.port.ProcurementCreditBookAllocationPort.BookAllocationPlan plan,List<CaseCreditInput> inputs){
        List<String> fingerprint=new ArrayList<>(List.of(bookPlanJson(plan)));
        for(CaseBookAllocation allocation:caseBookAllocations(plan.amountOriginal(),plan.amountLocal(),inputs))
            fingerprint.add(allocation.toString());
        return com.uten.imp.common.util.CanonicalFingerprint.sha256(fingerprint);
    }
    // PostgreSQL uuid orders unsigned bytes. UUID.compareTo uses signed longs
    // and would disagree at either sign boundary, breaking the frozen balance chain.
    private static final java.util.Comparator<CaseCreditInput> CASE_DATABASE_ORDER =
            java.util.Comparator.comparing(input -> input.caseId().toString());

    public static List<CaseBookAllocation> caseBookAllocations(BigDecimal original,BigDecimal local,List<CaseCreditInput> inputs){
        var remainingOriginal=original;
        var remainingLocal=local;
        List<CaseBookAllocation> result=new ArrayList<>();
        for(CaseCreditInput input:inputs.stream().sorted(CASE_DATABASE_ORDER).toList()){
            BigDecimal allocatedLocal=ProcurementConsiderationBasis.bookAllocation(remainingLocal,input.amountOriginal(),remainingOriginal);
            BigDecimal afterOriginal=remainingOriginal.subtract(input.amountOriginal());
            BigDecimal afterLocal=remainingLocal.subtract(allocatedLocal);
            result.add(new CaseBookAllocation(input,allocatedLocal,remainingOriginal,remainingLocal,afterOriginal,afterLocal));
            remainingOriginal=afterOriginal;remainingLocal=afterLocal;
        }
        if(remainingOriginal.signum()!=0||remainingLocal.signum()!=0)throw conflict("案件分项必须保留并完整分配本次真实贷项的账面余额");
        return List.copyOf(result);
    }
    /** Called only after the exact stock movement and IQC batch item are written. */
    public void settleStockIn(UUID stockInItemId) {
        Object[] source = rows("""
                SELECT inspection_item_id,pass_event_id,base_qty
                FROM procurement_iqc_stock_in_batch_items WHERE id=:id
                """, Map.of("id", stockInItemId)).getFirst();
        freezeQuality(uuid(source[0]));
        if (number("SELECT COUNT(*) FROM procurement_iqc_stock_consideration_parts WHERE stock_in_item_id=:id",
                Map.of("id", stockInItemId)).signum() > 0) return;
        List<Object[]> parts = rows("""
                SELECT quality.id,quality.consideration_part_id,quality.base_qty,
                       quality.amount_original,quality.amount_local,COALESCE(used.qty,0),
                       part.billing_mode,part.funding_slice_id
                FROM procurement_iqc_quality_consideration_parts quality
                JOIN procurement_receipt_consideration_parts part ON part.id=quality.consideration_part_id
                LEFT JOIN LATERAL (
                    SELECT SUM(base_qty) qty FROM procurement_iqc_stock_consideration_parts stock
                    WHERE stock.quality_part_id=quality.id AND fn_procurement_consideration_active('STOCK',stock.id)
                ) used ON TRUE
                WHERE quality.inspection_event_id=:id AND fn_procurement_consideration_active('QUALITY',quality.id)
                ORDER BY quality.id
                """, Map.of("id", uuid(source[1])));
        if (parts.isEmpty()) return;
        BigDecimal left = decimal(source[2]);
        BigDecimal available = parts.stream().map(part -> decimal(part[2]).subtract(decimal(part[5])))
                .reduce(BigDecimal.ZERO, BigDecimal::add);
        if (left.compareTo(available) > 0) throw conflict("实际入库超过该合格事件的资金份额");
        for (Object[] part : parts) {
            BigDecimal used = decimal(part[5]);
            BigDecimal capacity = decimal(part[2]).subtract(used);
            if (capacity.signum() <= 0) continue;
            BigDecimal take = left.min(capacity);
            available = available.subtract(capacity);
            if (take.signum() <= 0) continue;
            BigDecimal original = portion(nullableDecimal(part[3]), take, decimal(part[2]));
            BigDecimal local = ProcurementConsiderationBasis.finiteBookPortion(nullableDecimal(part[4]), take, decimal(part[2]));
            UUID stockPartId = UUID.randomUUID();
            em.createNativeQuery("""
                    INSERT INTO procurement_iqc_stock_consideration_parts(id,stock_in_item_id,
                        quality_part_id,base_qty,amount_original,amount_local,created_by)
                    VALUES(:id,:stock,:quality,:qty,:original,:local,:actor)
                    """).setParameter("id", stockPartId).setParameter("stock", stockInItemId)
                    .setParameter("quality", uuid(part[0])).setParameter("qty", take)
                    .setParameter("original", original).setParameter("local", local)
                    .setParameter("actor", currentUser.requireId()).executeUpdate();
            if ("NO_CHARGE".equals(part[6])) {
                settleAncestors(uuid(part[7]), "STOCK_IN", stockPartId, uuid(part[1]), take, original, local);
            }
            left = left.subtract(take);
        }
        if (left.signum() != 0) throw conflict("实际入库的资金份额未完全分配");
    }

    public void settleCredit(CreditQuote quote) {
        for (CreditPart part : quote.parts()) {
            settleAncestors(part.fundingSliceId(), "CREDIT", part.id(), null,
                    part.baseQty(), part.original(), part.local());
        }
    }

    public void reverseReceipt(String rawType,UUID receiptId,UUID commandId,String reason) {
        String type=type(rawType);
        Map<String,Object> params=Map.of("type",type,"receipt",receiptId);
        List<UUID> considerationIds=ids("""
                SELECT id FROM procurement_receipt_consideration_parts
                WHERE receipt_type=:type AND receipt_id=:receipt
                  AND fn_procurement_consideration_active('CONSIDERATION',id) ORDER BY id
                """,params);
        if(considerationIds.isEmpty())return;
        List<UUID> fundingIds=ids("""
                SELECT funding.id FROM procurement_iqc_funding_slices funding
                JOIN procurement_iqc_quality_consideration_parts quality ON quality.id=funding.quality_part_id
                JOIN procurement_receipt_consideration_parts part ON part.id=quality.consideration_part_id
                WHERE part.receipt_type=:type AND part.receipt_id=:receipt
                  AND fn_procurement_consideration_active('FUNDING',funding.id) ORDER BY funding.id
                """,params);
        for(UUID fundingId:fundingIds){
            Object[] free=uncommittedFunding(fundingId);
            BigDecimal total=number("SELECT base_qty FROM procurement_iqc_funding_slices WHERE id=:id",Map.of("id",fundingId));
            if(decimal(free[0]).compareTo(total)!=0){
                throw conflict("该收货失败份额已被补回或退货减款使用，请先反向对应后续事实");
            }
        }
        List<UUID> stockIds=ids("""
                SELECT stock.id FROM procurement_iqc_stock_consideration_parts stock
                JOIN procurement_iqc_quality_consideration_parts quality ON quality.id=stock.quality_part_id
                JOIN procurement_receipt_consideration_parts part ON part.id=quality.consideration_part_id
                WHERE part.receipt_type=:type AND part.receipt_id=:receipt
                  AND fn_procurement_consideration_active('STOCK',stock.id) ORDER BY stock.id
                """,params);
        for(UUID stockId:stockIds){
            for(UUID settlement:ids("""
                    SELECT id FROM procurement_iqc_funding_settlements WHERE source_kind='STOCK_IN' AND source_id=:id
                      AND fn_procurement_consideration_active('SETTLEMENT',id) ORDER BY id
                    """,Map.of("id",stockId)))appendReversal("SETTLEMENT",settlement,commandId,reason);
            appendReversal("STOCK",stockId,commandId,reason);
        }
        for(UUID fundingId:fundingIds)appendReversal("FUNDING",fundingId,commandId,reason);
        for(UUID qualityId:ids("""
                SELECT quality.id FROM procurement_iqc_quality_consideration_parts quality
                JOIN procurement_receipt_consideration_parts part ON part.id=quality.consideration_part_id
                WHERE part.receipt_type=:type AND part.receipt_id=:receipt
                  AND fn_procurement_consideration_active('QUALITY',quality.id) ORDER BY quality.id
                """,params))appendReversal("QUALITY",qualityId,commandId,reason);
        for(UUID partId:considerationIds)appendReversal("CONSIDERATION",partId,commandId,reason);
    }

    public void reverseCredit(UUID caseId,UUID documentId,UUID commandId,String reason) {
        List<UUID> creditIds=requireCreditReversible(caseId,documentId);
        for(UUID creditId:creditIds){
            for(UUID settlement:ids("""
                    SELECT id FROM procurement_iqc_funding_settlements WHERE source_kind='CREDIT' AND source_id=:id
                      AND fn_procurement_consideration_active('SETTLEMENT',id) ORDER BY id
                    """,Map.of("id",creditId)))appendReversal("SETTLEMENT",settlement,commandId,reason);
            appendReversal("CREDIT",creditId,commandId,reason);
        }
    }

    public List<UUID> requireCreditReversible(UUID caseId,UUID documentId) {
        List<UUID> creditIds=ids("""
                SELECT id FROM procurement_iqc_credit_slices WHERE credit_document_id=:document
                  AND EXISTS(SELECT 1 FROM procurement_iqc_credit_slices anchor
                    WHERE anchor.credit_document_id=:document AND anchor.case_id=:caseId)
                  AND fn_procurement_consideration_active('CREDIT',id) ORDER BY id
                """,Map.of("caseId",caseId,"document",documentId));
        if(creditIds.isEmpty())throw conflict("该退货减款凭证不存在或已经反向");
        for(UUID creditId:creditIds){
            if(number("""
                    SELECT COUNT(*) FROM procurement_receipt_consideration_parts WHERE credit_slice_id=:id
                      AND fn_procurement_consideration_active('CONSIDERATION',id)
                    """,Map.of("id",creditId)).signum()>0){
                throw conflict("该减款份额已用于重新计款补回，请先红冲对应补回收货");
            }
        }
        return creditIds;
    }

    public List<UUID> creditDocumentCases(UUID caseId,UUID documentId){
        List<UUID> documents=documentId==null?activeCreditDocuments(caseId):List.of(documentId);
        if(documents.isEmpty())return List.of(caseId);
        var cases=new java.util.TreeSet<>(ids("""
                SELECT DISTINCT case_id FROM procurement_iqc_credit_slices WHERE credit_document_id IN (:documents)
                """,Map.of("documents",documents)));
        cases.add(caseId);
        return List.copyOf(cases);
    }

    public List<UUID> activeCreditDocuments(UUID caseId) {
        return ids("""
                SELECT DISTINCT credit_document_id FROM procurement_iqc_credit_slices
                WHERE case_id=:id AND fn_procurement_consideration_active('CREDIT',id)
                ORDER BY credit_document_id
                """,Map.of("id",caseId));
    }

    public boolean hasFunding(UUID caseId) {
        return number("""
                SELECT COUNT(*) FROM procurement_iqc_funding_slices
                WHERE case_id=:id AND fn_procurement_consideration_active('FUNDING',id)
                """,Map.of("id",caseId)).signum()>0;
    }

    @Transactional(propagation=Propagation.MANDATORY,readOnly=true)
    public BigDecimal creditableBaseQty(UUID caseId,UUID sourceApId){
        return number("""
                SELECT COALESCE(SUM(funding.base_qty-COALESCE((
                    SELECT SUM(base_qty) FROM procurement_receipt_consideration_parts part
                    WHERE part.funding_slice_id=funding.id AND part.billing_mode='NO_CHARGE'
                      AND fn_procurement_consideration_active('CONSIDERATION',part.id)),0)-COALESCE((
                    SELECT SUM(base_qty) FROM procurement_iqc_credit_slices credit
                    WHERE credit.funding_slice_id=funding.id AND fn_procurement_consideration_active('CREDIT',credit.id)),0)),0)
                FROM procurement_iqc_funding_slices funding WHERE funding.case_id=:caseId
                  AND funding.source_ap_ledger_id=:ap AND fn_procurement_consideration_active('FUNDING',funding.id)
                """,Map.of("caseId",caseId,"ap",sourceApId));
    }

    @Transactional(propagation=Propagation.MANDATORY,readOnly=true)
    public Resolution resolution(UUID caseId) {
        Object[] result=rows("""
                SELECT COUNT(funding.id),COALESCE(SUM(funding.base_qty),0),
                       COALESCE(SUM(funding.amount_original),0),COALESCE(SUM(funding.amount_local),0),
                       COALESCE(SUM(committed.qty),0),COALESCE(SUM(physical.qty),0),
                       COALESCE(SUM(settled.stocked),0),COALESCE(SUM(settled.credited),0),
                       COALESCE(SUM(settled.original),0),COALESCE(SUM(settled.local),0),
                       COALESCE(SUM(settled.descendant_credited),0),
                       COALESCE(BOOL_AND(funding.amount_original IS NOT NULL AND settled.original_known),FALSE),
                       COALESCE(BOOL_AND(funding.amount_local IS NOT NULL AND settled.local_known),FALSE)
                FROM procurement_iqc_funding_slices funding
                LEFT JOIN LATERAL (
                    SELECT SUM(qty) qty FROM (
                        SELECT base_qty qty FROM procurement_receipt_consideration_parts part
                        WHERE part.funding_slice_id=funding.id AND part.billing_mode='NO_CHARGE'
                          AND fn_procurement_consideration_active('CONSIDERATION',part.id)
                        UNION ALL
                        SELECT base_qty FROM procurement_iqc_credit_slices credit
                        WHERE credit.funding_slice_id=funding.id AND fn_procurement_consideration_active('CREDIT',credit.id)
                    ) used
                ) committed ON TRUE
                LEFT JOIN LATERAL (
                    SELECT SUM(base_qty) qty FROM procurement_receipt_consideration_parts part
                    WHERE part.funding_slice_id=funding.id AND part.billing_mode='NO_CHARGE'
                      AND fn_procurement_consideration_active('CONSIDERATION',part.id)
                ) physical ON TRUE
                LEFT JOIN LATERAL (
                    SELECT SUM(base_qty) FILTER(WHERE source_kind='STOCK_IN') stocked,
                           SUM(base_qty) FILTER(WHERE source_kind='CREDIT') credited,
                           SUM(base_qty) FILTER(WHERE source_kind='CREDIT'
                               AND terminal_funding_slice_id<>funding.id) descendant_credited,
                           SUM(amount_original) original,SUM(amount_local) local,
                           COUNT(*)=COUNT(amount_original) original_known,COUNT(*)=COUNT(amount_local) local_known
                    FROM procurement_iqc_funding_settlements settlement
                    WHERE settlement.funding_slice_id=funding.id
                      AND fn_procurement_consideration_active('SETTLEMENT',settlement.id)
                ) settled ON TRUE
                WHERE funding.case_id=:id AND fn_procurement_consideration_active('FUNDING',funding.id)
                """,Map.of("id",caseId)).getFirst();
        boolean legacy=decimal(result[0]).signum()==0;
        BigDecimal stocked=decimal(result[6]);
        BigDecimal credited=decimal(result[7]);
        BigDecimal unresolved=decimal(result[1]).subtract(stocked).subtract(credited).max(BigDecimal.ZERO);
        BigDecimal creditable=decimal(result[1]).subtract(decimal(result[4])).max(BigDecimal.ZERO);
        BigDecimal pending=decimal(result[5]).subtract(stocked).subtract(decimal(result[10])).max(BigDecimal.ZERO);
        String state=legacy?"LEGACY_UNCLASSIFIED":unresolved.signum()==0?"SETTLED"
                :stocked.add(credited).signum()>0?"PARTIAL":"OPEN";
        return new Resolution(creditable,pending,stocked,credited,unresolved,
                Boolean.TRUE.equals(result[11])?decimal(result[2]).subtract(decimal(result[8])).max(BigDecimal.ZERO):null,
                Boolean.TRUE.equals(result[12])?decimal(result[3]).subtract(decimal(result[9])).max(BigDecimal.ZERO):null,state,legacy);
    }

    private void appendReversal(String kind,UUID targetId,UUID commandId,String reason) {
        em.createNativeQuery("""
                INSERT INTO procurement_iqc_consideration_reversals(id,target_kind,target_id,command_id,reason,created_by)
                VALUES(:id,:kind,:target,:command,:reason,:actor)
                """).setParameter("id",UUID.randomUUID()).setParameter("kind",kind)
                .setParameter("target",targetId).setParameter("command",commandId).setParameter("reason",reason)
                .setParameter("actor",currentUser.requireId()).executeUpdate();
    }

    private void settleAncestors(UUID terminalFundingId, String kind, UUID sourceId, UUID considerationId,
            BigDecimal baseQty, BigDecimal original, BigDecimal local) {
        em.createNativeQuery("""
                WITH RECURSIVE ancestors AS (
                    SELECT id,parent_funding_slice_id FROM procurement_iqc_funding_slices WHERE id=:terminal
                    UNION ALL
                    SELECT parent.id,parent.parent_funding_slice_id FROM procurement_iqc_funding_slices parent
                    JOIN ancestors child ON child.parent_funding_slice_id=parent.id
                )
                INSERT INTO procurement_iqc_funding_settlements(id,funding_slice_id,terminal_funding_slice_id,
                    source_kind,source_id,consideration_part_id,base_qty,amount_original,amount_local,created_by)
                SELECT gen_random_uuid(),id,:terminal,:kind,:source,:part,:qty,:original,:local,:actor FROM ancestors
                """).setParameter("terminal", terminalFundingId).setParameter("kind", kind)
                .setParameter("source", sourceId).setParameter("part", considerationId)
                .setParameter("qty", baseQty).setParameter("original", original).setParameter("local", local)
                .setParameter("actor", currentUser.requireId()).executeUpdate();
    }

    private List<Object[]> funding(UUID caseId) {
        return rows("""
                SELECT funding.id,funding.base_qty,funding.amount_original,funding.amount_local,funding.source_ap_ledger_id
                FROM procurement_iqc_funding_slices funding
                JOIN procurement_iqc_quality_consideration_parts quality ON quality.id=funding.quality_part_id
                JOIN procurement_inspection_events event ON event.id=quality.inspection_event_id
                WHERE funding.case_id=:id AND fn_procurement_consideration_active('FUNDING',funding.id)
                ORDER BY event.occurred_at,event.id,funding.id FOR UPDATE OF funding
                """, Map.of("id", caseId));
    }

    private Object[] uncommittedFunding(UUID fundingId) {
        return rows("""
                SELECT funding.base_qty-COALESCE(parts.qty,0)-COALESCE(credits.qty,0),
                       funding.amount_original-COALESCE(parts.original,0)-COALESCE(credits.original,0),
                       funding.amount_local-COALESCE(parts.local,0)-COALESCE(credits.local,0)
                FROM procurement_iqc_funding_slices funding
                LEFT JOIN LATERAL (
                    SELECT SUM(base_qty) qty,SUM(nominal_original) original,SUM(nominal_local) local
                    FROM procurement_receipt_consideration_parts part
                    WHERE part.funding_slice_id=funding.id AND part.billing_mode='NO_CHARGE'
                      AND fn_procurement_consideration_active('CONSIDERATION',part.id)
                ) parts ON TRUE
                LEFT JOIN LATERAL (
                    SELECT SUM(base_qty) qty,SUM(amount_original) original,SUM(amount_local) local
                    FROM procurement_iqc_credit_slices credit WHERE credit.funding_slice_id=funding.id
                      AND fn_procurement_consideration_active('CREDIT',credit.id)
                ) credits ON TRUE
                WHERE funding.id=:id
                """, Map.of("id", fundingId)).getFirst();
    }

    @Override
    @Transactional(propagation = Propagation.MANDATORY, readOnly = true)
    public List<Part> receipt(String rawType, UUID receiptId) {
        return readParts("part.receipt_type=:type AND part.receipt_id=:id",
                Map.of("type", type(rawType), "id", receiptId));
    }

    @Override
    @Transactional(propagation = Propagation.MANDATORY, readOnly = true)
    public List<Part> failure(UUID failureCaseId) {
        return rows("""
                SELECT part.id,part.receipt_type,part.receipt_id,part.receipt_item_id,part.billing_mode,
                       part.replacement_allocation_id,funding.case_id,funding.id,
                       funding.root_funding_slice_id,funding.root_case_id,part.credit_slice_id,
                       source_case.receipt_item_id,funding.root_receipt_item_id,funding.source_ap_ledger_id,
                       ledger.id,funding.base_qty,funding.amount_original,funding.amount_local,
                       CASE WHEN part.billing_mode='NO_CHARGE' THEN 0 ELSE funding.amount_original END,
                       CASE WHEN part.billing_mode='NO_CHARGE' THEN 0 ELSE funding.amount_local END
                FROM procurement_iqc_funding_slices funding
                JOIN procurement_iqc_quality_consideration_parts quality ON quality.id=funding.quality_part_id
                JOIN procurement_receipt_consideration_parts part ON part.id=quality.consideration_part_id
                LEFT JOIN procurement_iqc_funding_slices source_funding ON source_funding.id=part.funding_slice_id
                LEFT JOIN procurement_iqc_rejection_cases source_case ON source_case.id=source_funding.case_id
                LEFT JOIN ar_ap_ledger ledger ON ledger.source_doc_id=part.receipt_id
                  AND ledger.source_doc_type=part.receipt_type||'_RECEIPT'
                  AND ledger.direction='AP' AND ledger.status=1 AND ledger.is_deleted=FALSE
                  AND part.billing_mode<>'NO_CHARGE'
                WHERE funding.case_id=:id AND fn_procurement_consideration_active('FUNDING',funding.id)
                ORDER BY funding.id
                """, Map.of("id", failureCaseId)).stream().map(ProcurementReceiptConsiderationService::part).toList();
    }

    private List<Part> readParts(String where, Map<String, Object> params) {
        return rows("""
                SELECT part.id,part.receipt_type,part.receipt_id,part.receipt_item_id,part.billing_mode,
                       part.replacement_allocation_id,funding.case_id,funding.id,
                       funding.root_funding_slice_id,funding.root_case_id,part.credit_slice_id,
                       source_case.receipt_item_id,funding.root_receipt_item_id,funding.source_ap_ledger_id,
                       ledger.id,part.base_qty,part.nominal_original,part.nominal_local,
                       part.payable_original,part.payable_local
                FROM procurement_receipt_consideration_parts part
                LEFT JOIN procurement_iqc_funding_slices funding ON funding.id=part.funding_slice_id
                LEFT JOIN procurement_iqc_rejection_cases source_case ON source_case.id=funding.case_id
                LEFT JOIN ar_ap_ledger ledger ON ledger.source_doc_id=part.receipt_id
                  AND ledger.source_doc_type=part.receipt_type||'_RECEIPT'
                  AND ledger.direction='AP' AND ledger.status=1 AND ledger.is_deleted=FALSE
                  AND part.billing_mode<>'NO_CHARGE'
                WHERE fn_procurement_consideration_active('CONSIDERATION',part.id)
                  AND (%s) ORDER BY part.id
                """.formatted(where), params).stream().map(ProcurementReceiptConsiderationService::part).toList();
    }

    private static Part part(Object[] row) {
        return new Part(uuid(row[0]), text(row[1]), uuid(row[2]), uuid(row[3]), BillingMode.valueOf(text(row[4])),
                uuid(row[5]), uuid(row[6]), uuid(row[7]), uuid(row[8]), uuid(row[9]), uuid(row[10]),
                uuid(row[11]), uuid(row[12]), uuid(row[13]), uuid(row[14]), decimal(row[15]),
                nullableDecimal(row[16]), nullableDecimal(row[17]), decimal(row[18]), decimal(row[19]));
    }

    @Override
    @Transactional(propagation = Propagation.MANDATORY, readOnly = true)
    public List<QualityPart> quality(UUID inspectionEventId) {
        return rows("""
                SELECT part.id,part.consideration_part_id,event.inspection_item_id,
                       event.id,event.action,part.base_qty
                FROM procurement_iqc_quality_consideration_parts part
                JOIN procurement_inspection_events event ON event.id=part.inspection_event_id
                WHERE event.id=:id AND fn_procurement_consideration_active('QUALITY',part.id)
                ORDER BY part.id
                """,Map.of("id",inspectionEventId)).stream().map(row -> new QualityPart(
                        uuid(row[0]),uuid(row[1]),uuid(row[2]),uuid(row[3]),text(row[4]),decimal(row[5]))).toList();
    }

    @Override
    @Transactional(propagation=Propagation.MANDATORY,readOnly=true)
    public Optional<QualityPart> failureQuality(UUID failureCaseId,UUID fundingSliceId) {
        List<Object[]> result=rows("""
                SELECT quality.id,quality.consideration_part_id,event.inspection_item_id,
                       event.id,event.action,quality.base_qty
                FROM procurement_iqc_funding_slices funding
                JOIN procurement_iqc_quality_consideration_parts quality ON quality.id=funding.quality_part_id
                JOIN procurement_inspection_events event ON event.id=quality.inspection_event_id
                JOIN procurement_iqc_rejection_cases rejection ON rejection.id=funding.case_id
                  AND rejection.inspection_item_id=event.inspection_item_id
                WHERE funding.id=:funding AND funding.case_id=:caseId AND event.action='FAIL'
                  AND rejection.status<>'REVERSED' AND rejection.is_deleted=FALSE
                  AND fn_procurement_consideration_active('FUNDING',funding.id)
                  AND fn_procurement_consideration_active('QUALITY',quality.id)
                  AND fn_procurement_consideration_active('CONSIDERATION',quality.consideration_part_id)
                """,Map.of("funding",fundingSliceId,"caseId",failureCaseId));
        if(result.isEmpty())return Optional.empty();
        if(result.size()!=1)throw conflict("质量失败资金来源重复，不能猜测实际成本位置");
        Object[] row=result.getFirst();
        return Optional.of(new QualityPart(uuid(row[0]),uuid(row[1]),uuid(row[2]),uuid(row[3]),text(row[4]),decimal(row[5])));
    }

    @Override
    @Transactional(propagation = Propagation.MANDATORY, readOnly = true)
    public List<StockPart> stock(UUID stockInItemId) {
        return rows("""
                SELECT part.id,part.quality_part_id,quality.consideration_part_id,
                       part.stock_in_item_id,part.base_qty
                FROM procurement_iqc_stock_consideration_parts part
                JOIN procurement_iqc_quality_consideration_parts quality ON quality.id=part.quality_part_id
                WHERE part.stock_in_item_id=:id AND fn_procurement_consideration_active('STOCK',part.id)
                ORDER BY part.id
                """,Map.of("id",stockInItemId)).stream().map(row -> new StockPart(
                        uuid(row[0]),uuid(row[1]),uuid(row[2]),uuid(row[3]),decimal(row[4]))).toList();
    }

    @SuppressWarnings("unchecked")
    private List<Object[]> rows(String sql, Map<String, Object> params) {
        Query query = em.createNativeQuery(sql);
        params.forEach(query::setParameter);
        return query.getResultList();
    }

    @SuppressWarnings("unchecked")
    private List<UUID> ids(String sql,Map<String,Object> params) {
        Query query=em.createNativeQuery(sql);
        params.forEach(query::setParameter);
        return query.getResultList();
    }

    private BigDecimal number(String sql, Map<String, Object> params) {
        Query query = em.createNativeQuery(sql);
        params.forEach(query::setParameter);
        return decimal(query.getSingleResult());
    }

    private static BigDecimal portion(BigDecimal amount, BigDecimal quantity, BigDecimal total) {
        return ProcurementConsiderationBasis.finitePortion(amount,quantity,total);
    }

    private static BigDecimal nullableDecimal(Object value) { return value==null?null:decimal(value); }
    private static String type(String type) {
        if (!"PURCHASE".equals(type) && !"SUBCONTRACT".equals(type)) throw conflict("收货类型无效");
        return type;
    }

    private static BigDecimal decimal(Object value) {
        return value == null ? BigDecimal.ZERO : value instanceof BigDecimal decimal
                ? decimal : new BigDecimal(value.toString());
    }

    private static UUID uuid(Object value) { return value == null ? null : (UUID) value; }
    private static String text(Object value) { return value == null ? null : value.toString(); }
    private static ApiException conflict(String message) { return new ApiException(ErrorCode.CONFLICT, message); }
}
