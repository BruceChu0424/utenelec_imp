package com.uten.imp.features.finance.statement;

import com.fasterxml.jackson.databind.*;
import com.fasterxml.jackson.core.type.TypeReference;
import com.uten.imp.application.port.*;
import com.uten.imp.application.port.FinanceMaterialStatementSourcePort.*;
import com.uten.imp.common.storage.ImmutableDocumentStore;
import com.uten.imp.common.util.FinancialExactAmount;
import com.uten.imp.common.finance.FinancialSourceAllocationGuard;
import com.uten.imp.common.finance.BusinessPrecisionContext;
import com.uten.imp.common.web.*;
import com.uten.imp.features.finance.*;
import com.uten.imp.features.finance.report.*;
import com.uten.imp.security.*;
import lombok.RequiredArgsConstructor;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.*;
import java.math.BigDecimal;
import java.nio.charset.StandardCharsets;
import java.time.LocalDate;
import java.util.*;
import java.util.function.Supplier;
import static com.uten.imp.features.finance.statement.FinanceMaterialStatementContracts.*;

/** Reviewed identities, weights and complete processing splits; stock and GL remain their own authorities. */
@Service @RequiredArgsConstructor
public class FinanceMaterialStatementService {
    final JdbcTemplate db;final ObjectMapper json;final FinanceMaterialStatementSourcePort physical;
    final FinancialAuxiliaryValidationPort auxiliary;final FinanceAuxiliaryLedgerReadPort ledger;final FinancialChartCurrencyReadPort chartCurrencies;
    final FinanceTemplateSourceService templateSources;final jakarta.persistence.EntityManager em;final FinanceDocumentAccessPolicy access;final SecurityContextCurrentUser current;final TxSessionVars tx;
    void readAccess(){CurrentAuthorityGuard.requireAll("finance_report:view");FinanceCompanyReportAccess.require(access);}
    private void editAccess(){readAccess();CurrentAuthorityGuard.requireAll("payment_style:edit");}
    private void reviewAccess(){readAccess();CurrentAuthorityGuard.requireAll("finance_post:execute");}

    @Transactional(readOnly=true,isolation=Isolation.REPEATABLE_READ)
    public Map<String,Object> sidebarReport(UUID anchor,LocalDate from,LocalDate to){readAccess();var metadata=new FinanceMaterialStatementReport(this,em).cohort(anchor,from,to).metadata();return exactMap(Map.of("sourceFingerprint",metadata.get("sourceFingerprint"),"materialContextIds",metadata.get("materialContextIds"),"cells",metadata.get("supplementalCells")));}
    @Transactional(readOnly=true)
    public Fact source(Key key){readAccess();return physical.read(List.of(key)).getFirst();}
    Map<String,Object> adjustmentCreditSource(GlAllocationKey key,Map<String,Object> receivable,AdjustmentPurpose purpose){return new FinanceMaterialProcessingAdjustment(this).credit(key,receivable,purpose);}
    @Transactional(readOnly=true,isolation=Isolation.REPEATABLE_READ)
    public ReportTableResponse report(UUID contextId,String keyword,LocalDate from,LocalDate to,int page,int size,FinanceReportColumnOptions options){
        readAccess();var c=context(contextId,false);return report((UUID)c.get("auxiliary_id"),(UUID)c.get("accounting_currency_id"),contextId,keyword,from,to,page,size,options);
    }
    @Transactional(readOnly=true,isolation=Isolation.REPEATABLE_READ)
    public ReportTableResponse report(UUID auxiliaryId,UUID accountingCurrencyId,UUID contextId,String keyword,LocalDate from,LocalDate to,int page,int size,FinanceReportColumnOptions options){
        readAccess();return new FinanceMaterialStatementReport(this,em).report(auxiliaryId,accountingCurrencyId,contextId,keyword,from,to,page,size,options);
    }
    @Transactional(readOnly=true,isolation=Isolation.REPEATABLE_READ)
    public ReportTableResponse reportFromAnchorCohort(UUID anchor,String keyword,LocalDate from,LocalDate to,int page,int size,FinanceReportColumnOptions options){readAccess();return new FinanceMaterialStatementReport(this,em).reportFromAnchorCohort(anchor,keyword,from,to,page,size,options);}
    @Transactional(readOnly=true,isolation=Isolation.REPEATABLE_READ)
    public ReportTableResponse snapshotFromAnchorCohort(UUID anchor,LocalDate from,LocalDate to){readAccess();return new FinanceMaterialStatementReport(this,em).snapshotFromAnchorCohort(anchor,from,to);}
    /** Complete bounded snapshot for originals/exports: one prepare, no forty full rereads. */
    @Transactional(readOnly=true,isolation=Isolation.REPEATABLE_READ)
    public ReportTableResponse snapshot(UUID contextId,LocalDate from,LocalDate to){
        readAccess();var c=context(contextId,false);return new FinanceMaterialStatementReport(this,em).snapshot((UUID)c.get("auxiliary_id"),(UUID)c.get("accounting_currency_id"),contextId,from,to);
    }
    @Transactional(readOnly=true,isolation=Isolation.REPEATABLE_READ)
    public ReportTableResponse snapshot(UUID auxiliaryId,UUID accountingCurrencyId,UUID contextId,LocalDate from,LocalDate to){
        readAccess();return new FinanceMaterialStatementReport(this,em).snapshot(auxiliaryId,accountingCurrencyId,contextId,from,to);
    }
    @Transactional(readOnly=true)
    public Map<String,Object> contexts(UUID auxiliaryId,UUID accountingCurrencyId,String keyword,int page,int size){
        readAccess();var args=new ArrayList<Object>();String where=" WHERE c.active";
        if(auxiliaryId!=null){where+=" AND c.auxiliary_id=?";args.add(auxiliaryId);}if(accountingCurrencyId!=null){where+=" AND c.accounting_currency_id=?";args.add(accountingCurrencyId);}
        if(keyword!=null&&!keyword.isBlank()){if(keyword.length()>240)throw invalid("检索内容过长");where+=" AND (a.source_code ILIKE ? OR a.source_name ILIKE ? OR g.code ILIKE ? OR g.name ILIKE ? OR COALESCE(configured.source_snapshot->'effectiveInput'->>'productNameCaption',configured.input->>'productNameCaption') ILIKE ?)";for(int i=0;i<5;i++)args.add("%"+keyword.replace("%","\\%").replace("_","\\_")+"%");}
        String from=" FROM finance_material_contexts c JOIN finance_auxiliary_items a ON a.id=c.auxiliary_id JOIN goods g ON g.id=c.goods_id LEFT JOIN currencies currency ON currency.id=c.accounting_currency_id LEFT JOIN colors color ON color.id=c.color_id LEFT JOIN finance_material_evidence configured ON configured.context_id=c.id AND configured.kind='CONTEXT' AND configured.current_approved";
        long total=Objects.requireNonNull(db.queryForObject("SELECT count(*)"+from+where,Long.class,args.toArray()));
        int p=Math.max(1,page),n=Math.max(1,Math.min(100,size));args.add(n);args.add((long)(p-1)*n);
        var rows=db.queryForList("SELECT c.*,a.source_name AS auxiliary_name,a.source_code AS auxiliary_code,g.code AS goods_code,g.name AS goods_name,color.name AS color_name,currency.code AS accounting_currency_code,a.role AS party_role,a.party_id,configured.id AS configured_id,configured.input::text AS configured_input,configured.source_snapshot::text AS configured_snapshot"+from+where+" ORDER BY a.source_code,g.code,c.id LIMIT ? OFFSET ?",args.toArray());
        var currencyRows=db.queryForList("SELECT id,code,name,is_base_currency,is_deleted FROM currencies");var currencyById=new HashMap<UUID,Map<String,Object>>();currencyRows.forEach(row->currencyById.put((UUID)row.get("id"),row));var base=currencyRows.stream().filter(row->Boolean.TRUE.equals(row.get("is_base_currency"))&&!Boolean.TRUE.equals(row.get("is_deleted"))).map(row->(UUID)row.get("id")).toList();
        for(var row:rows){UUID id=(UUID)row.get("id");var configured=row.get("configured_id")==null?null:new LinkedHashMap<String,Object>();if(configured!=null){configured.put("input",decode(row.get("configured_input").toString()));configured.put("source_snapshot",decode(row.get("configured_snapshot").toString()));}var v=configured==null?null:input(configured,ContextInput.class);row.remove("configured_id");row.remove("configured_input");row.remove("configured_snapshot");
            row.put("contextId",id);row.put("version",row.get("row_version"));row.put("auxiliaryId",row.get("auxiliary_id"));row.put("accountCode",row.get("account_code"));row.put("accountingCurrencyId",row.get("accounting_currency_id"));row.put("accountingCurrencyCode",row.get("accounting_currency_code"));
            row.put("partyRole",row.get("party_role"));row.put("partyId",row.get("party_id"));row.put("auxiliaryName",row.get("auxiliary_name"));row.put("auxiliaryCode",row.get("auxiliary_code"));row.put("goodsId",row.get("goods_id"));row.put("colorId",row.get("color_id"));row.put("goodsName",row.get("goods_name"));row.put("goodsCode",row.get("goods_code"));
            row.put("state",v==null?"DRAFT":"APPROVED");row.put("productNameCaption",v==null?null:v.productNameCaption());row.put("amountBasis",v==null?null:v.amountBasis());row.put("originalCurrencyId",v==null?null:v.originalCurrencyId());row.put("effectiveFrom",v==null?null:v.effectiveFrom());row.put("sourceOrder",v==null?null:v.sortOrder());UUID actualCurrency=v==null?null:v.amountBasis()==AmountBasis.ORIGINAL?v.originalCurrencyId():base.size()==1?base.getFirst():null;row.put("actualCurrencyId",actualCurrency);var actual=currencyById.get(actualCurrency);row.put("actualCurrencyCode",actual==null?null:actual.get("code"));row.put("actualCurrencyName",actual==null?null:actual.get("name"));
        }
        return exactMap(Map.of("items",rows,"total",total,"page",p,"size",n,"totalPages",(total+n-1)/n));
    }
    @Transactional(readOnly=true)
    public Map<String,Object> get(UUID id){readAccess();var result=new LinkedHashMap<>(context(id,false));result.put("evidence",db.queryForList("SELECT id,kind,resource_key,status,row_version AS version,current_approved,submitted_by,approved_by,created_by,created_at FROM finance_material_evidence WHERE context_id=? ORDER BY created_at DESC,id DESC LIMIT 30",id));result.put("historyTotal",db.queryForObject("SELECT count(*) FROM finance_material_evidence WHERE context_id=?",Long.class,id));result.put("approved",approved(id));result.put("sidebar",new FinanceMaterialSidebar(this).current(result));return exactMap(result);}
    @Transactional(readOnly=true)
    public Map<String,Object> history(UUID contextId,int page,int size){readAccess();context(contextId,false);int p=Math.max(1,page),n=Math.max(1,Math.min(100,size));long total=Objects.requireNonNull(db.queryForObject("SELECT count(*) FROM finance_material_evidence WHERE context_id=?",Long.class,contextId));var rows=db.queryForList("SELECT id,kind,resource_key,status,row_version AS version,current_approved,submitted_by,approved_by,created_by,created_at FROM finance_material_evidence WHERE context_id=? ORDER BY created_at DESC,id DESC LIMIT ? OFFSET ?",contextId,n,(long)(p-1)*n);return exactMap(Map.of("items",rows,"page",p,"size",n,"total",total,"totalPages",(total+n-1)/n));}
    @Transactional(readOnly=true)
    public Map<String,Object> evidence(UUID id){readAccess();return exactMap(evidenceRow(id,false));}
    @Transactional(readOnly=true)
    public Map<String,Object> operation(UUID id){readAccess();var rows=db.queryForList("SELECT actor_id,result::text AS result FROM finance_material_operations WHERE request_id=?",id);if(rows.size()!=1||!Objects.equals(rows.getFirst().get("actor_id"),current.requireId()))throw missing("原操作回执不存在或不属于当前账号");return decode(rows.getFirst().get("result").toString());}

