package com.uten.imp.features.finance.gl;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.fasterxml.jackson.databind.JsonNode;
import com.uten.imp.application.concurrency.PaymentStyleHierarchyLock;
import com.uten.imp.application.port.FinancialChartCurrencyReadPort;
import com.uten.imp.common.storage.ImmutableDocumentStore;
import com.uten.imp.common.web.*;
import com.uten.imp.features.finance.FinanceCompanyReportAccess;
import com.uten.imp.features.finance.FinanceDocumentAccessPolicy;
import com.uten.imp.security.*;
import jakarta.persistence.EntityManager;
import lombok.RequiredArgsConstructor;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;
import org.springframework.transaction.annotation.Isolation;
import java.util.*;
import static com.uten.imp.features.finance.gl.FinanceChartContracts.*;

@Service
@RequiredArgsConstructor
public class FinanceChartService {
    @org.springframework.beans.factory.annotation.Autowired
    private com.uten.imp.common.readsnapshot.VersionedSummaryPages summaryPages;

    private final JdbcTemplate db;
    private final EntityManager em;
    private final ObjectMapper json;
    private final ImmutableDocumentStore files;
    private final SecurityContextCurrentUser current;
    private final FinanceDocumentAccessPolicy access;
    private final GlReportLineBindingService bindings;
    private final TxSessionVars tx;
    private final com.uten.imp.application.port.FinancialChartAccountCreationPort accountCreation;
    private final com.uten.imp.application.port.FinancialChartCurrencyReadPort chartCurrencies;
    @org.springframework.beans.factory.annotation.Autowired private com.uten.imp.features.finance.FinanceOperationJournal operations;

    private void readAccess(){CurrentAuthorityGuard.requireAll("finance_report:view");FinanceCompanyReportAccess.require(access);}
    private void writeAccess(){readAccess();CurrentAuthorityGuard.requireAll("payment_style:edit");}
    private void lock(){db.query("SELECT pg_advisory_xact_lock(hashtextextended('uten:finance-chart',0))",rs->{});}
    private static final String ACCOUNT_CREATE="CHART_ACCOUNT_CREATE",MAPPING_REPLACE="CHART_MAPPING_REPLACE",TARGET_CREATE="CHART_TARGET_CREATE";
    private static final String IMPORT_APPLY="CHART_IMPORT_APPLY",IMPORT_REVIEW="CHART_IMPORT_REPREVIEW";
    private static final Set<String> CHART_COMMANDS=Set.of(ACCOUNT_CREATE,MAPPING_REPLACE,TARGET_CREATE,IMPORT_REVIEW);

    @Transactional public Map<String,Object> createAccountCommand(JsonNode original){return chartCommand(ACCOUNT_CREATE,null,original);}
    @Transactional public Map<String,Object> mapCommand(String code,JsonNode original){return chartCommand(MAPPING_REPLACE,chartCode(code),original);}
    @Transactional public Map<String,Object> createTargetCommand(String code,JsonNode original){return chartCommand(TARGET_CREATE,chartCode(code),original);}

    /** The chart's original table owns both success and stopped-unwritten rows.
     * No current directory or mapping equality can stand in for this receipt. */
    private Map<String,Object> chartCommand(String operation,String code,JsonNode original){
        writeAccess();UUID request=originalRequestId(original);
        if(TARGET_CREATE.equals(operation)||ACCOUNT_CREATE.equals(operation)&&!original.path("category").isMissingNode()&&!original.path("category").isNull())
            CurrentAuthorityGuard.requireAll("payment_style:create");
        String method=commandMethod(operation),path=commandPath(operation,code);
        tx.bind();lockCommand(operation,original);
        var previous=manualOperation(request);
        if(previous!=null){
            var result=originalReceipt(request,operation,method,path,original,previous);
            if("CANCELLED_UNWRITTEN".equals(result.get("outcome")))throw conflict("原科目请求已确认未写入并已停止，请核对原回执后重新发起");
            return result;
        }
        Object result;
        if(ACCOUNT_CREATE.equals(operation))result=createAccountCore(commandBody(original,CreateAccount.class));
        else if(MAPPING_REPLACE.equals(operation)){
            var body=commandBody(original,Mapping.class);requireOriginalVersion(original,body.expectedVersion());mapCore(code,body);result=mutationResult(request,code);
        }else{
            var body=commandBody(original,CreateTarget.class);requireOriginalVersion(original,body.expectedVersion());
            requireCurrentVersion(code,body.expectedVersion());
            requireExistingTargetCurrencyUnchanged(code,body);
            createTargetCore(code,body);requireTargetCorrespondence(code);result=mutationResult(request,code);
        }
        String fingerprint=commandFingerprint(operation,path,original);
        var receipt=operations.cancellationOutcome(request,operation,method,path,original,result,false);
        receipt.put("proofScope","RAW_BODY");
        if(ACCOUNT_CREATE.equals(operation))receipt.put("chartProof",metadataEnvelope(encode(mutationResult(request,commandBody(original,CreateAccount.class).code()))));
        db.update("INSERT INTO finance_chart_manual_operations(request_id,actor_id,fingerprint,result) VALUES(?,?,?,?::jsonb)",request,current.requireId(),fingerprint,encode(receipt));
        return receipt;
    }

    @Transactional(readOnly=true) public Map<String,Object> operationReceipt(UUID request){
        readAccess();if(request==null)throw invalid("请保留原科目请求编号");
        var rows=db.queryForList("SELECT actor_id,fingerprint,result::text FROM finance_chart_manual_operations WHERE request_id=? AND actor_id=?",request,current.requireId());
        if(rows.isEmpty())return Map.of("found",false);
        var stored=metadataEnvelope(rows.getFirst().get("result").toString());
        if(stored.containsKey("operation")){
            if(!CHART_COMMANDS.contains(Objects.toString(stored.get("operation"),"")))return Map.of("found",false);
            requireReceiptIdentity(request,stored);return stored;
        }
        if(!"CREATED".equals(stored.get("status")))return Map.of("found",false);
        var legacy=decode(encode(stored),CreateAccountResult.class);
        if(!request.equals(legacy.requestId())||!"CREATED".equals(legacy.status()))return Map.of("found",false);
        // The historical table never stored the original raw body. A caller
        // must supply its original typed body to confirm the old8-field hash;
        // historical optional omissions have the same typed null semantics.
        var result=new LinkedHashMap<String,Object>();result.put("found",true);result.put("requestId",request);
        result.put("actorId",current.requireId());result.put("operation",ACCOUNT_CREATE);result.put("method","POST");result.put("path","/finance/chart");
        result.put("outcome","SUCCEEDED");result.put("result",legacy);result.put("requiresOriginalRequestProof",true);result.put("proofScope","LEGACY_TYPED_BODY");return result;
    }

    @Transactional public Map<String,Object> cancelOperation(UUID request,com.uten.imp.features.finance.FinanceOperationJournal.Cancellation cancellation){
        readAccess();
        if(cancellation==null||cancellation.operation()==null||!CHART_COMMANDS.contains(cancellation.operation()))throw invalid("请保留原科目操作身份");
        if(IMPORT_REVIEW.equals(cancellation.operation()))return cancelRepreview(request,cancellation);
        String operation=cancellation.operation(),code=codeFromCommandPath(operation,cancellation.path());
        String method=commandMethod(operation),path=commandPath(operation,code);
        JsonNode original=operations.cancellationBody(request,cancellation,operation,method,path,JsonNode.class);
        tx.bind();lockCommand(operation,original);
        var previous=manualOperation(request);if(previous!=null)return originalReceipt(request,operation,method,path,original,previous);
        var receipt=operations.cancellationOutcome(request,operation,method,path,original,Map.of("cancelled",true),true);
        receipt.put("proofScope","RAW_BODY");
        db.update("INSERT INTO finance_chart_manual_operations(request_id,actor_id,fingerprint,result) VALUES(?,?,?,?::jsonb)",request,current.requireId(),commandFingerprint(operation,path,original),encode(receipt));
        return receipt;
    }

