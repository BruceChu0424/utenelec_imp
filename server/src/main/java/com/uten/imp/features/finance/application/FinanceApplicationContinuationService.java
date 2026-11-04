package com.uten.imp.features.finance.application;

import com.fasterxml.jackson.core.type.TypeReference;
import com.fasterxml.jackson.databind.DeserializationFeature;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.application.port.*;
import com.uten.imp.common.util.FinancialExactAmount;
import com.uten.imp.common.web.*;
import com.uten.imp.security.*;
import lombok.RequiredArgsConstructor;
import org.springframework.beans.factory.ObjectProvider;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;
import java.math.BigDecimal;
import java.time.*;
import java.util.*;
import static com.uten.imp.features.finance.application.FinanceApplicationContinuationContracts.*;

/** The only bridge from an original six-form draft to current native authority.
 * Review is immutable; confirmation only creates a draft, never an approval,
 * payment, stock event or GL entry. The original command stays byte-for-byte. */
@Service @RequiredArgsConstructor
public class FinanceApplicationContinuationService {
    private final JdbcTemplate db;
    private final ObjectMapper json;
    private final FinanceApplicationService originals;
    private final FinanceApplicationLegacyPolicy legacy;
    private final FinanceApplicationRoles roles;
    private final FinanceApplicationExpensePort expenses;
    private final AttachmentEvidencePort evidence;
    private final ObjectProvider<NativeApplicationContinuationPort> targets;
    private final SecurityContextCurrentUser current;
    private final TxSessionVars tx;

    private record Source(UUID applicationId,String kind,long version,String fingerprint,
            String title,String requestedDate,UUID currency,BigDecimal amount,UUID supplier,
            String nature,Map<String,Object> original,Map<String,Object> payload,
            UUID expenseId,Long expenseVersion,String expenseFingerprint,Map<String,Object> nativeFacts,
            List<AttachmentLinkedEvidencePort.Frozen> attachments,List<Map<String,String>> obligations) { }

    @Transactional
    public Map<String,Object> review(Review input){
        var actor=writer();if(input==null||input.originId()==null)throw invalid("请保留本机原稿编号");
        originals.originLock(input.originId());requestLock(input.originalRequestId());
        var mapped=mapping(input.originId());if(mapped!=null)return continued(mapped,actor);
        var source=source(input,actor,true);
        var draft=proposed(source,input);
        var target=target(source.expenseId()==null?"BUSINESS_APPLICATION":"EXPENSE_CLAIM");
        if(!target.canContinueDraft(draft,actor))throw new ApiException(ErrorCode.FORBIDDEN,"当前账号无权按该来源继续申请");
        target.validateDraft(draft);
        UUID token=UUID.randomUUID();Instant expires=Instant.now().plus(Duration.ofMinutes(20));
        db.update("""
          INSERT INTO finance_application_continuation_reviews(id,origin_id,original_application_id,actor_id,
            actor_employee_id,actor_session_id,original_request_id,source_version,source_fingerprint,original_command,
            original_snapshot,native_source_snapshot,attachment_snapshot,target_kind,target_business_kind,target_id,
            proposed_input,expires_at)
          VALUES(?,?,?,?,?,?,?,?,?,?,?::jsonb,?::jsonb,?::jsonb,?,?,?,?::jsonb,?)
          """,token,input.originId(),source.applicationId(),actor.getId(),actor.getEmployeeId(),actor.getSessionId(),
                input.originalRequestId(),source.version(),source.fingerprint(),input.originalCommand(),encode(source.original()),
                encode(source.nativeFacts()),encode(source.attachments()),target.targetType(),draft.businessKind(),draft.targetId(),
                encode(draft),java.sql.Timestamp.from(expires));
        var out=new LinkedHashMap<String,Object>();out.put("reviewId",token);out.put("originId",input.originId());
        out.put("reviewedFingerprint",source.fingerprint());out.put("expiresAt",expires.toString());out.put("original",source.original());
        out.put("nativeSource",source.nativeFacts());out.put("attachments",source.attachments());out.put("proposed",draft);
        out.put("targetType",target.targetType());out.put("originalRequestResolved",true);out.put("createsDraftOnly",true);
        return out;
    }

