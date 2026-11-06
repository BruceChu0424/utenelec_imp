package com.uten.imp.features.finance.application;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.application.port.*;
import com.uten.imp.common.docnumber.*;
import com.uten.imp.common.storage.ImmutableDocumentStore;
import com.uten.imp.common.time.BusinessTime;
import com.uten.imp.common.util.FinancialExactAmount;
import com.uten.imp.common.web.*;
import com.uten.imp.features.common.taskclaim.TaskClaimService;
import com.uten.imp.security.*;
import lombok.RequiredArgsConstructor;
import org.springframework.beans.factory.ObjectProvider;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.*;
import java.math.BigDecimal;
import java.time.*;
import java.util.*;
import java.util.function.Supplier;
import static com.uten.imp.features.finance.application.FinanceApplicationCatalog.*;
import static com.uten.imp.features.finance.application.FinanceApplicationContracts.*;

/** Original six-stage paths over native sources and immutable decisions. Approval never moves money. */
@Service @RequiredArgsConstructor
public class FinanceApplicationService {
    static final String CLAIM="FINANCE_APPLICATION_REVIEW";
    private final JdbcTemplate db;private final ObjectMapper json;private final FinanceApplicationRoles roles;
    private final SecurityContextCurrentUser current;private final TxSessionVars tx;private final DocNumberService numbers;
    private final FinanceApplicationExpensePort expenses;private final ObjectProvider<FinancePayrollPaymentPort> payroll;
    private final TaskClaimService claims;private final FinanceApplicationClaimTargetLocks targetLocks;
    private final FinanceApplicationNoticePort notices;private final ObjectProvider<FinanceApplicationExecutionPort> executions;
    private final FinanceApplicationReadAccess reads;private final FinanceApplicationLegacyPolicy legacy;

    @Transactional(readOnly=true)
    public Map<String,Object> catalog(){var user=roles.staff();if(!canEnter(user))throw new ApiException(ErrorCode.FORBIDDEN);List<Map<String,Object>> types=new ArrayList<>();for(Kind kind:Kind.values()){types.add(Map.of("key",kind.name(),"label",title(kind),"steps",steps(kind)));}return Map.of("types",types,"enabled",roles.enabled(),"payrollReady",payroll.getIfAvailable()!=null,"canConfigure",roles.has(user,FinanceApplicationPermissions.SETTINGS));}
    @Transactional(readOnly=true)
    public Map<String,Object> intake(){var user=roles.staff();if(!roles.has(user,"finance_expense:create")&&!roles.has(user,"finance_payment:create")&&!roles.has(user,"expense:apply")&&!roles.has(user,"payroll:generate")&&!roles.has(user,FinanceApplicationPermissions.APPLY))throw new ApiException(ErrorCode.FORBIDDEN);return Map.of("enabled",roles.enabled(),"canApply",roles.has(user,FinanceApplicationPermissions.APPLY));}

    @Transactional
    public Map<String,Object> save(DraftInput input){
        var user=roles.staff();if(input==null||input.id()==null||input.requestId()==null)throw invalid("请保留原申请和请求编号");Kind kind=kind(input.kind());requireApply(user,kind);tx.bind();
        return operation(input.id(),input.requestId(),"SAVE",input,()->{
            var old=optional(input.id(),false);if(old!=null){old=lockSourceAndRow(input.id());owner(old,user);editable(old);legacy.requireEditableOriginal(old);version(old,input.expectedVersion());if(!kind.name().equals(old.get("kind"))||!Objects.equals(input.sourceId(),old.get("source_id")))throw conflict("申请类型和已关联原始来源不能替换，请保留原申请历史并另建明确申请");}else {legacy.requireCreation(kind);if(input.expectedVersion()!=-1)throw conflict("原申请已变化");}
            var payload=payload(input,kind);String title=text(input.title(),200,"申请事由");if(title.isBlank())throw invalid("请填写申请事由");String remark=text(input.remark(),2000,"备注");LocalDate date=date(input.requestedDate(),"申请日期");
            UUID owner=user.getEmployeeId();var person=db.queryForMap("SELECT full_name,department_id FROM employees WHERE id=fn_canonical_employee_identity(?) AND NOT is_deleted AND status<>'resigned'",owner);UUID department=(UUID)person.get("department_id");
            String sourceKind=switch(kind){case TRAVEL_APPLICATION->"TRAVEL_PLAN";case REIMBURSEMENT,TRAVEL_REIMBURSEMENT->"EXPENSE_CLAIM";case PAYROLL_PAYMENT->"PAYROLL_BATCH";default->"PAYMENT_INTENT";};
            if(Set.of("EXPENSE_CLAIM","PAYROLL_BATCH").contains(sourceKind)&&input.sourceId()==null)throw invalid("请选择明确原始来源");
            if(sourceKind.equals("EXPENSE_CLAIM")){var source=expenses.source(input.sourceId(),true);if(!same(source.applicantId(),owner)||!Set.of("DRAFT","REJECTED").contains(source.status()))throw invalid("只能关联本人的原报销草稿/退回单，历史已批单不能重审");}
            if(sourceKind.equals("EXPENSE_CLAIM")){var linked=db.queryForList("SELECT application_id FROM finance_expense_application_links WHERE claim_id=? AND application_id IS NOT NULL",UUID.class,input.sourceId());if(!linked.isEmpty()&&!input.id().equals(linked.getFirst()))throw conflict("这张原报销单已形成另一申请，请回原申请继续办理");}
            if(sourceKind.equals("PAYROLL_BATCH")){var bridge=payroll.getIfAvailable();if(bridge==null)throw conflict("原工资事实桥尚未准备好");var source=bridge.source(input.sourceId(),true);if(!same(source.generatedBy(),owner)&&!roles.has(user,"payroll:view:all"))throw new ApiException(ErrorCode.FORBIDDEN,"原工资批次不在本人制表或明确全员薪资查看范围内");}
            if(kind==Kind.TRAVEL_REIMBURSEMENT){var travel=row(input.travelApplicationId(),false);if(!"TRAVEL_APPLICATION".equals(travel.get("kind"))||!"ARCHIVED".equals(travel.get("status"))||!same(owner,(UUID)travel.get("applicant_id")))throw invalid("请选择本人已批准并由财务保管的出差申请");}
            if(old==null)db.update("""
                    INSERT INTO finance_applications(id,application_no,kind,source_kind,source_id,applicant_id,applicant_name_snapshot,department_id,
                        department_name_snapshot,title,remark,travel_application_id,requested_date,requested_payload,request_fingerprint,created_by,updated_by)
                    VALUES(?,?,?,?,?,?,?,?,COALESCE((SELECT name FROM departments WHERE id=?),''),?,?,?,?,?::jsonb,?,?,?)
                    """,input.id(),numbers.nextNumber(DocNumberPrefix.FIN_APPLICATION),kind.name(),sourceKind,input.sourceId(),owner,person.get("full_name"),department,department,title,remark,input.travelApplicationId(),date,encode(payload),digest(payload),current.requireId(),current.requireId());
            else db.update("UPDATE finance_applications SET source_id=?,title=?,remark=?,travel_application_id=?,requested_date=?,requested_payload=?::jsonb,request_fingerprint=?,row_version=row_version+1,updated_at=now(),updated_by=? WHERE id=?",input.sourceId(),title,remark,input.travelApplicationId(),date,encode(payload),digest(payload),current.requireId(),input.id());
            if(sourceKind.equals("EXPENSE_CLAIM"))db.update("INSERT INTO finance_expense_application_links(claim_id,kind,travel_application_id,application_id,created_by) VALUES(?,?,?,?,?) ON CONFLICT(claim_id) DO UPDATE SET application_id=excluded.application_id,kind=excluded.kind,travel_application_id=excluded.travel_application_id",input.sourceId(),kind.name(),input.travelApplicationId(),input.id(),current.requireId());
            return detail(input.id());
        });
    }