    private void lockCommand(String operation,JsonNode original){
        if(TARGET_CREATE.equals(operation)||ACCOUNT_CREATE.equals(operation)&&original.hasNonNull("category"))PaymentStyleHierarchyLock.lockForHierarchyChange(em);
        else PaymentStyleHierarchyLock.lock(em);
        lock();
        db.query("SELECT pg_advisory_xact_lock(hashtextextended('uten:finance-report-line-bindings',0))",rs->{});
    }
    private Map<String,Object> manualOperation(UUID request){
        var rows=db.queryForList("SELECT actor_id,fingerprint,result::text FROM finance_chart_manual_operations WHERE request_id=?",request);
        return rows.isEmpty()?null:rows.getFirst();
    }
    private Map<String,Object> originalReceipt(UUID request,String operation,String method,String path,JsonNode original,Map<String,Object> stored){
        if(!current.requireId().equals(stored.get("actor_id")))throw new ApiException(ErrorCode.FORBIDDEN,"只能核对并办理本人原请求");
        if(!commandFingerprint(operation,path,original).equals(stored.get("fingerprint")))throw conflict("原科目请求的完整参数或办理动作不同，请保留原请求核对");
        var receipt=metadataEnvelope(stored.get("result").toString());
        if(receipt.containsKey("operation")){
            requireReceiptIdentity(request,receipt);
            if(!operation.equals(receipt.get("operation"))||!method.equals(receipt.get("method"))||!path.equals(receipt.get("path")))throw conflict("原科目请求回执的来源不一致");
            operations.requireOriginalBodyMatch(tree(receipt.get("requestBody")),original);return receipt;
        }
        if(!ACCOUNT_CREATE.equals(operation))throw conflict("原编号已有其他科目操作，请保留原请求核对");
        var typed=commandBody(original,CreateAccount.class);
        for(String required:List.of("requestId","code","name","currencyName","sourceReference"))
            if(!original.path(required).isTextual())throw invalid("请保留原新增科目的必要字段，不能猜补旧请求");
        var legacy=decode(encode(receipt),CreateAccountResult.class);
        if(!request.equals(legacy.requestId())||!Objects.equals(typed.code(),legacy.code())||!"CREATED".equals(legacy.status()))throw conflict("原新增科目回执身份不一致");
        var verified=operations.cancellationOutcome(request,operation,method,path,original,legacy,false);
        verified.put("proofScope","LEGACY_TYPED_BODY");return verified;
    }
    private void requireReceiptIdentity(UUID request,Map<String,Object> receipt){
        if(!Boolean.TRUE.equals(receipt.get("found"))||!request.toString().equals(Objects.toString(receipt.get("requestId"),""))
                ||!current.requireId().toString().equals(Objects.toString(receipt.get("actorId"),""))
                ||!Set.of("SUCCEEDED","CANCELLED_UNWRITTEN").contains(Objects.toString(receipt.get("outcome"),"")))throw conflict("原科目回执身份不完整");
    }
    private String commandFingerprint(String operation,String path,JsonNode original){
        if(ACCOUNT_CREATE.equals(operation)){
            try{return ImmutableDocumentStore.digest(encode(commandBody(original,CreateAccount.class)).getBytes(java.nio.charset.StandardCharsets.UTF_8));}
            catch(ApiException invalidBody){/* A malformed unwritten original may still be stopped by its exact raw identity. */}
        }
        return ImmutableDocumentStore.digest((operation+":"+path+":"+operations.originalBodyFingerprint(original)).getBytes(java.nio.charset.StandardCharsets.UTF_8));
    }
    private UUID originalRequestId(JsonNode original){
        try{if(original==null||!original.isObject()||!original.path("requestId").isTextual())throw new IllegalArgumentException();
            UUID id=UUID.fromString(original.path("requestId").asText());if(!id.toString().equals(original.path("requestId").asText()))throw new IllegalArgumentException();return id;
        }catch(Exception error){throw invalid("请保留原科目请求编号和完整正文");}
    }
    private static String chartCode(String code){if(code==null||!code.matches("[0-9]{1,32}"))throw invalid("请保留原科目编码");return code;}
    private static String commandMethod(String operation){return MAPPING_REPLACE.equals(operation)?"PUT":"POST";}
    private static String commandPath(String operation,String code){return ACCOUNT_CREATE.equals(operation)?"/finance/chart":"/finance/chart/"+chartCode(code)+(TARGET_CREATE.equals(operation)?"/create-target":"");}
    private static String codeFromCommandPath(String operation,String path){
        if(ACCOUNT_CREATE.equals(operation)){if(!"/finance/chart".equals(path))throw invalid("原新增科目路径不一致");return null;}
        String suffix=TARGET_CREATE.equals(operation)?"/create-target":"";
        if(path==null||!path.startsWith("/finance/chart/")||!path.endsWith(suffix))throw invalid("原科目操作路径不一致");
        return chartCode(path.substring("/finance/chart/".length(),path.length()-suffix.length()));
    }
    private <T>T commandBody(JsonNode original,Class<T> type){
        var body=operations.decodeOriginal(new com.uten.imp.features.finance.FinanceOperationJournal.WireCommand(original),type);
        if(type==Mapping.class&&original.hasNonNull("styleIds"))for(var id:original.path("styleIds"))requireUuidText(id);
        if(original.hasNonNull("currencyId"))requireUuidText(original.path("currencyId"));
        return body;
    }
    private static void requireUuidText(JsonNode value){try{if(!value.isTextual()||!UUID.fromString(value.asText()).toString().equals(value.asText()))throw new IllegalArgumentException();}catch(Exception error){throw invalid("科目请求身份必须保留原UUID文本");}}
    private JsonNode tree(Object value){try{return com.uten.imp.common.finance.FinancialJsonResults.tree(json,encode(value));}catch(Exception error){throw conflict("原科目回执正文无法完整读取");}}
    private static void requireOriginalVersion(JsonNode original,Long expected){if(expected==null||expected<0||!original.path("expectedVersion").isIntegralNumber()||!original.path("expectedVersion").canConvertToLong())throw invalid("请明确保留本次审阅的科目版本，缺失或空值不能当作零");}
    private void requireCurrentVersion(String code,Long expected){
        var versions=db.queryForList("SELECT row_version FROM finance_chart_codes WHERE code=? FOR UPDATE",Long.class,code);
        if(versions.isEmpty())throw new ApiException(ErrorCode.NOT_FOUND,"财务科目代码不存在");
        if(!Objects.equals(versions.getFirst(),expected))throw conflict("科目目录已变化，请保留原选择核对当前版本");
    }
    private void requireExistingTargetCurrencyUnchanged(String code,CreateTarget request){
        if(request.currencyId()==null||(request.balanceLineKey()!=null&&!request.balanceLineKey().isBlank())
                ||(request.profitLineKey()!=null&&!request.profitLineKey().isBlank()))return;
        UUID nativeId=db.queryForObject("SELECT native_style_id FROM finance_chart_codes WHERE code=?",UUID.class,code);
        if(nativeId==null)return;
        // The read port resolves a historical unset base UUID by the same
        // authority as the single-account view. No name-based currency guess
        // or metadata rewrite is introduced by a legacy target no-op.
        var saved=chartCurrencies.read(Set.of(code)).get(code);
        if(saved==null||!Objects.equals(saved.currencyId(),request.currencyId()))
            throw conflict("本财务科目已有系统目标；改选币别请通过修改对应关系办理，本次未写入");
    }
    private MutationResult mutationResult(UUID request,String code){
        var row=db.queryForMap("SELECT row_version,classification FROM finance_chart_codes WHERE code=?",code);
        var effectiveCurrency=chartCurrencies.read(Set.of(code)).get(code);
        if(effectiveCurrency==null)throw conflict("科目币别资料未完整读取，不能发布原操作证明");
        return new MutationResult(request,code,"APPLIED",((Number)row.get("row_version")).longValue(),
                List.copyOf(db.queryForList("SELECT style_id FROM finance_chart_code_styles WHERE code=? ORDER BY style_id",UUID.class,code)),
                db.queryForObject("SELECT min(s.category) FROM finance_chart_code_styles m JOIN payment_styles s ON s.id=m.style_id WHERE m.code=?",String.class,code),
                (String)row.get("classification"),effectiveCurrency.currencyId(),effectiveLineKeys(code));
    }
    private void requireTargetCorrespondence(String code){
        Integer nativeMapping=db.queryForObject("SELECT count(*) FROM finance_chart_codes c JOIN finance_chart_code_styles m ON m.code=c.code AND m.style_id=c.native_style_id WHERE c.code=?",Integer.class,code);
        Integer categories=db.queryForObject("SELECT count(DISTINCT s.category) FROM finance_chart_code_styles m JOIN payment_styles s ON s.id=m.style_id WHERE m.code=?",Integer.class,code);
        if(!Objects.equals(nativeMapping,1)||!Objects.equals(categories,1))
            throw conflict("本财务科目已有原系统科目但尚未形成一致对应，请通过“对应已有科目”明确选择原科目；本次未写入");
    }
    private List<String> effectiveLineKeys(String code){return List.copyOf(db.queryForList("SELECT DISTINCT b.line_key FROM finance_chart_code_styles m JOIN finance_report_line_bindings b ON b.style_id=m.style_id AND b.binding_kind='STYLE' WHERE m.code=? AND (b.line_key LIKE 'BS\\_%' OR b.line_key LIKE 'PL\\_%' OR b.line_key='SALES_FEE') ORDER BY b.line_key",String.class,code));}