    @Transactional
    public Map<String,Object> confirm(Confirm input){
        var actor=writer();if(input==null||input.requestId()==null||input.reviewId()==null)throw invalid("请保留审阅和本次确认编号");
        var reviews=db.queryForList("SELECT * FROM finance_application_continuation_reviews WHERE id=?",input.reviewId());
        if(reviews.isEmpty())throw conflict("原审阅不存在，请保留输入重新审阅");var review=reviews.getFirst();
        if(!actor.getId().equals(review.get("actor_id"))||!Objects.equals(actor.getSessionId(),review.get("actor_session_id")))throw new ApiException(ErrorCode.FORBIDDEN,"请由同一申请人会话确认已审阅的原稿");
        UUID origin=(UUID)review.get("origin_id");originals.originLock(origin);requestLock((UUID)review.get("original_request_id"));
        var mapped=mapping(origin);if(mapped!=null){if(!input.reviewId().equals(mapped.get("review_id")))throw conflict("该原稿已通过另一审阅接续，请查询原接续回执");return continued(mapped,actor);}
        if(!Objects.equals(input.reviewedFingerprint(),review.get("source_fingerprint")))throw conflict("确认内容与原审阅不一致，请重新审阅");
        if(((java.sql.Timestamp)review.get("expires_at")).toInstant().isBefore(Instant.now()))throw conflict("审阅已过期，请重新核对原稿；当前输入已保留");
        var old=decode(review.get("original_snapshot"));
        var recheck=new Review(origin,(UUID)review.get("original_request_id"),(String)review.get("original_command"),
                ((Number)review.get("source_version")).longValue(),null,Map.of(),null,null,uuid(old.get("reviewedCurrencyId")));
        var source=source(recheck,actor,true);
        if(!source.fingerprint().equals(review.get("source_fingerprint")))throw conflict("原稿、来源或凭证已变化，请重新审阅；本次未建立当前申请");
        var draft=convert(review.get("proposed_input"),NativeApplicationContinuationPort.Draft.class);
        var target=target(review.get("target_kind").toString());
        if(!target.canContinueDraft(draft,actor))throw new ApiException(ErrorCode.FORBIDDEN,"当前申请权限已变化");
        var frozen=source.attachments();
        if(!evidence.frozenEvidenceReady(frozen))throw conflict("原稿凭证已变化或尚未安全可用；本次未接续");
        // Freeze the exact group first. The native reader sees it only after the
        // mapping is inserted below in this same transaction.
        for(var item:frozen)db.update("INSERT INTO finance_application_continued_originals(review_id,attachment_id,owner_type,owner_id,sha256,attachment_name) VALUES(?,?,?,?,?,?)",
                input.reviewId(),item.id(),item.ownerType(),item.ownerId(),item.sha256(),item.originalName());
        // Mapping precedes the target update so the same real expense is read
        // under current native authority. Any target validation failure rolls all back.
        db.update("""
          INSERT INTO finance_application_native_mappings(origin_id,review_id,original_application_id,original_kind,
            native_kind,native_id,native_business_kind,source_fingerprint,original_currency_id,amount_basis,original_amount,
            original_obligations,actor_id,actor_employee_id,request_id)
          VALUES(?,?,?,?,?,?,?,?,?,?,?,?::jsonb,?,?,?)
          """,origin,input.reviewId(),source.applicationId(),source.kind(),target.targetType(),draft.targetId(),draft.businessKind(),
                source.fingerprint(),source.currency(),source.amount()==null?"NOT_APPLICABLE":"ORIGINAL",source.amount(),encode(source.obligations()),
                actor.getId(),actor.getEmployeeId(),input.requestId());
        var result=target.continueDraft(draft);
        return result(result,origin);
    }

    @Transactional(readOnly=true)
    public Map<String,Object> receipt(UUID origin){var actor=roles.staff();var mapped=mapping(origin);if(mapped==null)return Map.of("found",false);return continued(mapped,actor);}