    @Transactional
    public Map<String,Object> submit(UUID id,Action input){var user=roles.staff();tx.bind();return operation(id,input.requestId(),"SUBMIT",input,()->{
        var app=lockSourceAndRow(id);owner(app,user);requireApply(user,kind(app.get("kind").toString()));editable(app);legacy.requireNewRound(app);version(app,input.expectedVersion());if(!roles.enabled())throw conflict("请先完成原岗位配置并启用流程，当前草稿已保留");
        if("EXPENSE_CLAIM".equals(app.get("source_kind"))){UUID source=(UUID)app.get("source_id");NativeApplicationContext.run(new NativeApplicationContext.Value(id,source,NativeApplicationContext.Action.SUBMIT),()->expenses.submit(source));}
        submitLocked(app,input.sourceFingerprint());return detail(id);
    });}

    /** Called after the native reimbursement submission has frozen its own invoices and amount. */
    @Transactional
    public boolean submittedExpense(UUID claim){if(NativeApplicationContext.matches(claim,NativeApplicationContext.Action.SUBMIT))return true;
        expenses.source(claim,true);var linked=db.queryForList("SELECT application_id,kind,travel_application_id FROM finance_expense_application_links WHERE claim_id=?",claim);
        if(linked.isEmpty()||linked.getFirst().get("application_id")==null)return false; // New employee submissions keep their native approval authority.
        UUID id=(UUID)linked.getFirst().get("application_id");
        if(legacy.mapped(id))return false;
        throw conflict("这张原报销尚未按当前流程审阅接续，请保留原稿并先完成审阅；本次未提交旧审批");
    }

    private void submitLocked(Map<String,Object> app,String expected){
        legacy.requireNewRound(app);var source=source(app);if(expected!=null&&!Objects.equals(expected,source.fingerprint))throw conflict("原申请内容已变化，请刷新核对");
        UUID id=(UUID)app.get("id");Kind kind=kind(app.get("kind").toString());int round=((Number)app.get("submission_round")).intValue()+1;
        List<List<Assignment>> path=new ArrayList<>();
        for(var step:steps(kind)){var assigned=roles.resolve(step.role(),(UUID)app.get("department_id"),(UUID)app.get("applicant_id"),Set.of());if(assigned.isEmpty())throw invalid(step.label()+"尚未明确对应可办理且不自批的人员，请在流程设置/组织架构中维护");if(!step.action().equals("ARCHIVE"))path.add(assigned);
            db.update("INSERT INTO finance_application_nodes(application_id,submission_round,step_no,role_key,label_snapshot,action,assignees) VALUES(?,?,?,?,?,?,?::jsonb)",id,round,step.ordinal(),step.role().name(),step.label(),step.action(),encode(assigned));
        }
        if(!distinctPath(path,0,new HashSet<>()))throw invalid("当前部门/财务/总经办岗位无法形成不同人员的完整审批链，请明确配置可代办人员");
        db.update("""
                UPDATE finance_applications SET previous_source_snapshot=source_snapshot,source_snapshot=?::jsonb,source_fingerprint=?,amount_original=?,currency_id=?,
                    status='SUBMITTED',submission_round=?,current_step=1,submitted_at=now(),approved_at=NULL,approved_by=NULL,approved_name_snapshot=NULL,
                    payroll_instruction=NULL,payroll_instruction_fingerprint=NULL,row_version=row_version+1,updated_at=now(),updated_by=? WHERE id=?
                """,encode(source.facts),source.fingerprint,source.amount,source.currency,round,current.requireId(),id);
        event(id,round,"SUBMITTED",null,Map.of("sourceFingerprint",source.fingerprint));noticeCurrent(row(id,false));
    }
    private static boolean distinctPath(List<List<Assignment>> path,int index,Set<UUID> used){if(index==path.size())return true;for(var person:path.get(index)){if(used.add(person.employeeId())){if(distinctPath(path,index+1,used))return true;used.remove(person.employeeId());}}return false;}