    @Transactional(readOnly=true,isolation=Isolation.REPEATABLE_READ) public Account account(String code){
        readAccess();chartCode(code);var rows=db.queryForList("SELECT code,name,currency_name,row_version,classification FROM finance_chart_codes WHERE code=?",code);
        if(rows.isEmpty())throw new ApiException(ErrorCode.NOT_FOUND,"财务科目代码不存在");var row=rows.getFirst();
        var targets=db.query("SELECT s.id,s.code,s.name,s.category FROM finance_chart_code_styles m JOIN payment_styles s ON s.id=m.style_id WHERE m.code=? ORDER BY s.path,s.id",(rs,n)->new Target(rs.getObject(1,UUID.class),rs.getString(2),rs.getString(3),rs.getString(4)),code);
        var currency=chartCurrencies.read(Set.of(code)).get(code);if(currency==null)throw conflict("科目币别资料未完整读取");
        return new Account(code,(String)row.get("name"),(String)row.get("currency_name"),((Number)row.get("row_version")).longValue(),List.copyOf(targets),effectiveLineKeys(code),(String)row.get("classification"),currency.currencyId());
    }

    @Transactional
    public CreateAccountResult createAccount(CreateAccount request) {
        var receipt=createAccountCommand(json.valueToTree(request));
        return decode(encode(receipt.get("result")),CreateAccountResult.class);
    }

    private CreateAccountResult createAccountCore(CreateAccount request) {
        writeAccess();
        if(request==null||request.requestId()==null||request.code()==null||!request.code().matches("[0-9]{1,32}")
                ||request.name()==null||request.name().isBlank()||request.name().strip().length()>240
                ||request.currencyName()==null||request.currencyName().length()>80
                ||request.sourceReference()==null||request.sourceReference().isBlank()||request.sourceReference().length()>1000)
            throw invalid("请填写完整数字文本代码、科目名称、外币名称属性和新增依据");
        if(request.category()!=null&&!Set.of("ACCOUNT","LIABILITY","EQUITY","INCOME","EXPENSE").contains(request.category()))throw invalid("核算类别不正确");
        if(request.category()!=null)CurrentAuthorityGuard.requireAll("payment_style:create");
        tx.bind();if(request.category()!=null){PaymentStyleHierarchyLock.lockForHierarchyChange(em);}lock();
        String classification=FinanceChartClassification.resolve(request.code(),request.classification(),request.category());
        if(classification==null)throw invalid("请选择原表的财务类别：资产、负债、权益、成本或损益");
        UUID currency=currencyIdentity(request.currencyName(),request.currencyId(),null);
        if(db.queryForObject("SELECT count(*) FROM finance_chart_codes WHERE code=?",Integer.class,request.code())!=0)throw conflict("该财务代码已存在，请直接维护对应关系");
        db.update("INSERT INTO finance_chart_codes(code,name,currency_name,sort_order,source_row,source_kind,source_reference,classification,currency_id,updated_by) SELECT ?,?,?,COALESCE(max(sort_order),0)+1,1,'MANUAL',?,?,?,? FROM finance_chart_codes",
                request.code(),request.name().strip(),request.currencyName().strip(),request.sourceReference().strip(),classification,currency,current.requireId());
        if(request.category()!=null)createTargetCore(request.code(),new CreateTarget(0,request.category(),classification));
        var result=new CreateAccountResult(request.requestId(),request.code(),"CREATED");
        return result;
    }

    /** HTTP shape adapter: retain the established typed4 hash and original
     * string values, while never inventing a reviewed version from a default0. */
    @Transactional
    public UpdateAccountResult updateAccountCommand(String code,JsonNode original){
        writeAccess();originalRequestId(original);
        if(original.size()!=4||!original.has("expectedVersion")||!original.path("name").isTextual()
                ||!original.path("sourceReference").isTextual()||!original.path("expectedVersion").isIntegralNumber()
                ||!original.path("expectedVersion").canConvertToLong())
            throw invalid("请保留科目名称修改的完整四个原字段及明确整数版本，缺失或空版本不能当作零");
        UpdateAccount request;
        try{request=com.uten.imp.common.finance.FinancialJsonResults.value(json,encode(original),UpdateAccount.class);}
        catch(Exception error){throw invalid("原科目名称修改请求格式不正确，本次未写入");}
        requireOriginalVersion(original,request.expectedVersion());
        operations.requireOriginalBodyMatch(json.valueToTree(request),original);
        return updateAccount(code,request);
    }