    private Source source(Review input,AuthUser actor,boolean lock){
        var rows=db.queryForList("SELECT to_jsonb(app)::text AS snapshot FROM finance_applications app WHERE id=?",input.originId());
        Map<String,Object> app=null,payload;String kind,title,date,nature=null;UUID currency=null,supplier=null,expense=null;
        BigDecimal amount=null;long version=-1;UUID appId=null;Map<String,Object> nativeFacts=Map.of();Long expenseVersion=null;String expenseFingerprint=null;
        var original=new LinkedHashMap<String,Object>();
        if(!rows.isEmpty()){
            var currentRow=lock?originals.lockSourceAndRow(input.originId()):originals.row(input.originId(),false);
            originals.owner(currentRow,actor);originals.editable(currentRow);legacy.requireEditableOriginal(currentRow);
            version=((Number)currentRow.get("row_version")).longValue();
            if(input.expectedVersion()==null||input.expectedVersion()!=version)throw conflict("原稿版本已变化，请刷新审阅，不覆盖原输入");
            app=decode(db.queryForObject("SELECT to_jsonb(app)::text FROM finance_applications app WHERE id=?",String.class,input.originId()));
            appId=input.originId();kind=app.get("kind").toString();title=app.get("title").toString();date=Objects.toString(app.get("requested_date"),null);
            payload=asMap(app.get("requested_payload"));
            if(input.originalCommand()!=null&&!input.originalCommand().isBlank()){
                var declared=convert(input.originalCommand(),FinanceApplicationContracts.DraftInput.class);
                if(!input.originId().equals(declared.id())||input.originalRequestId()==null||!input.originalRequestId().equals(declared.requestId()))throw invalid("保留原正文与原稿、原请求编号不一致");
                var receipts=db.queryForList("SELECT actor_id,payload_hash,operation FROM finance_application_operations WHERE request_id=?",input.originalRequestId());
                if(!receipts.isEmpty()){
                    var receipt=receipts.getFirst();String expected=originals.digest(List.of("SAVE",input.originId(),declared));
                    if(!actor.getId().equals(receipt.get("actor_id"))||!"SAVE".equals(receipt.get("operation"))||!expected.equals(receipt.get("payload_hash")))throw conflict("该原请求已有不同内容或动作的回执，不能替换原正文");
                }
                var declaredPayload=originals.payload(declared,FinanceApplicationCatalog.kind(kind));
                if(!Objects.equals(declared.title(),app.get("title"))||!Objects.equals(declared.requestedDate(),date)
                        ||!json.valueToTree(declaredPayload).equals(json.valueToTree(payload)))throw conflict("本机尚有未保存内容与服务端原稿不同，请先核对原请求并保存原草稿后重新审阅；当前正文仍保留");
                original.put("declaredCommand",decode(input.originalCommand()));
            }
            var facts=originals.source(currentRow);amount=facts.amount();currency=facts.currency();nativeFacts=facts.facts();
            // A missing plan amount is inapplicable. An actually stored zero or
            // estimate remains that value; it is never reclassified as missing.
            if("TRAVEL_APPLICATION".equals(kind)&&currentRow.get("amount_original") instanceof BigDecimal stored){
                amount=FinancialExactAmount.require(stored,"原出差申请金额");currency=(UUID)currentRow.get("currency_id");
            }
            original.put("applicationNo",app.get("application_no"));original.put("header",app);
            if("EXPENSE_CLAIM".equals(app.get("source_kind")))expense=uuid(app.get("source_id"));
        }else{
            if(input.expectedVersion()!=null&&input.expectedVersion()!=-1)throw conflict("原稿在服务端不存在，请核对原请求回执");
            if(input.originalCommand()==null||input.originalCommand().isBlank()||input.originalCommand().length()>1_000_000)throw invalid("请完整保留本机原请求正文，不能从显示值重建");
            FinanceApplicationContracts.DraftInput command=convert(input.originalCommand(),FinanceApplicationContracts.DraftInput.class);
            if(!input.originId().equals(command.id())||input.originalRequestId()==null||!input.originalRequestId().equals(command.requestId()))throw invalid("原稿、原请求编号和保留正文不一致");
            if(!db.queryForList("SELECT request_id FROM finance_application_operations WHERE request_id=? OR application_id=?",input.originalRequestId(),input.originId()).isEmpty())throw conflict("原请求已有服务端处理记录，请先查询原回执，不得改写原请求继续");
            var originalKind=FinanceApplicationCatalog.kind(command.kind());if(originalKind==FinanceApplicationCatalog.Kind.PAYROLL_PAYMENT)throw invalid("工资付款保留独立原事实流程");
            kind=originalKind.name();payload=originals.payload(command,originalKind);title=FinanceApplicationService.text(command.title(),200,"申请事由");date=FinanceApplicationService.date(command.requestedDate(),"申请日期").toString();
            if(title.isBlank())throw invalid("原申请事由不能为空");
            if(Set.of("REIMBURSEMENT","TRAVEL_REIMBURSEMENT").contains(kind))expense=command.sourceId();
            if(Set.of("PAYMENT_APPLICATION","PREPAYMENT_APPLICATION").contains(kind)){currency=command.currencyId();amount=sum(payload);}
            original.put("applicationNo","本机原稿");original.put("declaredCommand",decode(input.originalCommand()));
        }
        if("PAYROLL_PAYMENT".equals(kind))throw invalid("工资付款保留独立原事实流程");
        if(expense!=null){
            var claim=expenses.source(expense,lock);if(!originals.same(claim.applicantId(),actor.getEmployeeId())||!Set.of("DRAFT","REJECTED").contains(claim.status()))throw conflict("原报销不是本人可编辑草稿，请先核对原审批和付款状态");
            expenseVersion=db.queryForObject("SELECT version FROM expense_claims WHERE id=?",Long.class,expense);
            expenseFingerprint=claim.fingerprint();currency=claim.currencyId();amount=claim.amount();nativeFacts=claim.facts();
        }else if(Set.of("REIMBURSEMENT","TRAVEL_REIMBURSEMENT").contains(kind))throw invalid("请保留同一张明确的原报销来源");
        nature=Objects.toString(payload.get("paymentNature"),"");supplier=uuid(payload.get("supplierId"));
        var obligations=new ArrayList<Map<String,String>>();
        if("SUPPLIER_AP".equals(nature))for(Object item:(List<?>)payload.get("lines")){var line=asMap(item);obligations.add(Map.of("ledgerId",line.get("appliedLedgerId").toString(),"amountOriginal",line.get("amountOriginal").toString()));}
        UUID originalCurrency=currency;
        if(input.reviewedCurrencyId()!=null){
            if(amount==null)throw invalid("原出差申请没有金额，本次币别不适用，不能补成一笔金额");
            if(currency!=null&&!currency.equals(input.reviewedCurrencyId()))throw invalid("原稿已有明确币别，不能在接续中替换");
            if(currency==null){
                if(!"TRAVEL_APPLICATION".equals(kind)||db.queryForObject("SELECT count(*) FROM currencies WHERE id=? AND NOT is_deleted AND status='使用'",Integer.class,input.reviewedCurrencyId())!=1)throw invalid("请明确选择原稿金额对应的在用币别");
                currency=input.reviewedCurrencyId();original.put("reviewedCurrencyId",currency);original.put("currencyEvidence","REVIEW_COMPLETION");
            }
        }
        original.put("originalCurrencyId",originalCurrency);
        original.put("kind",kind);original.put("title",title);original.put("requestedDate",date);original.put("payload",payload);
        original.put("currencyId",currency);original.put("amountOriginal",amount==null?null:amount.toPlainString());original.put("amountBasis",amount==null?"NOT_APPLICABLE":"ORIGINAL");
        if(amount!=null){
            if(currency==null)throw conflict("原申请币别没有明确依据，请先核对原稿，不能默认本币");
            var currencyRow=db.queryForMap("SELECT code,name,is_base_currency FROM currencies WHERE id=?",currency);
            original.put("currencyCode",currencyRow.get("code"));original.put("currencyName",currencyRow.get("name"));original.put("baseCurrency",currencyRow.get("is_base_currency"));
        }
        var attachments=attachments(appId,expense,lock);
        if(!attachments.isEmpty()&&(!actor.getPermissions().contains("attachment:view")||!actor.getPermissions().contains("attachment:download")))
            throw new ApiException(ErrorCode.FORBIDDEN,"审阅原件须具备原稿凭证查看与下载权限；原稿和当前输入均保留");
        var versioned=new LinkedHashMap<String,Object>();versioned.put("original",original);versioned.put("nativeFacts",nativeFacts);versioned.put("expenseVersion",expenseVersion);versioned.put("attachments",attachments);
        return new Source(appId,kind,version,originals.digest(versioned),title,date,currency,amount,supplier,nature,original,payload,
                expense,expenseVersion,expenseFingerprint,nativeFacts,attachments,obligations);
    }

