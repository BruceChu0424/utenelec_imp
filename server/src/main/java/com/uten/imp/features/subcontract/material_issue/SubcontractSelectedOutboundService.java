package com.uten.imp.features.subcontract.material_issue;

import com.fasterxml.jackson.core.JsonProcessingException;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.common.concurrency.ProcurementMutationLocks;
import com.uten.imp.common.docnumber.DocNumberPrefix;
import com.uten.imp.common.docnumber.DocNumberService;
import com.uten.imp.common.util.CanonicalFingerprint;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.subcontract.plan.SubcontractMaterialPlanService;
import com.uten.imp.security.SecurityContextCurrentUser;
import com.uten.imp.security.TxSessionVars;
import jakarta.persistence.EntityManager;
import jakarta.persistence.LockModeType;
import lombok.RequiredArgsConstructor;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.util.*;
import static com.uten.imp.features.subcontract.material_issue.SubcontractSelectedOutboundContracts.*;

/** Atomically separates an explicit warehouse selection without editing any remaining draw line. */
@Service
@RequiredArgsConstructor
public class SubcontractSelectedOutboundService {
    private final EntityManager em;
    private final TxSessionVars tx;
    private final SecurityContextCurrentUser currentUser;
    private final ProcurementMutationLocks locks;
    private final SubcontractMaterialIssueService issues;
    private final SubcontractMaterialIssueRepository headers;
    private final SubcontractMaterialIssueItemRepository items;
    private final SubcontractMaterialPlanService plans;
    private final DocNumberService numbers;
    private final ObjectMapper json;

    @Transactional
    @PreAuthorize("hasAuthority('subcontract_material_issue:view') and hasAuthority('subcontract_outbound:view')")
    public Review review(UUID sourceId) {
        var guard=locks.materialIssue(sourceId);
        em.find(SubcontractMaterialIssue.class,sourceId,LockModeType.PESSIMISTIC_READ);
        var document = issues.detail(sourceId);
        if (document.getStatus()==null || document.getStatus()!=0) throw conflict("领料单已变化，请重新核对");
        guard.verifyUnchanged();
        return new Review(document, fingerprint(sourceId));
    }