    @Transactional
    public UpdateAccountResult updateAccount(String code,UpdateAccount request) {
        writeAccess();
        if(code==null||!code.matches("[0-9]{1,32}")||request==null||request.requestId()==null||request.expectedVersion()<0
                ||request.name()==null||request.name().isBlank()||request.name().strip().length()>240
                ||request.sourceReference()==null||request.sourceReference().isBlank()||request.sourceReference().length()>1000)
            throw invalid("请填写科目名称、修改依据并保留当前版本");
        tx.bind();lock();
        String fingerprint=ImmutableDocumentStore.digest(("UPDATE_METADATA:"+code+":"+encode(request)).getBytes(java.nio.charset.StandardCharsets.UTF_8));
        var previous=db.queryForList("SELECT actor_id,fingerprint,result::text FROM finance_chart_manual_operations WHERE request_id=?",request.requestId());
        if(!previous.isEmpty()) {
            var stored=previous.getFirst();
            if(!current.requireId().equals(stored.get("actor_id"))||!fingerprint.equals(stored.get("fingerprint")))
                throw conflict("同一修改请求已使用，请保留原参数核对结果");
            return metadataResult(stored.get("result").toString());
        }
        var rows=db.queryForList("SELECT name,row_version FROM finance_chart_codes WHERE code=? FOR UPDATE",code);
        if(rows.isEmpty())throw new ApiException(ErrorCode.NOT_FOUND,"财务科目代码不存在");
        var account=rows.getFirst();
        if(((Number)account.get("row_version")).longValue()!=request.expectedVersion())
            throw conflict("科目目录已变化，请刷新后核对名称和版本");
        // The code, mapped UUIDs, original import and its evidence remain unchanged.
        db.update("UPDATE finance_chart_codes SET name=?,row_version=row_version+1,updated_at=now(),updated_by=? WHERE code=?",
                request.name().strip(),current.requireId(),code);
        var result=new UpdateAccountResult(request.requestId(),code,"UPDATED",(String)account.get("name"),request.name().strip(),request.sourceReference().strip());
        db.update("INSERT INTO finance_chart_manual_operations(request_id,actor_id,fingerprint,result) VALUES(?,?,?,?::jsonb)",
                request.requestId(),current.requireId(),fingerprint,encode(result));
        return result;
    }

    @Transactional
    public Preview preview(String filename,byte[] bytes) {
        writeAccess();tx.bind();lock();UUID actor=current.requireId();String hash=ImmutableDocumentStore.digest(bytes);
        var previous=db.queryForList("SELECT id FROM finance_chart_imports WHERE actor_id=? AND sha256=? AND parent_import_id IS NULL",UUID.class,actor,hash);
        if(!previous.isEmpty()) {files.checkLegacy("FINANCE_CHART_IMPORT_REPLAY",bytes);return imported(previous.getFirst());}
        String name=filename==null?"chart.xlsx":filename.replaceAll("[\\\\/:*?\"<>|\\p{Cntrl}]","_");
        if(name.isBlank()||name.length()>240)throw invalid("文件名称无效");
        UUID id=UUID.randomUUID();Preview parsed=FinanceChartWorkbookParser.parse(id,name,hash,bytes);
        List<SourceRow> rows=new ArrayList<>();
        Map<String,Long> versions=new HashMap<>();
        db.query("SELECT code,row_version FROM finance_chart_codes",rs->{versions.put(rs.getString(1),rs.getLong(2));});
        for(var row:parsed.rows())rows.add(new SourceRow(row.code(),row.name(),row.currencyName(),row.sourceRow(),versions.get(row.code()),row.classification()));
        Preview result=new Preview(id,name,hash,List.copyOf(rows),parsed.issues(),false);
        var stored=files.save("FINANCE_CHART_IMPORT",name,name.toLowerCase(Locale.ROOT).endsWith(".xls")?
                "application/vnd.ms-excel":"application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",bytes);
        db.update("""
                INSERT INTO finance_chart_imports(id,actor_id,source_name,sha256,storage_provider,storage_key,storage_version,storage_size,preview)
                VALUES(?,?,?,?,?,?,?,?,?::jsonb)
                """,id,actor,name,hash,stored.provider(),stored.key(),stored.version(),stored.size(),encode(result));
        db.update("""
                INSERT INTO attachment_object_outbox(operation,storage_provider,storage_key,storage_version,dedupe_key)
                VALUES('DELETE_STAGING',?,?,?,?) ON CONFLICT(dedupe_key) DO NOTHING
                """,stored.provider(),stored.key(),stored.version(),stored.provider()+"|DELETE_STAGING|"+stored.key()+"|"+Objects.toString(stored.version(),"<local>"));
        return result;
    }

    @Transactional(readOnly=true)
    public Map<String,Object> metadataReceipt(String code,UUID requestId) {
        readAccess();
        if(code==null||!code.matches("[0-9]{1,32}")||requestId==null)throw invalid("请保留原科目编码和修改请求编号");
        var rows=db.queryForList("SELECT result::text FROM finance_chart_manual_operations WHERE request_id=? AND actor_id=?",requestId,current.requireId());
        if(rows.isEmpty())return Map.of("found",false);
        String encoded=rows.getFirst().get("result").toString();
        var rawReceipt=metadataEnvelope(encoded);
        if(rawReceipt.containsKey("operation")&&!"CHART_METADATA_UPDATE".equals(rawReceipt.get("operation")))return Map.of("found",false);
        var result=metadataResult(encoded);
        if("CANCELLED_UNWRITTEN".equals(result.status())){
            if(!code.equals(result.code())||!requestId.equals(result.requestId()))return Map.of("found",false);
            return metadataEnvelope(encoded);
        }
        if(!"UPDATED".equals(result.status())||!code.equals(result.code())||!requestId.equals(result.requestId()))return Map.of("found",false);
        return Map.of("found",true,"actorId",current.requireId(),"requestId",requestId,"operation","CHART_METADATA_UPDATE","outcome","SUCCEEDED","result",result);
    }
    @Transactional(readOnly=true) public Map<String,Object> metadata(String code){
        readAccess();if(code==null||!code.matches("[0-9]{1,32}"))throw invalid("请保留原科目编码");
        var rows=db.queryForList("SELECT code,name,row_version AS version FROM finance_chart_codes WHERE code=?",code);
        if(rows.isEmpty())throw new ApiException(ErrorCode.NOT_FOUND,"财务科目代码不存在");return rows.getFirst();
    }
    @Transactional public Map<String,Object> cancelMetadata(String code,UUID requestId,com.uten.imp.features.finance.FinanceOperationJournal.Cancellation cancellation){
        readAccess();if(code==null||!code.matches("[0-9]{1,32}"))throw invalid("请保留原科目编码");
        String path="/finance/chart/"+code+"/metadata",operation="CHART_METADATA_UPDATE";
        var request=operations.cancellationBody(requestId,cancellation,operation,"PUT",path,UpdateAccount.class);
        tx.bind();lock();
        String fingerprint=ImmutableDocumentStore.digest(("UPDATE_METADATA:"+code+":"+encode(request)).getBytes(java.nio.charset.StandardCharsets.UTF_8));
        var previous=db.queryForList("SELECT actor_id,fingerprint,result::text FROM finance_chart_manual_operations WHERE request_id=?",requestId);
        if(!previous.isEmpty()){
            var stored=previous.getFirst();if(!current.requireId().equals(stored.get("actor_id"))||!fingerprint.equals(stored.get("fingerprint")))
                throw conflict("同一修改请求已使用，请保留原参数核对结果");
            String encoded=stored.get("result").toString();var result=metadataResult(encoded);
            if(!code.equals(result.code())||!requestId.equals(result.requestId())||!Set.of("UPDATED","CANCELLED_UNWRITTEN").contains(result.status()))throw conflict("原科目修改回执身份不一致");
            return "CANCELLED_UNWRITTEN".equals(result.status())?metadataEnvelope(encoded):operations.cancellationOutcome(requestId,operation,"PUT",path,request,result,false);
        }
        var result=new UpdateAccountResult(requestId,code,"CANCELLED_UNWRITTEN",null,request.name(),request.sourceReference());
        var marker=metadataEnvelope(encode(result));marker.put("cancelled",true);
        var stopped=operations.cancellationOutcome(requestId,operation,"PUT",path,request,marker,true);
        db.update("INSERT INTO finance_chart_manual_operations(request_id,actor_id,fingerprint,result) VALUES(?,?,?,?::jsonb)",requestId,current.requireId(),fingerprint,encode(stopped));
        return stopped;
    }
    private UpdateAccountResult metadataResult(String encoded){
        var value=metadataEnvelope(encoded);
        if("CANCELLED_UNWRITTEN".equals(value.get("outcome"))){
            var result=metadataEnvelope(encode(value.get("result")));result.remove("cancelled");return decode(encode(result),UpdateAccountResult.class);
        }
        return decode(encoded,UpdateAccountResult.class);
    }
    private Map<String,Object> metadataEnvelope(String encoded){
        try{return com.uten.imp.common.finance.FinancialJsonResults.object(json,encoded);}catch(Exception error){throw conflict("原科目修改回执无法完整读取");}
    }