    private NativeApplicationContinuationPort.Draft proposed(Source source,Review review){
        var fields=new LinkedHashMap<String,String>();if(review.fields()!=null)fields.putAll(review.fields());
        String business=null;
        if(source.expenseId()==null){
            business=switch(source.kind()){
                case "TRAVEL_APPLICATION"->"TRAVEL";
                case "PREPAYMENT_APPLICATION"->"PREPAYMENT";
                case "PAYMENT_APPLICATION"->switch(source.nature()){
                    case "SUPPLIER_AP"->"SUPPLIER_PAYMENT";case "SUPPLIER_PREPAYMENT"->"PREPAYMENT";case "GENERAL_EXPENSE"->"PAYMENT";
                    default->Objects.toString(review.selectedBusinessKind(),"");};
                default->throw invalid("原申请来源类型不能接续当前行政财务申请");};
            if(!Set.of("TRAVEL","PAYMENT","PREPAYMENT","SUPPLIER_PAYMENT").contains(business))throw invalid("请明确审阅真实付款性质后选择当前申请类别");
            if(review.selectedBusinessKind()!=null&&!business.equals(review.selectedBusinessKind()))throw invalid("所选当前流程与原稿明确付款性质不一致");
            fields.putIfAbsent("reason",Objects.toString(source.payload().get("travelPurpose"),source.title()));
            fields.putIfAbsent("remark",Objects.toString(source.payload().get("remark"),""));
            if("TRAVEL".equals(business)){copy(fields,"destination",source.payload(),"destination");copy(fields,"startDate",source.payload(),"travelStart");copy(fields,"endDate",source.payload(),"travelEnd");}
            if(Set.of("PREPAYMENT","SUPPLIER_PAYMENT").contains(business)){
                if(source.supplier()==null)throw invalid("原供应商来源未明确，请先核对原稿");
                if(fields.containsKey("supplierId")&&!source.supplier().toString().equals(fields.get("supplierId")))throw invalid("不能用另一供应商替换原义务");
                fields.put("supplierId",source.supplier().toString());
            }
        }
        UUID travel=review.travelApplicationId();String travelSource=review.travelApplicationSourceKind();
        if("TRAVEL_REIMBURSEMENT".equals(source.kind())&&travel==null){
            var header=asMap(source.original().get("header"));var local=asMap(source.original().get("declaredCommand"));
            travel=uuid(header.isEmpty()?local.get("travelApplicationId"):header.get("travel_application_id"));
            if(travel!=null)travelSource="FINANCE_APPLICATION";
        }
        return new NativeApplicationContinuationPort.Draft(source.expenseId()==null?UUID.randomUUID():source.expenseId(),business,source.title(),
                source.amount()==null?null:source.amount().toPlainString(),fields,source.expenseId(),source.expenseVersion(),source.expenseFingerprint(),
                source.expenseId()==null?null:source.kind(),travel,travelSource);
    }

