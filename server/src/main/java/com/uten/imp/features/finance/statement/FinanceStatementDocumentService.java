package com.uten.imp.features.finance.statement;

import com.fasterxml.jackson.core.type.TypeReference;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.application.port.*;
import com.uten.imp.common.storage.ImmutableDocumentStore;
import com.uten.imp.common.finance.ChineseMoneyUppercase;
import com.uten.imp.common.util.FinancialExactAmount;
import com.uten.imp.common.web.*;
import com.uten.imp.features.finance.*;
import com.uten.imp.features.finance.gl.FinanceTemplateContract;
import com.uten.imp.security.*;
import jakarta.persistence.EntityManager;
import lombok.RequiredArgsConstructor;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.beans.factory.ObjectProvider;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;
import java.math.BigDecimal;
import java.time.LocalDate;
import java.util.*;
import static com.uten.imp.features.finance.statement.FinanceStatementDocumentContracts.*;

/** Reviewed original print captions and footer facts. This service never changes GL, AP or stock. */
@Service @RequiredArgsConstructor
public class FinanceStatementDocumentService {
    private static final Set<String> TEMPLATES=Set.of("subcontractStatement","supplierStatement","clientStatement","otherReceivableStatement");
    private final JdbcTemplate db;
    private final EntityManager em;
    private final TxSessionVars tx;
    private final SecurityContextCurrentUser current;
    private final ObjectMapper json;
    private final FinanceDocumentAccessPolicy access;
    private final FinanceStatementOriginalSnapshotReader originalSnapshots;
    private final FinanceAuxiliaryLedgerReadPort ledger;
    private final FinancialAuxiliaryValidationPort auxiliary;
    private final ObjectProvider<FinanceStatementService> statements;
    private final ObjectProvider<FinanceMaterialStatementService> materials;
    private final ImmutableDocumentStore documents;
    private final com.uten.imp.common.util.EmployeeNameResolver actorNames;
    private final ObjectProvider<FinancePayableStatementAdjustmentPort> adjustments;
    private final ObjectProvider<FinancePayableClassificationPort> payableClassifications;

    @Transactional(readOnly=true)
    public Map<String,Object> profiles(String kind,String templateKey,String partyRole,UUID partyId,UUID currencyId,int page,int size){
        read();profileIdentity(kind,templateKey,partyRole,partyId,currencyId);int p=Math.max(1,page),s=Math.max(1,Math.min(Pageables.MAX_PAGE_SIZE,size));
        Object[] scope={kind,templateKey,partyRole,partyId,currencyId};String where=" WHERE kind=? AND template_key=? AND party_role IS NOT DISTINCT FROM ?::text AND party_id IS NOT DISTINCT FROM ?::uuid AND currency_id=?";
        long total=db.queryForObject("SELECT count(*) FROM finance_statement_profiles"+where,Long.class,scope);
        var args=new ArrayList<Object>(Arrays.asList(scope));args.add(s);args.add((long)(p-1)*s);
        var rows=db.queryForList("SELECT id,revision,status,source_reference,submitted_by,submitted_name,submitted_at,reviewed_by,reviewed_name,reviewed_at,review_reason FROM finance_statement_profiles"+where+" ORDER BY revision DESC LIMIT ? OFFSET ?",args.toArray());
        return Map.of("items",rows,"page",p,"size",s,"total",total,"totalPages",(total+s-1)/s);
    }

    @Transactional(readOnly=true)
    public Map<String,Object> profile(UUID id){read();var row=profileRow(id,false);return profileView(row);}

    @Transactional
    public Map<String,Object> saveProfile(ProfileSave command){
        read();CurrentAuthorityGuard.requireAll("payment_style:edit");tx.bind();
        if(command==null||command.requestId()==null)throw invalid("请保留本次打印资料提交编号");
        profileIdentity(command.kind(),command.templateKey(),command.partyRole(),command.partyId(),command.currencyId());reference(command.sourceReference());
        Object body;
        if("CONTEXT".equals(command.kind())){if(command.organization()!=null||command.settings()==null)throw invalid("账载与质保资料须使用对应设置内容");validateSettings(command.settings(),command.templateKey(),command.partyRole(),command.partyId(),command.currencyId(),null);body=command.settings();}
        else {if(command.organization()==null||command.settings()!=null)throw invalid("请填写实际组织/联系人/收款资料");validateOrganization(command.organization());body=command.organization();}
        String hash=hash(command);requestLock(command.requestId());
        var replay=db.queryForList("SELECT * FROM finance_statement_profiles WHERE request_id=?",command.requestId());
        if(!replay.isEmpty()){if(!hash.equals(replay.getFirst().get("payload_hash")))throw conflict("这个提交编号已用于不同打印资料，请核对原结果");return profileView(replay.getFirst());}
        db.query("SELECT pg_advisory_xact_lock(hashtextextended(?::text,0))",rs->{},"uten:statement-profile:"+command.kind()+":"+command.templateKey()+":"+command.partyRole()+":"+command.partyId()+":"+command.currencyId());
        Long before=db.queryForObject("SELECT COALESCE(max(revision),-1) FROM finance_statement_profiles WHERE kind=? AND template_key=? AND party_role IS NOT DISTINCT FROM ?::text AND party_id IS NOT DISTINCT FROM ?::uuid AND currency_id=?",Long.class,command.kind(),command.templateKey(),command.partyRole(),command.partyId(),command.currencyId());
        if(before!=command.expectedRevision())throw conflict("打印资料已有另一版本，请重新读取后再提交");
        UUID id=UUID.randomUUID();db.update("""
            INSERT INTO finance_statement_profiles(id,request_id,payload_hash,kind,template_key,party_role,party_id,currency_id,revision,body_cipher,source_reference,status,submitted_by,submitted_name)
            VALUES(?,?,?,?,?,?,?,?,?,?,?,'SUBMITTED',?,?)
            """,id,command.requestId(),hash,command.kind(),command.templateKey(),command.partyRole(),command.partyId(),command.currencyId(),before+1,tx.encrypt(encode(body)),command.sourceReference(),current.requireId(),actorName());
        return profile(id);
    }

    @Transactional
    public Map<String,Object> decideProfile(UUID id,Decision command){
        read();CurrentAuthorityGuard.requireAll("finance_post:execute");tx.bind();if(command==null)throw invalid("请明确资料审核结果");reference(command.reason());var row=profileRow(id,true);
        if(!"SUBMITTED".equals(row.get("status")))throw conflict("此版本已经审核，请核对原结果");
        if(current.requireId().equals(row.get("submitted_by")))throw conflict("打印资料提交人与审核人不可相同");
        if(command.approve()&&"CONTEXT".equals(row.get("kind")))validateSettings(decode(row.get("body_cipher"),Settings.class),row.get("template_key").toString(),row.get("party_role").toString(),(UUID)row.get("party_id"),(UUID)row.get("currency_id"),null);
        db.update("UPDATE finance_statement_profiles SET status=?,reviewed_by=?,reviewed_name=?,reviewed_at=now(),review_reason=? WHERE id=?",command.approve()?"APPROVED":"REJECTED",current.requireId(),actorName(),command.reason(),id);return profile(id);
    }