    @Transactional(readOnly=true)
    public List<Map<String,Object>> recent() {
        readAccess();return db.queryForList("SELECT id AS \"importId\",source_name AS \"sourceName\",applied_at AS \"appliedAt\",cancelled_at AS \"cancelledAt\" FROM finance_chart_imports WHERE actor_id=? ORDER BY created_at DESC,id LIMIT 10",current.requireId());
    }

    @Transactional(readOnly=true)
    public Preview imported(UUID id) {
        readAccess();var row=importRow(id,false);var p=decode((String)row.get("preview"),Preview.class);
        return new Preview(p.importId(),p.sourceName(),p.sha256(),p.rows(),p.issues(),row.get("applied_at")!=null,p.columnContractVersion());
    }

    @Transactional(readOnly=true,isolation=Isolation.REPEATABLE_READ)
    public Map<String,Object> importView(UUID id){
        readAccess();var row=importRow(id,false);var view=metadataEnvelope((String)row.get("preview"));
        view.put("applied",row.get("applied_at")!=null);view.put("cancelled",row.get("cancelled_at")!=null);
        view.put("parentImportId",row.get("parent_import_id"));view.put("sourceImportId",sourceImportId(id));
        view.put("applyOutcome",row.get("applied_at")!=null?"SUCCEEDED":row.get("cancelled_at")!=null?"CANCELLED_UNWRITTEN":null);
        return view;
    }

    /** Upload response recovery is actor+content bound and independent of the
     * recent-ten convenience list. Absence never declares an in-flight upload unwritten. */
    @Transactional(readOnly=true)
    public Map<String,Object> importBySha(String sha){
        readAccess();if(sha==null||!sha.matches("[a-f0-9]{64}"))throw invalid("请保留原文件SHA256摘要");
        var rows=db.queryForList("SELECT id,source_name,sha256,storage_size,applied_at,cancelled_at FROM finance_chart_imports WHERE actor_id=? AND sha256=? AND parent_import_id IS NULL",current.requireId(),sha);
        if(rows.isEmpty())return Map.of("found",false);var row=rows.getFirst();
        return Map.of("found",true,"importId",row.get("id"),"sourceName",row.get("source_name"),"sha256",row.get("sha256"),"storageSize",row.get("storage_size"),"applied",row.get("applied_at")!=null,"cancelled",row.get("cancelled_at")!=null);
    }

    @Transactional
    public Map<String,Object> applyCommand(JsonNode original){
        writeAccess();UUID id=importIdentity(original);tx.bind();lockCommand(IMPORT_APPLY,original);
        var row=importRow(id,true);
        if(row.get("cancellation_result")!=null)throw conflict("原导入批次已确认未写入并已停止，请核对原回执后显式重新审阅");
        if(row.get("applied_result")!=null)return importApplyReceipt(row);
        verifyImportFile(row);
        var result=applyCore(id,row);var receipt=operations.cancellationOutcome(id,IMPORT_APPLY,"POST","/finance/chart/import-apply",original,result,false);
        receipt.put("proofScope","RAW_BODY");
        db.update("UPDATE finance_chart_imports SET applied_at=now(),applied_result=?::jsonb,apply_receipt=?::jsonb WHERE id=?",encode(result),encode(receipt),id);
        return receipt;
    }

    @Transactional(readOnly=true)
    public Map<String,Object> importApplyOperation(UUID id){
        readAccess();var rows=importRows(id,false);if(rows.isEmpty())return Map.of("found",false);
        var row=rows.getFirst();return row.get("applied_result")==null&&row.get("cancellation_result")==null?Map.of("found",false):importApplyReceipt(row);
    }

    @Transactional
    public Map<String,Object> cancelImportApply(UUID id,com.uten.imp.features.finance.FinanceOperationJournal.Cancellation cancellation){
        readAccess();var original=operations.cancellationBodyForIdentityField(id,cancellation,IMPORT_APPLY,"POST","/finance/chart/import-apply","importId",Apply.class);
        JsonNode body=json.valueToTree(original);importIdentity(body);tx.bind();lockCommand(IMPORT_APPLY,body);
        var row=importRow(id,true);if(row.get("applied_result")!=null||row.get("cancellation_result")!=null)return importApplyReceipt(row);
        var receipt=operations.cancellationOutcome(id,IMPORT_APPLY,"POST","/finance/chart/import-apply",body,Map.of("cancelled",true),true);receipt.put("proofScope","RAW_BODY");
        db.update("UPDATE finance_chart_imports SET cancelled_at=now(),cancellation_result=?::jsonb WHERE id=?",encode(receipt),id);return receipt;
    }

    private Map<String,Object> importApplyReceipt(Map<String,Object> row){
        UUID id=(UUID)row.get("id");
        String encoded=(String)(row.get("cancellation_result")!=null?row.get("cancellation_result"):row.get("apply_receipt"));
        if(encoded!=null){var receipt=metadataEnvelope(encoded);requireReceiptIdentity(id,receipt);
            if(!IMPORT_APPLY.equals(receipt.get("operation"))||!"POST".equals(receipt.get("method"))||!"/finance/chart/import-apply".equals(receipt.get("path")))throw conflict("原导入回执的动作或来源不一致");
            operations.requireOriginalBodyMatch(tree(receipt.get("requestBody")),json.valueToTree(new Apply(id)));return receipt;}
        var result=decode((String)row.get("applied_result"),Result.class);var preview=decode((String)row.get("preview"),Preview.class);
        if(!id.equals(result.importId())||!"APPLIED".equals(result.status())||result.imported()!=preview.rows().size())throw conflict("原导入成功回执不完整，不能按当前目录推定结果");
        var receipt=operations.cancellationOutcome(id,IMPORT_APPLY,"POST","/finance/chart/import-apply",new Apply(id),result,false);
        receipt.put("proofScope","LEGACY_TYPED_IMPORT_ID");return receipt;
    }

    private UUID importIdentity(JsonNode original){
        if(original==null||!original.isObject()||original.size()!=1||!original.has("importId"))throw invalid("请保留原导入批次的唯一完整参数");
        requireUuidText(original.path("importId"));return UUID.fromString(original.path("importId").asText());
    }