    @Transactional(readOnly=true)
    public Map<String,Object> verifyOperation(UUID id,VerifyOperation command){
        readAccess();String fp=expectedOperationFingerprint(id,command);var rows=db.queryForList("SELECT actor_id,fingerprint,result::text AS result FROM finance_material_operations WHERE request_id=?",id);
        if(rows.size()!=1||!current.requireId().equals(rows.getFirst().get("actor_id")))throw missing("尚无属于当前账号的原请求回执");if(!fp.equals(rows.getFirst().get("fingerprint")))throw conflict("回执属于不同的原始参数，请保留草稿核对，不能视为本次成功");return decode(rows.getFirst().get("result").toString());
    }
    @Transactional
    public Map<String,Object> cancelUnwrittenOperation(UUID id,VerifyOperation command){
        readAccess();String fp=expectedOperationFingerprint(id,command);tx.bind();lock("request:"+id);
        var rows=db.queryForList("SELECT actor_id,fingerprint,result::text AS result FROM finance_material_operations WHERE request_id=?",id);
        if(!rows.isEmpty()){var row=rows.getFirst();if(!current.requireId().equals(row.get("actor_id"))||!fp.equals(row.get("fingerprint")))throw conflict("原请求身份或参数不一致，不能终止其他请求");return decode(row.get("result").toString());}
        var result=Map.<String,Object>of("receiptState","CANCELLED_NOT_WRITTEN","requestId",id,"actorId",current.requireId(),"requestFingerprint",fp);
        db.update("INSERT INTO finance_material_operations(request_id,actor_id,fingerprint,result) VALUES(?,?,?,?::jsonb)",id,current.requireId(),fp,encode(result));return exactMap(result);
    }
    private String expectedOperationFingerprint(UUID id,VerifyOperation command){
        if(command==null||command.path()==null||command.body()==null)throw invalid("请保留完整原请求后核对");String kind;Object input;
        if(command.path().equals("/finance/material-statements/contexts")){kind="CONTEXT";var value=parse(command.body(),ContextInput.class);if(!id.equals(value.requestId()))throw conflict("原请求编号不一致");input=value;}
        else if(command.path().equals("/finance/material-statements/drafts")){kind="DRAFT";var value=parse(command.body(),Draft.class);if(!id.equals(value.requestId()))throw conflict("原请求编号不一致");input=value;}
        else{var match=java.util.regex.Pattern.compile("^/finance/material-statements/evidence/([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})/(submit|approve|reject|withdraw)$").matcher(command.path());if(!match.matches())throw invalid("原请求路径无效");var value=parse(command.body(),Action.class);if(!id.equals(value.requestId()))throw conflict("原请求编号不一致");kind=match.group(2).equals("submit")?"SUBMIT":match.group(2);input=Map.of("id",UUID.fromString(match.group(1)),"action",value);}
        return hash(List.of(kind,input));
    }
    @Transactional
    public Map<String,Object> saveContext(ContextInput input){
        editAccess();if(input==null||input.requestId()==null)throw invalid("请保留上下文请求编号");
        return operation(input.requestId(),"CONTEXT",input,()->{
            UUID id=input.id()==null?input.requestId():input.id();identity(input);
            var existing=db.queryForList("SELECT * FROM finance_material_contexts WHERE id=? FOR UPDATE",id);
            if(existing.isEmpty()){
                if(input.expectedVersion()!=null&&input.expectedVersion()!=-1)throw conflict("本上下文不存在，请先刷新");
                db.update("INSERT INTO finance_material_contexts(id,auxiliary_id,account_code,accounting_currency_id,goods_id,color_id,amount_basis,original_currency_id,created_by) VALUES(?,?,?,?,?,?,?,?,?)",id,input.auxiliaryId(),input.accountCode(),input.accountingCurrencyId(),input.goodsId(),input.colorId(),input.amountBasis().name(),input.amountBasis()==AmountBasis.ORIGINAL?input.originalCurrencyId():null,current.requireId());
            }else{
                var old=existing.getFirst();if(input.expectedVersion()==null||version(old)!=input.expectedVersion())throw conflict("上下文版本已变化，请刷新");
                if(!Boolean.TRUE.equals(old.get("active")))throw conflict("该上下文已撤销，原历史保留，请新建新的明确上下文");
                boolean changed=!grain(old).equals(grain(input));
                if(changed){
                    if(!Objects.equals(old.get("created_by"),current.requireId())||db.queryForObject("SELECT count(*) FROM finance_material_evidence WHERE context_id=? AND status IN('SUBMITTED','APPROVED')",Integer.class,id)>0)throw invalid("已有提交或已审核来源，主体更正须先由另一人复核撤销本次维护，再新建，不改旧历史");
                    db.update("UPDATE finance_material_contexts SET auxiliary_id=?,account_code=?,accounting_currency_id=?,goods_id=?,color_id=?,amount_basis=?,original_currency_id=? WHERE id=?",input.auxiliaryId(),input.accountCode(),input.accountingCurrencyId(),input.goodsId(),input.colorId(),input.amountBasis().name(),input.amountBasis()==AmountBasis.ORIGINAL?input.originalCurrencyId():null,id);
                }
            }
            var approved=currentEvidence(EvidenceKind.CONTEXT,id.toString());
            UUID draft=input.draftId()==null?UUID.nameUUIDFromBytes((input.requestId()+":context").getBytes(StandardCharsets.UTF_8)):input.draftId();
            if(input.draftId()==null)db.update("INSERT INTO finance_material_evidence(id,context_id,kind,input,expected_approved_id,created_by) VALUES(?,?,'CONTEXT',?::jsonb,?,?)",draft,id,encode(input),approved==null?null:approved.get("id"),current.requireId());
            else{var before=evidenceRow(draft,true);if(!"DRAFT".equals(before.get("status"))||!"CONTEXT".equals(before.get("kind"))||!Objects.equals(before.get("created_by"),current.requireId())||!Objects.equals(before.get("context_id"),id)||input.expectedDraftVersion()==null||version(before)!=input.expectedDraftVersion())throw conflict("只有本人同一版本的分组草稿可维护");
                db.update("UPDATE finance_material_evidence SET input=?::jsonb,expected_approved_id=?,row_version=row_version+1,updated_at=now() WHERE id=?",encode(input),approved==null?null:approved.get("id"),draft);}
            bump(id);
            return receipt(id,draft);
        });
    }
    @Transactional
    public Map<String,Object> saveDraft(Draft input){
        editAccess();if(input==null||input.requestId()==null||input.contextId()==null||input.kind()==null||input.input()==null||!input.input().isObject()||encode(input.input()).length()>2_000_000)throw invalid("请保留明确上下文、草稿类型和有界原输入");
        rejectFloatingInput(input.input());
        if(input.kind()==EvidenceKind.CONTEXT)throw invalid("上下文资料请使用明确上下文维护入口");
        return operation(input.requestId(),"DRAFT",input,()->{
            var context=context(input.contextId(),true);if(!Boolean.TRUE.equals(context.get("active")))throw conflict("该上下文已撤销，不能追加新资料");if(version(context)!=input.expectedContextVersion())throw conflict("上下文已变化，请刷新后保存原草稿");
            UUID id=input.id()==null?input.requestId():input.id();
            if(input.id()==null)db.update("INSERT INTO finance_material_evidence(id,context_id,kind,input,expected_approved_id,created_by) VALUES(?,?,?,?::jsonb,?,?)",id,input.contextId(),input.kind().name(),encode(input.input()),input.expectedApprovedId(),current.requireId());
            else{var before=evidenceRow(id,true);if(!"DRAFT".equals(before.get("status"))||!Objects.equals(before.get("created_by"),current.requireId())||!Objects.equals(before.get("context_id"),input.contextId())||!Objects.equals(before.get("kind"),input.kind().name())||version(before)!=input.expectedVersion())throw conflict("只有本人的同一版本草稿可更正");
                db.update("UPDATE finance_material_evidence SET input=?::jsonb,expected_approved_id=?,row_version=row_version+1,updated_at=now() WHERE id=?",encode(input.input()),input.expectedApprovedId(),id);}
            bump(input.contextId());return receipt(input.contextId(),id);
        });
    }
    @Transactional
    public Map<String,Object> submit(UUID id,Action action){editAccess();return action(id,"SUBMIT",action,()->{
        reference(action.reason());var e=lockedAction(id,action);if(!"DRAFT".equals(e.get("status"))||!Objects.equals(e.get("created_by"),current.requireId()))throw conflict("只有本人草稿可提交");
        var proof=validate(e,true);lockResource(proof.kind(),proof.key());checkBase(e,proof);
        db.update("UPDATE finance_material_evidence SET status='SUBMITTED',resource_key=?,source_snapshot=?::jsonb,source_fingerprint=?,submission_reason=?,submitted_by=?,submitted_at=now(),row_version=row_version+1,updated_at=now() WHERE id=?",proof.key(),encode(proof.snapshot()),proof.fingerprint(),action.reason(),current.requireId(),id);
        bump((UUID)e.get("context_id"));return receipt((UUID)e.get("context_id"),id);
    });}
    @Transactional
    public Map<String,Object> decide(UUID id,String decision,Action action){
        if(!Set.of("approve","reject","withdraw").contains(decision))throw invalid("复核动作无效");
        if(decision.equals("withdraw"))editAccess();else reviewAccess();
        return action(id,decision,action,()->{
            var e=lockedAction(id,action);
            if(decision.equals("withdraw")&&"DRAFT".equals(e.get("status"))){if(!Objects.equals(e.get("created_by"),current.requireId()))throw conflict("仅草稿创建人可撤回");reference(action.reason());db.update("UPDATE finance_material_evidence SET status='WITHDRAWN',decision_reason=?,row_version=row_version+1,updated_at=now() WHERE id=?",action.reason(),id);bump((UUID)e.get("context_id"));return receipt((UUID)e.get("context_id"),id);}
            if(!"SUBMITTED".equals(e.get("status")))throw conflict("该证据当前不在待复核状态");
            if(decision.equals("withdraw")?!Objects.equals(e.get("submitted_by"),current.requireId()):Objects.equals(e.get("submitted_by"),current.requireId()))throw conflict("撤回仅本人；审核必须为另一位财务");reference(action.reason());
            if(decision.equals("approve")){
                var proof=validate(e,true);lockResource(proof.kind(),proof.key());checkBase(e,proof);
                if(!proof.fingerprint().equals(e.get("source_fingerprint")))throw conflict("来源已变化，不能批准原快照，请退回后重新核对");
                ownership(e,proof);
                db.update("UPDATE finance_material_evidence SET current_approved=false WHERE kind=? AND resource_key=? AND current_approved",proof.kind().name(),proof.key());
                db.update("UPDATE finance_material_evidence SET status='APPROVED',current_approved=true,approved_by=?,approved_at=now(),decision_reason=?,row_version=row_version+1,updated_at=now() WHERE id=?",current.requireId(),action.reason(),id);
                if(proof.kind()==EvidenceKind.CLOSE){
                    db.update("UPDATE finance_material_contexts SET active=false WHERE id=?",e.get("context_id"));
                    db.update("UPDATE finance_material_evidence SET current_approved=false WHERE context_id=? AND current_approved AND kind NOT IN('FEE','CLOSE')",e.get("context_id"));
                }
            }else db.update("UPDATE finance_material_evidence SET status=?,decision_reason=?,row_version=row_version+1,updated_at=now() WHERE id=?",decision.equals("reject")?"REJECTED":"WITHDRAWN",action.reason(),id);
            bump((UUID)e.get("context_id"));return receipt((UUID)e.get("context_id"),id);
        });
    }
    private Map<String,Object> action(UUID id,String kind,Action a,Supplier<Map<String,Object>> task){if(a==null||a.requestId()==null)throw invalid("请保留操作请求编号");return operation(a.requestId(),kind,Map.of("id",id,"action",a),task);}
    private Map<String,Object> lockedAction(UUID id,Action a){var before=evidenceRow(id,false);var ids=new TreeSet<UUID>();ids.add((UUID)before.get("context_id"));
        if(before.get("kind").equals("FEE")){var fee=input(before,FeeAssignment.class);if(fee.processingParts()!=null)fee.processingParts().stream().filter(Objects::nonNull).map(FeePart::contextId).filter(Objects::nonNull).forEach(ids::add);}for(UUID context:ids)context(context,true);
        var context=context((UUID)before.get("context_id"),false);if(!Boolean.TRUE.equals(context.get("active")))throw conflict("该上下文已撤销，旧请求和历史均保留");var e=evidenceRow(id,true);if(version(e)!=a.expectedVersion()||version(context)!=a.expectedContextVersion())throw conflict("原草稿或上下文版本已变化，请先核对原结果");return e;}
    private Map<String,Object> receipt(UUID context,UUID evidence){return Map.of("contextId",context,"contextVersion",version(context(context,false)),"evidenceId",evidence,"evidence",evidenceRow(evidence,false));}
    private Map<String,Object> operation(UUID request,String kind,Object input,Supplier<Map<String,Object>> task){
        tx.bind();lock("request:"+request);String fp=hash(List.of(kind,input));var rows=db.queryForList("SELECT actor_id,fingerprint,result::text AS result FROM finance_material_operations WHERE request_id=?",request);
        if(!rows.isEmpty()){var row=rows.getFirst();if(!current.requireId().equals(row.get("actor_id"))||!fp.equals(row.get("fingerprint")))throw conflict("原请求编号已用于其他内容，请先核对原结果");var saved=decode(row.get("result").toString());if("CANCELLED_NOT_WRITTEN".equals(saved.get("receiptState")))throw conflict("该原请求已明确终止且未写入，不能再次执行；请核对回执后保留输入另发新请求");return saved;}
        var result=exactMap(task.get());db.update("INSERT INTO finance_material_operations(request_id,actor_id,fingerprint,result) VALUES(?,?,?,?::jsonb)",request,current.requireId(),fp,encode(result));return result;
    }
    @Transactional(readOnly=true,isolation=Isolation.REPEATABLE_READ)
    public Map<String,Object> compare(Compare input){
        readAccess();if(input==null||input.sourceImportId()==null||input.rows()==null||input.rows().size()>2000)throw invalid("请明确原表批次和逐原行对应，不按同名自动比对");
        var source=templateSources.get(input.sourceImportId());if(!"otherReceivableStatement".equals(source.template()))throw invalid("请选择其他应收款原10列文件");
        var reader=new FinanceMaterialStatementReport(this,em);
        var projection=input.allMaterialContexts()?reader.cohort(input.contextId(),input.dateFrom(),input.dateTo()):reader.prepare(input.auxiliaryId(),input.accountingCurrencyId(),input.contextId(),input.dateFrom(),input.dateTo());
        var targets=new HashMap<String,Map<String,Object>>();projection.rows().forEach(row->targets.put(row.get("__rowKey").toString(),row));
        var originals=new HashMap<Integer,FinanceTemplateSourceReader.Row>();source.rows().forEach(row->originals.put(row.sourceRow(),row));
        var seen=new HashSet<Integer>();var used=new HashSet<String>();var results=new ArrayList<Map<String,Object>>();
        String[] fields={"billDate","goodsName","spec","inWeight","outWeight","loss","balance","outQty","price","processAmount"};
        for(var selected:input.rows()){
            if(!seen.add(selected.sourceRow())||!used.add(selected.reportRowKey()))throw invalid("原表行与已计算行不能重复认作另一行");
            var original=originals.get(selected.sourceRow());var actual=targets.get(selected.reportRowKey());if(original==null||actual==null)throw invalid("选定原行或真实计算行已变化，请刷新");
            var differences=new ArrayList<Map<String,Object>>();
            for(int col=1;col<=fields.length;col++){
                final int index=col;var cell=original.cells().stream().filter(c->c.column()==index).findFirst().orElse(null);String raw=cell==null?"":cell.number()==null?cell.text():cell.number();Object value=actual.get(fields[col-1]);boolean equal;
                if(cell!=null&&cell.number()!=null){try{equal=value!=null&&new BigDecimal(raw).compareTo(new BigDecimal(value.toString()))==0;}catch(NumberFormatException error){equal=false;}}
                else equal=raw.strip().equals(value==null?"":value.toString().strip());
                if(!equal){var diff=new LinkedHashMap<String,Object>();diff.put("column",col);diff.put("label",source.headers().get(col-1));diff.put("source",raw);diff.put("actual",value);differences.add(diff);}
            }
            results.add(Map.of("sourceRow",selected.sourceRow(),"reportRowKey",selected.reportRowKey(),"issues",original.issues(),"differences",differences));
        }
        var supplementalActual=new HashMap<String,Map<?,?>>();Object extra=projection.metadata().get("supplementalCells");if(extra instanceof List<?> cells)for(Object cell:cells)if(cell instanceof Map<?,?> map&&map.get("sourceCell")!=null)supplementalActual.put(map.get("sourceCell").toString(),map);
        var supplemental=new ArrayList<Map<String,Object>>();for(var original:source.supplementalCells()){
            var actual=supplementalActual.get(original.sourceCell());var row=new LinkedHashMap<String,Object>();String raw=original.number()==null?original.text():original.number();Object value=actual==null?null:actual.get("value");boolean pending=actual==null||Boolean.TRUE.equals(actual.get("pending"));boolean equal=false;
            if(!pending){if(original.number()!=null){try{equal=value!=null&&new BigDecimal(raw).compareTo(new BigDecimal(value.toString()))==0;}catch(NumberFormatException ignored){equal=false;}}else equal=Objects.toString(raw,"").equals(Objects.toString(value,""));}
            row.put("sourceCell",original.sourceCell());row.put("source",raw);row.put("actual",value);row.put("pending",pending);row.put("equal",equal);row.put("sourceKind",original.kind());supplemental.add(row);
        }
        return exactMap(Map.of("sourceImportId",source.importId(),"sourceSha256",source.sha256(),"sourceIssues",source.issues(),"sourceFingerprint",projection.metadata().get("sourceFingerprint"),"results",results,"unmappedSourceRows",source.rows().stream().filter(row->!seen.contains(row.sourceRow())).map(FinanceTemplateSourceReader.Row::sourceRow).toList(),"supplementalComparisons",supplemental,"basis","仅比对外部原值与同源实际计算；不执行公式、不自动匹配名字，不写库存、余额或GL"));
    }
    record Proof(EvidenceKind kind,String key,Map<String,Object> snapshot,String fingerprint){}
    static final class ReadScope {
        final Map<Key,Fact> facts=new HashMap<>();final Map<UUID,Map<String,Object>> contexts=new HashMap<>();
        final Map<GlAllocationKey,Map<String,Object>> gl=new HashMap<>();
        final Map<UUID,List<Map<String,Object>>> reviewed=new HashMap<>();final Map<String,Map<String,Object>> byResource=new HashMap<>();
        final Map<Key,UUID> routes=new HashMap<>();final Set<Key> invalidRoutes=new HashSet<>();final Set<Key> readRoutes=new HashSet<>();
        final Map<String,Boolean> adjustmentEffects=new HashMap<>();
        final Map<UUID,Set<String>> nativeLinks=new HashMap<>();final Map<UUID,Boolean> valid=new HashMap<>();
        final Map<String,Map<Key,Fact>> physicalScopes=new HashMap<>();
    }
    Proof validate(Map<String,Object> e,boolean posting){return validate(e,posting,new ReadScope());}
    Proof validate(Map<String,Object> e,boolean posting,ReadScope scope){
        UUID contextId=(UUID)e.get("context_id");var c=readContext(contextId,scope);var s=new TreeMap<String,Object>();s.put("context",grain(c));
        var frozen=e.get("source_snapshot") instanceof Map<?,?> existing?existing:null;
        boolean immutable=Set.of("SUBMITTED","APPROVED").contains(e.get("status"))&&frozen!=null&&frozen.get("effectiveInput")!=null;
        var input=immutable?json.valueToTree(frozen.get("effectiveInput")):normalizeInput(json.valueToTree(e.get("input")));
        s.put("effectiveInput",input);s.put("precisionChoices",immutable?frozen.get("precisionChoices"):precisionSnapshot());
        EvidenceKind kind=EvidenceKind.valueOf(e.get("kind").toString());String key;
        if(Set.of(EvidenceKind.GOODS,EvidenceKind.NATIVE_PARTY,EvidenceKind.UNIT,EvidenceKind.WEIGHT,EvidenceKind.SOURCE_RELATION,EvidenceKind.COVERAGE,EvidenceKind.SIDEBAR).contains(kind)){
            if(input.has("enabled")&&!input.get("enabled").isBoolean())throw invalid("请明确启用或停用本条资料");
            if(posting&&!input.has("enabled"))throw invalid("请明确本条资料的启用/停用；原输入仍保留");
            if(input.has("enabled")&&!input.get("enabled").booleanValue()){
                if(e.get("expected_approved_id")==null)throw invalid("停用须从确切原已审版本新建更正，不能用空规则声明停用");
                requireContext(contextId,UUID.fromString(input.path("contextId").asText()));reference(input.path("sourceReference").asText());
                key=disabledKey(kind,input,contextId);s.put("disabledPreviousId",e.get("expected_approved_id"));s.put("ruleDisabled",true);var frozenDisabled=exactMap(s);return new Proof(kind,key,frozenDisabled,hash(frozenDisabled));
            }
        }
        switch(kind){
            case CONTEXT->{var v=parse(input,ContextInput.class);identity(v,posting);if(!grain(c).equals(grain(v)))throw invalid("上下文身份与原草稿不一致");s.put("input",input);key=contextId.toString();}
            case GOODS->{var v=parse(input,SourceGoods.class);requireContext(contextId,v.contextId());reference(v.sourceReference());
                if(v.productNameCaption()!=null&&(v.productNameCaption().isBlank()||v.productNameCaption().length()>240)||v.specificationCaption()!=null&&v.specificationCaption().length()>240)throw invalid("请按该真实原料/产物维护财务原名与规格");
                if(v.sourceKind()==null||v.goodsId()==null||v.flowRole()==null)throw invalid("请明确原料/产物的真实货品、颜色和对应物量");
                if(db.queryForObject("SELECT count(*) FROM goods WHERE id=?",Integer.class,v.goodsId())!=1||v.colorId()!=null&&db.queryForObject("SELECT count(*) FROM colors WHERE id=?",Integer.class,v.colorId())!=1)throw invalid("来源货品或颜色不存在");
                boolean validRole=switch(v.sourceKind()){case PURCHASE_RECEIPT_LINE->v.flowRole()==FlowRole.INBOUND;case SUBCONTRACT_MATERIAL_ISSUE_LINE->v.flowRole()==FlowRole.MATERIAL_OUT;case SUBCONTRACT_MATERIAL_RETURN_LINE->v.flowRole()==FlowRole.MATERIAL_RETURN;case STOCK_OTHER_OUT_LINE,SALES_OTHER_SHIPMENT_LINE->Set.of(FlowRole.MATERIAL_OUT,FlowRole.FINISHED_OUT).contains(v.flowRole());};
                if(!validRole)throw invalid("来源类型与物量不一致；委外发料/退料不计成品PCS或新加工款");
                s.put("input",input);key=contextId+":"+v.sourceKind()+":"+v.goodsId()+":"+Objects.toString(v.colorId(),"NONE");
            }
            case NATIVE_PARTY->{var v=parse(input,NativePartyLink.class);requireContext(contextId,v.contextId());if(!Set.of("SUPPLIER","CUSTOMER").contains(Objects.toString(v.nativeRole(),""))||v.nativePartyId()==null||v.sourceKind()==null)throw invalid("请选择真实供应商/客户UUID和来源类型");reference(v.sourceReference());
                if(!input.has("enabled")||!input.get("enabled").isBoolean())throw invalid("请明确本次实际关系启用或停用，不能省略");
                if(Set.of(Kind.PURCHASE_RECEIPT_LINE,Kind.SUBCONTRACT_MATERIAL_ISSUE_LINE,Kind.SUBCONTRACT_MATERIAL_RETURN_LINE).contains(v.sourceKind())&&!v.nativeRole().equals("SUPPLIER")||v.sourceKind()==Kind.SALES_OTHER_SHIPMENT_LINE&&!v.nativeRole().equals("CUSTOMER"))throw invalid("原采购/销售来源与真实对象类别不一致");
                String table=v.nativeRole().equals("SUPPLIER")?"suppliers":"clients";if(db.queryForObject("SELECT count(*) FROM "+table+" WHERE id=?"+(posting?" AND NOT is_deleted":""),Integer.class,v.nativePartyId())!=1)throw invalid("真实来源单位已删除或不存在");s.put("input",input);key=contextId+":"+v.sourceKind()+":"+v.nativeRole()+":"+v.nativePartyId();}
            case UNIT->{var v=parse(input,UnitEvidence.class);requireContext(contextId,v.contextId());reference(v.sourceReference());
                if(v.sourceGoodsId()==null||!Set.of("BASE","SOURCE").contains(Objects.toString(v.quantityBasis(),"")))throw invalid("请选择真实货品、颜色及以库存基本量或原单单位量换算");
                if(v.sourceUnitId()==null||db.queryForObject("SELECT count(*) FROM units WHERE id=?"+(posting?" AND NOT is_deleted":""),Integer.class,v.sourceUnitId())!=1)throw invalid("请选择真实来源单位UUID");
                if(db.queryForObject("SELECT count(*) FROM goods WHERE id=?",Integer.class,v.sourceGoodsId())!=1)throw invalid("真实货品不存在");
                positiveOptional(v.kgPerSourceUnit(),"每原单位KG");positiveOptional(v.pcsPerSourceUnit(),"每原单位PCS");
                if(v.kgPerSourceUnit()==null&&v.pcsPerSourceUnit()==null)throw invalid("至少明确一项KG或PCS换算，不按单位名称猜测");
                if(v.kgPerSourceUnit()!=null&&!Set.of("EXACT_UNIT","ESTIMATE").contains(Objects.toString(v.kgBasis(),"")))throw invalid("请明确KG是已核重量单位换算还是估计单重；估计不能冒充实称");
                if(v.quantityBasis().equals("SOURCE")){if(v.sourceUnitRate()==null||v.sourceUnitRate().signum()<=0)throw invalid("原单单位换算须明确匹配的原unit_rate，不能把不同箱规混用");FinancialExactAmount.require(v.sourceUnitRate(),"原库存换算率");}
                s.put("input",input);key=unitKey(contextId,v.sourceGoodsId(),v.sourceColorId(),v.sourceUnitId(),v.quantityBasis(),v.sourceUnitRate());
            }
            case OPENING->{var v=parse(input,OpeningEvidence.class);requireContext(contextId,v.contextId());reference(v.sourceReference());if(v.effectiveFrom()==null)throw invalid("请明确期初重量有效起点");FinancialExactAmount.book(v.balanceWeightKg(),"期初KG");s.put("input",input);key=contextId.toString();}
            case WEIGHT->{var v=parse(input,WeightEvidence.class);requireContext(contextId,v.contextId());reference(v.sourceReference());var f=one(v.source(),scope);requireSource(c,f,scope);var effect=effect(f,v.movementId());if(!Objects.equals(v.expectedEffectFingerprint(),effect.identityFingerprint())||posting&&!Objects.equals(v.expectedIdentityFingerprint(),f.identityFingerprint()))throw conflict("本次实物切片已变化，请重新读取真实流水");
                if(v.actualWeightKg()==null&&v.actualQuantityPcs()==null)throw invalid("至少明确一项实称KG或实点PCS");nonnegative(v.actualWeightKg(),"实称KG");nonnegative(v.actualQuantityPcs(),"实点PCS");
                if(effect.weightKg()!=null&&v.actualWeightKg()!=null&&effect.weightKg().compareTo(v.actualWeightKg())!=0)throw invalid("原库存流水已具明确实称，不能通过财务输入改写原库存重量");s.put("effect",effect.sourceSnapshot());s.put("input",input);key=contextId+":"+effect.movementId();}
            case ZERO->{var v=parse(input,ZeroProcessing.class);requireContext(contextId,v.contextId());reference(v.sourceReference());var f=one(v.source(),scope);var rule=requireSource(c,f,scope);var effect=effect(f,v.movementId());
                if(rule.flowRole()!=FlowRole.FINISHED_OUT||effect.reversal()||effect.eventSign()!=1)throw invalid("仅可明确原真实成品发出切片是否免加工款，不给委外原料/退料伪造费用");
                if(!input.has("zeroProcessing")||!Objects.equals(v.expectedEffectFingerprint(),effect.identityFingerprint())||posting&&!Objects.equals(v.expectedIdentityFingerprint(),f.identityFingerprint()))throw conflict("免加工款来源切片已变化或未明确选择，请重读");
                if(v.zeroProcessing()&&db.queryForObject("SELECT count(*) FROM finance_material_evidence fee CROSS JOIN LATERAL jsonb_array_elements(COALESCE(fee.source_snapshot->'effectiveInput'->'processingParts',fee.input->'processingParts','[]'::jsonb)) part WHERE fee.kind='FEE' AND fee.current_approved AND part->>'contextId'=? AND part->'outboundSource'->>'kind'=? AND part->'outboundSource'->>'lineId'=? AND part->>'outboundMovementId'=?",Integer.class,contextId.toString(),v.source().kind().name(),v.source().lineId().toString(),v.movementId().toString())>0)throw conflict("该真实发出已有已审GL加工归属，请先更正原完整分配，不能再标免加工款");
                s.put("effect",effect.sourceSnapshot());s.put("input",input);key=contextId+":"+effect.movementId();}
            case SOURCE_RELATION->{var v=parse(input,SourceRelation.class);requireContext(contextId,v.contextId());reference(v.sourceReference());var f=one(v.source(),scope);requireSource(c,f,scope);if(posting&&!f.identityFingerprint().equals(v.expectedIdentityFingerprint()))throw conflict("物理来源身份或原入库切片已变化，请重新读取");var stable=new TreeMap<>(f.sourceSnapshot());stable.remove("originalEffects");stable.remove("currentStatus");s.put("source",stable);s.put("input",input);key=v.source().kind()+":"+v.source().lineId();}
            case COVERAGE->{var v=parse(input,SourceCoverage.class);requireContext(contextId,v.contextId());reference(v.sourceReference());
                if(v.sourceKind()==null||v.dateFrom()==null||v.dateTo()==null||v.dateFrom().isAfter(v.dateTo())||!v.completeReviewed()||v.completeSources()==null||v.completeSources().size()>20000||new HashSet<>(v.completeSources()).size()!=v.completeSources().size())throw invalid("请明确本段实际来源范围、完整清单（可明确为空）及复核依据");
                var actual=physicalScope(c,v.sourceKind(),v.dateFrom(),v.dateTo(),scope);var selected=new HashSet<>(v.completeSources());
                for(var k:selected){if(k==null||k.kind()==null||k.lineId()==null||k.kind()!=v.sourceKind())throw invalid("完整来源清单的来源类型不一致");var fact=actual.get(k);if(fact==null)throw invalid("完整来源清单包含本期间外或不存在的实物来源");requireSource(c,fact,scope);if(!owns(contextId,fact,scope))throw invalid("逐源完整范围须先明确每行归户关系");}
                for(var fact:actual.values())if(owns(contextId,fact,scope)&&!selected.contains(fact.key()))throw invalid("已有明确归户的本段实物流不能从完整来源清单漏掉");
                s.put("input",input);s.put("actualScope",actual.values().stream().sorted(Comparator.comparing(f->f.key().lineId().toString())).map(f->Map.of("key",f.key(),"identityFingerprint",f.identityFingerprint(),"effects",f.effects().stream().filter(x->!x.businessDate().isBefore(v.dateFrom())&&!x.businessDate().isAfter(v.dateTo())).map(x->Map.of("id",x.movementId(),"fingerprint",x.identityFingerprint())).toList())).toList());
                key=contextId+":"+v.sourceKind()+":"+v.dateFrom()+":"+v.dateTo();
            }
            case SIDEBAR->{var line=parse(input,SidebarLine.class);s.put("sidebar",new FinanceMaterialSidebar(this).validate(c,line));key=new FinanceMaterialSidebar(this).key(c,line);}
            case CLOSE->{var v=parse(input,Close.class);requireContext(contextId,v.contextId());reference(v.sourceReference());
                if(!Boolean.TRUE.equals(c.get("active")))throw conflict("该上下文已撤销");
                int dependencies=db.queryForObject("SELECT count(*) FROM finance_material_evidence fee CROSS JOIN LATERAL jsonb_array_elements(COALESCE(fee.source_snapshot->'effectiveInput'->'processingParts',fee.input->'processingParts','[]'::jsonb)) part WHERE fee.kind='FEE' AND fee.current_approved AND part->>'contextId'=?",Integer.class,contextId.toString());
                if(dependencies>0)throw conflict("还有已审核加工份额引用本上下文，请先按真实GL重新完整分配并审核；撤销维护不会冲原GL或库存");
                s.put("input",input);s.put("currentEvidence",approved(contextId).stream().filter(x->!x.get("kind").equals("CLOSE")).map(x->Map.of("id",x.get("id"),"fingerprint",Objects.toString(x.get("source_fingerprint"),""))).toList());key=contextId.toString();
            }
            case FEE->{var v=parse(input,FeeAssignment.class);reference(v.sourceReference());if(v.source()==null||v.processingParts()==null||v.processingParts().size()>2000||v.processingParts().stream().anyMatch(p->p==null||p.contextId()==null||p.outboundSource()==null))throw invalid("请完整分配真实其他应收GL条目");var gl=scope.gl.computeIfAbsent(v.source(),k->feeSource(k,posting));
                if(posting&&!Objects.equals(v.expectedSourceFingerprint(),hash(gl)))throw conflict("原GL金额或辅助来源已变化，请重新读取精确原值后分配");
                if(!Objects.equals(c.get("auxiliary_id"),gl.get("auxiliary_id"))||!Objects.equals(c.get("accounting_currency_id"),gl.get("currency_id"))||!Objects.equals(c.get("account_code"),gl.get("account_code")))throw invalid("真实GL须属于本上下文的同一辅助、科目及会计币别");
                var keys=v.processingParts().stream().map(FeePart::outboundSource).distinct().filter(k->!scope.facts.containsKey(k)).toList();
                for(int offset=0;offset<keys.size();offset+=200)for(var fact:physical.readForIdentity(keys.subList(offset,Math.min(offset+200,keys.size()))))scope.facts.put(fact.key(),fact);
                s.put("source",gl);var parts=new ArrayList<Map<String,Object>>();
                BigDecimal local=decimal(gl.get("amount_local")),original=decimal(gl.get("amount_original"));UUID originalUnit=(UUID)gl.get("original_currency_id");
                for(var p:v.processingParts()){
                    var target=readContext(p.contextId(),scope);if(posting&&!Boolean.TRUE.equals(target.get("active")))throw conflict("加工份额不能新增归入已撤销的上下文");if(!Objects.equals(target.get("auxiliary_id"),gl.get("auxiliary_id"))||!Objects.equals(target.get("accounting_currency_id"),gl.get("currency_id"))||!Objects.equals(target.get("account_code"),gl.get("account_code")))throw invalid("加工份额须属于同一真实辅助、科目和会计币别");
                    if("ORIGINAL".equals(target.get("amount_basis"))&&!Objects.equals(target.get("original_currency_id"),gl.get("original_currency_id")))throw invalid("加工份额目标纸面实际原币与该GL来源不一致，请选择同实际单位或本币口径分组，不能拿科目币别属性代替原币");var f=one(p.outboundSource(),scope);if(Set.of(Kind.PURCHASE_RECEIPT_LINE,Kind.SUBCONTRACT_MATERIAL_RETURN_LINE).contains(f.key().kind()))throw invalid("加工款须明确关联真实发出来源，来料或退料不是新加工发出");var rule=requireSource(target,f,scope);if(rule.flowRole()!=FlowRole.FINISHED_OUT)throw invalid("委外原料发出/退料仅计重量，不是成品PCS和加工款来源");if(!owns(p.contextId(),f,scope))throw invalid("请先明确原出库对象与财务辅助上下文的对应关系");var effect=effect(f,p.outboundMovementId());var zero=reviewed(p.contextId(),EvidenceKind.ZERO,p.contextId()+":"+effect.movementId(),scope);if(zero!=null&&input(zero,ZeroProcessing.class).zeroProcessing())throw conflict("该切片已审为免加工款，请先由另一财务复核取消免款标记，再认领真实GL");if(effect.eventSign()<0)throw invalid("加工份额关联原实际发出切片；金融反向另按真实GL日期读取");
                    if(p.quotedProcessingPrice()!=null){nonnegative(p.quotedProcessingPrice(),"原加工单价");reference(p.quotationReference());if(!Set.of("INCLUDED","EXCLUDED","NOT_APPLICABLE").contains(Objects.toString(p.quotationTaxBasis(),"")))throw invalid("请明确原加工报价含税、未税或不适用，不用固定税率倒推");if(p.quotationCurrencyId()==null)throw invalid("加工报价须保留真实币别，不按当前汇率重算");}
                    FinancialExactAmount.book(p.amountLocal(),"加工本币份额");if(original==null){if(p.amountOriginal()!=null)throw invalid("原GL没有原币证据，不得把本币份额填作原币");}else FinancialExactAmount.require(p.amountOriginal(),"加工原币份额");
                    var part=new LinkedHashMap<String,Object>();part.put("context",grain(target));part.put("sourceKind",p.outboundSource().kind());part.put("sourceId",p.outboundSource().lineId());part.put("movement",effect.sourceSnapshot());part.put("amountLocal",p.amountLocal());part.put("amountOriginal",p.amountOriginal());part.put("quotedProcessingPrice",p.quotedProcessingPrice());part.put("quotationCurrencyId",p.quotationCurrencyId());part.put("quotationReference",p.quotationReference());part.put("quotationTaxBasis",p.quotationTaxBasis());parts.add(part);
                }
                var localParts=new ArrayList<BigDecimal>(v.processingParts().stream().map(FeePart::amountLocal).toList());for(var p:v.processingParts())if(p.adjustments()!=null)for(var a:p.adjustments())if(!a.includedInProcessing())localParts.add(FinancialExactAmount.book(a.amountLocal(),"未含入J的附加本币份额"));localParts.add(FinancialExactAmount.book(v.nonprocessingLocal(),"明确非加工本币余项"));conserve(local,localParts);
                if(original!=null){var originals=new ArrayList<BigDecimal>(v.processingParts().stream().map(FeePart::amountOriginal).toList());for(var p:v.processingParts())if(p.adjustments()!=null)for(var a:p.adjustments())if(!a.includedInProcessing())originals.add(FinancialExactAmount.require(a.amountOriginal(),"未含入J的附加原币份额"));originals.add(FinancialExactAmount.require(v.nonprocessingOriginal(),"明确非加工原币余项"));conserve(original,originals);}else if(v.nonprocessingOriginal()!=null)throw invalid("原币缺证据时非加工原币余项也不能假填0");
                s.put("adjustments",new FinanceMaterialProcessingAdjustment(this).validate(v,gl,posting,e));s.put("parts",parts);s.put("originalUnit",originalUnit);s.put("nonprocessingLocal",v.nonprocessingLocal());s.put("nonprocessingOriginal",v.nonprocessingOriginal());key=v.source().entryId()+":"+v.source().allocationNo();
            }
            default->throw invalid("资料类型无效");
        }
        var exact=exactMap(s);return new Proof(kind,key,exact,hash(exact));
    }
    private String disabledKey(EvidenceKind kind,JsonNode input,UUID context){return switch(kind){
        case SIDEBAR->{var v=parse(input,SidebarLine.class);yield new FinanceMaterialSidebar(this).key(context(context,false),v);}
        case GOODS->{var v=parse(input,SourceGoods.class);yield context+":"+v.sourceKind()+":"+v.goodsId()+":"+Objects.toString(v.colorId(),"NONE");}
        case NATIVE_PARTY->{var v=parse(input,NativePartyLink.class);yield context+":"+v.sourceKind()+":"+v.nativeRole()+":"+v.nativePartyId();}
        case UNIT->{var v=parse(input,UnitEvidence.class);yield unitKey(context,v.sourceGoodsId(),v.sourceColorId(),v.sourceUnitId(),v.quantityBasis(),v.sourceUnitRate());}
        case WEIGHT->{var v=parse(input,WeightEvidence.class);yield context+":"+v.movementId();}
        case SOURCE_RELATION->{var v=parse(input,SourceRelation.class);yield v.source().kind()+":"+v.source().lineId();}
        case COVERAGE->{var v=parse(input,SourceCoverage.class);yield context+":"+v.sourceKind()+":"+v.dateFrom()+":"+v.dateTo();}
        default->throw invalid("该资料不支持单条停用");};}
    private void identity(ContextInput v){identity(v,true);}
    private void identity(ContextInput v,boolean posting){
        if(v.sideSlot()!=null&&!"PCS".equals(v.quantityUnitCaption()))throw invalid("原旁算数量单位为PCS，请按原文字及已核PCS换算，不把KG或箱数直接放入该位置");
        if(v.sideQuantityUnitId()!=null&&db.queryForObject("SELECT count(*) FROM units WHERE id=?"+(posting?" AND NOT is_deleted":""),Integer.class,v.sideQuantityUnitId())!=1)throw invalid("原旁算单位引用不存在");
        if(v.sideSlot()!=null&&(v.sideSlot()<1||v.sideSlot()>4))throw invalid("原隐藏旁算区仅有四个资料位置，请明确1至4或留空待核");
        if(v.productNameCaption()==null||v.productNameCaption().isBlank()||v.productNameCaption().length()>240||v.specificationCaption()!=null&&v.specificationCaption().length()>240||v.quantityUnitCaption()!=null&&v.quantityUnitCaption().length()>100)throw invalid("请按财务原文明确产品名称与规格/单位标签，不能只拿当前货品名替代");
        if(v.sortOrder()==null||v.sortOrder()<1||v.sortOrder()>10000||v.requiredSourceKinds()==null||v.requiredSourceKinds().isEmpty())throw invalid("请明确原表顺序及本上下文实际采用的入/出库来源类型");
        if(v.accountCode()==null||v.auxiliaryId()==null||v.accountingCurrencyId()==null||v.goodsId()==null||v.amountBasis()==null||v.effectiveFrom()==null)throw invalid("请明确财务科目、辅助对象、会计币别、货品、金额口径和有效起点");reference(v.sourceReference());
        var selection=new FinancialAuxiliaryValidationPort.Selection(v.accountCode(),v.auxiliaryId(),v.accountingCurrencyId());var ref=posting?auxiliary.inspect(selection):auxiliary.inspectHistorical(selection);if(ref==null||ref.partyId()==null||ref.role().equals("EMPLOYEE"))throw invalid("其他应收原表须先明确客户、供应商或其他往来辅助，不按名称匹配");
        if(posting){var configured=chartCurrencies.read(Set.of(v.accountCode())).get(v.accountCode());boolean currentProperty=configured!=null&&Objects.equals(configured.currencyId(),v.accountingCurrencyId());
            if(!currentProperty&&db.queryForObject("SELECT count(*) FROM finance_gl_entry_allocations a JOIN gl_entries e ON e.id=a.entry_id WHERE a.account_code=? AND a.auxiliary_id=? AND a.currency_id=? AND a.party_id_snapshot=? AND a.auxiliary_role=? AND NOT e.is_deleted AND fn_finance_gl_voucher_is_booked(e.voucher_id)",Integer.class,v.accountCode(),v.auxiliaryId(),v.accountingCurrencyId(),ref.partyId(),ref.role())==0)throw invalid("会计币别属性须与科目公共对应一致；历史不同属性须有同科目/辅助的真实已记账来源，不能任填另一币别");
        }
        if(db.queryForObject("SELECT count(*) FROM finance_chart_code_styles map JOIN payment_styles style ON style.id=map.style_id WHERE map.code=? AND style.category='ACCOUNT'"+(posting?" AND style.status='使用' AND NOT style.is_deleted":"")+" AND EXISTS(SELECT 1 FROM finance_report_line_bindings binding WHERE binding.binding_kind='STYLE' AND binding.style_id=style.id AND binding.line_key IN('BS_4','BS_8'))",Integer.class,v.accountCode())<1)throw invalid("请选择财务已明确对应应收账款/其他应收款的真实资产往来科目，不能用现金代债权");
        if(v.amountBasis()==AmountBasis.ORIGINAL&&v.originalCurrencyId()==null)throw invalid("原币口径须明确真实原币单位");
        if(v.originalCurrencyId()!=null&&db.queryForObject("SELECT count(*) FROM currencies WHERE id=?"+(posting?" AND NOT is_deleted":""),Integer.class,v.originalCurrencyId())!=1)throw invalid("真实原币单位不存在");
        if(db.queryForObject("SELECT count(*) FROM goods WHERE id=?"+(posting?" AND NOT is_deleted":""),Integer.class,v.goodsId())!=1)throw invalid("请选择真实货品UUID");
        if(v.colorId()!=null&&db.queryForObject("SELECT count(*) FROM colors WHERE id=?"+(posting?" AND NOT is_deleted":""),Integer.class,v.colorId())!=1)throw invalid("请选择真实颜色UUID；无色与所有颜色不能混用");
    }
    Map<String,Object> feeSource(GlAllocationKey key,boolean posting){
        if(key==null||key.entryId()==null||key.allocationNo()<1)throw invalid("请选择真实GL entry及allocation序号");
        var rows=db.queryForList("SELECT allocation.*,entry.direction,entry.entry_date,entry.style_id,entry.voucher_id,voucher.voucher_no,voucher.status AS voucher_status,voucher.reversal_of_voucher_id FROM finance_gl_entry_allocations allocation JOIN gl_entries entry ON entry.id=allocation.entry_id JOIN gl_vouchers voucher ON voucher.id=entry.voucher_id WHERE allocation.entry_id=? AND allocation.allocation_no=? AND NOT entry.is_deleted AND fn_finance_gl_voucher_is_booked(voucher.id) AND NOT fn_finance_entry_is_pnl_closing(entry.id)",key.entryId(),key.allocationNo());
        if(rows.size()!=1)throw invalid("原其他应收GL分配不存在、未入账或为损益结转");var source=rows.getFirst();
        if(((Number)source.get("direction")).intValue()!=1||source.get("reversal_of_voucher_id")!=null)throw invalid("请选择真实其他应收原借方及原allocation；普通回款或反向凭证不是新的加工来源");
        var selection=new FinancialAuxiliaryValidationPort.Selection(source.get("account_code").toString(),(UUID)source.get("auxiliary_id"),(UUID)source.get("currency_id"));var ref=posting?auxiliary.inspect(selection):auxiliary.inspectHistorical(selection);
        if(ref==null||ref.partyId()==null||!Objects.equals(ref.partyId(),source.get("party_id_snapshot"))||!Objects.equals(ref.role(),source.get("auxiliary_role")))throw invalid("原GL辅助快照与实际对象不一致");
        var stable=new TreeMap<String,Object>();for(String field:List.of("entry_id","allocation_no","account_code","auxiliary_id","currency_id","original_currency_id","amount_local","amount_original","entry_date","direction","style_id","voucher_id","voucher_no","party_id_snapshot","auxiliary_role"))stable.put(field,source.get(field));return stable;
    }
    private void ownership(Map<String,Object> e,Proof p){
        if(p.kind()==EvidenceKind.SIDEBAR){new FinanceMaterialSidebar(this).claim(e,input(e,SidebarLine.class));return;}
        if(p.kind()==EvidenceKind.FEE){new FinanceMaterialProcessingAdjustment(this).claim(e,input(e,FeeAssignment.class));return;}
        if(p.kind()!=EvidenceKind.NATIVE_PARTY&&p.kind()!=EvidenceKind.GOODS)return;
        UUID contextId=(UUID)e.get("context_id");var rules=new ArrayList<>(sourceGoods(contextId,new ReadScope()));
        var links=approved(contextId).stream().filter(row->row.get("kind").equals("NATIVE_PARTY")).map(row->input(row,NativePartyLink.class)).filter(NativePartyLink::enabled).toList();
        if(p.kind()==EvidenceKind.GOODS){var candidate=input(e,SourceGoods.class);rules.removeIf(rule->rule.sourceKind()==candidate.sourceKind()&&rule.goodsId().equals(candidate.goodsId())&&Objects.equals(rule.colorId(),candidate.colorId()));if(candidate.active())rules.add(candidate);}
        else{var candidate=input(e,NativePartyLink.class);if(!candidate.enabled())return;links=List.of(candidate);}
        var checked=new TreeMap<String,List<Object>>();
        for(var link:links)for(var rule:rules)if(rule.sourceKind()==link.sourceKind()){
            String key=link.sourceKind()+":"+link.nativeRole()+":"+link.nativePartyId()+":"+rule.goodsId()+":"+Objects.toString(rule.colorId(),"NONE");
            var args=new ArrayList<Object>(List.of(contextId,link.nativeRole(),link.nativePartyId().toString(),link.sourceKind().name(),rule.goodsId().toString()));args.add(rule.colorId()==null?null:rule.colorId().toString());checked.put(key,args);
        }
        for(var candidate:checked.entrySet()){
            lock("native-route:"+candidate.getKey());
            int other=db.queryForObject("SELECT count(*) FROM finance_material_evidence link JOIN finance_material_contexts c ON c.id=link.context_id AND c.active JOIN finance_material_evidence goods ON goods.context_id=c.id AND goods.kind='GOODS' AND goods.current_approved AND COALESCE((goods.input->>'enabled')::boolean,true) WHERE link.kind='NATIVE_PARTY' AND link.current_approved AND (link.input->>'enabled')::boolean AND link.context_id<>? AND link.input->>'nativeRole'=? AND link.input->>'nativePartyId'=? AND link.input->>'sourceKind'=? AND goods.input->>'sourceKind'=link.input->>'sourceKind' AND goods.input->>'goodsId'=? AND goods.input->>'colorId' IS NOT DISTINCT FROM CAST(? AS text)",Integer.class,candidate.getValue().toArray());
            if(other>0)throw conflict("该真实单位/来源类型/原料产品颜色已有另一已审分组关系；请先复核撤销原关系或逐源明确归属，不能重复归户");
        }
    }
    private void checkBase(Map<String,Object> e,Proof p){var live=currentEvidence(p.kind(),p.key());if(!Objects.equals(e.get("expected_approved_id"),live==null?null:live.get("id")))throw conflict("已审核版本已变化，请先读取原版本再更正");}
    Map<String,Object> currentEvidence(EvidenceKind kind,String key){var rows=db.queryForList("SELECT * FROM finance_material_evidence WHERE kind=? AND resource_key=? AND current_approved",kind.name(),key);return rows.isEmpty()?null:decodeEvidence(rows.getFirst());}
    List<Map<String,Object>> approved(UUID id){return db.queryForList("SELECT * FROM finance_material_evidence WHERE context_id=? AND current_approved ORDER BY kind,resource_key",id).stream().map(this::decodeEvidence).toList();}
    Map<String,Object> context(UUID id,boolean lock){var rows=db.queryForList("SELECT * FROM finance_material_contexts WHERE id=?"+(lock?" FOR UPDATE":""),id);if(rows.size()!=1)throw missing("原表上下文不存在");return rows.getFirst();}
    ContextInput approvedContext(UUID id){var current=currentEvidence(EvidenceKind.CONTEXT,id.toString());if(current==null)throw invalid("该上下文尚未由另一位财务确认");var proof=validate(current,false);if(!proof.fingerprint().equals(current.get("source_fingerprint")))throw conflict("上下文财务身份依据已变化，请先重新核对");return input(current,ContextInput.class);}
    Map<String,Object> evidenceRow(UUID id,boolean lock){var rows=db.queryForList("SELECT * FROM finance_material_evidence WHERE id=?"+(lock?" FOR UPDATE":""),id);if(rows.size()!=1)throw missing("原表资料草稿不存在");return decodeEvidence(rows.getFirst());}
    Map<String,Object> decodeEvidence(Map<String,Object> e){for(String field:List.of("input","source_snapshot")){Object raw=e.get(field);if(raw!=null&&!(raw instanceof Map))e.put(field,decode(raw.toString()));}e.put("version",e.get("row_version"));return e;}
    Map<String,Object> readContext(UUID id,ReadScope scope){return scope.contexts.computeIfAbsent(id,k->context(k,false));}
    List<Map<String,Object>> approved(UUID id,ReadScope scope){return scope.reviewed.computeIfAbsent(id,k->{var items=approved(k);items.forEach(e->scope.byResource.put(e.get("kind")+":"+e.get("resource_key"),e));return items;});}
    Map<String,Object> reviewed(UUID context,EvidenceKind kind,String key,ReadScope scope){approved(context,scope);return scope.byResource.get(kind+":"+key);}
    void preloadRoutes(Collection<Key> keys,ReadScope scope){
        var missing=keys.stream().filter(k->!scope.readRoutes.contains(k)).toList();for(int offset=0;offset<missing.size();offset+=200){
            var chunk=missing.subList(offset,Math.min(offset+200,missing.size()));var reverse=new HashMap<String,Key>();for(var k:chunk){reverse.put(k.kind()+":"+k.lineId(),k);scope.readRoutes.add(k);}
            for(var row:db.queryForList("SELECT * FROM finance_material_evidence WHERE kind='SOURCE_RELATION' AND current_approved AND resource_key IN("+String.join(",",Collections.nCopies(chunk.size(),"?"))+")",reverse.keySet().toArray())){
                var evidence=decodeEvidence(row);var relation=input(evidence,SourceRelation.class);if(!relation.active())continue;var key=reverse.get(evidence.get("resource_key"));
                boolean valid;try{valid=validate(evidence,false,scope).fingerprint().equals(evidence.get("source_fingerprint"));}catch(ApiException error){valid=false;}
                if(valid)scope.routes.put(key,(UUID)evidence.get("context_id"));else scope.invalidRoutes.add(key);
            }
        }
    }
    boolean owns(UUID contextId,Fact fact){return owns(contextId,fact,new ReadScope());}
    boolean owns(UUID contextId,Fact fact,ReadScope scope){
        preloadRoutes(List.of(fact.key()),scope);if(scope.invalidRoutes.contains(fact.key()))return false;if(scope.routes.containsKey(fact.key()))return Objects.equals(scope.routes.get(fact.key()),contextId);
        if(fact.supplierId()!=null&&fact.customerId()!=null)return false;
        var links=scope.nativeLinks.computeIfAbsent(contextId,id->{var values=new HashSet<String>();for(var e:approved(id,scope))if(e.get("kind").equals("NATIVE_PARTY")){var v=input(e,NativePartyLink.class);if(v.enabled())values.add(v.sourceKind()+":"+v.nativeRole()+":"+v.nativePartyId());}return values;});
        return links.contains(fact.key().kind()+":SUPPLIER:"+fact.supplierId())||links.contains(fact.key().kind()+":CUSTOMER:"+fact.customerId());
    }
    Map<Key,Fact> physicalScope(Map<String,Object> c,Kind kind,LocalDate from,LocalDate to,ReadScope scope){return scope.physicalScopes.computeIfAbsent(c.get("id")+":"+kind+":"+from+":"+to,ignored->{var facts=physicalScope(c,kind,from,to);scope.facts.putAll(facts);preloadRoutes(facts.keySet(),scope);return facts;});}
    Map<Key,Fact> physicalScope(Map<String,Object> c,Kind kind,LocalDate from,LocalDate to){
        var all=new LinkedHashMap<Key,Fact>();var rules=sourceGoods((UUID)c.get("id"),new ReadScope()).stream().filter(rule->rule.sourceKind()==kind).toList();
        if(rules.isEmpty())throw invalid("请先明确此来源类型的实际原料/产物货品和颜色对应");
        for(var rule:rules)for(int page=1;;page++){
            var result=physical.candidates(new Query(kind,null,null,rule.goodsId(),rule.colorId(),from,to,null,page,200,rule.colorId()==null?ColorMode.NO_COLOR:ColorMode.EXACT,false));
            for(var f:result.items())all.put(f.key(),f);if(all.size()>20000)throw invalid("实际来源范围超过20000行，请按真实期间分段");if(page>=result.totalPages())break;
        }return all;
    }
    Fact one(Key key,ReadScope scope){return scope.facts.computeIfAbsent(key,this::one);}
    Fact one(Key key){if(key==null)throw invalid("请明确原始来源行");return physical.readForIdentity(List.of(key)).getFirst();}
    static Effect effect(Fact fact,UUID movement){if(movement==null)throw invalid("请选择一条确切实际入/出库流水，不能把多批合并当一笔");return fact.effects().stream().filter(e->e.movementId().equals(movement)).findFirst().orElseThrow(()->invalid("实际物理切片不存在"));}
    static String unitKey(UUID context,UUID goods,UUID color,UUID unit,String basis,BigDecimal rate){return context+":"+goods+":"+Objects.toString(color,"NONE")+":"+unit+":"+basis+":"+(basis.equals("SOURCE")&&rate!=null?rate.stripTrailingZeros().toPlainString():"BASE");}
    List<SourceGoods> sourceGoods(UUID context,ReadScope scope){return approved(context,scope).stream().filter(e->e.get("kind").equals("GOODS")).map(e->input(e,SourceGoods.class)).filter(SourceGoods::active).toList();}
    SourceGoods requireSource(Map<String,Object> context,Fact f,ReadScope scope){
        if(!f.approved()||!f.identityComplete())throw invalid("原始实际来源缺少完整效应，不能确认归户或加工款");
        return sourceRule(context,f,scope);
    }
    SourceGoods sourceRule(Map<String,Object> context,Fact f,ReadScope scope){
        return sourceGoods((UUID)context.get("id"),scope).stream().filter(rule->rule.sourceKind()==f.key().kind()&&Objects.equals(rule.goodsId(),f.goodsId())&&Objects.equals(rule.colorId(),f.colorId())).findFirst().orElseThrow(()->invalid("请先明确该原料/产物货品及颜色与财务原表分组的对应，不按同名猜配"));
    }

