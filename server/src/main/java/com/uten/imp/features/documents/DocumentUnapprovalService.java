package com.uten.imp.features.documents;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.application.port.DocumentUnapprovalPort;
import com.uten.imp.common.docnumber.DocNumberService;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.security.SecurityContextCurrentUser;
import com.uten.imp.security.TxSessionVars;
import jakarta.persistence.EntityManager;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.UUID;
import java.util.function.Function;
import java.util.stream.Collectors;

/** Reverse the approved generation and atomically produce an editable, independently approvable draft. */
@Service
public class DocumentUnapprovalService {
    private final Map<String, DocumentUnapprovalPort> families;
    private final EntityManager em;
    private final SecurityContextCurrentUser currentUser;
    private final DocNumberService numbers;
    private final TxSessionVars tx;
    private final ObjectMapper json;

    public DocumentUnapprovalService(List<DocumentUnapprovalPort> adapters, EntityManager em,
            SecurityContextCurrentUser currentUser, DocNumberService numbers, TxSessionVars tx,
            ObjectMapper json) {
        this.families = adapters.stream().collect(Collectors.toUnmodifiableMap(
                DocumentUnapprovalPort::family, Function.identity()));
        this.em = em; this.currentUser = currentUser; this.numbers = numbers; this.tx = tx; this.json = json;
    }

    @Transactional
    public Object unapprove(String family, UUID originalId, UnapproveRequest request) {
        if (originalId == null) throw new ApiException(ErrorCode.VALIDATION_FAILED,"请填写有效的反审原因和提交编号");
        if (request == null) throw new ApiException(ErrorCode.VALIDATION_FAILED,"请填写有效的反审原因和提交编号");
        if(request.idempotencyKey()==null || request.reason()==null
                || request.idempotencyKey().strip().length()<8 || request.idempotencyKey().strip().length()>128
                || !request.idempotencyKey().strip().matches("[A-Za-z0-9._:-]+")
                || request.reason().isBlank() || request.reason().strip().length()>500)
            throw new ApiException(ErrorCode.VALIDATION_FAILED,"请填写有效的反审原因和提交编号");
        tx.bind();
        var adapter = requireFamily(family);
        requireAuthorities(adapter, "view", "reverse");
        requireWriteIdentity();
        // Existing family methods still own object scopes and physical/downstream reversibility.
        adapter.detail(originalId);
        em.createNativeQuery("SELECT pg_advisory_xact_lock(hashtextextended(:identity, 0))")
                .setParameter("identity", "DOCUMENT_UNAPPROVAL:" + family + ":" + originalId).getSingleResult();
        List<?> prior = em.createNativeQuery("SELECT draft_id FROM document_unapprovals WHERE family=:family AND original_id=:id")
                .setParameter("family", family).setParameter("id", originalId).getResultList();
        if (!prior.isEmpty()) return successorDetail(adapter,(UUID) prior.getFirst(),originalId);
        if(Boolean.TRUE.equals(em.createNativeQuery("SELECT legacy_id IS NOT NULL FROM "+adapter.header().table()+" WHERE id=:id")
                .setParameter("id",originalId).getSingleResult()))
            throw new ApiException(ErrorCode.CONFLICT,"历史原始记录仅供核对，不能通用反审生成新业务");
        adapter.requireSupported(originalId);
        if (request.expectedSnapshot() != null && !request.expectedSnapshot().matches("[a-f0-9]{64}"))
            throw new ApiException(ErrorCode.VALIDATION_FAILED,"反审核对版本无效，请重新核对");
        var capability = capability(family, originalId);
        if (!capability.eligible())
            throw new ApiException(ErrorCode.CONFLICT,capability.reasons().stream()
                    .map(DocumentUnapprovalPort.Reason::message).collect(Collectors.joining("；")));
        if (request.expectedSnapshot() != null && !request.expectedSnapshot().equals(capability.factsSnapshot()))
            throw new ApiException(ErrorCode.CONFLICT,"反审条件在确认期间已变化，请重新核对");
        adapter.reverse(originalId);
        em.flush();
        var draftId = UUID.randomUUID();
        var billNo = numbers.nextNumber(adapter.numberPrefix(originalId));
        copyHeader(adapter.header(), originalId, draftId, billNo);
        var lineIds = copyLines(adapter, originalId, draftId, billNo);
        for (var source : adapter.sources()) copySources(source, lineIds);
        copyPlatformFields(originalId,draftId,lineIds);
        adapter.afterDraftCreated(originalId, draftId);
        // The same original can have only one successor even when a lost response is retried with a new key.
        em.createNativeQuery("""
                INSERT INTO document_unapprovals(family,original_id,draft_id,draft_bill_no,request_key,
                        reason,line_id_map,created_by)
                VALUES (:family,:original,:draft,:number,:key,:reason,CAST(:lines AS jsonb),:actor)
                """).setParameter("family", family).setParameter("original", originalId)
                .setParameter("draft", draftId).setParameter("number", billNo)
                .setParameter("key", request.idempotencyKey().strip()).setParameter("reason", request.reason().strip())
                .setParameter("lines", lineMapJson(lineIds)).setParameter("actor", currentUser.requireId()).executeUpdate();
        em.flush();
        return successorDetail(adapter,draftId,originalId);
    }