    @Transactional
    public Map<String,Object> repreview(UUID parent,JsonNode original){
        writeAccess();UUID request=originalRequestId(original);commandBody(original,Repreview.class);
        String path=repreviewPath(parent);tx.bind();lockCommand(IMPORT_REVIEW,original);
        var previous=manualOperation(request);
        if(previous!=null){var receipt=originalReceipt(request,IMPORT_REVIEW,"POST",path,original,previous);
            if("CANCELLED_UNWRITTEN".equals(receipt.get("outcome")))throw conflict("原重新审阅请求已停止，请核对原回执后另行发起");return receipt;}
        var source=importRow(parent,true);verifyImportFile(source);
        var raw=tree(metadataEnvelope((String)source.get("preview"))).deepCopy();
        if(!raw.isObject()||!raw.path("rows").isArray())throw conflict("原科目文件预览不完整，不能重建源行");
        UUID id=UUID.randomUUID();((com.fasterxml.jackson.databind.node.ObjectNode)raw).put("importId",id.toString());
        ((com.fasterxml.jackson.databind.node.ObjectNode)raw).put("columnContractVersion",com.uten.imp.common.importing.ImportColumnGuard.VERSION);
        Map<String,Long> versions=new HashMap<>();db.query("SELECT code,row_version FROM finance_chart_codes",rs->{versions.put(rs.getString(1),rs.getLong(2));});
        for(JsonNode row:raw.path("rows")){
            if(!row.isObject()||!row.path("code").isTextual())throw conflict("原科目源行身份不完整，不能猜补");
            Long version=versions.get(row.path("code").asText());var mutable=(com.fasterxml.jackson.databind.node.ObjectNode)row;
            if(version==null)mutable.putNull("existingVersion");else mutable.put("existingVersion",version);
        }
        db.update("""
                INSERT INTO finance_chart_imports(id,actor_id,source_name,sha256,storage_provider,storage_key,storage_version,storage_size,preview,parent_import_id,review_request_id)
                VALUES(?,?,?,?,?,?,?,?,?::jsonb,?,?)
                """,id,current.requireId(),source.get("source_name"),source.get("sha256"),source.get("storage_provider"),source.get("storage_key"),source.get("storage_version"),source.get("storage_size"),encode(raw),parent,request);
        var result=Map.of("requestId",request,"importId",id,"parentImportId",parent,"sourceImportId",sourceImportId(parent),"sha256",source.get("sha256"),"status","PREVIEWED");
        var receipt=operations.cancellationOutcome(request,IMPORT_REVIEW,"POST",path,original,result,false);receipt.put("proofScope","RAW_BODY");
        db.update("INSERT INTO finance_chart_manual_operations(request_id,actor_id,fingerprint,result)VALUES(?,?,?,?::jsonb)",request,current.requireId(),commandFingerprint(IMPORT_REVIEW,path,original),encode(receipt));return receipt;
    }

    private Map<String,Object> cancelRepreview(UUID request,com.uten.imp.features.finance.FinanceOperationJournal.Cancellation cancellation){
        String prefix="/finance/chart/imports/",suffix="/repreview",path=cancellation.path();
        if(path==null||!path.startsWith(prefix)||!path.endsWith(suffix))throw invalid("请保留原重新审阅来源路径");
        UUID parent;try{parent=UUID.fromString(path.substring(prefix.length(),path.length()-suffix.length()));if(!repreviewPath(parent).equals(path))throw new IllegalArgumentException();}catch(Exception error){throw invalid("请保留原重新审阅来源批次身份");}
        var original=operations.cancellationBody(request,cancellation,IMPORT_REVIEW,"POST",path,JsonNode.class);
        tx.bind();lockCommand(IMPORT_REVIEW,original);var previous=manualOperation(request);
        if(previous!=null)return originalReceipt(request,IMPORT_REVIEW,"POST",path,original,previous);
        importRow(parent,false); // Same actor's retained source is required even after write permission is lost.
        var receipt=operations.cancellationOutcome(request,IMPORT_REVIEW,"POST",path,original,Map.of("cancelled",true),true);receipt.put("proofScope","RAW_BODY");
        db.update("INSERT INTO finance_chart_manual_operations(request_id,actor_id,fingerprint,result)VALUES(?,?,?,?::jsonb)",request,current.requireId(),commandFingerprint(IMPORT_REVIEW,path,original),encode(receipt));return receipt;
    }
    private static String repreviewPath(UUID parent){if(parent==null)throw invalid("请保留原科目文件批次");return "/finance/chart/imports/"+parent+"/repreview";}
    private void verifyImportFile(Map<String,Object> row){
        byte[] bytes=files.checkLegacy("FINANCE_CHART_IMPORT_REPLAY",files.read(new ImmutableDocumentStore.Reference((String)row.get("storage_provider"),(String)row.get("storage_key"),(String)row.get("storage_version"),((Number)row.get("storage_size")).longValue(),(String)row.get("sha256"))));
        var checked=FinanceChartWorkbookParser.parse((UUID)row.get("id"),(String)row.get("source_name"),(String)row.get("sha256"),bytes);
        if(!checked.issues().isEmpty())throw invalid("原文件仍有列映射或数据问题，请重新检测；未写入任何科目");
    }
    private List<Map<String,Object>> importRows(UUID id,boolean forUpdate){
        if(id==null)throw invalid("请保留原科目文件批次");
        return db.queryForList("SELECT id,actor_id,source_name,sha256,storage_provider,storage_key,storage_version,storage_size,preview::text AS preview,applied_at,applied_result::text AS applied_result,parent_import_id,review_request_id,apply_receipt::text AS apply_receipt,cancelled_at,cancellation_result::text AS cancellation_result FROM finance_chart_imports WHERE id=? AND actor_id=?"+(forUpdate?" FOR UPDATE":""),id,current.requireId());
    }
    private Map<String,Object> importRow(UUID id,boolean forUpdate){var rows=importRows(id,forUpdate);if(rows.isEmpty())throw new ApiException(ErrorCode.NOT_FOUND,"导入批次不存在或不属于当前账号");return rows.getFirst();}
    private UUID sourceImportId(UUID id){
        return db.queryForObject("""
                WITH RECURSIVE source AS(SELECT id,parent_import_id,ARRAY[id] AS path FROM finance_chart_imports WHERE id=? AND actor_id=?
                UNION ALL SELECT p.id,p.parent_import_id,s.path||p.id FROM source s JOIN finance_chart_imports p ON p.id=s.parent_import_id WHERE NOT p.id=ANY(s.path))
                SELECT id FROM source WHERE parent_import_id IS NULL
                """,UUID.class,id,current.requireId());
    }

    @Transactional
    public Result apply(Apply request) {
        writeAccess();if(request==null||request.importId()==null)throw invalid("请选择已预览的科目文件");
        var receipt=applyCommand(json.valueToTree(request));return decode(encode(receipt.get("result")),Result.class);
    }
    private Result applyCore(UUID id,Map<String,Object> data){
        com.uten.imp.common.importing.ImportColumnGuard.requireValidated(decode((String)data.get("preview"),Preview.class).columnContractVersion());
        Preview preview=decode((String)data.get("preview"),Preview.class);
        if(preview.rows()==null||preview.rows().isEmpty())throw invalid("原导入预览没有可审阅科目，不能返回空成功");
        if(!preview.issues().isEmpty())throw invalid("请先修正预览中的全部错误，未写入任何科目");
        int order=db.queryForObject("SELECT COALESCE(max(sort_order),0) FROM finance_chart_codes",Integer.class);
        for(var row:preview.rows()) {
            validateClassification(row.code(),row.classification());
            if(row.existingVersion()==null) {
                if(db.queryForObject("SELECT count(*) FROM finance_chart_codes WHERE code=?",Integer.class,row.code())!=0)
                    throw conflict("科目目录已变化，请重新预览："+row.code());
                db.update("INSERT INTO finance_chart_codes(code,name,currency_name,sort_order,source_row,source_import_id,classification,updated_by) VALUES(?,?,?,?,?,?,?,?)",
                        row.code(),row.name(),row.currencyName(),++order,row.sourceRow(),id,row.classification(),current.requireId());
            } else {
                // Preserve existing UUID mappings and the established order on a metadata refresh.
                if(db.update("""
                        UPDATE finance_chart_codes SET name=?,currency_id=CASE WHEN currency_name IS DISTINCT FROM ? THEN NULL ELSE currency_id END,currency_name=?,source_row=?,source_import_id=?,classification=COALESCE(?,classification),source_kind='IMPORT',source_reference=NULL,
                            row_version=row_version+1,updated_at=now(),updated_by=? WHERE code=? AND row_version=?
                        """,row.name(),row.currencyName(),row.currencyName(),row.sourceRow(),id,row.classification(),current.requireId(),row.code(),row.existingVersion())!=1)
                    throw conflict("科目目录已变化，请重新预览："+row.code());
            }
        }
        return new Result(id,preview.rows().size(),"APPLIED");
    }