    @Transactional
    @PreAuthorize("hasAuthority('subcontract_material_issue:edit') and hasAuthority('subcontract_material_issue:approve') and hasAuthority('subcontract_outbound:execute') and hasAuthority('subcontract_outbound:view') and hasAuthority('subcontract_material_issue:view')")
    public Result execute(UUID sourceId, Request request) {
        validate(request);
        tx.bind();
        UUID actor=currentUser.requireId();
        String requestJson=encode(request);
        String requestHash=CanonicalFingerprint.sha256(List.of(sourceId.toString(),requestJson));
        em.createNativeQuery("SELECT pg_advisory_xact_lock(hashtextextended(:key, 900))")
                .setParameter("key", actor+":SC_SELECTED_OUTBOUND:"+request.idempotencyKey()).getSingleResult();
        Result replay=findReceipt(sourceId,request.idempotencyKey(),requestHash);
        if(replay!=null)return replay;

        var input=json.convertValue(request.document(),com.uten.imp.features.subcontract.material_issue.dto.MaterialIssueSaveRequest.class);
        var guard=locks.materialIssueInputs(sourceId,
                input.getItems().stream().map(line->line.getOrderItemId()).toList(),
                input.getItems().stream().map(line->new com.uten.imp.application.concurrency.FulfillmentMutationLockPlan.InventoryDimension(
                        line.getGoodsId(),line.getColorId())).toList(),input.getWarehouseId());
        var source=em.find(SubcontractMaterialIssue.class,sourceId,LockModeType.PESSIMISTIC_WRITE);
        if(source==null || source.isDeleted())throw new ApiException(ErrorCode.NOT_FOUND,"委外材料出仓单不存在");
        issues.requireIssueWritable(source,"subcontract_material_issue:edit");
        issues.requireIssueWritable(source,"subcontract_material_issue:approve");
        if(source.getStatus()==null || source.getStatus()!=0)throw conflict("领料单已变化，请重新核对");
        List<SubcontractMaterialIssueItem> all=items.findByIssueIdOrderByLineNoAsc(sourceId);
        em.createNativeQuery("""
                SELECT record_id FROM platform_record_fields WHERE record_id=:source
                  OR record_id IN (SELECT id FROM subcontract_material_issue_items WHERE issue_id=:source)
                ORDER BY scope,record_id FOR UPDATE
                """).setParameter("source",sourceId).getResultList();
        List<UUID> allIds=all.stream().map(SubcontractMaterialIssueItem::getId).toList();
        Set<UUID> selected=new HashSet<>(request.itemIds());
        if(!allIds.containsAll(selected) || !Objects.equals(fingerprint(sourceId),request.fingerprint()))
            throw conflict("领料单或所选明细已变化，请重新核对");
        guard.verifyUnchanged();
        if(!Objects.equals(source.getSupplierId(),input.getSupplierId()))throw conflict("领料单的委外商不可变更");
        Map<UUID,SubcontractMaterialIssueItem> selectedRows=new HashMap<>();
        for(var row:all)if(selected.contains(row.getId())) {
            if(row.getPlanItemId()==null || row.getRequestedQty()==null)throw conflict("所选行缺少原领料来源");
            selectedRows.put(row.getId(),row);
        }
        var selectedPlans=selectedRows.values().stream().map(SubcontractMaterialIssueItem::getPlanItemId)
                .collect(java.util.stream.Collectors.toSet());
        if(all.stream().anyMatch(row->!selected.contains(row.getId()) && selectedPlans.contains(row.getPlanItemId())))
            throw conflict("领料行存在重复计划来源，请核对后出仓");
        Set<UUID> posted=new HashSet<>();
        for(var line:input.getItems()) {
            var original=selectedRows.get(line.getId());
            if(original==null || !posted.add(line.getId()) || !Objects.equals(original.getPlanItemId(),line.getPlanItemId()))
                throw conflict("出仓内容必须是所选的原领料明细");
        }
        if(!posted.equals(selected))throw validation("本次出仓范围必须与正数明细完全一致；暂不发的行请保留待发");
        // Only positive execution rows enter this command. Omitted/zero rows stay on the source.
        input.setItemIds(request.itemIds());
        UUID executionId=sourceId;
        String billNo=source.getBillNo();
        Map<UUID,UUID> executionRows=new LinkedHashMap<>();
        boolean split=selected.size()!=allIds.size();
        if(split) {
            var execution=executionHeader(source);
        com.uten.imp.common.history.ImportedBusinessDocumentPolicy.mutable(em,"subcontract_material_issues",execution);
            headers.saveAndFlush(execution);
            executionId=execution.getId();
            billNo=execution.getBillNo();
        }
        UUID commandId=UUID.randomUUID();
        for(UUID originalId:request.itemIds()) {
            UUID executionItemId=originalId;
            if(split) {
                var executionItem=new SubcontractMaterialIssueItem();
                org.springframework.beans.BeanUtils.copyProperties(selectedRows.get(originalId),executionItem,
                        "id","legacyId","issueId","createdAt","updatedAt","createdBy","updatedBy");
                executionItem.setIssueId(executionId);executionItem.setBillNo(billNo);
                items.save(executionItem);executionItemId=executionItem.getId();
            }
            executionRows.put(originalId,executionItemId);
        }
        items.flush();
        em.createNativeQuery("""
                INSERT INTO subcontract_selected_outbound_commands
                  (id,actor_id,idempotency_key,request_hash,request_json,source_issue_id,execution_issue_id,execution_bill_no,selected_item_ids)
                VALUES (:id,:actor,:key,:hash,CAST(:request AS jsonb),:source,:execution,:billNo,CAST(:selected AS uuid[]))
                """).setParameter("id",commandId).setParameter("actor",actor).setParameter("key",request.idempotencyKey()).setParameter("hash",requestHash)
                .setParameter("request",requestJson).setParameter("source",sourceId).setParameter("execution",executionId)
                .setParameter("billNo",billNo).setParameter("selected",uuidArray(request.itemIds())).executeUpdate();
        for(var mapping:executionRows.entrySet())em.createNativeQuery("""
                INSERT INTO subcontract_selected_outbound_items(command_id,source_item_id,execution_item_id)
                VALUES (:command,:source,:execution)
                """).setParameter("command",commandId).setParameter("source",mapping.getKey())
                .setParameter("execution",mapping.getValue()).executeUpdate();
        if(split) {
            // Source identities of reservations/entitlement handoffs are immutable. Release A only,
            // then let the existing execution kernel reserve A for its new header. B is never written.
            plans.releaseDraftReservations(sourceId,selectedPlans);
            Map<UUID,UUID> fieldCopies=new LinkedHashMap<>(executionRows);fieldCopies.put(sourceId,executionId);
            com.uten.imp.common.platformcolumns.PlatformRecordFieldForks.copy(em,actor,fieldCopies);
            for(var line:input.getItems()) {
                UUID originalId=line.getId();UUID targetId=executionRows.get(originalId);
                var fields=line.getPlatformFields();
                if(fields!=null) {
                    @SuppressWarnings("unchecked") List<Number> versions=em.createNativeQuery("SELECT version FROM platform_record_fields WHERE scope='subcontract_material_issue_item' AND record_id=:id")
                            .setParameter("id",originalId).getResultList();
                    long version=versions.isEmpty()?0:versions.getFirst().longValue();
                    if(!originalId.equals(fields.sourceRecordId())||version!=fields.expectedVersion())throw conflict("原明细扩展字段已变化，请重新核对");
                    line.setPlatformFields(new com.uten.imp.common.platformcolumns.PlatformColumnLineInput.Fields(targetId,
                            versions.isEmpty()?0:1,fields.cells()));
                }
                line.setId(targetId);
            }
            input.setItemIds(List.copyOf(executionRows.values()));
            em.createNativeQuery("""
                    UPDATE subcontract_material_issue_items SET is_deleted=TRUE,
                      warehouse_split_at=now(),warehouse_split_command_id=:command
                    WHERE issue_id=:source AND id IN (:selected) AND NOT is_deleted
                    """).setParameter("command",commandId).setParameter("source",sourceId).setParameter("selected",request.itemIds()).executeUpdate();
            em.createNativeQuery("""
                    UPDATE subcontract_material_issues SET
                      total_original=COALESCE((SELECT sum(amount_original) FROM subcontract_material_issue_items WHERE issue_id=:source AND NOT is_deleted),0),
                      total_local=COALESCE((SELECT sum(amount_local) FROM subcontract_material_issue_items WHERE issue_id=:source AND NOT is_deleted),0)
                    WHERE id=:source
                    """).setParameter("source",sourceId).executeUpdate();
            em.clear();
        }
        issues.update(executionId,input);
        var approved=issues.approveSelected(executionId,
                new com.uten.imp.features.subcontract.material_issue.dto.MaterialIssueApproveRequest(
                        input.getItems().stream().map(line->line.getId()).toList()));
        if(approved.getStatus()!=1)throw conflict("出仓结果未完成");
        return new Result(sourceId,executionId,billNo,List.copyOf(request.itemIds()),(short)1);
    }