    @Transactional
    public Map<String,Object> review(UUID id,Action input,boolean approved){roles.live(FinanceApplicationPermissions.REVIEW);tx.bind();return operation(id,input.requestId(),approved?"APPROVE":"REJECT",input,()->{
        var app=lockSourceAndRow(id);version(app,input.expectedVersion());legacy.requireRound(app);requirePending(app);claims.requireActiveClaimByMe(CLAIM,id.toString(),input.expectedClaimId());fresh(app,input.sourceFingerprint());
        int round=((Number)app.get("submission_round")).intValue(),step=((Number)app.get("current_step")).intValue();var node=db.queryForMap("SELECT * FROM finance_application_nodes WHERE application_id=? AND submission_round=? AND step_no=? FOR UPDATE",id,round,step);String reason=text(input.reason(),1000,"处理意见");
        var actor=roles.staff();String name=actorName();if(!approved&&reason.strip().isEmpty())throw invalid("请填写退回原因");
        if(approved&&"PAYROLL_PAYMENT".equals(app.get("kind"))&&"FINANCE_REVIEW_2".equals(node.get("role_key"))&&app.get("payroll_instruction_fingerprint")==null)throw conflict("请先核对并保存原工资会计准备及其全部来源问题");
        String status=approved?("ARCHIVE".equals(node.get("action"))?"ARCHIVED":"APPROVED"):"REJECTED";
        db.update("UPDATE finance_application_nodes SET status=?,decided_by=?,decided_name_snapshot=?,decided_at=now(),reason=? WHERE application_id=? AND submission_round=? AND step_no=?",status,actor.getEmployeeId(),name,reason,id,round,step);
        notices.resolve(id,approved?"STEP_COMPLETED":"REJECTED");
        if(!approved){if("EXPENSE_CLAIM".equals(app.get("source_kind")))NativeApplicationContext.run(new NativeApplicationContext.Value(id,(UUID)app.get("source_id"),NativeApplicationContext.Action.DECIDE),()->expenses.decideFromApplication((UUID)app.get("source_id"),false,reason));
            db.update("UPDATE finance_applications SET status='REJECTED',row_version=row_version+1,updated_at=now(),updated_by=? WHERE id=?",current.requireId(),id);event(id,round,"REJECTED",step,Map.of("reason",reason));notices.returned(id,title(kind(app.get("kind").toString())),reason,userId((UUID)app.get("applicant_id")));
        }else if("ARCHIVED".equals(status)){db.update("UPDATE finance_applications SET status='ARCHIVED',approved_at=now(),approved_by=?,approved_name_snapshot=?,row_version=row_version+1,updated_at=now(),updated_by=? WHERE id=?",actor.getEmployeeId(),name,current.requireId(),id);event(id,round,"ARCHIVED",step,Map.of());
        }else if(step==steps(kind(app.get("kind").toString())).size()){
            if("EXPENSE_CLAIM".equals(app.get("source_kind")))NativeApplicationContext.run(new NativeApplicationContext.Value(id,(UUID)app.get("source_id"),NativeApplicationContext.Action.DECIDE),()->expenses.decideFromApplication((UUID)app.get("source_id"),true,null));
            db.update("UPDATE finance_applications SET status='APPROVED',approved_at=now(),approved_by=?,approved_name_snapshot=?,row_version=row_version+1,updated_at=now(),updated_by=? WHERE id=?",actor.getEmployeeId(),name,current.requireId(),id);event(id,round,"APPROVED_TO_PAY",step,Map.of());var approvedRow=row(id,false);notices.payment(id,title(kind(app.get("kind").toString())),roles.paymentRecipients(approvedRow));
        }else{db.update("UPDATE finance_applications SET status='REVIEWING',current_step=current_step+1,row_version=row_version+1,updated_at=now(),updated_by=? WHERE id=?",current.requireId(),id);event(id,round,"STEP_APPROVED",step,Map.of("reason",reason));noticeCurrent(row(id,false));}
        claims.releaseAfterBusinessResolution(CLAIM,id.toString());return detail(id);
    });}

    @Transactional
    public Map<String,Object> withdraw(UUID id,Action input){var actor=roles.staff();tx.bind();return operation(id,input.requestId(),"WITHDRAW",input,()->{var app=lockSourceAndRow(id);owner(app,actor);version(app,input.expectedVersion());legacy.requireRound(app);requirePending(app);
        if("EXPENSE_CLAIM".equals(app.get("source_kind")))NativeApplicationContext.run(new NativeApplicationContext.Value(id,(UUID)app.get("source_id"),NativeApplicationContext.Action.WITHDRAW),()->expenses.withdraw((UUID)app.get("source_id")));
        db.update("UPDATE finance_application_nodes SET status='WITHDRAWN' WHERE application_id=? AND submission_round=? AND status='PENDING'",id,app.get("submission_round"));db.update("UPDATE finance_applications SET status='DRAFT',current_step=NULL,row_version=row_version+1,updated_at=now(),updated_by=? WHERE id=?",current.requireId(),id);event(id,((Number)app.get("submission_round")).intValue(),"WITHDRAWN",null,Map.of());notices.resolve(id,"WITHDRAWN");claims.releaseAfterBusinessResolution(CLAIM,id.toString());return detail(id);});}
    @Transactional
    public void withdrawnExpense(UUID claim){var ids=db.queryForList("SELECT application_id FROM finance_expense_application_links WHERE claim_id=? AND application_id IS NOT NULL",UUID.class,claim);if(ids.isEmpty())return;UUID id=ids.getFirst();var app=row(id,true);if(!Set.of("SUBMITTED","REVIEWING").contains(app.get("status")))return;legacy.requireRound(app);owner(app,roles.staff());db.update("UPDATE finance_application_nodes SET status='WITHDRAWN' WHERE application_id=? AND submission_round=? AND status='PENDING'",id,app.get("submission_round"));db.update("UPDATE finance_applications SET status='DRAFT',current_step=NULL,row_version=row_version+1,updated_at=now(),updated_by=? WHERE id=?",current.requireId(),id);event(id,((Number)app.get("submission_round")).intValue(),"WITHDRAWN",null,Map.of());notices.resolve(id,"WITHDRAWN");claims.releaseAfterBusinessResolution(CLAIM,id.toString());}