    @Transactional(readOnly=true,isolation=Isolation.REPEATABLE_READ)
    public List<Account> list() {
        readAccess();Map<String,List<Target>> targets=new HashMap<>();
        Map<String,List<String>> lineKeys=new HashMap<>();
        db.query("""
                SELECT DISTINCT m.code,b.line_key FROM finance_chart_code_styles m
                JOIN finance_report_line_bindings b ON b.style_id=m.style_id AND b.binding_kind='STYLE'
                WHERE b.line_key LIKE 'BS\\_%' OR b.line_key LIKE 'PL\\_%' OR b.line_key='SALES_FEE'
                ORDER BY m.code,b.line_key
                """,rs->{lineKeys.computeIfAbsent(rs.getString(1),k->new ArrayList<>()).add(rs.getString(2));});
        db.query("""
                SELECT m.code,s.id,s.code,s.name,s.category FROM finance_chart_code_styles m
                JOIN payment_styles s ON s.id=m.style_id ORDER BY s.path,s.id
                """,rs->{targets.computeIfAbsent(rs.getString(1),k->new ArrayList<>()).add(
                        new Target(rs.getObject(2,UUID.class),rs.getString(3),rs.getString(4),rs.getString(5)));});
        Set<String> codes=new HashSet<>(db.queryForList("SELECT code FROM finance_chart_codes",String.class));
        // The port bounds each lookup, not the total directory size. Repeated
        // imports and manual additions must not make the full directory unreadable.
        var currencyCodes=new ArrayList<>(codes);
        var currencies=new HashMap<String,FinancialChartCurrencyReadPort.Reference>();
        for(int offset=0;offset<currencyCodes.size();offset+=FinancialChartCurrencyReadPort.MAX_ACCOUNTS_PER_READ)
            currencies.putAll(chartCurrencies.read(new LinkedHashSet<>(currencyCodes.subList(offset,Math.min(offset+FinancialChartCurrencyReadPort.MAX_ACCOUNTS_PER_READ,currencyCodes.size())))));
        return db.query("SELECT code,name,currency_name,row_version,classification FROM finance_chart_codes ORDER BY sort_order,code",
                (rs,n)->new Account(rs.getString(1),rs.getString(2),rs.getString(3),rs.getLong(4),List.copyOf(targets.getOrDefault(rs.getString(1),List.of())),
                        List.copyOf(lineKeys.getOrDefault(rs.getString(1),List.of())),rs.getString(5),currencies.get(rs.getString(1)).currencyId()));
    }
    @Transactional(readOnly=true) public Map<String,Object> options(){readAccess();return Map.of("currencies",chartCurrencies.choices());}

    /** Controlled compound helper; external writes use the original-request adapter. */
    @Transactional
    public List<Account> createTarget(String code,CreateTarget request) {
        createTargetCore(code,request);return list();
    }
    private void createTargetCore(String code,CreateTarget request) {
        writeAccess();CurrentAuthorityGuard.requireAll("payment_style:create");
        if(request==null||request.expectedVersion()==null||request.expectedVersion()<0||request.category()==null||!Set.of("ACCOUNT","LIABILITY","EQUITY","INCOME","EXPENSE").contains(request.category()))
            throw invalid("请选择财务核算类别");
        tx.bind();PaymentStyleHierarchyLock.lockForHierarchyChange(em);lock();
        var rows=db.queryForList("SELECT name,row_version,native_style_id,classification FROM finance_chart_codes WHERE code=? FOR UPDATE",code);
        if(rows.isEmpty())throw new ApiException(ErrorCode.NOT_FOUND,"财务科目代码不存在");
        var row=rows.getFirst();
        String classification=FinanceChartClassification.resolve(code,request.classification()==null?(String)row.get("classification"):request.classification(),request.category());
        if(classification==null)throw invalid("请明确原表财务类别，资产与成本不能猜配");
        if(row.get("native_style_id")!=null) {
            String category=db.queryForObject("SELECT category FROM payment_styles WHERE id=?",String.class,row.get("native_style_id"));
            if(!request.category().equals(category)||!classification.equals(row.get("classification")))throw conflict("本财务科目已有其他核算类别或财务类别，不能重复创建");
            // Legacy create-target callers have no report-line fields. Creation
            // without an explicit selection must not clear an existing mapping.
            if((request.balanceLineKey()==null||request.balanceLineKey().isBlank())
                    &&(request.profitLineKey()==null||request.profitLineKey().isBlank()))return;
            mapCore(code,new Mapping(request.expectedVersion(),List.of((UUID)row.get("native_style_id")),request.balanceLineKey(),request.profitLineKey(),classification,request.currencyId()));return;
        }
        if(((Number)row.get("row_version")).longValue()!=request.expectedVersion())throw conflict("科目目录已变化，请刷新后核对");
        if(db.queryForObject("SELECT count(*) FROM finance_chart_code_styles WHERE code=?",Integer.class,code)!=0)
            throw conflict("本财务科目已有对应，请核对现有取数，不能再创建一份");
        UUID style=accountCreation.create(code,(String)row.get("name"),request.category());
        db.update("UPDATE finance_chart_codes SET native_style_id=? WHERE code=?",style,code);
        mapCore(code,new Mapping(request.expectedVersion(),List.of(style),request.balanceLineKey(),request.profitLineKey(),classification,request.currencyId()));
    }