    @Transactional(readOnly=true)
    public Map<String,Object> metadata(Context context,BigDecimal periodAmount){
        read();context(context);
        var own=latest("OWN","ALL",null,null,context.currencyId());var other=latest("COUNTERPART","ALL",context.partyRole(),context.partyId(),context.currencyId());
        var settingsRow=latest("CONTEXT",context.templateKey(),context.partyRole(),context.partyId(),context.currencyId());
        var ours=own==null?null:decode(own.get("body_cipher"),Organization.class);var theirs=other==null?null:decode(other.get("body_cipher"),Organization.class);
        var settings=settingsRow==null?null:decode(settingsRow.get("body_cipher"),Settings.class);
        String currency=db.queryForObject("SELECT name FROM currencies WHERE id=?",String.class,context.currencyId());
        String party=theirs==null?null:theirs.organizationName();var result=new LinkedHashMap<String,Object>();var lines=new ArrayList<Map<String,Object>>();
        String owner=(context.templateKey().equals("supplierStatement")||context.templateKey().equals("subcontractStatement"))?(theirs==null?null:theirs.organizationName()):(ours==null?null:ours.organizationName());
        String period=context.dateFrom().getYear()==context.dateTo().getYear()&&context.dateFrom().getMonth()==context.dateTo().getMonth()?context.dateTo().getYear()+"年"+context.dateTo().getMonthValue()+"月份":context.dateFrom()+"至"+context.dateTo();
        result.put("version",1);result.put("title",(owner==null?"":owner+" ")+period+"对账单");result.put("partyId",context.partyId());result.put("partyName",party);result.put("currencyId",context.currencyId());result.put("currencyName",currency);result.put("dateFrom",context.dateFrom());result.put("dateTo",context.dateTo());
        result.put("templateKey",context.templateKey());result.put("partyRole",context.partyRole());
        var headerLines=new ArrayList<Map<String,Object>>();boolean supplierForm=context.templateKey().equals("supplierStatement")||context.templateKey().equals("subcontractStatement");
        add(headerLines,"customerName",context.templateKey().equals("supplierStatement")?"客户名称：":"客户：",supplierForm?(ours==null?null:ours.organizationName()):party,"已审核的双方实际名称，往来UUID不按同名猜配",supplierForm?ours==null:party==null);
        if(context.templateKey().equals("supplierStatement"))add(headerLines,"address","地址：",theirs==null?null:theirs.address(),"原对账单出具方已审核地址",theirs==null);
        if(!context.templateKey().equals("subcontractStatement")){
            add(headerLines,"phone","电话：",theirs==null?null:theirs.phone(),"已审核财务联系资料",theirs==null);
            add(headerLines,"fax","传真：",theirs==null?null:theirs.fax(),"已审核财务联系资料",theirs==null);
        }
        result.put("headerLines",headerLines);result.put("organizationName",owner);
        Organization printOwner=supplierForm?theirs:ours;addOrganization(lines,printOwner);
        boolean base=Boolean.TRUE.equals(db.queryForObject("SELECT is_base_currency FROM currencies WHERE id=?",Boolean.class,context.currencyId()));
        String periodLabel=context.templateKey().equals("otherReceivableStatement")?"本月加工费总金额：":context.templateKey().equals("clientStatement")?"本月货款人民币大写金额：":"合计：";
        boolean client=context.templateKey().equals("clientStatement");
        add(lines,"periodAmount",periodLabel,client?(base?uppercase(periodAmount):null):periodAmount==null?null:periodAmount.toPlainString(),"与当前完整原表同源金额合计；不复制样例扣款或尾差。人民币大写只用于真实本位币的精确分",periodAmount==null||client&&(!base||!centExact(periodAmount)));
        result.put("periodAmount",periodAmount==null?null:periodAmount.toPlainString());
        if(base&&context.templateKey().equals("otherReceivableStatement"))
            add(lines,"periodAmountUpper","人民币大写总金额：",uppercase(periodAmount),"按同一精确金额转换；不足分的实际尾差保留原数字并待核，不擅自舍入",periodAmount==null||!centExact(periodAmount));
        BigDecimal closing=null,retained=null;String sourceFingerprint=null,basis="请维护并审核同币账载余额来源";
        if(settings!=null)try{
            validateSettings(settings,context.templateKey(),context.partyRole(),context.partyId(),context.currencyId(),context.dateTo());
            BigDecimal combined=BigDecimal.ZERO;boolean known=true;var sourceHashes=new ArrayList<String>();var bases=new ArrayList<String>();
            for(var selected:settings.balances()){var balance=ledger.read(selected.scope(context.dateFrom(),context.dateTo()));var amounts=selected.originalAmounts()?balance.original():balance.local();if(amounts.closing()==null)known=false;else{combined=combined.add(amounts.closing().multiply(BigDecimal.valueOf(selected.normalDirection())));}sourceHashes.add(selected.originalAmounts()?balance.originalFingerprint():balance.fingerprint());bases.add(selected.accountCode()+"："+balance.basis());}
            closing=known?combined:null;sourceFingerprint=hash(sourceHashes);basis=String.join("；",bases)+"；仅合并明确选择的不同账载科目，不加另一套ERP余额";
            retained=settings.retentions()==null?null:sumRetentions(settings,context.dateTo());
            if(closing==null||retained!=null&&retained.compareTo(closing.max(BigDecimal.ZERO))>0)retained=null;
        }catch(ApiException failure){if(failure.getCode()==ErrorCode.FORBIDDEN)throw failure;basis=failure.getMessage();closing=null;retained=null;}
        add(lines,"closingBalance",context.templateKey().equals("otherReceivableStatement")?"截止本期贵公司应付总金额：":"截止本期往来余额：",closing==null?null:closing.toPlainString(),basis,closing==null);
        if(context.templateKey().equals("clientStatement"))add(lines,"retention","已扣质保金：",retained==null?null:retained.toPlainString(),"原协议/客户扣款依据明确的现有未结款组成；已包含在往来余额内，不再次加额",retained==null);
        add(lines,"printRemark","备注：",settings==null?null:settings.printRemark(),"本张对账表已审核打印备注；样例公司/人名/账号不自动填充",settings==null);
        add(lines,"counterpartConfirmation",context.templateKey().equals("clientStatement")?"客户对账人签名盖章：":"客户确认:",null,"须绑定本次原表SHA的真实确认资料；未确认不填样例签名",true);
        add(lines,"internalConfirmation",context.templateKey().equals("clientStatement")?"供应商对账人签名盖章：":"优腾确认:",null,"独立审核后记录实际审核人，签章需真实资料",true);
        result.put("footerLines",lines);result.put("sourceFingerprint",sourceFingerprint);result.put("profileIds",Arrays.asList(own==null?null:own.get("id"),other==null?null:other.get("id"),settingsRow==null?null:settingsRow.get("id")));
        return result;
    }

    /** Reads all original pages in one repeatable source snapshot; HTTP never supplies editable amounts. */
    @Transactional(readOnly=true,isolation=org.springframework.transaction.annotation.Isolation.REPEATABLE_READ)
    public Map<String,Object> preview(Context context){read();context(context);return snapshot(context);}

    @Transactional(isolation=org.springframework.transaction.annotation.Isolation.REPEATABLE_READ)
    public Map<String,Object> submitReview(ReviewSave command){
        read();if(command==null||command.requestId()==null)throw invalid("请保留本次对账原件提交编号");context(command.context());writeDocument(command.context());tx.bind();requestLock(command.requestId());
        String payload=hash(command);var replay=db.queryForList("SELECT * FROM finance_statement_document_reviews WHERE request_id=?",command.requestId());
        if(!replay.isEmpty()){if(!payload.equals(replay.getFirst().get("payload_hash")))throw conflict("这个提交编号已有另一份原件，请核对原结果");return review((UUID)replay.getFirst().get("id"));}
        var snapshot=snapshot(command.context());String source=snapshot.get("sourceFingerprint").toString();if(!Objects.equals(source,command.expectedSourceFingerprint()))throw conflict("原单、账载余额或打印资料已变化，请重新核对整份原件");
        UUID id=insertReview(command.requestId(),payload,command.context(),snapshot);
        return review(id);
    }

    private UUID insertReview(UUID requestId,String payload,Context c,Map<String,Object> snapshot){
        requireReady(snapshot);var meta=map(snapshot.get("documentMetadata"));var ids=(List<?>)meta.get("profileIds");UUID id=UUID.randomUUID();
        db.update("""
            INSERT INTO finance_statement_document_reviews(id,request_id,payload_hash,template_key,party_role,party_id,currency_id,date_from,date_to,material_context_id,material_all_contexts,
              own_profile_id,counterpart_profile_id,context_profile_id,document_sha256,source_fingerprint,snapshot_cipher,status,submitted_by,submitted_name)
            VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,'SUBMITTED',?,?)
            """,id,requestId,payload,c.templateKey(),c.partyRole(),c.partyId(),c.currencyId(),c.dateFrom(),c.dateTo(),c.materialContextId(),Boolean.TRUE.equals(c.allMaterialContexts()),uuid(ids.get(0)),uuid(ids.get(1)),uuid(ids.get(2)),snapshot.get("documentSha256"),snapshot.get("sourceFingerprint"),tx.encrypt(encode(snapshot)),current.requireId(),actorName());
        return id;
    }

