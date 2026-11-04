package com.uten.imp.features.applications;

import com.fasterxml.jackson.core.type.TypeReference;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.application.policy.DepartmentApprovalScope;
import com.uten.imp.common.time.BusinessTime;
import com.uten.imp.common.web.*;
import com.uten.imp.features.applications.BusinessApplicationController.*;
import com.uten.imp.security.*;
import lombok.RequiredArgsConstructor;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.core.namedparam.NamedParameterJdbcTemplate;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;
import java.math.BigDecimal;
import java.time.*;
import java.util.*;
import static com.uten.imp.features.applications.BusinessApplicationWorkflow.*;

@Service
@RequiredArgsConstructor
public class BusinessApplicationService {
    private static final String LINK_PREPAYMENT="application:prepayment:link_finance";
    private final JdbcTemplate jdbc;
    private final ObjectMapper json;
    private final SecurityContextCurrentUser current;
    private final TxSessionVars tx;
    private final DepartmentApprovalScope departments;
    private final com.uten.imp.application.port.AttachmentEvidencePort evidence;
    private final com.uten.imp.application.port.FinanceApplicationReferencePort financeReferences;
    private final com.uten.imp.application.port.EmployeeApplicationNoticePort notices;
    private final com.uten.imp.application.port.ApprovalCandidateDirectoryPort approvalCandidates;
    private final com.uten.imp.application.port.MasterReferenceValidationPort masterReferences;
    private final com.uten.imp.common.docnumber.DocNumberService documentNumbers;
    private final com.uten.imp.application.policy.DepartmentApprovalRouting departmentRouting;
    @org.springframework.beans.factory.annotation.Autowired(required=false)
    private com.uten.imp.application.port.TaskAudiencePort taskAudience;
    private NamedParameterJdbcTemplate named(){return new NamedParameterJdbcTemplate(jdbc);}
    private AuthUser user(){var u=current.get().orElseThrow(()->new ApiException(ErrorCode.UNAUTHORIZED));
        if(u.isVisitor()||u.getEmployeeId()==null)throw new ApiException(ErrorCode.FORBIDDEN);
        if(!departments.isCurrent(u))throw new ApiException(ErrorCode.FORBIDDEN);
        return u;}
    private AuthUser writer(){var u=user();if(u.getImpersonatedBy()!=null)throw new ApiException(ErrorCode.IMPERSONATION_READ_ONLY);tx.bind();return u;}
    private boolean has(AuthUser u,String p){return u.getPermissions().contains(p);}
    private void require(AuthUser u,String p){if(!has(u,p))throw new ApiException(ErrorCode.FORBIDDEN);}
    private boolean apply(AuthUser u,String kind){return has(u,"application:apply")||has(u,applyPermission(kind));}
    private void requireApply(AuthUser u,String kind){if(!apply(u,kind))throw new ApiException(ErrorCode.FORBIDDEN);}
    private boolean participant(Map<String,Object> row,AuthUser u){return jdbc.queryForList("SELECT DISTINCT stage FROM business_application_events WHERE application_id=? AND actor_id=? AND action IN('APPROVED','REJECTED','RECEIVED','PAID','PAYMENT_CANCELLED','FINANCE_LINKED')",String.class,id(row),u.getEmployeeId()).stream().anyMatch(stage->has(u,"application:view")||(has(u,permission(stage))&&(!"FINANCE_POSTING".equals(stage)||has(u,"finance_payment:view"))));}
    private boolean participatedThisRound(Map<String,Object> row,AuthUser u){return jdbc.queryForObject("SELECT EXISTS(SELECT 1 FROM business_application_events WHERE application_id=? AND actor_id=? AND round=? AND action IN('APPROVED','RECEIVED'))",Boolean.class,id(row),u.getEmployeeId(),row.get("round"));}
    private boolean canCancelPayment(Map<String,Object> row,AuthUser u){return u.getImpersonatedBy()==null&&has(u,"application:pay")&&!owns(row,u)&&"PAID".equals(row.get("status"))&&Boolean.TRUE.equals(jdbc.queryForObject("SELECT COALESCE((SELECT actor_id=? FROM business_application_events WHERE application_id=? AND action='PAID' ORDER BY occurred_at DESC,id DESC LIMIT 1),false)",Boolean.class,u.getEmployeeId(),id(row)));}
    private boolean owns(Map<String,Object> row,AuthUser u){return u.getEmployeeId().equals(row.get("applicant_id"));}
    private boolean postingPending(Map<String,Object> row){return "PREPAYMENT".equals(row.get("kind"))&&"PAID".equals(row.get("status"))&&row.get("finance_document_id")==null;}
    private static String postingPendingSql(String a){return "("+a+".kind='PREPAYMENT' AND "+a+".status='PAID' AND "+a+".finance_document_id IS NULL)";}
    private boolean postingRole(AuthUser u){return has(u,"application:pay")||(has(u,LINK_PREPAYMENT)&&has(u,"finance_payment:view"));}
    private boolean canFollowPosting(Map<String,Object> row,AuthUser u){return postingPending(row)&&!owns(row,u)&&postingRole(u);}
    private boolean canLinkFinanceBase(Map<String,Object> row,AuthUser u){return postingPending(row)&&!owns(row,u)&&u.getImpersonatedBy()==null&&has(u,LINK_PREPAYMENT)&&has(u,"finance_payment:view")&&has(u,"attachment:view")&&has(u,"attachment:download");}
    private boolean canLinkFinance(Map<String,Object> row,AuthUser u){
        if(!canLinkFinanceBase(row,u))return false;
        var proof=financeReferences.prepaymentMatchingCondition("a",u);var args=new HashMap<String,Object>(proof.parameters());args.put("applicationId",id(row));
        return Boolean.TRUE.equals(named().queryForObject("SELECT "+proof.sql()+" FROM business_applications a WHERE a.id=:applicationId",args,Boolean.class));
    }
    private UUID id(Map<String,Object> row){return (UUID)row.get("id");}
    private String text(Map<String,Object> row,String key){return Objects.toString(row.get(key),"");}
    private static String routingStaleSql(String a){return "(CASE WHEN "+a+".approval_stage='DEPARTMENT' AND "+a+".status IN('SUBMITTED','REVIEWING') THEN COALESCE(fn_department_approval_snapshot_stale("+a+".applicant_id,"+a+".department_id,"+a+".department_approval_snapshot),true) ELSE false END)";}
    private boolean routingStale(Map<String,Object> row){if(row.containsKey("approval_routing_stale"))return Boolean.TRUE.equals(row.get("approval_routing_stale"));if(!"DEPARTMENT".equals(row.get("approval_stage"))||!Set.of("SUBMITTED","REVIEWING").contains(row.get("status")))return false;return Boolean.TRUE.equals(jdbc.queryForObject("SELECT "+routingStaleSql("a")+" FROM business_applications a WHERE id=?",Boolean.class,id(row)));}
    private String encoded(Object value){try{return json.writeValueAsString(value);}catch(Exception e){throw invalid("申请内容无法保存");}}
    private Map<String,Object> fields(Map<String,Object> row){try{return json.readValue(text(row,"fields"),new TypeReference<LinkedHashMap<String,Object>>(){});}catch(Exception e){throw new ApiException(ErrorCode.CONFLICT,"申请数据无法读取，请联系管理员");}}
    Map<String,Object> row(UUID id,boolean lock){var rows=jdbc.queryForList("SELECT * FROM business_applications WHERE id=?"+(lock?" FOR UPDATE":""),id);if(rows.isEmpty())throw new ApiException(ErrorCode.NOT_FOUND,"申请不存在");return rows.getFirst();}
    private void version(Map<String,Object> row,Long version){if(version==null||version.longValue()!=((Number)row.get("version")).longValue())throw new ApiException(ErrorCode.CONFLICT,"申请已被修改或已处理，请刷新后重新核对");}
    private void editable(Map<String,Object> row,AuthUser u){requireApply(u,text(row,"kind"));if(!owns(row,u)||!Set.of("DRAFT","REJECTED").contains(text(row,"status")))throw new ApiException(ErrorCode.CONFLICT,"当前申请不可修改");}
    private Set<UUID> departmentIds(AuthUser u,String code){var codes=departmentRouting.departmentCodes(u);if(code==null||code.isBlank())return codes.keySet();Set<UUID> ids=new LinkedHashSet<>();codes.forEach((id,v)->{if(code.equals(v))ids.add(id);});return ids;}
    boolean canAct(Map<String,Object> row,AuthUser u){
        String stage=text(row,"approval_stage");
        return u.getImpersonatedBy()==null&&departments.isCurrent(u)&&Set.of("SUBMITTED","REVIEWING","APPROVED").contains(text(row,"status"))&&!stage.isBlank()
            &&has(u,permission(stage))&&!owns(row,u)&&!participatedThisRound(row,u)
            &&(!"DEPARTMENT".equals(stage)||departmentRouting.canReview(u,(UUID)row.get("applicant_id"),(UUID)row.get("department_id"),text(row,"department_approval_snapshot")));
    }
    private boolean canInspectOriginals(Map<String,Object> row,AuthUser u){return evidence.cleanEvidence("BUSINESS_APPLICATION",id(row)).isEmpty()||(has(u,"attachment:view")&&has(u,"attachment:download"));}
    private boolean paymentPrerequisites(Map<String,Object> row,AuthUser u){return has(u,"attachment:view")&&has(u,"attachment:download")&&
        ("PREPAYMENT".equals(row.get("kind"))||has(u,"finance_payment:view")||(!"SUPPLIER_PAYMENT".equals(row.get("kind"))&&has(u,"finance_expense:view")))&&
        (has(u,"attachment:upload")||!evidence.cleanEvidence("BUSINESS_APPLICATION_PAYMENT",id(row)).isEmpty());}
    void readable(Map<String,Object> row,AuthUser u){if(!(owns(row,u)&&(apply(u,text(row,"kind"))||has(u,"application:view")))&&!canAct(row,u)&&!canFollowPosting(row,u)&&!participant(row,u))throw new ApiException(ErrorCode.NOT_FOUND,"申请不存在");}
    @Transactional(readOnly=true) public Map<String,Object> detail(UUID id){var u=user();var row=row(id,false);readable(row,u);return dto(row,u,true);}
    private Map<String,Object> dto(Map<String,Object> row,AuthUser u,boolean detail){
        var out=new LinkedHashMap<String,Object>();
        Map<String,String> mapping=Map.ofEntries(Map.entry("id","id"),Map.entry("application_no","applicationNo"),Map.entry("kind","kind"),Map.entry("title","title"),Map.entry("status","status"),Map.entry("approval_stage","approvalStage"),Map.entry("applicant_id","applicantId"),Map.entry("applicant_name","applicantName"),Map.entry("department_id","departmentId"),Map.entry("department_name","departmentName"),Map.entry("round","round"),Map.entry("version","version"),Map.entry("reject_reason","rejectReason"),Map.entry("finance_document_id","financeDocumentId"));
        mapping.forEach((key,value)->out.put(value,row.get(key)));out.put("amount",((BigDecimal)row.get("amount")).toPlainString());
        out.put("fields",fields(row));out.put("createdAt",instant(row.get("created_at")));out.put("submittedAt",instant(row.get("submitted_at")));
        out.put("approvalStageLabel",label(text(row,"kind"),text(row,"approval_stage")));boolean action=canAct(row,u);
        out.put("canApprove",action&&REVIEW_STAGES.contains(text(row,"approval_stage"))&&canInspectOriginals(row,u));
        out.put("canReject",action);
        out.put("canReceive",action&&"FINANCE_RECEIVE".equals(text(row,"approval_stage")));
        out.put("canPay",action&&"PAYMENT".equals(text(row,"approval_stage"))&&paymentPrerequisites(row,u));
        out.put("canCancelPayment",canCancelPayment(row,u));
        out.put("approvalRoutingStale",routingStale(row));
        out.put("postingStatus",postingPending(row)?"PENDING":row.get("finance_document_id")!=null?"POSTED":"NOT_REQUIRED");
        out.put("canLinkFinance",canLinkFinance(row,u));
        if(detail){out.put("events",jdbc.queryForList("SELECT action,actor_name AS \"actorName\",stage,remark,round,occurred_at FROM business_application_events WHERE application_id=? ORDER BY occurred_at,id",id(row)).stream().map(e->{e.put("occurredAt",instant(e.remove("occurred_at")));return e;}).toList());
            out.put("submissions",jdbc.queryForList("SELECT round,snapshot::text snapshot,created_at FROM business_application_submissions WHERE application_id=? ORDER BY round",id(row)).stream().map(e->{e.put("createdAt",instant(e.remove("created_at")));try{e.put("snapshot",json.readValue(e.get("snapshot").toString(),Map.class));}catch(Exception ignored){throw new ApiException(ErrorCode.CONFLICT,"历史提交无法读取");}return e;}).toList());}
        return out;
    }
    private String instant(Object value){return value==null?null:value instanceof java.sql.Timestamp t?t.toInstant().toString():value instanceof OffsetDateTime t?t.toInstant().toString():value.toString();}
    private void validate(Input in){validate(in,null);}
    private UUID retainedSupplier(Map<String,Object> row){return (UUID)row.get("supplier_id");}
    private void validate(Input in,UUID retainedSupplier){
        if(in==null||in.id()==null||in.kind()==null||!KINDS.containsKey(in.kind()))throw invalid("请选择申请类别");
        if(in.title()==null||in.title().isBlank()||in.title().trim().length()>200)throw invalid("申请标题为必填，最多200字");
        amount(in.amount(),"TRAVEL".equals(in.kind()));
        if(in.fields()==null||in.fields().size()>30||encoded(in.fields()).length()>20000)throw invalid("申请内容过多");
        for(var e:in.fields().entrySet()){
            if(!Set.of("reason","destination","startDate","endDate","transport","companions","payee","paymentUnit","supplierId","supplierName","remark").contains(e.getKey()))throw invalid("申请含不支持的字段，请刷新核对");
            if(e.getValue()!=null&&!(e.getValue() instanceof String))throw invalid("申请字段必须是文字");}
        if(!Set.of("SUPPLIER_PAYMENT","PREPAYMENT").contains(in.kind())&&List.of("supplierId","supplierName").stream().anyMatch(key->!Objects.toString(in.fields().get(key),"").isBlank()))throw invalid("当前申请类别不接受供应商主档字段");
        required(in.fields(),"reason","申请事由");
        if("TRAVEL".equals(in.kind())){
            required(in.fields(),"destination","出差地点");LocalDate start=date(in.fields(),"startDate"),end=date(in.fields(),"endDate");
            if(end.isBefore(start))throw invalid("返回日期不能早于出发日期");
        }else if(!Set.of("SUPPLIER_PAYMENT","PREPAYMENT").contains(in.kind())){required(in.fields(),"payee","收款人或收款单位");}
        if(Set.of("SUPPLIER_PAYMENT","PREPAYMENT").contains(in.kind())){
            if("SUPPLIER_PAYMENT".equals(in.kind()))required(in.fields(),"paymentUnit","付款单位");
            UUID supplier=uuid(in.fields(),"supplierId");
            if(supplier.equals(retainedSupplier))masterReferences.requireExistingSupplier(supplier);
            else masterReferences.requireSelectableSupplier(supplier);
        }
    }
    private String required(Map<String,Object> fields,String key,String label){String value=Objects.toString(fields.get(key),"").trim();if(value.isEmpty()||value.length()>3000)throw invalid(label+"为必填，最多3000字");return value;}
    private LocalDate date(Map<String,Object> fields,String key){try{return LocalDate.parse(Objects.toString(fields.get(key),""));}catch(Exception e){throw invalid("请填写有效日期");}}
    private UUID uuid(Map<String,Object> fields,String key){try{return UUID.fromString(Objects.toString(fields.get(key),""));}catch(Exception e){throw invalid("请选择有效的关联资料");}}
    private Map<String,Object> storedFields(Input in,Map<String,Object> existing){
        var fields=new LinkedHashMap<String,Object>(in.fields());
        if(Set.of("SUPPLIER_PAYMENT","PREPAYMENT").contains(in.kind())){
            UUID supplier=uuid(fields,"supplierId");String name=existing!=null&&supplier.equals(existing.get("supplier_id"))?Objects.toString(fields(existing).get("supplierName"),""):"";
            if(name.isBlank())name=jdbc.queryForObject("SELECT name FROM suppliers WHERE id=?",String.class,supplier);
            if(name==null||name.isBlank())throw invalid("供应商名称无法读取，请刷新后重试");
            fields.put("supplierName",name);fields.put("payee",name);
        }
        return fields;
    }
    private boolean sameFields(String kind,Map<String,Object> before,Map<String,Object> request){
        var left=new LinkedHashMap<>(before);var right=new LinkedHashMap<>(request);
        if(Set.of("SUPPLIER_PAYMENT","PREPAYMENT").contains(kind)){for(String key:List.of("supplierName","payee")){left.remove(key);right.remove(key);}}
        return left.equals(right);
    }
    private void append(Map<String,Object> row,String action,AuthUser u,String stage,String remark){String name=jdbc.queryForObject("SELECT full_name FROM employees WHERE id=?",String.class,u.getEmployeeId());jdbc.update("INSERT INTO business_application_events(application_id,action,actor_id,actor_name,stage,remark,round) VALUES(?,?,?,?,?,?,?)",id(row),action,u.getEmployeeId(),name,stage,remark,row.get("round"));}
    @Transactional public Map<String,Object> create(Input in){var u=writer();validate(in);requireApply(u,in.kind());
        jdbc.queryForObject("SELECT pg_advisory_xact_lock(hashtextextended(?,0))",Object.class,"application-create:"+in.id());
        var existing=jdbc.queryForList("SELECT * FROM business_applications WHERE id=?",in.id());
        if(!existing.isEmpty()){var old=existing.getFirst();if(!owns(old,u)||!text(old,"kind").equals(in.kind())||!text(old,"title").equals(in.title().trim())||((BigDecimal)old.get("amount")).compareTo(amount(in.amount(),"TRAVEL".equals(in.kind())))!=0||!sameFields(in.kind(),fields(old),in.fields()))throw new ApiException(ErrorCode.CONFLICT,"原申请编号已存在，请核对原记录");return dto(old,u,true);}
        var employee=jdbc.queryForList("SELECT e.full_name name,e.department_id,d.name department_name FROM employees e JOIN departments d ON d.id=e.department_id WHERE e.id=? AND NOT e.is_deleted AND NOT d.is_deleted FOR SHARE OF e,d",u.getEmployeeId());
        if(employee.isEmpty())throw invalid("请先配置申请人的有效部门");var e=employee.getFirst();
        String number=documentNumbers.nextNumber(com.uten.imp.common.docnumber.DocNumberPrefix.BUSINESS_APPLICATION);
        jdbc.update("INSERT INTO business_applications(id,application_no,kind,title,amount,fields,supplier_id,applicant_id,applicant_name,department_id,department_name) VALUES(?,?,?,?,?,?::jsonb,?,?,?,?,?)",in.id(),number,in.kind(),in.title().trim(),amount(in.amount(),"TRAVEL".equals(in.kind())),encoded(storedFields(in,null)),Set.of("SUPPLIER_PAYMENT","PREPAYMENT").contains(in.kind())?uuid(in.fields(),"supplierId"):null,u.getEmployeeId(),e.get("name"),e.get("department_id"),e.get("department_name"));
        var row=row(in.id(),false);append(row,"CREATED",u,null,null);return dto(row,u,true);
    }
    @Transactional public Map<String,Object> update(UUID id,Input in){var u=writer();var row=row(id,true);editable(row,u);if(in==null)throw invalid("申请内容不能为空");version(row,in.expectedVersion());validate(in,retainedSupplier(row));
        if(!id.equals(in.id())||!text(row,"kind").equals(in.kind()))throw invalid("申请类别与原记录不一致");
        jdbc.update("UPDATE business_applications SET title=?,amount=?,fields=?::jsonb,supplier_id=?,version=version+1,updated_at=now() WHERE id=?",in.title().trim(),amount(in.amount(),"TRAVEL".equals(in.kind())),encoded(storedFields(in,row)),Set.of("SUPPLIER_PAYMENT","PREPAYMENT").contains(in.kind())?uuid(in.fields(),"supplierId"):null,id);append(row,"EDITED",u,null,null);return dto(row(id,false),u,true);
    }
    @Transactional public Map<String,Object> act(UUID id,String action,Action in){var u=writer();var row=row(id,true);version(row,in==null?null:in.expectedVersion());String stage=text(row,"approval_stage");
        switch(action){
            case "cancel" -> {
                requireApply(u,text(row,"kind"));if(!owns(row,u)||!Set.of("DRAFT","REJECTED").contains(row.get("status")))throw new ApiException(ErrorCode.CONFLICT,"仅本人草稿或待修订申请可以作废；已提交的申请须先撤回");
                jdbc.update("UPDATE business_applications SET status='CANCELLED',approval_stage=NULL,version=version+1,updated_at=now() WHERE id=?",id);append(row,"CANCELLED",u,null,"作废申请；保留申请编号、凭据及全部历史，不释放单号");}
            case "submit" -> {editable(row,u);validate(new Input(id,text(row,"kind"),text(row,"title"),row.get("amount").toString(),fields(row),in.expectedVersion()),retainedSupplier(row));
                if(!"TRAVEL".equals(text(row,"kind"))&&evidence.cleanEvidence("BUSINESS_APPLICATION",id).isEmpty())throw invalid("请先上传相关凭证并等待扫描完成");
                int round=((Number)row.get("round")).intValue()+1;String first=stages(text(row,"kind")).getFirst();
                var applicants=jdbc.queryForList("SELECT e.full_name,e.department_id,d.name department_name FROM employees e JOIN departments d ON d.id=e.department_id WHERE e.id=? AND NOT e.is_deleted AND NOT d.is_deleted FOR SHARE OF e,d",u.getEmployeeId());
                if(applicants.isEmpty())throw invalid("请先配置申请人的有效部门");var applicant=applicants.getFirst();
                String approvalSnapshot="DEPARTMENT".equals(first)?departmentRouting.capture((UUID)row.get("applicant_id"),(UUID)applicant.get("department_id")):null;
                jdbc.update("UPDATE business_applications SET status='SUBMITTED',approval_stage=?,round=?,reject_reason=NULL,applicant_name=?,department_id=?,department_name=?,department_approval_snapshot=?::jsonb,submitted_at=now(),version=version+1,updated_at=now() WHERE id=?",first,round,applicant.get("full_name"),applicant.get("department_id"),applicant.get("department_name"),approvalSnapshot,id);
                row=row(id,false);
                var snapshot=new LinkedHashMap<String,Object>();snapshot.put("kind",row.get("kind"));snapshot.put("title",row.get("title"));snapshot.put("amount",row.get("amount").toString());snapshot.put("fields",fields(row));
                snapshot.put("applicantId",row.get("applicant_id"));snapshot.put("applicantName",row.get("applicant_name"));snapshot.put("departmentId",row.get("department_id"));snapshot.put("departmentName",row.get("department_name"));
                snapshot.put("attachments",evidence.cleanEvidence("BUSINESS_APPLICATION",id).stream().map(a->{Map<String,Object> f=new LinkedHashMap<>();f.put("id",a.id());f.put("sha256",a.sha256());f.put("originalName",a.originalName());return f;}).toList());
                jdbc.update("INSERT INTO business_application_submissions(application_id,round,snapshot) VALUES(?,?,?::jsonb)",id,round,encoded(snapshot));
                row=row(id,false);append(row,"SUBMITTED",u,first,null);notifyNext(row);}
            case "withdraw" -> {requireApply(u,text(row,"kind"));if(!owns(row,u)||!Set.of("SUBMITTED","REVIEWING").contains(text(row,"status")))throw new ApiException(ErrorCode.CONFLICT,"申请当前不可撤回");
                jdbc.update("UPDATE business_applications SET status='DRAFT',approval_stage=NULL,version=version+1,updated_at=now() WHERE id=?",id);append(row,"WITHDRAWN",u,stage,null);}
            case "cancel-payment" -> {
                if(!canCancelPayment(row,u))throw new ApiException(ErrorCode.FORBIDDEN,"仅原付款登记人可撤销登记");
                String reason=in.reason()==null?"":in.reason().trim();if(reason.isBlank()||reason.length()>1000)throw invalid("撤销原因必填，最多1000字");
                var f=fields(row);String original="原财务单 "+text(row,"finance_document_type")+" "+text(row,"finance_document_id")+"；原付款日期 "+f.get("paymentDate")+"；原流水 "+f.get("paymentReference");
                f.remove("paymentDate");f.remove("paymentReference");f.remove("financeDocumentType");
                jdbc.update("UPDATE business_applications SET status='APPROVED',approval_stage='PAYMENT',finance_document_id=NULL,finance_document_type=NULL,fields=?::jsonb,version=version+1,updated_at=now() WHERE id=?",encoded(f),id);
                append(row,"PAYMENT_CANCELLED",u,"PAYMENT",reason+"；"+original+"；仅撤销申请登记，财务账需另行核对");notifyOwner(row,"付款登记已撤销，等待财务核对修正");}
            case "link-finance" -> {
                if(!canLinkFinanceBase(row,u))throw new ApiException(ErrorCode.FORBIDDEN,"当前申请不可关联供应商预付入账");
                var fields=in.fields();if(fields==null||fields.keySet().stream().anyMatch(key->!Set.of("financeDocumentType","financeDocumentId").contains(key)))throw invalid("关联入账只能选择财务记录，不能修改原付款事实");
                if(!"PAYMENT".equals(Objects.toString(fields.get("financeDocumentType"),"PAYMENT")))throw invalid("供应商预付不能关联费用单");
                UUID document=uuid(fields,"financeDocumentId");var facts=fields(row);
                financeReferences.requireApprovedPrepaymentMatch(new com.uten.imp.application.port.FinanceApplicationReferencePort.Reference("PAYMENT",document,(BigDecimal)row.get("amount"),date(facts,"paymentDate"),retainedSupplier(row),u));
                if(Boolean.TRUE.equals(jdbc.queryForObject("SELECT EXISTS(SELECT 1 FROM business_applications WHERE finance_document_type='PAYMENT' AND finance_document_id=? AND id<>?)",Boolean.class,document,id)))throw new ApiException(ErrorCode.CONFLICT,"该财务单已关联其他申请");
                jdbc.update("UPDATE business_applications SET finance_document_id=?,finance_document_type='PAYMENT',version=version+1,updated_at=now() WHERE id=?",document,id);
                append(row,"FINANCE_LINKED",u,"FINANCE_POSTING","关联已审核供应商预付款 "+document+"；保留原实际付款日期和凭证号，未重复扣账");notifyOwner(row,"供应商预付已关联合法财务入账记录");}
            case "approve","reject","receive","pay" -> {
                if(!canAct(row,u))throw new ApiException(ErrorCode.FORBIDDEN,"当前申请不属于你的节点或部门范围，不能自审或同轮重复办理多个节点");
                if("DEPARTMENT".equals(stage))departmentRouting.requireReviewForUpdate(u,(UUID)row.get("applicant_id"),(UUID)row.get("department_id"),text(row,"department_approval_snapshot"));
                if("reject".equals(action)){
                    String reason=in.reason()==null?"":in.reason().trim();if(reason.isBlank()||reason.length()>1000)throw invalid("驳回原因必填，最多1000字");
                    jdbc.update("UPDATE business_applications SET status='REJECTED',approval_stage=NULL,reject_reason=?,version=version+1,updated_at=now() WHERE id=?",reason,id);append(row,"REJECTED",u,stage,reason);notifyOwner(row,"申请被驳回，请查看原因并修订");
                }else if("receive".equals(action)){
                    if(!"FINANCE_RECEIVE".equals(stage))throw invalid("当前节点不是财务接收保管");finish(row,"COMPLETED");append(row,"RECEIVED",u,stage,in.reason());notifyOwner(row,"出差申请已由财务接收保管");
                }else if("pay".equals(action)){
                    if(!"PAYMENT".equals(stage)||!"APPROVED".equals(text(row,"status")))throw invalid("尚未完成审批，不能登记付款");
                    if(!paymentPrerequisites(row,u))throw new ApiException(ErrorCode.FORBIDDEN,"付款登记须具备关联财务单和付款凭据的查看、下载权限，并能提供付款凭据");
                    if("PREPAYMENT".equals(row.get("kind"))){
                        registerPrepaymentPayment(row,in.fields());finish(row,"PAID");
                        append(row,"PAID",u,stage,"供应商预付实际付款已登记；付款日期 "+in.fields().get("paymentDate")+"；凭证号 "+in.fields().get("paymentReference")+"；财务入账待核对，未新建费用或扣减账户");
                        notifyOwner(row,"供应商预付实际付款已登记，待财务入账");
                        for(var candidate:approvalCandidates.candidates(LINK_PREPAYMENT,Set.of("finance_payment:view","attachment:view","attachment:download")))if(!candidate.employeeId().equals(row.get("applicant_id")))notices.pending(candidate.userId(),id,"预付待财务入账");
                    }else{linkFinance(row,u,in.fields());finish(row,"PAID");append(row,"PAID",u,stage,"已核对并关联已审核财务单；未重复过账");notifyOwner(row,"申请付款已登记，可查看对应财务单");}
                }else{
                    if(!REVIEW_STAGES.contains(stage))throw invalid("当前节点需要接收归档或登记付款");
                    if(!canInspectOriginals(row,u))throw new ApiException(ErrorCode.FORBIDDEN,"批准前须有原始凭证查看和下载权限");
                    String next=next(text(row,"kind"),stage);String status="PAYMENT".equals(next)?"APPROVED":"REVIEWING";
                    jdbc.update("UPDATE business_applications SET status=?,approval_stage=?,version=version+1,updated_at=now() WHERE id=?",status,next,id);append(row,"APPROVED",u,stage,in.reason());notifyNext(row(id,false));
                }
            }
            default -> throw invalid("未知申请操作");
        }
        return dto(row(id,false),u,true);
    }
    private void finish(Map<String,Object> row,String status){jdbc.update("UPDATE business_applications SET status=?,approval_stage=NULL,version=version+1,updated_at=now() WHERE id=?",status,id(row));}
    private void registerPrepaymentPayment(Map<String,Object> row,Map<String,Object> input){
        if(input==null||input.keySet().stream().anyMatch(key->!Set.of("paymentDate","paymentReference").contains(key)))throw invalid("供应商预付先登记真实付款，不得借费用单或普通付款单冒充预付入账");
        LocalDate date=date(input,"paymentDate");if(date.isAfter(BusinessTime.today()))throw invalid("实际付款日期不能晚于今天");
        String reference=required(input,"paymentReference","付款凭证号或交易流水号");
        if(evidence.cleanEvidence("BUSINESS_APPLICATION_PAYMENT",id(row)).isEmpty())throw invalid("请先上传银行回单或签收凭据并等待扫描完成");
        var fields=fields(row);fields.put("paymentDate",date.toString());fields.put("paymentReference",reference);
        jdbc.update("UPDATE business_applications SET fields=?::jsonb WHERE id=?",encoded(fields),id(row));
    }
    private void linkFinance(Map<String,Object> row,AuthUser u,Map<String,Object> input){
        if(input==null)throw invalid("请关联已审核财务单并填写实际付款日期");
        String type=Objects.toString(input.get("financeDocumentType"),"EXPENSE");
        if(!Set.of("EXPENSE","PAYMENT").contains(type)||("SUPPLIER_PAYMENT".equals(text(row,"kind"))&&!"PAYMENT".equals(type)))throw invalid("供应商付款须关联采购付款单");
        require(u,"EXPENSE".equals(type)?"finance_expense:view":"finance_payment:view");
        UUID document=uuid(input,"financeDocumentId");LocalDate date=date(input,"paymentDate");
        if(date.isAfter(BusinessTime.today()))throw invalid("实际付款日期不能晚于今天");required(input,"paymentReference","银行流水或现金签收编号");
        if(evidence.cleanEvidence("BUSINESS_APPLICATION_PAYMENT",id(row)).isEmpty())throw invalid("请先上传银行回单或签收凭据并等待扫描完成");
        financeReferences.requireApprovedMatch(new com.uten.imp.application.port.FinanceApplicationReferencePort.Reference(type,document,(BigDecimal)row.get("amount"),date,retainedSupplier(row),u));
        if(Boolean.TRUE.equals(jdbc.queryForObject("SELECT EXISTS(SELECT 1 FROM business_applications WHERE finance_document_type=? AND finance_document_id=? AND id<>?)",Boolean.class,type,document,id(row))))throw new ApiException(ErrorCode.CONFLICT,"该财务单已关联其他申请");
        var fields=fields(row);fields.put("paymentDate",date.toString());fields.put("paymentReference",input.get("paymentReference"));fields.put("financeDocumentType",type);
        jdbc.update("UPDATE business_applications SET finance_document_id=?,finance_document_type=?,fields=?::jsonb WHERE id=?",document,type,encoded(fields),id(row));
    }
    private String activeScope(AuthUser u,Set<String> stages,String code,Map<String,Object> params){
        params.put("actor",u.getEmployeeId());List<String> terms=new ArrayList<>();
        for(String stage:stages)if(has(u,permission(stage))){String term="a.approval_stage='"+stage+"'";if("DEPARTMENT".equals(stage)){term+=" AND "+departmentRouting.sql("a.applicant_id","a.department_id","a.department_approval_snapshot",u);if(code!=null&&!code.isBlank()){var ids=departmentIds(u,code);params.put("departmentIds",ids.isEmpty()?List.of(new UUID(0,0)):ids);term+=" AND a.department_id IN(:departmentIds)";}}terms.add("("+term+")");}
        return "a.status IN('SUBMITTED','REVIEWING','APPROVED') AND a.applicant_id<>:actor AND NOT EXISTS(SELECT 1 FROM business_application_events e WHERE e.application_id=a.id AND e.round=a.round AND e.actor_id=:actor AND e.action IN('APPROVED','RECEIVED')) AND ("+(terms.isEmpty()?"FALSE":String.join(" OR ",terms))+")";
    }
    @Transactional(readOnly=true) public PageResponse<Map<String,Object>> prepaymentFinanceCandidates(UUID id,int page,int size,String keyword){
        var u=user();var row=row(id,false);if(!canLinkFinanceBase(row,u))throw new ApiException(ErrorCode.FORBIDDEN);
        int p=Math.max(1,page),s=Math.clamp(size,1,100);var result=financeReferences.prepaymentCandidates(id,retainedSupplier(row),(BigDecimal)row.get("amount"),date(fields(row),"paymentDate"),u,p,s,keyword);
        return new PageResponse<>(result.items().stream().map(candidate->{Map<String,Object> out=new LinkedHashMap<>();out.put("id",candidate.id());out.put("billNo",candidate.billNo());out.put("billDate",candidate.billDate().toString());out.put("amountLocalText",candidate.amount().toPlainString());out.put("status",1);return out;}).toList(),p,s,result.total(),(int)((result.total()+s-1)/s));
    }
    @Transactional(readOnly=true) public PageResponse<Map<String,Object>> list(String queue,String kind,String status,String stage,String code,int page,int size){
        var u=user();Map<String,Object> params=new HashMap<>();params.put("actor",u.getEmployeeId());String where;
        if("mine".equals(queue)){if(!has(u,"application:view")&&!has(u,"application:apply")&&u.getPermissions().stream().noneMatch(p->p.startsWith("application:apply:")))throw new ApiException(ErrorCode.FORBIDDEN);where="a.applicant_id=:actor";}
        else if("pending".equals(queue))where=activeScope(u,scope(stage),code,params);
        else if("prepayment-posting".equals(queue)){if(!postingRole(u))throw new ApiException(ErrorCode.FORBIDDEN);where=postingPendingSql("a")+" AND a.applicant_id<>:actor";}
        else{var historyStages=new LinkedHashSet<>(scope(stage));if(!has(u,"application:view"))historyStages.removeIf(node->!has(u,permission(node))||("FINANCE_POSTING".equals(node)&&!has(u,"finance_payment:view")));params.put("historyStages",historyStages.isEmpty()?Set.of("NONE"):historyStages);where="EXISTS(SELECT 1 FROM business_application_events e WHERE e.application_id=a.id AND e.actor_id=:actor AND e.action IN('APPROVED','REJECTED','RECEIVED','PAID','PAYMENT_CANCELLED','FINANCE_LINKED') AND e.stage IN(:historyStages))";
            if(code!=null&&!code.isBlank()&&scope(stage).contains("DEPARTMENT")){params.put("historyDepartments",departmentIds(u,code).isEmpty()?List.of(new UUID(0,0)):departmentIds(u,code));where+=" AND (a.department_id IN(:historyDepartments) OR EXISTS(SELECT 1 FROM business_application_events e WHERE e.application_id=a.id AND e.actor_id=:actor AND e.stage<>'DEPARTMENT'))";}}
        if(kind!=null&&!kind.isBlank()){if(!KINDS.containsKey(kind))throw invalid("未知申请类别");where+=" AND a.kind=:kind";params.put("kind",kind);}
        if(status!=null&&!status.isBlank()){
            if("PROCESSING".equals(status))where+=" AND ((a.status IN('SUBMITTED','REVIEWING','APPROVED') AND NOT "+routingStaleSql("a")+") OR "+postingPendingSql("a")+")";
            else if("ACTION_REQUIRED".equals(status))where+=" AND (a.status='REJECTED' OR "+routingStaleSql("a")+")";
            else if("FINISHED".equals(status))where+=" AND a.status IN('PAID','COMPLETED','CANCELLED') AND NOT "+postingPendingSql("a");
            else{if(!Set.of("DRAFT","SUBMITTED","REVIEWING","REJECTED","APPROVED","PAID","COMPLETED","CANCELLED").contains(status))throw invalid("未知申请状态");where+=" AND a.status=:status";params.put("status",status);}}
        int p=Math.max(1,page),s=Math.clamp(size,1,100);params.put("limit",s);params.put("offset",(long)(p-1)*s);
        long total=named().queryForObject("SELECT count(*) FROM business_applications a WHERE "+where,params,Long.class);
        var rows=named().queryForList("SELECT a.*,"+routingStaleSql("a")+" AS approval_routing_stale FROM business_applications a WHERE "+where+" ORDER BY a.created_at DESC,a.id LIMIT :limit OFFSET :offset",params);
        return new PageResponse<>(rows.stream().map(row->dto(row,u,false)).toList(),p,s,total,(int)((total+s-1)/s));
    }
    @Transactional(readOnly=true) public Map<String,Object> counts(){var u=user();if(u.getPermissions().stream().noneMatch(p->p.startsWith("application:")))throw new ApiException(ErrorCode.FORBIDDEN);Map<String,Object> result=new LinkedHashMap<>();
        for(var entry:Map.of("DRAFT","mineDraftCount","REJECTED","mineRejectedCount").entrySet())result.put(entry.getValue(),jdbc.queryForObject("SELECT count(*) FROM business_applications WHERE applicant_id=? AND status=?",Long.class,u.getEmployeeId(),entry.getKey()));
        result.put("mineProcessingCount",jdbc.queryForObject("SELECT count(*) FROM business_applications a WHERE applicant_id=? AND ((status IN('SUBMITTED','REVIEWING','APPROVED') AND NOT "+routingStaleSql("a")+") OR "+postingPendingSql("a")+")",Long.class,u.getEmployeeId()));
        result.put("mineRoutingStaleCount",jdbc.queryForObject("SELECT count(*) FROM business_applications a WHERE applicant_id=? AND "+routingStaleSql("a"),Long.class,u.getEmployeeId()));
        AuthUser participant=taskAudience==null?u:taskAudience.freshTaskSubject(u);
        long postingTotal=0,postingTodo=0;
        if(postingRole(participant)){
            String postingWhere=postingPendingSql("a")+" AND a.applicant_id<>:postingActor";var postingArgs=new HashMap<String,Object>();postingArgs.put("postingActor",participant.getEmployeeId());
            postingTotal=named().queryForObject("SELECT count(*) FROM business_applications a WHERE "+postingWhere,postingArgs,Long.class);
            if(has(participant,LINK_PREPAYMENT)&&has(participant,"finance_payment:view")&&has(participant,"attachment:view")&&has(participant,"attachment:download")){
                var proof=financeReferences.prepaymentMatchingCondition("a",participant);postingArgs.putAll(proof.parameters());
                postingTodo=named().queryForObject("SELECT count(*) FROM business_applications a WHERE "+postingWhere+" AND "+proof.sql(),postingArgs,Long.class);
            }
        }
        result.put("prepaymentPostingTodoCount",postingTodo);result.put("prepaymentPostingInProgressCount",Math.max(0,postingTotal-postingTodo));
        Map<String,Object> params=new HashMap<>();String actionable=activeScope(participant,scope(null),null,params);var rows=named().queryForList("SELECT a.approval_stage,a.kind,a.department_id,count(*) n FROM business_applications a WHERE "+actionable+" GROUP BY a.approval_stage,a.kind,a.department_id",params);Map<String,Long> stages=new HashMap<>();for(var r:rows)stages.merge(r.get("approval_stage").toString(),((Number)r.get("n")).longValue(),Long::sum);
        result.put("pendingCount",stages.values().stream().mapToLong(Long::longValue).sum());result.put("executivePendingCount",stages.getOrDefault("EXECUTIVE",0L));result.put("viceExecutivePendingCount",stages.getOrDefault("VICE_EXECUTIVE",0L));result.put("procurementPendingCount",stages.getOrDefault("PROCUREMENT",0L));result.put("financePendingCount",stages.getOrDefault("FINANCE_INITIAL",0L)+stages.getOrDefault("FINANCE_REVIEW",0L));result.put("financeReceivePendingCount",stages.getOrDefault("FINANCE_RECEIVE",0L));result.put("payableCount",stages.getOrDefault("PAYMENT",0L));
        Map<String,Long> departmentCounts=new LinkedHashMap<>(),departmentScopes=new LinkedHashMap<>();var departmentCodes=has(participant,"application:approve:department")?departmentRouting.departmentCodes(participant):Map.<UUID,String>of();
        for(String code:new LinkedHashSet<>(departmentCodes.values())){departmentScopes.put(code,1L);departmentCounts.put(code,0L);}
        Map<String,Map<String,Long>> scopes=new LinkedHashMap<>();Map<String,Long> pendingKinds=new LinkedHashMap<>();
        for(var r:rows){String node=r.get("approval_stage").toString(),kind=r.get("kind").toString(),code=departmentCodes.get((UUID)r.get("department_id"));long n=((Number)r.get("n")).longValue();pendingKinds.merge(kind,n,Long::sum);
            if("DEPARTMENT".equals(node)&&code!=null){departmentCounts.merge(code,n,Long::sum);scopes.computeIfAbsent(code,k->new LinkedHashMap<>()).merge(kind,n,Long::sum);}
            if(scope("FINANCE").contains(node))scopes.computeIfAbsent("FINANCE",k->new LinkedHashMap<>()).merge(kind,n,Long::sum);
            if(scope("MANAGEMENT").contains(node))scopes.computeIfAbsent("MANAGEMENT",k->new LinkedHashMap<>()).merge(kind,n,Long::sum);
            if("PROCUREMENT".equals(node)||("DEPARTMENT".equals(node)&&"DEPT_PMC".equals(code)))scopes.computeIfAbsent("PMC",k->new LinkedHashMap<>()).merge(kind,n,Long::sum);
        }
        result.put("pendingByScopeKind",scopes);result.put("pendingByKind",pendingKinds);
        result.put("departmentPendingByCode",departmentCounts);result.put("departmentScopeByCode",departmentScopes);
        String mineStatus="CASE WHEN "+routingStaleSql("a")+" THEN 'ROUTING_STALE' WHEN "+postingPendingSql("a")+" THEN 'POSTING_PENDING' ELSE status END";
        Map<String,Map<String,Long>> kinds=new LinkedHashMap<>();for(var r:jdbc.queryForList("SELECT kind,"+mineStatus+" status,count(*) n FROM business_applications a WHERE applicant_id=? GROUP BY kind,"+mineStatus,u.getEmployeeId()))kinds.computeIfAbsent(r.get("kind").toString(),k->new LinkedHashMap<>()).put(r.get("status").toString(),((Number)r.get("n")).longValue());result.put("mineByKind",kinds);return result;
    }
    private void notifyOwner(Map<String,Object> row,String message){notices.result((UUID)row.get("applicant_id"),id(row),message);}
    private void notifyNext(Map<String,Object> row){String required=permission(text(row,"approval_stage"));
        Set<String> prerequisites=new LinkedHashSet<>();String stage=text(row,"approval_stage");
        if((REVIEW_STAGES.contains(stage)&&!evidence.cleanEvidence("BUSINESS_APPLICATION",id(row)).isEmpty())||"PAYMENT".equals(stage))prerequisites.addAll(Set.of("attachment:view","attachment:download"));
        List<com.uten.imp.application.port.ApprovalCandidateDirectoryPort.Candidate> directory;
        if("PAYMENT".equals(stage)){
            if(evidence.cleanEvidence("BUSINESS_APPLICATION_PAYMENT",id(row)).isEmpty())prerequisites.add("attachment:upload");
            var paymentPrerequisites=new LinkedHashSet<>(prerequisites);if(!"PREPAYMENT".equals(row.get("kind")))paymentPrerequisites.add("finance_payment:view");
            var byUser=new LinkedHashMap<UUID,com.uten.imp.application.port.ApprovalCandidateDirectoryPort.Candidate>();
            approvalCandidates.candidates(required,paymentPrerequisites).forEach(c->byUser.put(c.userId(),c));
            if(!Set.of("SUPPLIER_PAYMENT","PREPAYMENT").contains(row.get("kind"))){var expensePrerequisites=new LinkedHashSet<>(prerequisites);expensePrerequisites.add("finance_expense:view");approvalCandidates.candidates(required,expensePrerequisites).forEach(c->byUser.put(c.userId(),c));}
            directory=List.copyOf(byUser.values());
        }else directory=approvalCandidates.candidates(required,prerequisites);
        var eligible=directory.stream().filter(candidate->canAct(row,new AuthUser(candidate.userId(),candidate.employeeId(),"approval-candidate",Set.of(required),false,true,false))).toList();
        if(eligible.isEmpty())throw invalid("请先配置【"+label(text(row,"kind"),text(row,"approval_stage"))+"】的有效办理人员；须与申请人和本轮已办理人员分离");
        for(var candidate:eligible)notices.pending(candidate.userId(),id(row),label(text(row,"kind"),text(row,"approval_stage")));
    }
}