    @Transactional(readOnly=true)
    @PreAuthorize("hasAuthority('subcontract_material_issue:view') and hasAuthority('subcontract_outbound:view')")
    public Result receipt(UUID sourceId,String key) {
        if(key==null || !key.matches("[A-Za-z0-9._:-]{8,128}"))throw validation("操作编号缺失或不正确");
        return findReceipt(sourceId,key,null);
    }

    private Result findReceipt(UUID sourceId,String key,String requestHash) {
        @SuppressWarnings("unchecked") List<Object[]> rows=em.createNativeQuery("""
                SELECT source_issue_id,execution_issue_id,execution_bill_no,array_to_string(selected_item_ids,','),request_hash
                FROM subcontract_selected_outbound_commands WHERE actor_id=:actor AND idempotency_key=:key
                """).setParameter("actor",currentUser.requireId()).setParameter("key",key).getResultList();
        if(rows.isEmpty())return null;
        Object[] row=rows.getFirst();
        if(!sourceId.equals(row[0]) || (requestHash!=null && !requestHash.equals(row[4])))throw conflict("同一操作编号不能用于不同的出仓内容");
        // A historical receipt proves the old outcome; current ownership and read grants still apply.
        issues.detailHistory((UUID)row[0]);
        issues.detailHistory((UUID)row[1]);
        return new Result((UUID)row[0],(UUID)row[1],(String)row[2],
                Arrays.stream(((String)row[3]).split(",")).map(UUID::fromString).toList(),(short)1);
    }