    @Transactional(readOnly=true,isolation=org.springframework.transaction.annotation.Isolation.REPEATABLE_READ)
    public Map<String,Object> previewSettlement(SettlementPreview command){read();return settlementSnapshot(command);}

    @Transactional(isolation=org.springframework.transaction.annotation.Isolation.REPEATABLE_READ)
    public Map<String,Object> submitSettlement(SettlementSave command){
        read();if(command==null||command.requestId()==null||command.source()==null)throw invalid("请保留本次结算原件提交编号和原件来源");
        tx.bind();requestLock(command.requestId());String payload=hash(command);
        var replay=db.queryForList("SELECT * FROM finance_statement_document_reviews WHERE request_id=?",command.requestId());
        if(!replay.isEmpty()){
            var saved=replay.getFirst();writeDocument(reviewContext(saved));
            if(!Objects.equals(current.requireId(),saved.get("submitted_by"))||!payload.equals(saved.get("payload_hash")))throw conflict("此提交编号属于另一份原件或另一账号，请核对原提交");
            return review((UUID)saved.get("id"));
        }
        payableClassifications.getObject().lockForWrite();
        var snapshot=settlementSnapshot(command.source());var context=json.convertValue(snapshot.get("context"),Context.class);writeDocument(context);
        if(!Objects.equals(command.expectedSourceFingerprint(),snapshot.get("sourceFingerprint")))throw conflict("本单已审核手续费或尾数处理已经变化，请重新预览结算原件");
        UUID id=insertReview(command.requestId(),payload,context,snapshot);var version=map(map(snapshot.get("documentMetadata")).get("settlementVersion"));
        db.update("""
            INSERT INTO finance_statement_settlement_versions(review_id,root_review_id,based_review_id,based_source_fingerprint,
              effect_fingerprint,explicitly_no_deductions,source_reference,created_by)
            VALUES(?,?,?,?,?,?,?,?)
            """,id,uuid(version.get("rootReviewId")),command.source().basedReviewId(),command.source().expectedBasedFingerprint(),
            version.get("effectFingerprint"),command.source().explicitlyNoDeductions(),command.source().sourceReference(),current.requireId());
        return review(id);
    }

    private Map<String,Object> settlementSnapshot(SettlementPreview command){
        if(command==null||command.basedReviewId()==null)throw invalid("请选择已由财务确认的本单原件");reference(command.sourceReference());
        var based=reviewRow(command.basedReviewId(),false);Context c=reviewContext(based);
        if(!Set.of("supplierStatement","subcontractStatement").contains(c.templateKey())||!"SUPPLIER".equals(c.partyRole()))throw invalid("结算原件只能对应本单供应商或委外对账单");
        if(!Set.of("INTERNAL_CONFIRMED","BOTH_CONFIRMED").contains(based.get("status"))||!Objects.equals(command.expectedBasedFingerprint(),based.get("source_fingerprint")))throw conflict("所选原件未确认或指纹不一致，请读取这份原件自己的来源");
        var prior=db.queryForList("SELECT root_review_id FROM finance_statement_settlement_versions WHERE review_id=?",command.basedReviewId());
        UUID rootId=prior.isEmpty()?command.basedReviewId():(UUID)prior.getFirst().get("root_review_id");var root=reviewRow(rootId,false);
        if(!Set.of("INTERNAL_CONFIRMED","BOTH_CONFIRMED").contains(root.get("status")))throw conflict("本单基础原件已失效，不能据此生成结算原件");
        var original=decode(root.get("snapshot_cipher"),new TypeReference<Map<String,Object>>(){});
        var effects=new ArrayList<>(adjustments.getObject().readConfirmed(new FinancePayableStatementAdjustmentPort.Context(rootId,root.get("source_fingerprint").toString())));
        if(effects.size()>20000)throw invalid("本单处理记录超过有界范围，请先核对来源，不能截断结算记录");
        effects.sort(Comparator.comparing(effect->effect.lineId().toString()));
        BigDecimal released=BigDecimal.ZERO,stillOwed=BigDecimal.ZERO;int active=0;
        for(var effect:effects)if("APPROVED".equals(effect.status())){
            var amount=new BigDecimal(effect.amountOriginal());if(amount.signum()<0)throw invalid("本单处理金额符号无效，请核对原审批");active++;
            if(effect.decision()==FinancePayableStatementAdjustmentPort.Decision.RELEASED)released=released.add(amount);else stillOwed=stillOwed.add(amount);
        }
        if(command.explicitlyNoDeductions()&&active>0)throw conflict("本单已有已审核处理，不能同时声明无扣款");
        if(!command.explicitlyNoDeductions()&&active==0)throw invalid("请先完成本单处理审批，或明确选择本次没有手续费及尾数扣款");
        var metadata=new LinkedHashMap<>(map(original.get("documentMetadata")));Object rawAmount=metadata.get("periodAmount");
        if(rawAmount==null)throw invalid("基础原件本期金额未知，不能以整户余额替代");
        BigDecimal period=new BigDecimal(rawAmount.toString()),deduction=released.add(stillOwed);
        if(deduction.compareTo(period.max(BigDecimal.ZERO))>0)throw invalid("本单扣款超过基础原件的正向本期金额，请按真实单据重新核对");
        BigDecimal net=period.subtract(deduction);String effectFingerprint=hash(effects);
        var version=new LinkedHashMap<String,Object>();version.put("rootReviewId",rootId);version.put("rootSourceFingerprint",root.get("source_fingerprint"));
        version.put("rootDocumentSha256",root.get("document_sha256"));version.put("basedReviewId",command.basedReviewId());version.put("effectFingerprint",effectFingerprint);
        version.put("effects",effects);version.put("releasedOriginal",released.toPlainString());version.put("stillOwedOriginal",stillOwed.toPlainString());
        version.put("netOriginal",net.toPlainString());version.put("explicitlyNoDeductions",command.explicitlyNoDeductions());version.put("sourceReference",command.sourceReference());
        metadata.put("settlementVersion",version);
        var footer=new ArrayList<Map<String,Object>>();for(Object line:(List<?>)metadata.get("footerLines"))if(!Set.of("settlementNet","settlementAdjustmentBasis").contains(map(line).get("key")))footer.add(new LinkedHashMap<>(map(line)));
        String basis="基础原件本期金额减本单已审核扣款；仍欠与不再欠分别保留。不是扣除既往付款后的当前未付余额；原件旧SHA及原账载时点不改";
        add(footer,"settlementNet","合计：",net.toPlainString(),basis,false);
        add(footer,"settlementAdjustmentBasis","本次约定扣款：",active==0?"无额外扣款；"+command.sourceReference():"仍欠 "+stillOwed.toPlainString()+"；不再欠 "+released.toPlainString()+"；"+command.sourceReference(),basis,false);
        metadata.put("footerLines",footer);metadata.putAll(com.uten.imp.features.finance.report.FinanceStatementPaperLayout.metadata(c.templateKey(),metadata));
        var result=new LinkedHashMap<>(original);result.remove("sourceFingerprint");result.remove("documentSha256");result.put("documentMetadata",metadata);
        return sealSnapshot(result);
    }

    @Transactional(readOnly=true)
    public Map<String,Object> reviews(Context context,int page,int size){
        read();context(context);int p=Math.max(1,page),s=Math.max(1,Math.min(Pageables.MAX_PAGE_SIZE,size));String where=" WHERE template_key=? AND party_role=? AND party_id=? AND currency_id=? AND date_from=? AND date_to=? AND material_context_id IS NOT DISTINCT FROM ?::uuid AND material_all_contexts=?";
        Object[] scope={context.templateKey(),context.partyRole(),context.partyId(),context.currencyId(),context.dateFrom(),context.dateTo(),context.materialContextId(),Boolean.TRUE.equals(context.allMaterialContexts())};
        long total=db.queryForObject("SELECT count(*) FROM finance_statement_document_reviews"+where,Long.class,scope);var args=new ArrayList<Object>(Arrays.asList(scope));args.add(s);args.add((long)(p-1)*s);
        var rows=db.queryForList("SELECT id,status,document_sha256,source_fingerprint,submitted_by,submitted_name,submitted_at,approved_by,approved_name,approved_at,review_reason,counterpart_name,counterpart_confirmed_date FROM finance_statement_document_reviews"+where+" ORDER BY submitted_at DESC,id LIMIT ? OFFSET ?",args.toArray());
        return Map.of("items",rows,"page",p,"size",s,"total",total,"totalPages",(total+s-1)/s);
    }