    private List<AttachmentLinkedEvidencePort.Frozen> attachments(UUID app,UUID expense,boolean lock){
        // Lock owning headers before attachment inspection, matching public
        // delete/category order. Confirmation also checks every frozen member.
        var result=new ArrayList<AttachmentLinkedEvidencePort.Frozen>();
        if(app!=null)result.addAll(attachmentGroup("FINANCE_APPLICATION",app,lock));
        if(expense!=null)result.addAll(attachmentGroup("EXPENSE_CLAIM",expense,lock));
        result.sort(Comparator.comparing(item->item.id().toString()));return List.copyOf(result);
    }
    private List<AttachmentLinkedEvidencePort.Frozen> attachmentGroup(String type,UUID id,boolean lock){
        var rows=db.queryForList("SELECT id,owner_type,owner_id,sha256,original_name,lifecycle_state,delete_requested_at FROM attachments WHERE owner_type=? AND owner_id=? ORDER BY id"+(lock?" FOR SHARE":""),type,id);
        var result=new ArrayList<AttachmentLinkedEvidencePort.Frozen>();for(var row:rows){
            if(row.get("delete_requested_at")!=null)continue;
            if(!"CLEAN".equals(row.get("lifecycle_state"))||row.get("sha256")==null)throw conflict("原稿仍有未完成安全核验的凭证，请核对后重新审阅");
            result.add(new AttachmentLinkedEvidencePort.Frozen((UUID)row.get("id"),type,id,row.get("sha256").toString(),Objects.toString(row.get("original_name"),"")));
        }return result;
    }
    private Map<String,Object> mapping(UUID origin){var rows=db.queryForList("SELECT * FROM finance_application_native_mappings WHERE origin_id=?",origin);return rows.isEmpty()?null:rows.getFirst();}
    private Map<String,Object> continued(Map<String,Object> mapped,AuthUser actor){
        var target=target(mapped.get("native_kind").toString());UUID id=(UUID)mapped.get("native_id");
        if(!actor.getId().equals(mapped.get("actor_id"))||!target.mayRead(id,actor))throw new ApiException(ErrorCode.NOT_FOUND,"原稿接续记录不在当前查阅范围内");
        return result(target.read(id),(UUID)mapped.get("origin_id"));
    }
    private Map<String,Object> result(NativeApplicationContinuationPort.Result value,UUID origin){var out=new LinkedHashMap<String,Object>();out.put("found",true);out.put("originId",origin);out.put("targetType",value.targetType());out.put("id",value.id());out.put("location",value.location());out.put("current",value.current());out.put("createsDraftOnly",true);return out;}
    private NativeApplicationContinuationPort target(String type){return targets.orderedStream().filter(port->port.targetType().equals(type)).findFirst().orElseThrow(()->conflict("当前来源接续能力尚不可用"));}
    private AuthUser writer(){var actor=roles.staff();if(actor.getImpersonatedBy()!=null)throw new ApiException(ErrorCode.IMPERSONATION_READ_ONLY);tx.bind();return actor;}
    private void requestLock(UUID id){if(id!=null)db.query("SELECT pg_advisory_xact_lock(hashtextextended(?,7111))",rs->{},"finance-application-operation:"+id);}
    private BigDecimal sum(Map<String,Object> payload){BigDecimal total=BigDecimal.ZERO;for(Object item:(List<?>)payload.get("lines")){total=total.add(new BigDecimal(asMap(item).get("amountOriginal").toString()));}return FinancialExactAmount.require(total,"原申请合计");}
    private void copy(Map<String,String> fields,String key,Map<String,Object> source,String sourceKey){String value=Objects.toString(source.get(sourceKey),"");if(fields.containsKey(key)&&!value.equals(fields.get(key)))throw invalid("原出差日期和地点须保留，请回原稿修订后重新审阅");fields.put(key,value);}
    private UUID uuid(Object value){return value==null||value.toString().isBlank()?null:UUID.fromString(value.toString());}
    private Map<String,Object> asMap(Object value){if(value==null)return Map.of();return json.convertValue(value,new TypeReference<LinkedHashMap<String,Object>>(){});}
    private Map<String,Object> decode(Object value){try{return exactJson().readValue(value.toString(),new TypeReference<LinkedHashMap<String,Object>>(){});}catch(Exception bad){throw conflict("保留原稿无法完整读取，请勿用显示值重建");}}
    private <T>T convert(Object value,Class<T> type){try{return exactJson().readValue(value.toString(),type);}catch(Exception bad){throw invalid("原稿或审阅内容无法完整读取");}}
    private ObjectMapper exactJson(){return json.copy().enable(DeserializationFeature.USE_BIG_DECIMAL_FOR_FLOATS);}
    private String encode(Object value){return originals.encode(value);}
    private static ApiException invalid(String value){return new ApiException(ErrorCode.VALIDATION_FAILED,value);}
    private static ApiException conflict(String value){return new ApiException(ErrorCode.CONFLICT,value);}
}