    @Transactional(readOnly=true)
    public Map<String,Object> detail(UUID id){var app=row(id,false);var actor=roles.staff();readable(app,actor);var actions=actions(app,actor);var out=new LinkedHashMap<String,Object>(app);for(String key:List.of("requested_payload","source_snapshot","previous_source_snapshot","payroll_instruction"))if(out.get(key)!=null)out.put(key,decode(out.get(key).toString()));
        if(out.get("amount_original") instanceof BigDecimal amount)out.put("amount_original",amount.toPlainString());
        out.put("kindLabel",title(kind(app.get("kind").toString())));out.put("nodes",db.queryForList("SELECT submission_round,step_no,role_key,label_snapshot,action,assignees::text,status,decided_by,decided_name_snapshot,decided_at,reason FROM finance_application_nodes WHERE application_id=? ORDER BY submission_round,step_no",id));
        out.put("events",db.queryForList("SELECT event_type,submission_round,step_no,actor_name_snapshot,detail::text,occurred_at FROM finance_application_events WHERE application_id=? ORDER BY occurred_at,id",id));out.put("executions",db.queryForList("SELECT id,submission_round,doc_type,doc_id,state,result::text,paid_name_snapshot,paid_at,confirmed_name_snapshot,confirmed_at,reversed_name_snapshot,reversed_at FROM finance_application_executions WHERE application_id=? ORDER BY paid_at,id",id));
        if("EXPENSE_CLAIM".equals(app.get("source_kind")))try{out.put("expenseClaim",expenses.detail((UUID)app.get("source_id")));}catch(ApiException denied){if(denied.getCode()!=ErrorCode.FORBIDDEN&&denied.getCode()!=ErrorCode.NOT_FOUND)throw denied;out.put("expenseClaimUnavailable",true);}
        // Current draft facts belong to the existing edit audience. Read-only
        // history keeps its already-authorized frozen source, even when payment
        // reversal has correctly removed access to the mutable native claim.
        if(Boolean.TRUE.equals(actions.get("edit"))){var draft=source(app);out.put("currentDraftSource",draft.facts);out.put("currentDraftSourceFingerprint",draft.fingerprint);out.put("currentDraftAmountOriginal",draft.amount==null?null:draft.amount.toPlainString());}
        var requested=decode(app.get("requested_payload").toString());if(requested.get("supplierId")!=null){var refs=db.queryForList("SELECT id,code,name FROM suppliers WHERE id=?",UUID.fromString(requested.get("supplierId").toString()));if(!refs.isEmpty())out.put("supplierReference",refs.getFirst());}
        if(app.get("travel_application_id")!=null){var refs=db.queryForList("SELECT id,application_no AS code,title AS name FROM finance_applications WHERE id=?",app.get("travel_application_id"));if(!refs.isEmpty())out.put("travelReference",refs.getFirst());}
        out.put("actorEmployeeId",actor.getEmployeeId());
        out.put("actions",actions);
        return out;
    }
    @Transactional(readOnly=true) public Map<String,Object> receipt(UUID id,UUID request){roles.staff();var receipts=db.queryForList("SELECT operation,result::text FROM finance_application_operations WHERE request_id=? AND application_id=? AND actor_id=?",request,id,current.requireId());if(receipts.isEmpty()){readable(row(id,false),roles.staff());return Map.of("found",false);}var receipt=receipts.getFirst();if(!"ASSIGN".equals(receipt.get("operation"))){readable(row(id,false),roles.staff());}return Map.of("found",true,"result",decode(receipt.get("result").toString()));}
    private Map<String,Boolean> actions(Map<String,Object> app,AuthUser actor){
        String status=app.get("status").toString();boolean own=same((UUID)app.get("applicant_id"),actor.getEmployeeId()),pending=Set.of("SUBMITTED","REVIEWING").contains(status),editable=Set.of("DRAFT","REJECTED","REVERSED").contains(status);
        List<Map<String,Object>> nodes=pending?db.queryForList("SELECT role_key,action FROM finance_application_nodes n WHERE application_id=? AND submission_round=? AND step_no=? AND status='PENDING' AND EXISTS(SELECT 1 FROM jsonb_array_elements(n.assignees) p WHERE fn_canonical_employee_identity((p->>'employeeId')::uuid)=fn_canonical_employee_identity(?)) AND (action='ARCHIVE' OR (fn_canonical_employee_identity(?)<>fn_canonical_employee_identity(?) AND NOT EXISTS(SELECT 1 FROM finance_application_nodes p WHERE p.application_id=n.application_id AND p.submission_round=n.submission_round AND p.status='APPROVED' AND fn_canonical_employee_identity(p.decided_by)=fn_canonical_employee_identity(?))))",app.get("id"),app.get("submission_round"),app.get("current_step"),actor.getEmployeeId(),actor.getEmployeeId(),app.get("applicant_id"),actor.getEmployeeId()):List.of();
        boolean allowed=legacy.allowed((UUID)app.get("id")),mapped=legacy.mapped((UUID)app.get("id"));boolean view=roles.has(actor,FinanceApplicationPermissions.VIEW),canEdit=own&&editable&&!mapped&&canApply(actor,kind(app.get("kind").toString()));
        boolean review=allowed&&view&&!nodes.isEmpty()&&roles.has(actor,FinanceApplicationPermissions.REVIEW),payroll="PAYROLL_BATCH".equals(app.get("source_kind")),canPay=allowed&&legacy.uninvolvedPayer(app,actor.getEmployeeId())&&view&&roles.has(actor,FinanceApplicationPermissions.EXECUTE)&&!own&&!same((UUID)app.get("approved_by"),actor.getEmployeeId())&&nativeExecutionAllowed(app,actor);
        Map<String,Boolean> result=new LinkedHashMap<>();result.put("edit",canEdit);result.put("continue",canEdit&&!legacy.payroll(app));result.put("submit",canEdit&&legacy.payroll(app)&&roles.enabled());result.put("withdraw",allowed&&own&&pending);result.put("approve",review);result.put("reject",review&&!"ARCHIVE".equals(nodes.getFirst().get("action")));result.put("assign",allowed&&pending&&roles.has(actor,FinanceApplicationPermissions.SETTINGS));result.put("preparePayroll",review&&payroll&&"FINANCE_REVIEW_2".equals(nodes.getFirst().get("role_key")));result.put("verifyInvoice",review&&"EXPENSE_CLAIM".equals(app.get("source_kind"))&&Set.of("FINANCE_REVIEW_1","FINANCE_REVIEW_2").contains(nodes.getFirst().get("role_key")));
        result.put("execute",status.equals("APPROVED")&&canPay&&!"TRAVEL_APPLICATION".equals(app.get("kind")));result.put("confirm",allowed&&view&&status.equals("EXECUTED")&&roles.has(actor,FinanceApplicationPermissions.CONFIRM));result.put("unconfirm",allowed&&view&&status.equals("CONFIRMED")&&!payroll&&roles.has(actor,FinanceApplicationPermissions.CONFIRM));result.put("reverse",allowed&&view&&(status.equals("EXECUTED")||payroll&&status.equals("CONFIRMED"))&&roles.has(actor,FinanceApplicationPermissions.REVERSE));return result;
    }
    private boolean nativeExecutionAllowed(Map<String,Object> app,AuthUser actor){
        return switch(app.get("source_kind").toString()){
            case "EXPENSE_CLAIM"->roles.has(actor,"expense:pay");
            case "PAYROLL_BATCH"->true;
            case "PAYMENT_INTENT"->{String nature=Objects.toString(decode(app.get("requested_payload").toString()).get("paymentNature"),"");String prefix=nature.equals("GENERAL_EXPENSE")?"finance_expense:":"finance_payment:";yield roles.has(actor,prefix+"create")&&roles.has(actor,prefix+"approve");}
            default->false;
        };
    }
    @Transactional public Map<String,Object> execute(UUID id,Execute input){var bridge=executions.getIfAvailable();if(bridge==null)throw conflict("原付款执行桥尚未准备好");return bridge.execute(id,input);}
    @Transactional public Map<String,Object> confirm(UUID id,Action input){var bridge=executions.getIfAvailable();if(bridge==null)throw conflict("原付款确认桥尚未准备好");return bridge.confirm(id,input);}
    @Transactional public Map<String,Object> unconfirm(UUID id,Action input){return executions.getObject().unconfirm(id,input);}
    @Transactional public Map<String,Object> reverse(UUID id,Action input){var bridge=executions.getIfAvailable();if(bridge==null)throw conflict("原付款反审桥尚未准备好");return bridge.reverse(id,input);}