    @Transactional(readOnly=true)
    public Map<String,Object> review(UUID id){
        read();
        if(org.springframework.transaction.support.TransactionSynchronizationManager.isCurrentTransactionReadOnly()){
            // The same immutable reader serves the original table and every
            // read-only source/choice consumer. Reauthorize and bind current
            // confirmation metadata on every hit; never cache authority.
            var row=new LinkedHashMap<>(reviewSummaryRow(id));
            row.put("original",originalSnapshot(id,row));row.put("confirmationMetadata",confirmations(row));return row;
        }
        // Command response construction must retain the original write path:
        // a read-cache admission limit cannot roll back a business mutation.
        var row=new LinkedHashMap<>(reviewRow(id,false));var original=decode(row.remove("snapshot_cipher"),new TypeReference<Map<String,Object>>(){});
        row.remove("counterpart_file_provider");row.remove("counterpart_file_key");row.remove("counterpart_file_version");row.put("original",original);row.put("confirmationMetadata",confirmations(row));return row;
    }

    /** Public review/confirmation facts only, without fetching/decrypting all
     * original rows. The old full detail endpoint remains for command recovery. */
    @Transactional(readOnly=true)
    public Map<String,Object> reviewSummary(UUID id){
        read();var row=new LinkedHashMap<>(reviewSummaryRow(id));
        row.put("confirmationMetadata",confirmations(row));return row;
    }

    @Transactional(isolation=org.springframework.transaction.annotation.Isolation.REPEATABLE_READ)
    public Map<String,Object> decideReview(UUID id,Decision command){
        read();if(command==null)throw invalid("请明确原件审核结果");reference(command.reason());tx.bind();lockSettlementVersion(id);var row=reviewRow(id,true);Context c=reviewContext(row);writeDocument(c);
        if(!"SUBMITTED".equals(row.get("status")))throw conflict("这份原件已处理，请核对原状态");if(current.requireId().equals(row.get("submitted_by")))throw conflict("对账原件提交人与审核人不可相同");
        if(command.approve())requireUnchanged(row,c);
        db.update("UPDATE finance_statement_document_reviews SET status=?,approved_by=?,approved_name=?,approved_at=now(),review_reason=? WHERE id=?",command.approve()?"INTERNAL_CONFIRMED":"REJECTED",current.requireId(),actorName(),command.reason(),id);return review(id);
    }

    @Transactional(isolation=org.springframework.transaction.annotation.Isolation.REPEATABLE_READ)
    public Map<String,Object> confirmCounterpart(UUID id,CounterpartConfirmation command,String filename,String contentType,byte[] bytes){
        read();if(command==null)throw invalid("请填写这份原件的实际对方确认资料");reference(command.sourceReference());reference(command.signatoryName());
        if(command.confirmedDate()==null||command.confirmedDate().isAfter(com.uten.imp.common.time.BusinessTime.today()))throw invalid("请填写真实已发生的对方确认日期");
        tx.bind();lockSettlementVersion(id);var row=reviewRow(id,true);Context c=reviewContext(row);writeDocument(c);
        String fileHash=ImmutableDocumentStore.digest(bytes==null?new byte[0]:bytes);
        if("BOTH_CONFIRMED".equals(row.get("status"))){if(Objects.equals(command.documentSha256(),row.get("document_sha256"))&&Objects.equals(command.signatoryName(),row.get("counterpart_name"))&&Objects.equals(command.confirmedDate(),date(row.get("counterpart_confirmed_date")))&&Objects.equals(command.sourceReference(),row.get("counterpart_source_reference"))&&Objects.equals(filename,row.get("counterpart_file_name"))&&Objects.equals(contentType,row.get("counterpart_file_content_type"))&&Objects.equals(fileHash,row.get("counterpart_file_sha256")))return review(id);throw conflict("这份原件已有另一份确认资料，不能覆盖");}
        if(!"INTERNAL_CONFIRMED".equals(row.get("status"))||!Objects.equals(command.documentSha256(),row.get("document_sha256")))throw conflict("请先完成内部审核，并选择完全相同原件SHA的实际确认件");
        requireUnchanged(row,c);
        if(bytes==null||bytes.length==0)throw invalid("请上传实际签名/盖章确认件，不能用文本替代真实签章");
        if(filename==null||filename.isBlank()||filename.length()>240||filename.chars().anyMatch(Character::isISOControl))throw invalid("确认件原文件名无效");
        var reference=documents.save("FINANCE_STATEMENT_CONFIRMATION",filename,contentType,bytes);
        db.update("""
            UPDATE finance_statement_document_reviews SET status='BOTH_CONFIRMED',counterpart_name=?,counterpart_confirmed_date=?,counterpart_received_by=?,counterpart_received_name=?,counterpart_received_at=now(),counterpart_source_reference=?,counterpart_file_name=?,counterpart_file_content_type=?,
              counterpart_file_provider=?,counterpart_file_key=?,counterpart_file_version=?,counterpart_file_size=?,counterpart_file_sha256=? WHERE id=?
            """,command.signatoryName(),command.confirmedDate(),current.requireId(),actorName(),command.sourceReference(),filename,contentType,reference.provider(),reference.key(),reference.version(),reference.size(),reference.sha256(),id);
        return review(id);
    }

    @Transactional(readOnly=true)
    public byte[] counterpartFile(UUID id){read();var row=reviewRow(id,false);if(!"BOTH_CONFIRMED".equals(row.get("status")))throw invalid("这份原件尚未保存实际对方确认件");return documents.read(new ImmutableDocumentStore.Reference(row.get("counterpart_file_provider").toString(),row.get("counterpart_file_key").toString(),Objects.toString(row.get("counterpart_file_version"),null),((Number)row.get("counterpart_file_size")).longValue(),row.get("counterpart_file_sha256").toString()));}
    @Transactional(readOnly=true)public String counterpartFilename(UUID id){read();return Objects.toString(reviewRow(id,false).get("counterpart_file_name"),"statement-confirmation-"+id+".bin");}