    @Transactional(readOnly=true, noRollbackFor=ApiException.class)
    public UnapprovalCapability capability(String family, UUID id) {
        var adapter = requireFamily(family);
        requireAuthorities(adapter, "view");
        adapter.detail(id); // Never disclose whether a hidden document or its child exists.
        var user = currentUser.get().orElseThrow(() -> new ApiException(ErrorCode.FORBIDDEN));
        boolean permitted = !user.isVisitor() && user.getEmployeeId()!=null && !user.isMustChangePassword() && user.isAccountNonLocked()
                && user.getImpersonatedBy() == null && (user.isSuperAdmin() || user.getAuthorities().stream()
                .anyMatch(authority -> authority.getAuthority().equals(adapter.permission() + ":reverse")));
        Object[] stored = (Object[]) em.createNativeQuery("SELECT header.status,header.legacy_id,to_jsonb(header)::text FROM "
                + adapter.header().table() + " header WHERE header.id=:id AND NOT header.is_deleted")
                .setParameter("id", id).getSingleResult();
        short state = stored[0] instanceof Number number ? number.shortValue() : Short.MIN_VALUE;
        UUID successor = null;
        List<?> links = em.createNativeQuery("SELECT draft_id FROM document_unapprovals WHERE family=:family AND original_id=:id")
                .setParameter("family", family).setParameter("id", id).getResultList();
        if (!links.isEmpty()) {
            UUID candidate = (UUID) links.getFirst();
            try { adapter.detail(candidate); successor = candidate; }
            catch (ApiException failure) {
                if (failure.getCode() != ErrorCode.NOT_FOUND && failure.getCode() != ErrorCode.FORBIDDEN) throw failure;
            }
        }
        boolean supported = true;
        DocumentUnapprovalPort.Eligibility unsupported = null;
        try { adapter.requireSupported(id); }
        catch (ApiException failure) {
            if (failure.getCode() != ErrorCode.BUSINESS && failure.getCode() != ErrorCode.CONFLICT) throw failure;
            supported = false;
            unsupported = DocumentUnapprovalPort.Eligibility.blocked("SOURCE_WITHDRAWAL_REQUIRED",failure.getMessage(),null);
        }
        String action = "BLOCKED";
        DocumentUnapprovalPort.Eligibility check;
        if (successor != null || !links.isEmpty()) {
            check = DocumentUnapprovalPort.Eligibility.blocked("ALREADY_UNAPPROVED", "原单据已经反审，不会再次减量或生成另一份草稿", null);
            if (successor != null) action = "OPEN_SUCCESSOR";
        } else if (!permitted) {
            check = DocumentUnapprovalPort.Eligibility.blocked("REVERSE_PERMISSION_REQUIRED", "当前身份没有该单据的反审权限", null);
        } else if (stored[1] != null) {
            check = DocumentUnapprovalPort.Eligibility.blocked("IMPORTED_HISTORY", "历史原始单据仅供核对，不能通用反审生成新业务", null);
        } else if (state == 0) {
            check = DocumentUnapprovalPort.Eligibility.blocked("DRAFT_NOT_APPROVED", "草稿尚未审核，无需反审；请按草稿编辑或取消流程办理", null);
        } else if (state != 1) {
            check = DocumentUnapprovalPort.Eligibility.blocked("NOT_APPROVED_GENERATION", "只有当前已审核的业务代次可以反审", null);
        } else if (unsupported != null) {
            check = unsupported; action = "FOLLOW_SOURCE_WITHDRAWAL";
        } else {
            check = adapter.eligibility(id);
            if (check.eligible()) action = "UNAPPROVE_TO_DRAFT";
        }
        check = new DocumentUnapprovalPort.Eligibility(check.eligible(),check.reasons().stream()
                .map(reason -> new DocumentUnapprovalPort.Reason(reason.code(),reason.message().replace("红冲","反审"))).toList(),
                check.relatedDocuments(),check.factsSnapshot());
        String snapshot = com.uten.imp.common.util.CanonicalFingerprint.sha256(
                List.of("family=" + family, "id=" + id, "actor=" + user.getId(), "header=" + stored[2],
                        "supported=" + supported, "permitted=" + permitted, "action=" + action,
                        "successor=" + successor, "domain=" + check.factsSnapshot(), "reasons=" + check.reasons(),
                        "related=" + check.relatedDocuments()));
        return new UnapprovalCapability(supported, permitted, check.eligible(), action, check.reasons(),
                check.relatedDocuments(), snapshot, successor);
    }