    @Transactional(readOnly=true)
    public Map<String,Object> list(String queue,String search,int page,int size){
        var actor=roles.staff();if(!canEnter(actor))throw new ApiException(ErrorCode.FORBIDDEN);page=Math.max(1,page);size=Math.max(1,Math.min(100,size));
        if(!Set.of("mine","pending","payment","history").contains(queue))throw invalid("申请分类不存在");
        boolean operational=roles.has(actor,FinanceApplicationPermissions.EXECUTE)||roles.has(actor,FinanceApplicationPermissions.CONFIRM)||roles.has(actor,FinanceApplicationPermissions.REVERSE);
        var readScope=reads.predicate("a",actor);String scope=readScope.sql();
        String filter=switch(queue){case "mine"->" AND a.status IN('DRAFT','SUBMITTED','REVIEWING','REJECTED','REVERSED','APPROVED','EXECUTED') AND fn_canonical_employee_identity(a.applicant_id)=fn_canonical_employee_identity(?)";case "pending"->" AND a.status IN('SUBMITTED','REVIEWING') AND EXISTS(SELECT 1 FROM finance_application_nodes n CROSS JOIN LATERAL jsonb_array_elements(n.assignees) p WHERE n.application_id=a.id AND n.submission_round=a.submission_round AND n.step_no=a.current_step AND n.status='PENDING' AND fn_canonical_employee_identity((p->>'employeeId')::uuid)=fn_canonical_employee_identity(?))";case "payment"->" AND a.status IN('APPROVED','EXECUTED') AND ?";default->" AND a.status IN('ARCHIVED','CONFIRMED') AND ?";};
        List<Object> args=new ArrayList<>(readScope.arguments());args.add(queue.equals("mine")||queue.equals("pending")?actor.getEmployeeId():queue.equals("payment")?operational:true);
        String term=Objects.toString(search,"").strip();if(term.length()>200)throw invalid("查询内容过长");if(!term.isEmpty()){filter+=" AND (position(lower(?) in lower(a.application_no))>0 OR position(lower(?) in lower(a.title))>0 OR position(lower(?) in lower(a.applicant_name_snapshot))>0)";args.addAll(List.of(term,term,term));}
        String where=" FROM finance_applications a WHERE "+scope+filter;Long total=db.queryForObject("SELECT count(*)"+where,Long.class,args.toArray());
        args.add(size);args.add((page-1)*size);var rows=db.queryForList("SELECT a.id,a.application_no,a.kind,a.applicant_name_snapshot,a.department_name_snapshot,a.title,a.requested_date,a.amount_original::text,a.currency_id,a.status,a.current_step,a.row_version,a.created_at,(SELECT label_snapshot FROM finance_application_nodes n WHERE n.application_id=a.id AND n.submission_round=a.submission_round AND n.step_no=a.current_step) AS current_label"+where+" ORDER BY a.created_at DESC,a.id DESC LIMIT ? OFFSET ?",args.toArray());for(var row:rows)row.put("kindLabel",title(kind(row.get("kind").toString())));
        return Map.of("rows",rows,"total",total,"page",page,"size",size);
    }

    @Transactional(readOnly=true) @com.uten.imp.security.BusinessTaskRead
    public Map<String,Long> counts(){var actor=roles.staff();if(!canEnter(actor))throw new ApiException(ErrorCode.FORBIDDEN);var p=new HashMap<String,Object>();p.put("actor",actor.getEmployeeId());p.put("view",roles.has(actor,FinanceApplicationPermissions.VIEW));p.put("review",roles.has(actor,FinanceApplicationPermissions.REVIEW));p.put("execute",roles.has(actor,FinanceApplicationPermissions.EXECUTE));p.put("confirm",roles.has(actor,FinanceApplicationPermissions.CONFIRM));p.put("apply",roles.has(actor,FinanceApplicationPermissions.APPLY));p.put("expense",roles.has(actor,"expense:apply"));p.put("payroll",roles.has(actor,"payroll:generate"));p.put("expensePay",roles.has(actor,"expense:pay"));p.put("expenseExecute",roles.has(actor,"finance_expense:create")&&roles.has(actor,"finance_expense:approve"));p.put("paymentExecute",roles.has(actor,"finance_payment:create")&&roles.has(actor,"finance_payment:approve"));p.put("expenseConfirm",roles.has(actor,"finance_expense:gl_confirm"));p.put("paymentConfirm",roles.has(actor,"finance_payment:view"));
        var value=new org.springframework.jdbc.core.namedparam.NamedParameterJdbcTemplate(db).queryForMap("""
            WITH responsibilities AS(SELECT a.*,
                fn_canonical_employee_identity(a.applicant_id)=fn_canonical_employee_identity(:actor) AS own,
                ((a.kind='PAYROLL_PAYMENT' AND :payroll) OR (a.kind='TRAVEL_APPLICATION' AND (:apply OR :expense)) OR (a.kind IN('PAYMENT_APPLICATION','PREPAYMENT_APPLICATION') AND :apply)) AS can_apply,
                (:view AND :review AND EXISTS(SELECT 1 FROM finance_application_nodes n WHERE n.application_id=a.id AND n.submission_round=a.submission_round AND n.step_no=a.current_step AND n.status='PENDING'
                  AND EXISTS(SELECT 1 FROM jsonb_array_elements(n.assignees) person WHERE fn_canonical_employee_identity((person->>'employeeId')::uuid)=fn_canonical_employee_identity(:actor))
                  AND (n.action='ARCHIVE' OR (fn_canonical_employee_identity(a.applicant_id)<>fn_canonical_employee_identity(:actor) AND NOT EXISTS(SELECT 1 FROM finance_application_nodes previous WHERE previous.application_id=a.id AND previous.submission_round=a.submission_round AND previous.status='APPROVED' AND fn_canonical_employee_identity(previous.decided_by)=fn_canonical_employee_identity(:actor)))))) AS review_now,
                (:view AND :execute AND fn_canonical_employee_identity(a.applicant_id)<>fn_canonical_employee_identity(:actor) AND fn_canonical_employee_identity(a.approved_by)<>fn_canonical_employee_identity(:actor)
                  AND CASE a.source_kind WHEN 'EXPENSE_CLAIM' THEN :expensePay WHEN 'PAYROLL_BATCH' THEN true WHEN 'PAYMENT_INTENT' THEN CASE WHEN a.requested_payload->>'paymentNature'='GENERAL_EXPENSE' THEN :expenseExecute ELSE :paymentExecute END ELSE false END) AS execute_now,
                (:view AND :confirm AND CASE a.source_kind WHEN 'EXPENSE_CLAIM' THEN :expenseConfirm WHEN 'PAYROLL_BATCH' THEN true ELSE CASE WHEN a.native_doc_type='EXPENSE' THEN :expenseConfirm ELSE :paymentConfirm END END) AS confirm_now
              FROM finance_applications a)
            SELECT count(*) FILTER(WHERE (own AND can_apply AND status IN('DRAFT','REJECTED','REVERSED')) OR (status IN('SUBMITTED','REVIEWING') AND review_now) OR (status='APPROVED' AND execute_now) OR (status='EXECUTED' AND confirm_now)) AS todo,
              count(*) FILTER(WHERE own AND can_apply AND status IN('SUBMITTED','REVIEWING','APPROVED','EXECUTED') AND NOT review_now AND NOT COALESCE(execute_now,false) AND NOT confirm_now) AS ongoing
            FROM responsibilities
            """,p);return Map.of("todoCount",((Number)value.get("todo")).longValue(),"processingCount",((Number)value.get("ongoing")).longValue());
    }