    private String fingerprint(UUID sourceId) {
        @SuppressWarnings("unchecked") List<String> facts=em.createNativeQuery("""
                SELECT 'header:'||h.xmin::text||':'||to_jsonb(h)::text FROM subcontract_material_issues h WHERE h.id=:id
                UNION ALL SELECT 'item:'||i.xmin::text||':'||to_jsonb(i)::text FROM subcontract_material_issue_items i WHERE i.issue_id=:id
                UNION ALL SELECT 'reservation:'||r.xmin::text||':'||to_jsonb(r)::text FROM stock_reservations r
                  WHERE r.source_doc_type='SUBCONTRACT_OUTBOUND_DRAFT' AND r.source_doc_id=:id AND NOT r.is_deleted
                UNION ALL SELECT 'field:'||f.xmin::text||':'||to_jsonb(f)::text FROM platform_record_fields f
                  WHERE f.record_id=:id OR f.record_id IN (SELECT item.id FROM subcontract_material_issue_items item WHERE item.issue_id=:id)
                """).setParameter("id",sourceId).getResultList();
        return CanonicalFingerprint.sha256(facts);
    }

    private SubcontractMaterialIssue executionHeader(SubcontractMaterialIssue source) {
        var result=new SubcontractMaterialIssue();
        result.setBillNo(numbers.nextNumber(DocNumberPrefix.SUB_MATERIAL_ISSUE));
        result.setBillDate(source.getBillDate());result.setSupplierId(source.getSupplierId());
        result.setWarehouseId(source.getWarehouseId());result.setWorkerId(source.getWorkerId());
        result.setMakerId(source.getMakerId());result.setOwnerPool(source.getOwnerPool());
        result.setMakerName(source.getMakerName());result.setMakerLegacyId(source.getMakerLegacyId());
        result.setOperatorName(source.getOperatorName());result.setOperatorLegacyId(source.getOperatorLegacyId());
        result.setSourceDocNo(source.getSourceDocNo());result.setRemark(source.getRemark());
        result.setDeliverDate(source.getDeliverDate());
        return result;
    }

    private void validate(Request request) {
        if(request==null || request.idempotencyKey()==null || !request.idempotencyKey().matches("[A-Za-z0-9._:-]{8,128}")
                || request.fingerprint()==null || !request.fingerprint().matches("[a-f0-9]{64}")
                || request.itemIds()==null || request.itemIds().isEmpty() || request.itemIds().size()>com.uten.imp.common.validation.RequestLimits.DOCUMENT_LINES
                || request.itemIds().stream().anyMatch(Objects::isNull) || new HashSet<>(request.itemIds()).size()!=request.itemIds().size()
                || request.document()==null || request.document().getItems()==null || request.document().getItems().isEmpty()
                || request.document().getItems().size()>com.uten.imp.common.validation.RequestLimits.DOCUMENT_LINES
                || request.document().getBillDate()==null || request.document().getWarehouseId()==null
                || request.document().getItems().stream().anyMatch(line->line==null || line.getId()==null || line.getGoodsId()==null
                        || line.getQty()==null || line.getQty().signum()<=0))throw validation("请明确选择本次出仓明细和操作编号");
    }
    private String encode(Object value) {try{return json.writeValueAsString(value);}catch(JsonProcessingException e){throw validation("出仓内容无效");}}
    private String uuidArray(List<UUID> values){return "{"+values.stream().map(UUID::toString).collect(java.util.stream.Collectors.joining(","))+"}";}
    private ApiException validation(String message){return new ApiException(ErrorCode.VALIDATION_FAILED,message);}
    private ApiException conflict(String message){return new ApiException(ErrorCode.CONFLICT,message);}
}