    public record UnapprovalCapability(boolean supported, boolean permitted, boolean eligible, String nextAction,
            List<DocumentUnapprovalPort.Reason> reasons, List<DocumentUnapprovalPort.RelatedDocument> relatedDocuments,
            String factsSnapshot, UUID successorId) { }

    @Transactional(readOnly=true, noRollbackFor=ApiException.class)
    public Map<String,Object> lineage(String family, UUID id) {
        var adapter = requireFamily(family);
        requireAuthorities(adapter, "view");
        adapter.detail(id);
        var rows = em.createNativeQuery("""
                SELECT original_id,draft_id,draft_bill_no,reason,created_at
                FROM document_unapprovals WHERE family=:family AND (original_id=:id OR draft_id=:id)
                ORDER BY created_at
                """).setParameter("family",family).setParameter("id",id).getResultList();
        var links = new ArrayList<Map<String,Object>>();
        for (Object value : rows) {
            Object[] row = (Object[])value;
            UUID related=id.equals(row[0])?(UUID)row[1]:(UUID)row[0];
            try { adapter.detail(related); }
            catch(ApiException failure) {
                if(failure.getCode()==ErrorCode.NOT_FOUND || failure.getCode()==ErrorCode.FORBIDDEN)continue;
                throw failure;
            }
            links.add(Map.of("originalId",row[0],"draftId",row[1],"draftBillNo",row[2],
                    "reason",row[3],"createdAt",row[4].toString()));
        }
        return Map.of("links",links,"attachmentPolicy","ORIGINAL_RETAINED");
    }

    private void copyHeader(DocumentUnapprovalPort.TableSnapshot spec, UUID originalId, UUID draftId, String billNo) {
        var columns = new ArrayList<>(List.of("id","bill_no","status","created_at","updated_at","created_by","updated_by"));
        columns.addAll(spec.inputs());
        var values = new ArrayList<>(List.of(":draft",":number","0","CURRENT_TIMESTAMP","CURRENT_TIMESTAMP","source.created_by",":actor"));
        values.addAll(spec.inputs().stream().map(column -> column.equals("create_request_hash")
                ? "COALESCE(source.create_request_hash,encode(digest(CAST(:original AS text),'sha256'),'hex'))" : "source."+column).toList());
        // Fresh command identity is mandatory for modern money documents; the canonical hash remains the same.
        if (spec.inputs().contains("create_request_hash")) {
            columns.add("create_idempotency_key"); values.add("'unapprove:' || CAST(:draft AS text)");
        }
        int changed = em.createNativeQuery("INSERT INTO "+spec.table()+" ("+String.join(",",columns)+") SELECT "
                +String.join(",",values)+" FROM "+spec.table()+" source WHERE source.id=:original AND source.status=-1 AND NOT source.is_deleted")
                .setParameter("draft",draftId).setParameter("number",billNo).setParameter("actor",currentUser.requireId())
                .setParameter("original",originalId).executeUpdate();
        if (changed != 1) throw new ApiException(ErrorCode.CONFLICT,"反审来源已变化，本次未生成草稿");
    }