    @Transactional
    public Map<String,Object> preparePayroll(UUID id,PayrollPreparation input){roles.live(FinanceApplicationPermissions.REVIEW);tx.bind();return operation(id,input.requestId(),"PREPARE_PAYROLL",input,()->{
        var app=lockSourceAndRow(id);version(app,input.expectedVersion());legacy.requireRound(app);fresh(app,input.sourceFingerprint());claims.requireActiveClaimByMe(CLAIM,id.toString(),input.expectedClaimId());
        if(!"PAYROLL_BATCH".equals(app.get("source_kind")))throw invalid("这不是原工资付款申请");var bridge=payroll.getIfAvailable();if(bridge==null)throw conflict("原工资事实桥尚未准备好");
        var prepared=bridge.prepare(id,(UUID)app.get("source_id"),input.sourceFingerprint(),input.instruction());
        if(prepared.ready()){db.update("UPDATE finance_applications SET payroll_instruction=?::jsonb,payroll_instruction_fingerprint=?,row_version=row_version+1,updated_at=now(),updated_by=? WHERE id=?",encode(input.instruction()),prepared.instructionFingerprint(),current.requireId(),id);event(id,((Number)app.get("submission_round")).intValue(),"PAYROLL_PREPARED",((Number)app.get("current_step")).intValue(),Map.of("instructionFingerprint",prepared.instructionFingerprint()));}
        else db.update("UPDATE finance_applications SET payroll_instruction=NULL,payroll_instruction_fingerprint=NULL,row_version=row_version+1,updated_at=now(),updated_by=? WHERE id=?",current.requireId(),id);
        var result=new LinkedHashMap<>(detail(id));result.put("preparation",prepared);return result;
    });}

    @Transactional public Map<String,Object> verifyExpenseInvoice(UUID id,InvoiceVerification input){roles.live(FinanceApplicationPermissions.REVIEW);tx.bind();return operation(id,input.requestId(),"VERIFY_INVOICE",input,()->{
        var app=lockSourceAndRow(id);version(app,input.expectedVersion());legacy.requireRound(app);fresh(app,input.sourceFingerprint());claims.requireActiveClaimByMe(CLAIM,id.toString(),input.expectedClaimId());if(!"EXPENSE_CLAIM".equals(app.get("source_kind")))throw invalid("这不是原报销申请");UUID source=(UUID)app.get("source_id");
        NativeApplicationContext.run(new NativeApplicationContext.Value(id,source,NativeApplicationContext.Action.VERIFY),()->expenses.verifyInvoice(source,input.invoiceId(),input.nativeVersion(),input.result(),input.remark()));event(id,((Number)app.get("submission_round")).intValue(),"INVOICE_VERIFIED",((Number)app.get("current_step")).intValue(),Map.of("invoiceId",input.invoiceId(),"result",input.result(),"remark",input.remark()));return detail(id);
    });}

    @Transactional
    public Map<String,Object> assign(UUID id,Assign input){roles.require(roles.staff(),FinanceApplicationPermissions.SETTINGS);tx.bind();return operation(id,input.requestId(),"ASSIGN",input,()->{
        var app=lockSourceAndRow(id);version(app,input.expectedVersion());legacy.requireRound(app);requirePending(app);if(text(input.reason(),1000,"改派原因").strip().length()<4)throw invalid("请填写明确改派原因");if(input.employeeIds()==null||input.employeeIds().isEmpty()||input.employeeIds().size()>8)throw invalid("请明确选择1至8名当前节点人员");
        var prior=new HashSet<>(db.queryForList("SELECT decided_by FROM finance_application_nodes WHERE application_id=? AND submission_round=? AND status='APPROVED'",UUID.class,id,app.get("submission_round")));List<Assignment> values=new ArrayList<>();for(UUID person:input.employeeIds()){var assigned=roles.eligible(person,true);if(same(person,(UUID)app.get("applicant_id"))||prior.stream().anyMatch(x->same(x,person)))throw invalid("当前节点不能改派给申请人或已审核人员");if(values.stream().noneMatch(x->same(x.employeeId(),assigned.employeeId())))values.add(assigned);}
        claims.requireNoActiveClaimByOther(CLAIM,id.toString());db.update("UPDATE finance_application_nodes SET assignees=?::jsonb WHERE application_id=? AND submission_round=? AND step_no=? AND status='PENDING'",encode(values),id,app.get("submission_round"),app.get("current_step"));db.update("UPDATE finance_applications SET row_version=row_version+1,updated_at=now(),updated_by=? WHERE id=?",current.requireId(),id);event(id,((Number)app.get("submission_round")).intValue(),"REASSIGNED",((Number)app.get("current_step")).intValue(),Map.of("reason",input.reason(),"assignees",values));notices.resolve(id,"REASSIGNED");noticeCurrent(row(id,false));claims.releaseAfterBusinessResolution(CLAIM,id.toString());return Map.of("id",id,"reassigned",true);
    });}