    /** The original frozen rows plus separately recorded real confirmations, for the same preview/export writer. */
    @Transactional(readOnly=true)
    public com.uten.imp.features.finance.report.ReportTableResponse originalTableFor(String variant,UUID id,LocalDate from,LocalDate to,UUID partyId,UUID currencyId,int page,int size){
        return originalTableFor(variant,id,from,to,partyId,currencyId,page,size,null);
    }
    @Transactional(readOnly=true)
    public com.uten.imp.features.finance.report.ReportTableResponse originalTableFor(String variant,UUID id,LocalDate from,LocalDate to,UUID partyId,UUID currencyId,int page,int size,UUID materialContextId){
        return originalTableFor(variant,id,from,to,partyId,currencyId,page,size,materialContextId,null);
    }
    @Transactional(readOnly=true)
    public com.uten.imp.features.finance.report.ReportTableResponse originalTableFor(String variant,UUID id,LocalDate from,LocalDate to,UUID partyId,UUID currencyId,int page,int size,UUID materialContextId,Boolean allMaterialContexts){
        var result=originalTable(id,page,size);var meta=result.documentMetadata();
        String expected=switch(variant){case "supplier"->"supplierStatement";case "subcontract"->"subcontractStatement";case "client"->"clientStatement";case "other-receivable"->"otherReceivableStatement";default->throw invalid("所选原件不能套用其他报表");};
        if(!expected.equals(meta.get("templateKey"))||from!=null&&!from.toString().equals(Objects.toString(meta.get("dateFrom"),null))||to!=null&&!to.toString().equals(Objects.toString(meta.get("dateTo"),null))
                ||partyId!=null&&!partyId.toString().equals(Objects.toString(meta.get("partyId"),null))||currencyId!=null&&!currencyId.toString().equals(Objects.toString(meta.get("currencyId"),null))
                ||materialContextId!=null&&!materialContextId.toString().equals(Objects.toString(meta.get("materialContextId"),null))
                ||allMaterialContexts!=null&&!allMaterialContexts.equals(meta.get("allMaterialContexts")))
            throw conflict("所选对象、币别、期间或报表与这份冻结原件不一致，请打开原件自己的范围");
        return result;
    }
    @Transactional(readOnly=true)
    public com.uten.imp.features.finance.report.ReportTableResponse originalTable(UUID id,int page,int size){
        var reviewed=reviewSummary(id);var original=originalSnapshot(id,reviewed);var rows=(List<?>)original.get("rows");int p=Math.max(1,page),s=Math.max(1,Math.min(com.uten.imp.common.web.CompleteReadBatchPlan.MAX_BATCH_SIZE,size));
        var columns=json.convertValue(original.get("columns"),new TypeReference<List<com.uten.imp.features.finance.report.ReportColumn>>(){});
        var totals=json.convertValue(original.get("totals"),new TypeReference<List<com.uten.imp.common.report.ReportTotal>>(){});
        int start=(int)Math.min(rows.size(),(long)(p-1)*s),end=Math.min(rows.size(),start+s);var data=new ArrayList<Map<String,Object>>();for(Object row:rows.subList(start,end)){
            var projection=new LinkedHashMap<String,Object>(map(row));
            com.uten.imp.common.report.ReportQueryKit.includeFrozenDecimalTexts(projection);data.add(projection);
        }
        var meta=new LinkedHashMap<>(map(original.get("documentMetadata")));meta.put("reviewId",id);meta.put("documentSha256",reviewed.get("document_sha256"));meta.put("reviewStatus",reviewed.get("status"));meta.put("confirmationMetadata",reviewed.get("confirmationMetadata"));
        meta.put("preparedBy",reviewed.get("submitted_name"));
        meta.put("issuedDate",chinaDate(reviewed.get("submitted_at")));
        meta.put("templateKey",reviewed.get("template_key"));meta.put("partyRole",reviewed.get("party_role"));
        var confirmation=map(reviewed.get("confirmationMetadata"));var footer=new ArrayList<Map<String,Object>>();
        for(Object value:(List<?>)meta.get("footerLines")){var line=new LinkedHashMap<>(map(value));
            boolean counter=line.get("key").equals("counterpartConfirmation"),internal=line.get("key").equals("internalConfirmation");
            if(counter&&Boolean.TRUE.equals(confirmation.get("counterpartConfirmed"))){line.put("value","已收确认件："+confirmation.get("counterpartName")+"，"+confirmation.get("counterpartDate"));line.put("pending",false);line.put("basis","签章以本次绑定原件SHA的实际回传文件为准，不复制旧图或生成手写签名");}
            if(internal&&Boolean.TRUE.equals(confirmation.get("internalConfirmed"))){line.put("value","审核记录："+confirmation.get("internalName")+"，"+confirmation.get("internalDate"));line.put("pending",false);line.put("basis","实际系统审核记录；真实签章以回传确认件为准，不伪造盖章");}
            footer.add(line);
        }meta.put("footerLines",footer);
        meta.putAll(com.uten.imp.features.finance.report.FinanceStatementPaperLayout.metadata(reviewed.get("template_key").toString(),meta));
        return new com.uten.imp.features.finance.report.ReportTableResponse(columns,data,Map.of(),p,s,rows.size(),(rows.size()+s-1)/s,totals).withDocumentMetadata(meta);
    }

    private static Map<String,Object> confirmations(Map<String,Object> row){
        var result=new LinkedHashMap<String,Object>();boolean internal=Set.of("INTERNAL_CONFIRMED","BOTH_CONFIRMED").contains(row.get("status"));boolean both="BOTH_CONFIRMED".equals(row.get("status"));
        result.put("version",1);result.put("documentSha256",row.get("document_sha256"));result.put("internalConfirmed",internal);result.put("internalName",internal?row.get("approved_name"):null);result.put("internalDate",internal?chinaDate(row.get("approved_at")):null);result.put("internalConfirmedAt",internal?row.get("approved_at"):null);
        result.put("counterpartConfirmed",both);result.put("counterpartName",both?row.get("counterpart_name"):null);result.put("counterpartDate",both?row.get("counterpart_confirmed_date"):null);result.put("counterpartFileSha256",both?row.get("counterpart_file_sha256"):null);
        result.put("basis","系统记录实际审核人/账号；对方姓名来自本次实际回传件接收记录，不生成或复制手写签章");return result;
    }

    private static String chinaDate(Object value){
        if(value==null)return null;var zone=java.time.ZoneId.of("Asia/Shanghai");
        if(value instanceof java.sql.Timestamp timestamp)return timestamp.toInstant().atZone(zone).toLocalDate().toString();
        if(value instanceof java.time.OffsetDateTime timestamp)return timestamp.atZoneSameInstant(zone).toLocalDate().toString();
        if(value instanceof java.time.Instant timestamp)return timestamp.atZone(zone).toLocalDate().toString();
        if(value instanceof java.sql.Date date)return date.toLocalDate().toString();
        if(value instanceof LocalDate date)return date.toString();
        try{return java.time.OffsetDateTime.parse(value.toString()).atZoneSameInstant(zone).toLocalDate().toString();}
        catch(java.time.format.DateTimeParseException ignored){try{return LocalDate.parse(value.toString()).toString();}catch(java.time.format.DateTimeParseException invalid){return null;}}
    }