    private Map<UUID,UUID> copyLines(DocumentUnapprovalPort adapter, UUID originalId, UUID draftId, String billNo) {
        var spec=adapter.lines();
        Map<UUID,UUID> result = new LinkedHashMap<>();
        List<?> ids=em.createNativeQuery("SELECT id FROM "+spec.table()+" WHERE "+spec.parentColumn()+"=:original"
                +(spec.softDeleted()?" AND NOT is_deleted":"")+" ORDER BY line_no,id")
                .setParameter("original",originalId).getResultList();
        for(Object id:ids) {
            UUID newId=UUID.randomUUID(); result.put((UUID)id,newId);
            var columns=new ArrayList<>(List.of("id",spec.parentColumn(),"created_at","updated_at","created_by","updated_by"));
            var values=new ArrayList<>(List.of(":newLine",":draft","CURRENT_TIMESTAMP","CURRENT_TIMESTAMP","source.created_by",":actor"));
            columns.addAll(spec.inputs()); values.addAll(spec.inputs().stream().map(column->"source."+column).toList());
            columns.addAll(adapter.generatedLineInputs().keySet()); values.addAll(adapter.generatedLineInputs().values());
            if(spec.lineBillNumber()) { columns.add("bill_no"); values.add(":number"); }
            var query=em.createNativeQuery("INSERT INTO "+spec.table()+" ("+String.join(",",columns)+") SELECT "
                    +String.join(",",values)+" FROM "+spec.table()+" source WHERE source.id=:oldLine")
                    .setParameter("newLine",newId).setParameter("draft",draftId).setParameter("actor",currentUser.requireId())
                    .setParameter("oldLine",id);
            if(spec.lineBillNumber()) query.setParameter("number",billNo);
            if(query.executeUpdate()!=1) throw new ApiException(ErrorCode.CONFLICT,"反审明细已变化，本次未生成草稿");
        }
        return result;
    }

    private void copySources(DocumentUnapprovalPort.SourceSnapshot spec, Map<UUID,UUID> lines) {
        for(var line:lines.entrySet()) {
            var columns=new ArrayList<>(List.of(spec.lineColumn(),"created_by")); columns.addAll(spec.inputs());
            var values=new ArrayList<>(List.of(":newLine","source.created_by"));
            values.addAll(spec.inputs().stream().map(column->"source."+column).toList());
            em.createNativeQuery("INSERT INTO "+spec.table()+" ("+String.join(",",columns)+") SELECT "
                    +String.join(",",values)+" FROM "+spec.table()+" source WHERE source."+spec.lineColumn()+"=:oldLine")
                    .setParameter("newLine",line.getValue()).setParameter("oldLine",line.getKey()).executeUpdate();
        }
    }

    private String lineMapJson(Map<UUID,UUID> lines) {
        try { return json.writeValueAsString(lines); }
        catch(com.fasterxml.jackson.core.JsonProcessingException failure) { throw new IllegalStateException(failure); }
    }
    private Object successorDetail(DocumentUnapprovalPort adapter,UUID draftId,UUID originalId) {
        Object detail=adapter.detail(draftId);
        if(!(detail instanceof com.uten.imp.common.history.DocumentHistoryMetadata metadata))
            throw new IllegalStateException("Unapproval family must return retained document metadata");
        metadata.setUnapprovalOriginalId(originalId);
        return detail;
    }
    private void copyPlatformFields(UUID originalId,UUID draftId,Map<UUID,UUID> lines) {
        Map<UUID,UUID> records=new LinkedHashMap<>(lines);
        records.put(originalId,draftId);
        com.uten.imp.common.platformcolumns.PlatformRecordFieldForks.copy(em,currentUser.requireId(),records);
    }
    private DocumentUnapprovalPort requireFamily(String family) {
        var adapter=families.get(family);
        if(adapter==null) throw new ApiException(ErrorCode.BUSINESS,"该业务节点需使用原业务专用撤回流程，不能通用反审");
        return adapter;
    }
    private void requireAuthorities(DocumentUnapprovalPort adapter,String... actions) {
        var user=currentUser.get().orElseThrow(()->new ApiException(ErrorCode.FORBIDDEN,"请先登录"));
        if(user.isSuperAdmin()) return;
        for(String action:actions) if(user.getAuthorities().stream().noneMatch(authority->authority.getAuthority().equals(adapter.permission()+":"+action)))
            throw new ApiException(ErrorCode.FORBIDDEN,"反审需要该单据的查看和反审权限；编辑仍按原归属和编辑权限办理");
    }
    private void requireWriteIdentity() {
        var user=currentUser.get().orElseThrow(()->new ApiException(ErrorCode.FORBIDDEN));
        if(user.isVisitor() || user.getEmployeeId()==null || user.isMustChangePassword() || !user.isAccountNonLocked() || user.getImpersonatedBy()!=null)
            throw new ApiException(ErrorCode.FORBIDDEN,"当前身份不能执行反审，请核对登录身份和账号状态");
    }
    public record UnapproveRequest(
            @jakarta.validation.constraints.NotBlank @jakarta.validation.constraints.Size(min=8,max=128) String idempotencyKey,
            @jakarta.validation.constraints.NotBlank @jakarta.validation.constraints.Size(max=500) String reason,
            @jakarta.validation.constraints.Pattern(regexp="[a-f0-9]{64}") String expectedSnapshot) {
        public UnapproveRequest(String idempotencyKey,String reason){this(idempotencyKey,reason,null);}
    }
}