    record Facts(BigDecimal amount,UUID currency,String fingerprint,Map<String,Object> facts) { }
    Facts source(Map<String,Object> app){
        String kind=app.get("source_kind").toString();
        if(kind.equals("EXPENSE_CLAIM")){var value=expenses.source((UUID)app.get("source_id"),false);return new Facts(value.amount(),value.currencyId(),value.fingerprint(),value.facts());}
        if(kind.equals("PAYROLL_BATCH")){var bridge=payroll.getIfAvailable();if(bridge==null)throw conflict("原工资事实桥尚未准备好");var value=bridge.source((UUID)app.get("source_id"),false);Map<String,Object> facts=json.convertValue(value,new com.fasterxml.jackson.core.type.TypeReference<Map<String,Object>>(){});return new Facts(value.netIncome(),value.currencyId(),value.fingerprint(),facts);}
        var payload=decode(app.get("requested_payload").toString());var facts=new LinkedHashMap<String,Object>(payload);BigDecimal amount=null;UUID currency=null;
        if(kind.equals("PAYMENT_INTENT")){
            currency=UUID.fromString(payload.get("currencyId").toString());amount=BigDecimal.ZERO;
            for(Object raw:(List<?>)payload.get("lines")){var line=(Map<?,?>)raw;amount=amount.add(FinancialExactAmount.require(new BigDecimal(line.get("amountOriginal").toString()),"申请原币金额"));}
            amount=FinancialExactAmount.require(amount,"申请合计");
            if("SUPPLIER_AP".equals(payload.get("paymentNature")))facts.put("originalPayables",paymentFacts(payload,currency));
        }
        return new Facts(amount,currency,digest(facts),facts);
    }
    private List<Map<String,Object>> paymentFacts(Map<String,Object> payload,UUID currency){
        UUID supplier=UUID.fromString(payload.get("supplierId").toString());List<Map<?,?>> requested=new ArrayList<>();for(Object raw:(List<?>)payload.get("lines"))requested.add((Map<?,?>)raw);
        List<UUID> ids=requested.stream().map(r->UUID.fromString(r.get("appliedLedgerId").toString())).sorted().toList();
        if(ids.stream().distinct().count()!=ids.size())throw invalid("同一原应付项不能重复列入付款申请，请核对原行");
        var rows=new org.springframework.jdbc.core.namedparam.NamedParameterJdbcTemplate(db).queryForList("SELECT id,bill_no,bill_date,supplier_id,currency_id,direction,open_item_kind,status,is_deleted,amount_balance_original::text AS remaining_original,amount_balance::text AS remaining_local FROM ar_ap_ledger WHERE id IN(:ids) ORDER BY id",Map.of("ids",ids));
        if(rows.size()!=ids.size())throw conflict("原应付来源缺失，请核对原行，不生成虚拟余额");
        for(var row:rows){if(!supplier.equals(row.get("supplier_id"))||!currency.equals(row.get("currency_id"))||!"AP".equals(row.get("direction"))||!"PAYABLE".equals(row.get("open_item_kind"))||((Number)row.get("status")).intValue()!=1||Boolean.TRUE.equals(row.get("is_deleted"))||row.get("remaining_original")==null||row.get("remaining_local")==null)throw conflict("原应付项的供应商、原币、有效性或未结原额待核对："+row.get("bill_no"));
            var line=requested.stream().filter(r->r.get("appliedLedgerId").toString().equals(row.get("id").toString())).findFirst().orElseThrow();if(new BigDecimal(line.get("amountOriginal").toString()).compareTo(new BigDecimal(row.get("remaining_original").toString()))>0)throw conflict("申请原币金额超过当前原应付未结额："+row.get("bill_no"));
        }
        return rows;
    }
    Map<String,Object> payload(DraftInput input,Kind kind){
        var value=new LinkedHashMap<String,Object>();value.put("title",input.title());value.put("remark",input.remark());value.put("requestedDate",input.requestedDate());
        if(kind==Kind.TRAVEL_APPLICATION){LocalDate from=date(input.travelStart(),"出差开始日期"),to=date(input.travelEnd(),"出差结束日期");if(to.isBefore(from))throw invalid("出差结束日期不能早于开始日期");if(text(input.destination(),400,"出差地点").isBlank()||text(input.travelPurpose(),2000,"出差事由").isBlank())throw invalid("请填写出差地点和事由");value.put("destination",input.destination());value.put("travelStart",from.toString());value.put("travelEnd",to.toString());value.put("travelPurpose",input.travelPurpose());}
        if(Set.of(Kind.PAYMENT_APPLICATION,Kind.PREPAYMENT_APPLICATION).contains(kind)){
            if(input.currencyId()==null||input.lines()==null||input.lines().isEmpty()||input.lines().size()>500)throw invalid("请完整填写币种和1至500条原申请款项");
            String nature=Objects.toString(input.paymentNature(),"");if(!Set.of("SUPPLIER_AP","SUPPLIER_PREPAYMENT","GENERAL_EXPENSE").contains(nature))throw invalid("请选择明确原付款来源");if(kind==Kind.PREPAYMENT_APPLICATION&&!nature.equals("SUPPLIER_PREPAYMENT"))throw invalid("预付申请应关联真实预付来源");
            if(nature.equals("SUPPLIER_AP"))roles.require(roles.staff(),"ar_ap_ledger:view","finance:view:all");
            if(db.queryForObject("SELECT count(*) FROM currencies WHERE id=? AND NOT is_deleted AND status='使用'",Integer.class,input.currencyId())!=1)throw invalid("申请原币不存在或已停用");
            if(nature.equals("GENERAL_EXPENSE")&&!Boolean.TRUE.equals(db.queryForObject("SELECT is_base_currency FROM currencies WHERE id=?",Boolean.class,input.currencyId())))throw invalid("原一般费用执行链只支持本位币，请按实际来源选择可执行币种");
            if(nature.startsWith("SUPPLIER")&&(input.supplierId()==null||db.queryForObject("SELECT count(*) FROM suppliers WHERE id=? AND NOT is_deleted AND status='使用'",Integer.class,input.supplierId())!=1))throw invalid("请选择真实在用供应商");
            List<Map<String,Object>> lines=new ArrayList<>();Set<UUID> ids=new HashSet<>(),payables=new HashSet<>();
            for(var line:input.lines()){
                if(line.id()==null||!ids.add(line.id()))throw invalid("原申请行编号为空或重复");BigDecimal amount;try{amount=FinancialExactAmount.require(new BigDecimal(line.amountOriginal()),"申请原币金额");}catch(NullPointerException|NumberFormatException e){throw invalid("申请金额必须是有效十进制原文");}if(amount.signum()<=0)throw invalid("申请行金额必须大于0");
                if(nature.equals("SUPPLIER_AP")!=(line.appliedLedgerId()!=null))throw invalid("应付付款需明确原应付项，预付/一般费用不能冒充普通应付");if(line.appliedLedgerId()!=null&&!payables.add(line.appliedLedgerId()))throw invalid("同一原应付项不能重复列入申请");
                var row=new LinkedHashMap<String,Object>();row.put("id",line.id());row.put("label",text(line.label(),500,"款项说明"));row.put("amountOriginal",amount.toPlainString());row.put("appliedLedgerId",line.appliedLedgerId());row.put("expenseStyleId",line.expenseStyleId());lines.add(row);
            }
            value.put("paymentNature",nature);value.put("currencyId",input.currencyId());value.put("supplierId",input.supplierId());value.put("lines",lines);
        }
        return value;
    }
    Map<String,Object> row(UUID id,boolean lock){var value=optional(id,lock);if(value==null)throw new ApiException(ErrorCode.NOT_FOUND,"原申请不存在");return value;}
    private Map<String,Object> optional(UUID id,boolean lock){var rows=db.queryForList("SELECT * FROM finance_applications WHERE id=?"+(lock?" FOR UPDATE":""),id);return rows.isEmpty()?null:rows.getFirst();}
    Map<String,Object> lockSourceAndRow(UUID id){reads.require(id,roles.staff());var targets=targetLocks.resolve(List.of(id.toString()),true);targetLocks.lockHeader(targets.getFirst(),false);var row=row(id,true);reads.require(id,roles.staff());return row;}
    void fresh(Map<String,Object> app,String expected){if(expected==null||!expected.equals(app.get("source_fingerprint"))||!source(app).fingerprint.equals(expected))throw conflict("原申请事实已变化，请刷新核对，不覆盖原输入");}
    void version(Map<String,Object> app,long expected){if(((Number)app.get("row_version")).longValue()!=expected)throw conflict("申请或当前节点已变化，请刷新核对，不覆盖原输入");}
    void owner(Map<String,Object> app,AuthUser actor){if(!same((UUID)app.get("applicant_id"),actor.getEmployeeId()))throw new ApiException(ErrorCode.FORBIDDEN,"只能修改本人申请");}
    void editable(Map<String,Object> app){if(!Set.of("DRAFT","REJECTED","REVERSED").contains(app.get("status")))throw conflict("原申请当前已冻结，不能修改");}
    private void requirePending(Map<String,Object> app){if(!Set.of("SUBMITTED","REVIEWING").contains(app.get("status")))throw conflict("原申请已不在待办理状态");}
    void readable(Map<String,Object> app,AuthUser user){reads.require((UUID)app.get("id"),user);}
    boolean same(UUID a,UUID b){return a!=null&&b!=null&&Boolean.TRUE.equals(db.queryForObject("SELECT fn_canonical_employee_identity(?)=fn_canonical_employee_identity(?)",Boolean.class,a,b));}
    private boolean canEnter(AuthUser user){return roles.has(user,FinanceApplicationPermissions.VIEW)||roles.has(user,FinanceApplicationPermissions.APPLY)||roles.has(user,"expense:apply")||roles.has(user,"payroll:generate")||roles.has(user,FinanceApplicationPermissions.SETTINGS);}
    private boolean canApply(AuthUser user,Kind kind){return roles.has(user,switch(kind){case REIMBURSEMENT,TRAVEL_REIMBURSEMENT->"expense:apply";case PAYROLL_PAYMENT->"payroll:generate";case TRAVEL_APPLICATION->roles.has(user,"expense:apply")?"expense:apply":FinanceApplicationPermissions.APPLY;default->FinanceApplicationPermissions.APPLY;});}
    private void requireApply(AuthUser user,Kind kind){if(!canApply(user,kind))throw new ApiException(ErrorCode.FORBIDDEN,"当前账号没有原申请来源的填写权限");}
    private void noticeCurrent(Map<String,Object> app){UUID id=(UUID)app.get("id");var node=db.queryForMap("SELECT label_snapshot,assignees::text FROM finance_application_nodes WHERE application_id=? AND submission_round=? AND step_no=?",id,app.get("submission_round"),app.get("current_step"));List<UUID> users=new ArrayList<>();try{for(var item:json.readTree(node.get("assignees").toString())){var target=roles.eligible(UUID.fromString(item.required("employeeId").asText()),false);if(target!=null)users.add(target.userId());}}catch(com.fasterxml.jackson.core.JsonProcessingException e){throw conflict("原节点指派记录无法读取");}notices.review(id,title(kind(app.get("kind").toString())),app.get("applicant_name_snapshot").toString(),node.get("label_snapshot").toString(),List.copyOf(users));}
    void event(UUID id,int round,String type,Integer step,Map<String,Object> detail){db.update("INSERT INTO finance_application_events(application_id,submission_round,event_type,step_no,actor_id,actor_employee_id,actor_name_snapshot,detail) VALUES(?,?,?,?,?,?,?,?::jsonb)",id,round,type,step,current.requireId(),current.requireEmployeeId(),actorName(),encode(detail));}
    String actorName(){String name=db.queryForObject("SELECT full_name FROM employees WHERE id=fn_canonical_employee_identity(?)",String.class,current.requireEmployeeId());if(name==null||name.isBlank())throw conflict("实际操作人姓名尚未核对");return name;}
    private UUID userId(UUID employee){return db.queryForList("SELECT id FROM users WHERE employee_id=fn_canonical_employee_identity(?) AND NOT is_deleted AND status='active' ORDER BY id",UUID.class,employee).stream().findFirst().orElse(null);}
    Map<String,Object> operation(UUID id,UUID request,String type,Object payload,Supplier<Map<String,Object>> work){if(request==null)throw invalid("请保留原请求编号");originLock(id);db.query("SELECT pg_advisory_xact_lock(hashtextextended(?,7111))",rs->{},"finance-application-operation:"+request);String hash=digest(List.of(type,id,payload));var previous=db.queryForList("SELECT actor_id,operation,payload_hash,result::text FROM finance_application_operations WHERE request_id=?",request);if(!previous.isEmpty()){var old=previous.getFirst();if(!current.requireId().equals(old.get("actor_id"))||!hash.equals(old.get("payload_hash")))throw conflict("原请求编号已用于不同内容，不能重新解释原请求");if(!"ASSIGN".equals(old.get("operation"))){readable(row(id,false),roles.staff());}return decode(old.get("result").toString());}var result=work.get();db.update("INSERT INTO finance_application_operations(request_id,application_id,actor_id,operation,payload_hash,result) VALUES(?,?,?,?,?,?::jsonb)",request,id,current.requireId(),type,hash,encode(result));return result;}
    void originLock(UUID id){db.query("SELECT pg_advisory_xact_lock(hashtextextended(?,7111))",rs->{},"finance-application-origin:"+id);}
    String encode(Object value){try{return json.writeValueAsString(value);}catch(Exception e){throw new IllegalStateException("原申请记录无法保存",e);}}
    Map<String,Object> decode(String value){try{return json.readValue(value,new com.fasterxml.jackson.core.type.TypeReference<Map<String,Object>>(){});}catch(Exception e){throw conflict("原申请记录无法完整读取");}}
    String digest(Object value){return ImmutableDocumentStore.digest(encode(value).getBytes(java.nio.charset.StandardCharsets.UTF_8));}
    static LocalDate date(String raw,String label){try{return LocalDate.parse(raw);}catch(Exception e){throw invalid(label+"必须为YYYY-MM-DD");}}
    static String text(String value,int max,String label){return FinanceApplicationRoles.text(value,max,label);}
    static ApiException invalid(String text){return FinanceApplicationRoles.invalid(text);}
    static ApiException conflict(String text){return FinanceApplicationRoles.conflict(text);}
}