    private Map<String,Object> snapshot(Context context){
        var rows=new ArrayList<Map<String,Object>>();com.uten.imp.features.finance.report.ReportTableResponse first=null;int page=1,pages;
        if(context.templateKey().equals("otherReceivableStatement")){
            var source=materials.getObject();
            var material=Boolean.TRUE.equals(context.allMaterialContexts())?source.snapshotFromAnchorCohort(context.materialContextId(),context.dateFrom(),context.dateTo()):source.snapshot(context.materialContextId(),context.dateFrom(),context.dateTo());
            first=composeMaterialTable(material,context.materialContextId(),context.partyId(),context.currencyId(),context.dateFrom(),context.dateTo(),Boolean.TRUE.equals(context.allMaterialContexts()));
            if(first.total()>20000||first.total()!=first.rows().size())throw invalid("材料原件快照未包含完整有界来源，请按原资料重新核对");
            rows.addAll(first.rows());
        }else do{
                var part=originalPage(context,page,500);if(first==null){first=part;}rows.addAll(part.rows());pages=part.totalPages();
                if(rows.size()>20000||part.total()>20000)throw invalid("对账原件超过20000行，请按实际对象/期间分批核对，原报表/任务导出仍可查询完整来源");page++;
            }while(page<=pages);
        BigDecimal total=FinanceStatementTemplate.periodAmount(context.templateKey(),first.totals(),first.total());var meta=new LinkedHashMap<String,Object>(first.documentMetadata());
        if(!context.templateKey().equals("otherReceivableStatement"))meta.putAll(metadata(context,total));
        var original=new LinkedHashMap<String,Object>();original.put("context",context);original.put("columns",first.columns());original.put("rows",rows);original.put("totals",first.totals());original.put("documentMetadata",meta);
        // Monetary JSON is decimal text even after a read/restore; binary Double never becomes the frozen source.
        return sealSnapshot(original);
    }
    private Map<String,Object> sealSnapshot(Map<String,Object> original){
        var safe=jsonSafe(original);String fingerprint=hash(safe);var result=new LinkedHashMap<String,Object>(map(safe));result.put("sourceFingerprint",fingerprint);result.put("documentSha256",hash(result));return result;
    }
    private com.uten.imp.features.finance.report.ReportTableResponse originalPage(Context c,int page,int size){
        var service=statements.getObject();return switch(c.templateKey()){
            case "supplierStatement"->service.supplierStatement(null,c.dateFrom(),c.dateTo(),c.partyId(),c.currencyId(),page,size,com.uten.imp.features.finance.report.FinanceReportColumnOptions.NONE);
            case "subcontractStatement"->service.subcontractStatement(null,c.dateFrom(),c.dateTo(),null,c.partyId(),c.currencyId(),page,size,com.uten.imp.features.finance.report.FinanceReportColumnOptions.NONE);
            case "clientStatement"->service.clientStatement(null,c.dateFrom(),c.dateTo(),c.partyId(),c.currencyId(),page,size,com.uten.imp.features.finance.report.FinanceReportColumnOptions.NONE);
            case "otherReceivableStatement"->currentMaterialTable(c.materialContextId(),c.partyId(),c.currencyId(),null,c.dateFrom(),c.dateTo(),page,size,com.uten.imp.features.finance.report.FinanceReportColumnOptions.NONE,Boolean.TRUE.equals(c.allMaterialContexts()));
            default->throw invalid("其他应收原件须先维护真实来料/其它出库及加工款上下文，不能沿用委外拼接数据");
        };
    }
    /** The same approved material source supplies the old route, task export and frozen original. */
    @Transactional(readOnly=true,isolation=org.springframework.transaction.annotation.Isolation.REPEATABLE_READ)
    public com.uten.imp.features.finance.report.ReportTableResponse currentMaterialTable(UUID materialContextId,UUID partyId,UUID actualCurrencyId,
            String keyword,LocalDate from,LocalDate to,int page,int size,com.uten.imp.features.finance.report.FinanceReportColumnOptions options){
        return currentMaterialTable(materialContextId,partyId,actualCurrencyId,keyword,from,to,page,size,options,true);
    }
    @Transactional(readOnly=true,isolation=org.springframework.transaction.annotation.Isolation.REPEATABLE_READ)
    public com.uten.imp.features.finance.report.ReportTableResponse currentMaterialTable(UUID materialContextId,UUID partyId,UUID actualCurrencyId,
            String keyword,LocalDate from,LocalDate to,int page,int size,com.uten.imp.features.finance.report.FinanceReportColumnOptions options,boolean allMaterialContexts){
        read();if(materialContextId==null)throw invalid("请先选择已明确对应的材料对账资料");
        var source=materials.getObject();
        var table=allMaterialContexts?source.reportFromAnchorCohort(materialContextId,keyword,from,to,page,size,options):source.report(materialContextId,keyword,from,to,page,size,options);
        return composeMaterialTable(table,materialContextId,partyId,actualCurrencyId,from,to,allMaterialContexts);
    }
    private com.uten.imp.features.finance.report.ReportTableResponse composeMaterialTable(com.uten.imp.features.finance.report.ReportTableResponse table,
            UUID materialContextId,UUID partyId,UUID actualCurrencyId,LocalDate from,LocalDate to,boolean allMaterialContexts){
        var source=table.documentMetadata();UUID actualParty=uuid(source.get("partyId")),paperCurrency=uuid(source.get("actualCurrencyId"));
        if(partyId!=null&&!partyId.equals(actualParty)||actualCurrencyId!=null&&!actualCurrencyId.equals(paperCurrency)
                ||source.get("materialContextId")!=null&&!materialContextId.toString().equals(source.get("materialContextId").toString())
                ||source.get("materialAnchorContextId")!=null&&!materialContextId.toString().equals(source.get("materialAnchorContextId").toString()))
            throw invalid("材料资料与所选实际往来或纸面币别不一致，请按已审核来源选择");
        if(actualParty==null||paperCurrency==null)throw invalid("材料资料尚未明确实际往来或纸面币别");
        var scope=new Context("otherReceivableStatement",Objects.toString(source.get("partyRole"),""),actualParty,paperCurrency,from,to,materialContextId,allMaterialContexts);
        var meta=new LinkedHashMap<String,Object>(source);meta.put("materialContextId",materialContextId);meta.put("materialSourceFingerprint",source.get("sourceFingerprint"));
        meta.put("allMaterialContexts",allMaterialContexts);
        meta.putAll(metadata(scope,FinanceStatementTemplate.periodAmount(scope.templateKey(),table.totals(),table.total())));
        String owner=Objects.toString(meta.get("organizationName"),"");
        String period=from.getYear()==to.getYear()&&from.getMonth()==to.getMonth()?to.getYear()+"年"+to.getMonthValue()+"月份":from+"至"+to;
        meta.put("title",owner+"\n"+period+"对账单");
        var headings=new ArrayList<Map<String,Object>>();
        for(Object raw:(List<?>)meta.get("headerLines")){var line=new LinkedHashMap<>(map(raw));if("customerName".equals(line.get("key"))){line.put("label"," TO: ");}headings.add(line);}
        meta.put("headerLines",headings);
        var footer=new ArrayList<Map<String,Object>>();
        BigDecimal adjusted=materialAmount(source.get("processingAdjustedTotal")),weight=materialAmount(source.get("closingWeightKg"));
        String adjustmentBasis=Objects.toString(source.get("processingAdjustmentBasis"),"须以已审核的真实工费调整来源核对；不默认除0.87，不把客户税点当作增值税");
        for(Object raw:(List<?>)meta.get("footerLines")){
            var line=new LinkedHashMap<>(map(raw));String key=Objects.toString(line.get("key"),"");
            if(!Set.of("periodAmount","closingBalance","printRemark","counterpartConfirmation","internalConfirmation").contains(key))continue;
            if(key.equals("closingBalance"))line.put("label","截止"+to.getYear()+"年"+to.getMonthValue()+"月"+to.getDayOfMonth()+"日贵公司应付总金额：");
            footer.add(line);
            if(key.equals("periodAmount")){
                add(footer,"adjustedProcessingAmount","含税加工费金额",adjusted==null?null:adjusted.toPlainString(),adjustmentBasis,adjusted==null);
                boolean yuan=Boolean.TRUE.equals(db.queryForObject("SELECT is_base_currency FROM currencies WHERE id=?",Boolean.class,paperCurrency));
                add(footer,"periodAmountUpper","人民币大写总金额：",yuan?uppercase(adjusted):null,
                    yuan?"原F41大写对应D42实际调整后金额；"+adjustmentBasis:"纸面实际币别不是本位币，不将账簿币别属性当成人民币金额",!yuan||adjusted==null||!centExact(adjusted));
            }
            if(key.equals("closingBalance"))add(footer,"closingMaterialWeight","总欠金本材料",weight==null?null:weight.toPlainString(),Objects.toString(source.get("lossBasis"),"同一原表的KG结余汇总"),weight==null);
        }
        meta.put("footerLines",footer);
        meta.put("paperTotals",FinanceStatementTemplate.paperTotals(table.totals()));
        meta.putAll(com.uten.imp.features.finance.report.FinanceStatementPaperLayout.metadata("otherReceivableStatement",meta));
        return table.withDocumentMetadata(meta);
    }
    private static BigDecimal materialAmount(Object raw){
        if(raw==null)return null;
        try{return raw instanceof BigDecimal decimal?decimal:new BigDecimal(raw.toString());}
        catch(NumberFormatException invalid){throw invalid("材料原表金额或重量不是有效原始数值");}
    }
    private void lockSettlementVersion(UUID id){
        if(!db.queryForList("SELECT review_id FROM finance_statement_settlement_versions WHERE review_id=?",id).isEmpty())payableClassifications.getObject().lockForWrite();
    }
    private void requireUnchanged(Map<String,Object> source,Context c){
        var versions=db.queryForList("SELECT * FROM finance_statement_settlement_versions WHERE review_id=?",source.get("id"));
        var now=versions.isEmpty()?snapshot(c):settlementSnapshot(new SettlementPreview((UUID)versions.getFirst().get("based_review_id"),
            versions.getFirst().get("based_source_fingerprint").toString(),Boolean.TRUE.equals(versions.getFirst().get("explicitly_no_deductions")),versions.getFirst().get("source_reference").toString()));
        requireReady(now);if(!Objects.equals(now.get("sourceFingerprint"),source.get("source_fingerprint")))throw conflict("原单、账载余额、受审打印资料或本单扣款已经变化，旧原件保留；请重建另一版本再确认");
    }
    private static void requireReady(Map<String,Object> snapshot){
        for(var row:(List<?>)snapshot.get("rows"))if(Boolean.TRUE.equals(map(row).get("__pending")))throw invalid("原件仍有未核验来源行，请先按原单处理，不把未知金额确认成零");
        var metadata=map(snapshot.get("documentMetadata"));if(metadata.get("periodAmount")==null)throw invalid("完整原表合计尚未核验，不能冻结一页合计或猜金额");
        var ids=(List<?>)metadata.get("profileIds");if(ids.get(0)==null||ids.get(1)==null||ids.get(2)==null)throw invalid("请先维护并审核双方真实抬头与账载/质保来源资料");
        for(var value:(List<?>)metadata.get("footerLines")){var line=map(value);if(Set.of("partyName","closingBalance","retention","adjustedProcessingAmount","closingMaterialWeight").contains(line.get("key"))&&Boolean.TRUE.equals(line.get("pending")))throw invalid("原件末尾仍有待核验项目："+line.get("label"));}
    }
    // Explicit lean columns are intentional: to_jsonb(row)-'snapshot_cipher'
    // would still read the large TOAST ciphertext before subtracting its key.
    private static final String REVIEW_PUBLIC_COLUMNS="id,request_id,payload_hash,template_key,party_role,party_id,currency_id,date_from,date_to,"
        +"own_profile_id,counterpart_profile_id,context_profile_id,document_sha256,source_fingerprint,status,submitted_by,submitted_name,submitted_at,"
        +"approved_by,approved_name,approved_at,review_reason,counterpart_name,counterpart_confirmed_date,counterpart_received_by,counterpart_received_name,"
        +"counterpart_received_at,counterpart_source_reference,counterpart_file_name,counterpart_file_content_type,counterpart_file_size,counterpart_file_sha256,"
        +"material_context_id,material_all_contexts";
    private Map<String,Object> reviewSummaryRow(UUID id){
        var rows=db.queryForList("SELECT "+REVIEW_PUBLIC_COLUMNS+" FROM finance_statement_document_reviews WHERE id=?",id);
        if(rows.size()!=1)throw invalid("对账原件版本不存在");return rows.getFirst();
    }
    private Map<String,Object> originalSnapshot(UUID id,Map<String,Object> reviewed){
        var realm=db.queryForMap("SELECT business_dataset_id,business_reset_generation FROM authorization_state WHERE singleton_id=1");
        UUID dataset=uuid(realm.get("business_dataset_id"));Object rawGeneration=realm.get("business_reset_generation");
        if(dataset==null||!(rawGeneration instanceof Number generation)||generation.longValue()<0)
            throw new ApiException(ErrorCode.PRIMARY_UNAVAILABLE,"数据集读取范围信息不可用");
        var key=new FinanceStatementOriginalSnapshotReader.Key(dataset,generation.longValue(),id,
            Objects.requireNonNull(reviewed.get("document_sha256")).toString(),Objects.requireNonNull(reviewed.get("source_fingerprint")).toString(),1);
        return originalSnapshots.read(key,()->{
            var values=db.queryForList("SELECT snapshot_cipher FROM finance_statement_document_reviews WHERE id=? AND document_sha256=? AND source_fingerprint=?",
                id,key.documentSha256(),key.sourceFingerprint());
            if(values.size()!=1)throw conflict("原件身份已变化，请重新打开核对");
            return Objects.requireNonNull(values.getFirst().get("snapshot_cipher")).toString();
        });
    }
    private Map<String,Object> reviewRow(UUID id,boolean lock){var rows=db.queryForList("SELECT * FROM finance_statement_document_reviews WHERE id=?"+(lock?" FOR UPDATE":""),id);if(rows.size()!=1)throw invalid("对账原件版本不存在");return rows.getFirst();}
    private static Context reviewContext(Map<String,Object> row){return new Context(row.get("template_key").toString(),row.get("party_role").toString(),(UUID)row.get("party_id"),(UUID)row.get("currency_id"),date(row.get("date_from")),date(row.get("date_to")),(UUID)row.get("material_context_id"),(Boolean)row.get("material_all_contexts"));}
    private static LocalDate date(Object value){return value==null?null:value instanceof java.sql.Date d?d.toLocalDate():value instanceof LocalDate d?d:LocalDate.parse(value.toString());}
    private static UUID uuid(Object value){return value==null?null:value instanceof UUID id?id:UUID.fromString(value.toString());}
    private void writeDocument(Context c){CurrentAuthorityGuard.requireAll(c.templateKey().equals("supplierStatement")||c.templateKey().equals("subcontractStatement")?"supplier_settlement:confirm":"finance_receipt:approve");}
    @SuppressWarnings("unchecked") private static Map<String,Object> map(Object value){return (Map<String,Object>)value;}
    private Object jsonSafe(Object value){
        if(value==null||value instanceof String||value instanceof Boolean||value instanceof Integer||value instanceof Long)return value;
        if(value instanceof BigDecimal number)return number.toPlainString();if(value instanceof UUID||value instanceof java.time.temporal.TemporalAccessor)return value.toString();
        if(value instanceof java.math.BigInteger)return value.toString();
        if(value instanceof Number number){if(number instanceof Double d&&!Double.isFinite(d)||number instanceof Float f&&!Float.isFinite(f))throw invalid("原表含非有限数字，不能冻结");return number.toString();}
        if(value instanceof Enum<?> e)return e.name();
        if(value instanceof Map<?,?> input){var out=new LinkedHashMap<String,Object>();input.forEach((key,v)->out.put(key.toString(),jsonSafe(v)));return out;}
        if(value instanceof Collection<?> input)return input.stream().map(this::jsonSafe).toList();
        if(value.getClass().isRecord()){var out=new LinkedHashMap<String,Object>();try{for(var component:value.getClass().getRecordComponents()){out.put(component.getName(),jsonSafe(component.getAccessor().invoke(value)));}return out;}catch(ReflectiveOperationException error){throw new IllegalStateException("原表记录快照无法读取",error);}}
        return jsonSafe(json.convertValue(value,new TypeReference<Map<String,Object>>(){}));
    }