    /** Controlled compound helper; a current mapping is never an operation receipt. */
    @Transactional
    public List<Account> map(String code,Mapping request) {
        mapCore(code,request);return list();
    }
    private void mapCore(String code,Mapping request) {
        writeAccess();if(request==null||request.expectedVersion()==null||request.expectedVersion()<0||code==null||!code.matches("[0-9]{1,32}"))throw invalid("请选择科目和当前版本");
        tx.bind();PaymentStyleHierarchyLock.lock(em);lock();
        // Same order as GlReportLineBindingService; no unguarded secondary report allocation.
        db.query("SELECT pg_advisory_xact_lock(hashtextextended('uten:finance-report-line-bindings',0))",rs->{});
        var version=db.queryForList("SELECT row_version FROM finance_chart_codes WHERE code=? FOR UPDATE",Long.class,code);
        if(version.size()!=1)throw new ApiException(ErrorCode.NOT_FOUND,"科目代码不存在");
        if(!Objects.equals(version.getFirst(),request.expectedVersion()))
            throw conflict("科目对应已变化，请刷新核对后重试");
        String previousClassification=db.queryForObject("SELECT classification FROM finance_chart_codes WHERE code=?",String.class,code);
        String classification=FinanceChartClassification.resolve(code,request.classification()==null?previousClassification:request.classification(),null);
        var currencyRow=db.queryForMap("SELECT currency_name,currency_id FROM finance_chart_codes WHERE code=?",code);
        UUID currency=currencyIdentity((String)currencyRow.get("currency_name"),request.currencyId(),(UUID)currencyRow.get("currency_id"));
        var ids=new LinkedHashSet<>(request.styleIds()==null?List.<UUID>of():request.styleIds());
        if(ids.contains(null)||ids.size()>200)throw invalid("请选择最多200个系统末级科目");
        if(classification==null&&!ids.isEmpty()) {
            String category=(String)em.createNativeQuery("SELECT min(category) FROM payment_styles WHERE id IN(:ids)").setParameter("ids",ids).getSingleResult();
            classification=FinanceChartClassification.resolve(code,null,category);
            if(classification==null)throw invalid("请选择财务类别，资产与成本不能按核算类型猜配");
        }
        var desiredLines=new LinkedHashSet<String>();
        for(String line:Arrays.asList(request.balanceLineKey(),request.profitLineKey()))if(line!=null&&!line.isBlank()) {
            var definition=FinancialStatementCatalog.find(line);
            if(definition==null||!definition.direct())throw invalid("只能选择资产负债表或利润表的取数项目");
            if(!desiredLines.add(line))throw invalid("报表项目重复");
        }
        if(request.balanceLineKey()!=null&&!request.balanceLineKey().isBlank()&&!request.balanceLineKey().startsWith("BS_"))throw invalid("资产负债项目不正确");
        if(request.profitLineKey()!=null&&!request.profitLineKey().isBlank()&&request.profitLineKey().startsWith("BS_"))throw invalid("利润项目不正确");
        if(ids.isEmpty()&&!desiredLines.isEmpty())throw invalid("请先选择系统科目，再对应报表项目");
        String fingerprint=ImmutableDocumentStore.digest((ids.stream().map(UUID::toString).sorted().toList().toString()
                +desiredLines.stream().sorted().toList()+classification+currency).getBytes(java.nio.charset.StandardCharsets.UTF_8));
        Set<UUID> before=new LinkedHashSet<>(db.queryForList("SELECT style_id FROM finance_chart_code_styles WHERE code=?",UUID.class,code));
        if(!ids.isEmpty()) {
            var valid=em.createNativeQuery("""
                    SELECT count(*) FROM payment_styles s WHERE s.id IN(:ids) AND NOT s.is_deleted
                      AND NOT EXISTS(SELECT 1 FROM payment_styles child WHERE child.parent_id=s.id AND NOT child.is_deleted)
                    """).setParameter("ids",ids).getSingleResult();
            if(((Number)valid).intValue()!=ids.size())throw invalid("只能对应未删除的系统末级科目，不能用父级重复取数");
            var categories=em.createNativeQuery("SELECT count(DISTINCT category) FROM payment_styles WHERE id IN(:ids)").setParameter("ids",ids).getSingleResult();
            if(((Number)categories).intValue()!=1)throw invalid("同一财务科目不能合并不同核算类别");
            String category=(String)em.createNativeQuery("SELECT min(category) FROM payment_styles WHERE id IN(:ids)").setParameter("ids",ids).getSingleResult();
            FinanceChartClassification.resolve(code,classification,category);
            for(UUID style:ids) {
                var owner=db.queryForList("SELECT code FROM finance_chart_code_styles WHERE style_id=? AND code<>?",String.class,style,code);
                if(!owner.isEmpty())throw conflict("系统科目已对应财务代码"+owner.getFirst()+"，不能重复归集");
            }
        }
        // Remove only allocations owned by this exact mapping; unrelated manual bindings survive.
        db.update("""
                DELETE FROM finance_report_line_bindings b USING finance_chart_owned_bindings o
                WHERE o.code=? AND b.style_id=o.style_id AND b.line_key=o.line_key AND b.binding_kind='STYLE'
                """,code);
        db.update("DELETE FROM finance_chart_owned_bindings WHERE code=?",code);
        if(!before.equals(ids)) {
            for(UUID style:before)if(!ids.contains(style))db.update("DELETE FROM finance_chart_code_styles WHERE code=? AND style_id=?",code,style);
            for(UUID style:ids)if(!before.contains(style))db.update("INSERT INTO finance_chart_code_styles(code,style_id,created_by) VALUES(?,?,?)",code,style,current.requireId());
        }
        for(String line:desiredLines) {
            var existing=new LinkedHashSet<>(db.queryForList("SELECT style_id FROM finance_report_line_bindings WHERE line_key=? AND binding_kind='STYLE'",UUID.class,line));
            var added=new LinkedHashSet<>(ids);added.removeAll(existing);existing.addAll(ids);
            bindings.replace(line,new ArrayList<>(existing),false);
            for(UUID style:added)db.update("INSERT INTO finance_chart_owned_bindings(code,style_id,line_key) VALUES(?,?,?)",code,style,line);
        }
        if(currency!=null&&db.queryForObject("SELECT count(*) FROM finance_gl_entry_allocations WHERE account_code=? AND currency_id IS DISTINCT FROM ?",Long.class,code,currency)!=0)
            throw conflict("该科目已有其他币别的已过账来源，不能更换币别，请用独立科目明细维护");
        db.update("UPDATE finance_chart_codes SET row_version=row_version+1,mapping_fingerprint=?,classification=?,currency_id=?,updated_at=now(),updated_by=? WHERE code=?",fingerprint,classification,currency,current.requireId(),code);
    }
    private void validateClassification(String code,String classification) {
        if(classification==null)return;
        for(String category:db.queryForList("SELECT DISTINCT s.category FROM finance_chart_code_styles m JOIN payment_styles s ON s.id=m.style_id WHERE m.code=?",String.class,code))
            FinanceChartClassification.resolve(code,classification,category);
    }
    private UUID currencyIdentity(String source,UUID selected,UUID existing) {
        var choices=chartCurrencies.choices();UUID id=selected==null?existing:selected;
        if(id==null&&(source==null||source.isBlank())) {
            var base=choices.stream().filter(com.uten.imp.application.port.FinancialChartCurrencyReadPort.Choice::baseCurrency).toList();
            if(base.size()!=1)throw invalid("请先维护唯一有效本位币，不能按币别名称或旧编号猜测");id=base.getFirst().id();
        }
        if(id==null)return null;UUID resolved=id;
        var choice=choices.stream().filter(value->value.id().equals(resolved)).findFirst().orElseThrow(()->invalid("请选择有效币别"));
        if((source==null||source.isBlank())&&!choice.baseCurrency())throw invalid("未设置外币属性的原科目按本位币核算，请选择本位币");
        return id;
    }
    private String encode(Object value){try{return json.writeValueAsString(value);}catch(Exception e){throw new IllegalStateException("科目批次序列化失败",e);}}
    private <T>T decode(String value,Class<T> type){try{return com.uten.imp.common.finance.FinancialJsonResults.value(json,value,type);}catch(Exception e){throw new IllegalStateException("科目批次记录无效",e);}}
    private static ApiException invalid(String message){return new ApiException(ErrorCode.VALIDATION_FAILED,message);}
    private static ApiException conflict(String message){return new ApiException(ErrorCode.CONFLICT,message);}

    /** Full selected lifecycle range through bounded summary batches; original detail/write contracts are unchanged. */
    public com.uten.imp.common.readsnapshot.VersionedSummaryPages.Page<Map<String,Object>> summaries(String requestedScope,int page,int size,String revision) {
        readAccess();UUID actor=current.requireId();
        String scope=com.uten.imp.common.readsnapshot.VersionedSummaryPages.scope(requestedScope);
        String where="actor_id=?"+switch(scope) {
            case "active" -> " AND (applied_at IS NULL AND cancelled_at IS NULL)";
            case "history" -> " AND (applied_at IS NOT NULL OR cancelled_at IS NOT NULL)";
            default -> "";
        };
        var request=new com.uten.imp.common.readsnapshot.VersionedSummaryPages.Request("finance-chart-imports","finance",Map.of("actor",actor),scope,page,size,1000,revision);
        return summaryPages.page(request,()->{readAccess();},
                ()->db.queryForObject("SELECT count(*) FROM finance_chart_imports WHERE "+where,Long.class,actor),
                (readPage,readSize)->db.queryForList("SELECT id AS \"importId\",source_name AS \"sourceName\",applied_at AS \"appliedAt\",cancelled_at AS \"cancelledAt\" FROM finance_chart_imports WHERE "+where+" ORDER BY created_at DESC,id DESC LIMIT ? OFFSET ?",actor,readSize,Math.multiplyExact((long)readPage-1,readSize)));
    }
}