    private static Map<String,Object> grain(Map<String,Object> c){var s=new TreeMap<String,Object>();for(String k:List.of("auxiliary_id","account_code","accounting_currency_id","goods_id","color_id","amount_basis","original_currency_id"))s.put(k,Objects.toString(c.get(k),null));return s;}
    private static Map<String,Object> grain(ContextInput c){var s=new TreeMap<String,Object>();s.put("auxiliary_id",Objects.toString(c.auxiliaryId(),null));s.put("account_code",c.accountCode());s.put("accounting_currency_id",Objects.toString(c.accountingCurrencyId(),null));s.put("goods_id",Objects.toString(c.goodsId(),null));s.put("color_id",Objects.toString(c.colorId(),null));s.put("amount_basis",c.amountBasis().name());s.put("original_currency_id",Objects.toString(c.amountBasis()==AmountBasis.ORIGINAL?c.originalCurrencyId():null,null));return s;}
    private void bump(UUID context){db.update("UPDATE finance_material_contexts SET row_version=row_version+1 WHERE id=?",context);}
    private void lockResource(EvidenceKind kind,String key){lock("resource:"+kind+":"+key);}
    void lock(String key){db.query("SELECT pg_advisory_xact_lock(hashtextextended(?,1005))",r->{},"finance-material:"+key);}
    private Map<String,Object> precisionSnapshot(){var result=new TreeMap<String,Object>();BusinessPrecisionContext.choices().forEach((key,choice)->result.put(key,Map.of("scale",choice.scale(),"rounding",choice.rounding())));return result;}
    <T>T input(Map<String,Object> evidence,Class<T> type){
        Object raw=evidence.get("input");if(evidence.get("source_snapshot") instanceof Map<?,?> snapshot&&snapshot.get("effectiveInput")!=null)raw=snapshot.get("effectiveInput");
        return parse(json.valueToTree(raw),type);
    }
    private static final Set<String> DECIMALS=Set.of("kgPerSourceUnit","pcsPerSourceUnit","balanceWeightKg","actualWeightKg","actualQuantityPcs","amountLocal","amountOriginal","nonprocessingLocal","nonprocessingOriginal","quotedProcessingPrice","referencePrice","sourceUnitRate","unrelatedLocal","unrelatedOriginal");
    private void rejectFloatingInput(JsonNode node){
        if(node.isObject()){node.properties().forEach(e->{if(DECIMALS.contains(e.getKey())&&e.getValue().isFloatingPointNumber()&&!e.getValue().isBigDecimal())throw invalid("金额、重量和换算率须按十进制字符串保留原文，不能通过二进制浮点数传递");rejectFloatingInput(e.getValue());});}
        else if(node.isArray())node.forEach(this::rejectFloatingInput);
    }
    private JsonNode normalizeInput(JsonNode raw){
        var copy=raw.deepCopy();normalizeNode(copy);return copy;
    }
    private void normalizeNode(JsonNode node){
        if(node.isObject()){
            var object=(com.fasterxml.jackson.databind.node.ObjectNode)node;
            var fields=new ArrayList<Map.Entry<String,JsonNode>>();node.properties().forEach(fields::add);
            for(var e:fields){if(DECIMALS.contains(e.getKey())&&!e.getValue().isNull()&&!e.getValue().asText().isBlank()){
                BigDecimal value;try{value=new BigDecimal(e.getValue().asText());}catch(NumberFormatException error){throw invalid("请完成十进制原值后再提交，原草稿已保留");}
                int maximum=Set.of("balanceWeightKg","amountLocal","nonprocessingLocal","unrelatedLocal").contains(e.getKey())?30:24;
                String label=switch(e.getKey()){case "kgPerSourceUnit"->"每原单位折合KG";case "pcsPerSourceUnit"->"每原单位折合PCS";case "balanceWeightKg"->"期初重量KG";case "actualWeightKg"->"实称重量KG";case "actualQuantityPcs"->"实点数量PCS";case "amountLocal"->"加工份额本币";case "amountOriginal"->"加工份额原币";case "nonprocessingLocal"->"明确非加工余项本币";case "nonprocessingOriginal"->"明确非加工余项原币";default->"原加工报价";};
                value=maximum==30?FinancialExactAmount.book(value,label):FinancialExactAmount.require(value,label);object.put(e.getKey(),value.toPlainString());
            }else normalizeNode(e.getValue());}
        }else if(node.isArray())node.forEach(this::normalizeNode);
    }
    <T>T parse(JsonNode input,Class<T> type){try{return json.readerFor(type).with(DeserializationFeature.FAIL_ON_UNKNOWN_PROPERTIES).readValue(input);}catch(Exception e){throw invalid("原表资料字段或十进制原值不完整，请核对本类型输入");}}
    String encode(Object v){try{return json.writer().with(SerializationFeature.ORDER_MAP_ENTRIES_BY_KEYS).writeValueAsString(exact(v));}catch(Exception e){throw new IllegalStateException("财务原表资料无法保存",e);}}
    String hash(Object v){return ImmutableDocumentStore.digest(encode(v).getBytes(StandardCharsets.UTF_8));}
    Map<String,Object> decode(String raw){try{return json.readerFor(new TypeReference<Map<String,Object>>(){}).with(DeserializationFeature.USE_BIG_DECIMAL_FOR_FLOATS).readValue(raw);}catch(Exception e){throw new IllegalStateException("财务原表资料记录损坏",e);}}
    @SuppressWarnings("unchecked") Map<String,Object> exactMap(Map<String,?> v){return (Map<String,Object>)exact(v);}
    private static Object exact(Object v){if(v instanceof BigDecimal n)return n.toPlainString();if(v instanceof Map<?,?> m){var r=new LinkedHashMap<String,Object>();m.forEach((k,x)->r.put(k.toString(),exact(x)));return r;}if(v instanceof Collection<?> l)return l.stream().map(FinanceMaterialStatementService::exact).toList();return v;}
    static BigDecimal decimal(Object v){return v==null?null:new BigDecimal(v.toString());}
    static long version(Map<String,Object> v){return ((Number)v.get("row_version")).longValue();}
    static void requireContext(UUID a,UUID b){if(!Objects.equals(a,b))throw invalid("资料与所选上下文不一致");}
    static void reference(String v){if(v==null||v.isBlank()||v.length()>2000)throw invalid("请明确原单、称重、换算或核对依据（最多2000字）");}
    static void positiveOptional(BigDecimal v,String label){if(v!=null&&FinancialExactAmount.require(v,label).signum()<=0)throw invalid(label+"须为明确正数");}
    static void nonnegative(BigDecimal v,String label){if(v!=null&&FinancialExactAmount.require(v,label).signum()<0)throw invalid(label+"不能为负数");}
    static void conserve(BigDecimal source,List<BigDecimal> parts){
        if(source==null)throw invalid("真实源金额缺失，不能当0");
        FinancialSourceAllocationGuard.singleSource(source,parts);
    }

    static ApiException invalid(String m){return new ApiException(ErrorCode.VALIDATION_FAILED,m);}static ApiException conflict(String m){return new ApiException(ErrorCode.CONFLICT,m);}static ApiException missing(String m){return new ApiException(ErrorCode.NOT_FOUND,m);}
}