    private void validateSettings(Settings value,String template,String role,UUID party,UUID currency,LocalDate asOf){
        if(value.balance()==null||value.balances().size()>20)throw invalid("请选择1至20个不重复的同币账载余额来源");var identities=new HashSet<String>();
        for(var b:value.balances()){
        if(b==null||b.normalDirection()!=1&&b.normalDirection()!=-1)throw invalid("请选择完整账载余额及其正常借贷方向");
        if(b.originalAmounts()!=value.balance().originalAmounts())throw invalid("同一原件不能混加本币账面与原币金额，即使显示币名相同");
        if(!identities.add(b.accountCode()+":"+b.auxiliaryId()+":"+b.accountingCurrencyId()+":"+(b.originalAmounts()?b.originalCurrencyId():"LOCAL")))throw invalid("同一账载余额来源不能重复相加");
        int expected=template.equals("clientStatement")||template.equals("otherReceivableStatement")?1:-1;
        if(b.normalDirection()!=expected)throw invalid("本张原表的应收/应付方向与所选余额方向不一致，不能反转金额凑数");
        var selection=new FinancialAuxiliaryValidationPort.Selection(b.accountCode(),b.auxiliaryId(),b.accountingCurrencyId());
        var ref=asOf==null?auxiliary.inspect(selection):auxiliary.inspectHistorical(selection);
        if(ref==null||!Objects.equals(ref.partyId(),party)||!Objects.equals(ref.role(),role))throw invalid("余额科目辅助必须明确对应这一个真实往来对象和类别");
        if(b.originalAmounts()){if(!Objects.equals(b.originalCurrencyId(),currency))throw invalid("原币余额单位必须与原表真实币别相同");}
        else if(!Boolean.TRUE.equals(db.queryForObject("SELECT is_base_currency FROM currencies WHERE id=? AND NOT is_deleted",Boolean.class,currency)))throw invalid("本币账面余额只能打印在权威本位币原表，不能贴成外币");
        if(db.queryForObject("SELECT count(*) FROM finance_chart_codes WHERE code=? AND classification IN('ASSET','LIABILITY')",Integer.class,b.accountCode())!=1)throw invalid("往来余额来源须先明确为资产/负债类别，不能把收入或费用当作往来余额");
        }
        if(value.retentions()!=null){if(value.retentions().size()>100)throw invalid("每个版本最多维护100项质保组成，请按实际协议分组");for(var r:value.retentions()){if(r.effectiveFrom()==null||r.amount()==null||r.amount().signum()<0)throw invalid("质保组成须有实际起点和非负金额");if(value.balance().originalAmounts())FinancialExactAmount.require(r.amount(),"质保原币");else{FinancialExactAmount.book(r.amount(),"质保本币");}reference(r.sourceReference());}}
        if(value.printRemark()!=null&&value.printRemark().length()>4000)throw invalid("打印备注最多4000字");
    }
    private static BigDecimal sumRetentions(Settings settings,LocalDate asOf){return settings.retentions()==null?BigDecimal.ZERO:settings.retentions().stream().filter(r->!r.effectiveFrom().isAfter(asOf)).map(Retention::amount).reduce(BigDecimal.ZERO,BigDecimal::add);}
    private static void addOrganization(List<Map<String,Object>> lines,Organization org){
        add(lines,"address","地址：",org==null?null:org.address(),"已审核实际打印资料",org==null);
        add(lines,"phone","电话：",org==null?null:org.phone(),"财务明确维护的联系电话，不取HR敏感字段",org==null);
        add(lines,"fax","传真：",org==null?null:org.fax(),"已审核实际打印资料",org==null);
        add(lines,"bankHolder","收款户名：",org==null?null:org.bankHolder(),"财务明确维护并审核的实际收款资料",org==null);
        add(lines,"bankName","开户行：",org==null?null:org.bankName(),"财务明确维护并审核的实际收款资料",org==null);
        add(lines,"bankAccount","收款账户：",org==null?null:org.bankAccount(),"完整收款账号须明确审核，不从仅尾号字段推断",org==null);
        add(lines,"receiver","收货方：",org==null?null:org.receiver(),"已审核实际打印资料",org==null);
        add(lines,"receiverPhone","联系电话：",org==null?null:org.receiverPhone(),"已审核实际打印资料",org==null);
    }
    private static void add(List<Map<String,Object>> lines,String key,String label,Object value,String basis,boolean pending){var row=new LinkedHashMap<String,Object>();row.put("key",key);row.put("label",label);row.put("value",value);row.put("basis",basis);row.put("pending",pending||value==null);lines.add(row);}
    private void profileIdentity(String kind,String template,String role,UUID party,UUID currency){
        if(!Set.of("OWN","COUNTERPART","CONTEXT").contains(Objects.toString(kind,""))||currency==null)throw invalid("请选择打印资料类型和明确币别");
        if("CONTEXT".equals(kind)){if(!TEMPLATES.contains(Objects.toString(template,"")))throw invalid("请选择原对账单入口");}else if(!"ALL".equals(template))throw invalid("组织/收款资料使用共用资料范围，不另造入口名称");
        if("OWN".equals(kind)){if(role!=null||party!=null)throw invalid("本方资料不关联另一往来对象");}
        else if(party==null||role==null||!Set.of("CUSTOMER","SUPPLIER","EMPLOYEE","OTHER").contains(Objects.toString(role,"")))throw invalid("请选择真实往来对象及辅助类别");
        else {String table=switch(role){case "CUSTOMER"->"clients";case "SUPPLIER"->"suppliers";case "EMPLOYEE"->"employees";default->"finance_auxiliary_parties";};String deleted=role.equals("OTHER")?"":" AND NOT is_deleted";if(db.queryForObject("SELECT count(*) FROM "+table+" WHERE id=?"+deleted,Integer.class,party)!=1)throw invalid("所选实际往来对象不存在或已删除");}
        if(db.queryForObject("SELECT count(*) FROM currencies WHERE id=? AND NOT is_deleted",Integer.class,currency)!=1)throw invalid("币别不存在");
    }
    private void context(Context c){if(c==null||c.dateFrom()==null||c.dateTo()==null||c.dateFrom().isAfter(c.dateTo()))throw invalid("请选择完整对账期间");profileIdentity("CONTEXT",c.templateKey(),c.partyRole(),c.partyId(),c.currencyId());if(c.templateKey().equals("otherReceivableStatement")?(c.materialContextId()==null):c.materialContextId()!=null)throw invalid("材料原件须保留自己的已审核资料编号，不能套用其他原表");if(!c.templateKey().equals("otherReceivableStatement")&&!Objects.equals(c.partyRole(),c.templateKey().equals("clientStatement")?"CUSTOMER":"SUPPLIER"))throw invalid("本张原对账单与往来类别不一致");}
    private static void validateOrganization(Organization o){for(String text:Arrays.asList(o.organizationName(),o.address(),o.phone(),o.fax(),o.bankHolder(),o.bankName(),o.bankAccount(),o.receiver(),o.receiverPhone(),o.printRemark())){if(text!=null&&text.length()>4000)throw invalid("打印资料单项最多4000字");}if(o.organizationName()==null||o.organizationName().isBlank())throw invalid("请填写实际组织名称");}
    private Map<String,Object> latest(String kind,String template,String role,UUID party,UUID currency){var rows=db.queryForList("SELECT * FROM finance_statement_profiles WHERE kind=? AND template_key=? AND party_role IS NOT DISTINCT FROM ?::text AND party_id IS NOT DISTINCT FROM ?::uuid AND currency_id=? AND status='APPROVED' ORDER BY revision DESC LIMIT 1",kind,template,role,party,currency);return rows.isEmpty()?null:rows.getFirst();}
    private Map<String,Object> profileRow(UUID id,boolean lock){var rows=db.queryForList("SELECT * FROM finance_statement_profiles WHERE id=?"+(lock?" FOR UPDATE":""),id);if(rows.size()!=1)throw invalid("打印资料版本不存在");return rows.getFirst();}
    private Map<String,Object> profileView(Map<String,Object> source){var row=new LinkedHashMap<>(source);Object body=row.remove("body_cipher");row.put("body",decode(body,new TypeReference<Map<String,Object>>(){}));return row;}
    private <T>T decode(Object value,Class<T> type){try{return com.uten.imp.common.finance.FinancialJsonResults.value(json,tx.decrypt(value.toString()),type);}catch(Exception e){throw conflict("打印资料历史版本无法读取，请核对原密钥和版本");}}
    private <T>T decode(Object value,TypeReference<T> type){try{return com.uten.imp.common.finance.FinancialJsonResults.value(json,tx.decrypt(value.toString()),type);}catch(Exception e){throw conflict("打印资料历史版本无法读取，请核对原密钥和版本");}}
    private String encode(Object value){try{return json.writeValueAsString(value);}catch(Exception e){throw invalid("打印资料无法保存");}}
    private String hash(Object value){return ImmutableDocumentStore.digest(encode(value).getBytes(java.nio.charset.StandardCharsets.UTF_8));}
    private void requestLock(UUID id){db.query("SELECT pg_advisory_xact_lock(hashtextextended('uten:statement-document-request:'||?::text,0))",rs->{},id);}
    private void read(){CurrentAuthorityGuard.requireAll("finance_report:view");FinanceCompanyReportAccess.require(access);}
    private String actorName(){String name=current.employeeId().map(actorNames::nameOf).orElse(null);return name==null||name.isBlank()?"账号："+current.get().orElseThrow().getLoginAccount():name;}
    private static void reference(String value){if(value==null||value.isBlank()||value.length()>4000)throw invalid("请填写实际来源/审核依据，最多4000字");}
    private static boolean centExact(BigDecimal value){return value!=null&&Math.max(0,value.stripTrailingZeros().scale())<=2;}
    /** Never round financial evidence to make a money-in-words field look complete. */
    static String uppercase(BigDecimal value){if(!centExact(value))return null;return ChineseMoneyUppercase.format(value);}
    private static ApiException invalid(String value){return new ApiException(ErrorCode.VALIDATION_FAILED,value);}
    private static ApiException conflict(String value){return new ApiException(ErrorCode.CONFLICT,value);}
}
