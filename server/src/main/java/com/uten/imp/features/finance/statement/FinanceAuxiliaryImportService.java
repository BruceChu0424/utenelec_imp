package com.uten.imp.features.finance.statement;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.common.report.ReportReadPlan;
import com.uten.imp.common.storage.ImmutableDocumentStore;
import com.uten.imp.common.web.*;
import com.uten.imp.features.finance.*;
import com.uten.imp.application.port.FinancialChartCurrencyReadPort;
import com.uten.imp.security.*;
import jakarta.persistence.EntityManager;
import lombok.RequiredArgsConstructor;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;
import java.math.BigDecimal;
import java.time.LocalDate;
import java.util.*;
import static com.uten.imp.features.finance.statement.FinanceAuxiliaryWorkbookParser.*;

/** Durable external evidence and explicit directory staging; no journal, receipt or payable writes. */
@Service @RequiredArgsConstructor
public class FinanceAuxiliaryImportService {
    @org.springframework.beans.factory.annotation.Autowired
    private com.uten.imp.common.readsnapshot.VersionedSummaryPages summaryPages;

    private final JdbcTemplate db;
    private final EntityManager em;
    private final ObjectMapper json;
    private final ImmutableDocumentStore files;
    private final SecurityContextCurrentUser current;
    private final TxSessionVars tx;
    private final FinanceDocumentAccessPolicy access;
    private final FinanceAuxiliaryService auxiliaries;
    private final FinancialChartCurrencyReadPort chartCurrencies;
    private final FinanceDocumentIntakeOperations intake;
    public record Preview(UUID importId,boolean receivable,String sourceSystem,UUID currencyId,LocalDate dateFrom,LocalDate dateTo,
                          String sourceName,String sha256,List<Row> rows,List<Issue> issues,boolean directoryApplied,
                          List<com.uten.imp.features.finance.report.ReportColumn> columns,String currencyMappingFingerprint,int columnContractVersion) {
        public Preview(UUID importId,boolean receivable,String sourceSystem,UUID currencyId,LocalDate dateFrom,LocalDate dateTo,
                String sourceName,String sha256,List<Row> rows,List<Issue> issues,boolean directoryApplied,
                List<com.uten.imp.features.finance.report.ReportColumn> columns,String currencyMappingFingerprint){
            this(importId,receivable,sourceSystem,currencyId,dateFrom,dateTo,sourceName,sha256,rows,issues,directoryApplied,columns,currencyMappingFingerprint,1);
        }
        public Preview {columns=columns==null?FinanceAuxiliaryReports.columns(receivable):List.copyOf(columns);currencyMappingFingerprint=currencyMappingFingerprint==null?"LEGACY":currencyMappingFingerprint;}
        public Preview(UUID importId,boolean receivable,String sourceSystem,UUID currencyId,LocalDate dateFrom,LocalDate dateTo,
                String sourceName,String sha256,List<Row> rows,List<Issue> issues,boolean directoryApplied) {
            this(importId,receivable,sourceSystem,currencyId,dateFrom,dateTo,sourceName,sha256,rows,issues,directoryApplied,FinanceAuxiliaryReports.columns(receivable),"LEGACY");
        }
    }
    public record DirectoryResult(UUID importId,int auxiliaryCount,String status) { }
    public record Comparison(int sourceRow,String accountCode,String partyCode,String status,List<String> differences,Map<String,Object> ledger) { }
    private void authorize(){CurrentAuthorityGuard.requireAll("finance_report:view");FinanceCompanyReportAccess.require(access);}
    private void write(){authorize();CurrentAuthorityGuard.requireAll("payment_style:edit");}
    private void lock(){db.query("SELECT pg_advisory_xact_lock(hashtextextended('uten:finance-auxiliary-import',0))",rs->{});}

    @Transactional
    public Preview preview(boolean receivable,String sourceSystem,UUID currencyId,LocalDate from,LocalDate to,String filename,byte[] bytes) {
        return preview(receivable,sourceSystem,currencyId,from,to,filename,bytes,null,null);
    }
    @Transactional
    public Preview preview(boolean receivable,String sourceSystem,UUID currencyId,LocalDate from,LocalDate to,String filename,byte[] bytes,UUID requestId,String contentType) {
        write();if(sourceSystem==null||sourceSystem.isBlank()||sourceSystem.length()>80)throw invalid("请填写原来源账套");
        if(from==null||to==null||from.isAfter(to))throw invalid("请选择完整的核对期间");
        if(currencyId==null||db.queryForObject("SELECT count(*) FROM currencies WHERE id=?",Integer.class,currencyId)!=1)throw invalid("请选择原币别属性，明细金额仍是总账本币");
        if(bytes==null||bytes.length==0||bytes.length>15*1024*1024)throw invalid("文件应完整且不超过15MB");
        tx.bind();String payload=ImmutableDocumentStore.digest(encode(Arrays.asList("finance-document-intake-v1",receivable,sourceSystem,currencyId.toString(),from.toString(),to.toString(),filename,contentType,ImmutableDocumentStore.digest(bytes),new TreeMap<>(com.uten.imp.common.finance.BusinessPrecisionContext.choices()))).getBytes(java.nio.charset.StandardCharsets.UTF_8));
        if(requestId!=null){UUID original=intake.existing(requestId,FinanceDocumentIntakeOperations.Family.AUXILIARY_STATEMENT_PREVIEW,payload);if(original!=null)return imported(original);}
        lock();String book=sourceSystem.strip(),hash=ImmutableDocumentStore.digest(bytes),kind=kind(receivable);
        String name=filename==null?"auxiliary.xlsx":filename.replaceAll("[\\\\/:*?\"<>|\\p{Cntrl}]","_");
        if(name.isBlank()||name.length()>240)throw invalid("文件名称无效");
        var parsed=FinanceAuxiliaryWorkbookParser.parse(receivable,name,bytes);var resolved=resolveCurrencies(parsed);
        String mapping=resolved.fingerprint();
        var previous=db.queryForList("SELECT id FROM finance_statement_source_reviews WHERE actor_id=? AND kind=? AND source_system=? AND currency_id=? AND date_from=? AND date_to=? AND sha256=? AND currency_mapping_fingerprint=?",UUID.class,current.requireId(),kind,book,currencyId,from,to,hash,mapping);
        if(!previous.isEmpty()){
            files.checkLegacy("FINANCE_AUXILIARY_COMPARE_REPLAY",bytes);Preview original=imported(previous.getFirst());
            if(!original.directoryApplied()&&original.columnContractVersion()!=com.uten.imp.common.importing.ImportColumnGuard.VERSION){
                throw invalid(com.uten.imp.common.importing.ImportColumnGuard.retiredPreviewMessage());
            }
            if(requestId!=null){intake.complete(requestId,FinanceDocumentIntakeOperations.Family.AUXILIARY_STATEMENT_PREVIEW,payload,previous.getFirst());}return imported(previous.getFirst());
        }
        UUID id=UUID.randomUUID();
        Preview preview=new Preview(id,receivable,book,currencyId,from,to,name,hash,resolved.rows(),resolved.issues(),false,FinanceAuxiliaryReports.columns(receivable),mapping);
        var stored=files.save("FINANCE_AUXILIARY_COMPARE",name,name.toLowerCase(Locale.ROOT).endsWith(".xls")?"application/vnd.ms-excel":"application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",bytes);
        db.update("INSERT INTO finance_statement_source_reviews(id,actor_id,kind,source_system,currency_id,date_from,date_to,source_name,sha256,storage_provider,storage_key,storage_version,storage_size,preview,currency_mapping_fingerprint) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?::jsonb,?)",
                id,current.requireId(),kind,book,currencyId,from,to,name,hash,stored.provider(),stored.key(),stored.version(),stored.size(),encode(preview),mapping);
        db.update("INSERT INTO attachment_object_outbox(operation,storage_provider,storage_key,storage_version,dedupe_key) VALUES('DELETE_STAGING',?,?,?,?) ON CONFLICT(dedupe_key) DO NOTHING",stored.provider(),stored.key(),stored.version(),stored.provider()+"|DELETE_STAGING|"+stored.key()+"|"+Objects.toString(stored.version(),"<local>"));
        if(requestId!=null)intake.complete(requestId,FinanceDocumentIntakeOperations.Family.AUXILIARY_STATEMENT_PREVIEW,payload,id);
        return preview;
    }
    @Transactional(readOnly=true)public Map<String,Object> operation(UUID request){authorize();return Map.of("requestId",request,"preview",imported(intake.result(request,FinanceDocumentIntakeOperations.Family.AUXILIARY_STATEMENT_PREVIEW)));}
    @Transactional(readOnly=true)
    public Preview imported(UUID id) {
        authorize();var data=db.queryForList("SELECT preview::text,directory_applied_at FROM finance_statement_source_reviews WHERE id=? AND actor_id=?",id,current.requireId());
        if(data.isEmpty())throw new ApiException(ErrorCode.NOT_FOUND,"辅助导入批次不存在或不属于当前账号");
        var preview=decode(data.getFirst().get("preview").toString(),Preview.class);
        return new Preview(preview.importId(),preview.receivable(),preview.sourceSystem(),preview.currencyId(),preview.dateFrom(),preview.dateTo(),preview.sourceName(),preview.sha256(),preview.rows(),preview.issues(),data.getFirst().get("directory_applied_at")!=null,preview.columns(),preview.currencyMappingFingerprint(),preview.columnContractVersion());
    }
    @Transactional(readOnly=true)
    public List<Map<String,Object>> recent() {
        authorize();return db.queryForList("SELECT id AS \"importId\",source_name AS \"sourceName\",kind,source_system AS \"sourceSystem\",date_from AS \"dateFrom\",date_to AS \"dateTo\",directory_applied_at AS \"directoryAppliedAt\" FROM finance_statement_source_reviews WHERE actor_id=? ORDER BY created_at DESC,id LIMIT 15",current.requireId());
    }
    @Transactional(readOnly=true)public byte[] sourceBytes(UUID id){
        authorize();imported(id);var rows=db.queryForList("SELECT storage_provider,storage_key,storage_version,storage_size,sha256 FROM finance_statement_source_reviews WHERE id=? AND actor_id=?",id,current.requireId());
        if(rows.size()!=1)throw new ApiException(ErrorCode.NOT_FOUND,"本人原辅助明细文件尚未取得回执");var value=rows.getFirst();return files.read(new ImmutableDocumentStore.Reference(value.get("storage_provider").toString(),value.get("storage_key").toString(),(String)value.get("storage_version"),((Number)value.get("storage_size")).longValue(),value.get("sha256").toString()));
    }
    @Transactional
    public Preview recheck(UUID id) {return recheck(id,null);}
    @Transactional
    public Preview recheck(UUID id,UUID requestId) {
        write();var owned=imported(id);
        byte[] bytes=sourceBytes(id);
        return preview(owned.receivable(),owned.sourceSystem(),owned.currencyId(),owned.dateFrom(),owned.dateTo(),owned.sourceName(),bytes,requestId,owned.sourceName().toLowerCase(Locale.ROOT).endsWith(".xls")?"application/vnd.ms-excel":"application/vnd.openxmlformats-officedocument.spreadsheetml.sheet");
    }
    private record ResolvedCurrencies(List<Row> rows,List<Issue> issues,String fingerprint) { }
    private ResolvedCurrencies resolveCurrencies(Parsed parsed) {
        var codes=new TreeSet<String>();parsed.rows().forEach(row->codes.add(row.accountCode()));var references=chartCurrencies.read(codes);
        var rows=new ArrayList<Row>();var issues=new ArrayList<>(parsed.issues());var mapping=new ArrayList<Object>();
        for(String code:codes){var reference=references.get(code);mapping.add(reference==null?List.of(code,"MISSING_ACCOUNT"):List.of(code,Objects.toString(reference.currencyId(),"UNMAPPED"),reference.chartVersion(),reference.baseCurrency(),Objects.toString(reference.sourceCurrencyName(),"")));}
        for(var row:parsed.rows()) {
            var reference=references.get(row.accountCode());
            if(reference==null||reference.currencyId()==null)issues.add(new Issue(row.sourceRow(),"科目币别属性",reference==null?"原科目代码尚未维护，不能把整份默认币别套到该行":"原外币属性尚未明确对应币别UUID；请维护科目币别后重新核对原文件，不按美金/美元同名猜配"));
            rows.add(row.withCurrency(reference==null?null:reference.currencyId(),reference==null?null:reference.chartVersion()));
        }
        return new ResolvedCurrencies(List.copyOf(rows),List.copyOf(issues),ImmutableDocumentStore.digest(encode(mapping).getBytes(java.nio.charset.StandardCharsets.UTF_8)));
    }
    @Transactional
    public DirectoryResult applyDirectory(UUID id) {
        write();tx.bind();lock();var data=db.queryForList("SELECT directory_result::text FROM finance_statement_source_reviews WHERE id=? AND actor_id=? FOR UPDATE",id,current.requireId());
        if(data.isEmpty())throw new ApiException(ErrorCode.NOT_FOUND,"辅助导入批次不存在或不属于当前账号");
        if(data.getFirst().get("directory_result")!=null)return decode(data.getFirst().get("directory_result").toString(),DirectoryResult.class);
        Preview preview=imported(id);if(!preview.issues().isEmpty())throw invalid("请先修正全部原表错误；未写入任何辅助项目");
        com.uten.imp.common.importing.ImportColumnGuard.requireValidated(preview.columnContractVersion());
        String role=preview.receivable()?"CUSTOMER":"SUPPLIER";var names=new HashMap<String,String>();
        var existing=existing(preview);var ids=new HashSet<UUID>();
        for(var row:preview.rows()) {
            String earlier=names.putIfAbsent(row.partyCode(),row.partyName());
            if(earlier!=null&&!earlier.equals(row.partyName()))throw invalid("同一原辅助编号对应不同名称，请先核对原文件，不能合并同名对象");
            var old=existing.get(row.partyCode());
            var saved=auxiliaries.save(new FinanceAuxiliaryContracts.Save(old==null?null:(UUID)old.get("id"),old==null?null:((Number)old.get("row_version")).longValue(),preview.sourceSystem(),row.partyCode(),row.partyName(),role,
                    old==null?null:(UUID)old.get("party_id"),"辅助比对文件SHA256:"+preview.sha256()+"；原行:"+row.sourceRow(),row.accountCode()));
            ids.add(saved.id());
            // A repeated auxiliary under another account must use the current version, not a stale first-row snapshot.
            existing.put(row.partyCode(),new HashMap<>(Map.of("id",saved.id(),"row_version",saved.version())));
            if(saved.partyId()!=null)existing.get(row.partyCode()).put("party_id",saved.partyId());
        }
        DirectoryResult result=new DirectoryResult(id,ids.size(),"DIRECTORY_DRAFTS_APPLIED");
        db.update("UPDATE finance_statement_source_reviews SET directory_result=?::jsonb,directory_applied_at=now() WHERE id=?",encode(result),id);return result;
    }
    @Transactional(readOnly=true)
    public List<Comparison> compare(UUID id) {
        Preview preview=imported(id);if(!preview.issues().isEmpty())throw invalid("原表存在错误，不能作为完整金额比对依据");
        var existing=existing(preview);var selected=new LinkedHashSet<UUID>();existing.values().forEach(row->selected.add((UUID)row.get("id")));
        var actual=new HashMap<String,Map<String,Object>>();
        if(!selected.isEmpty())try(var ignored=ReportReadPlan.open(ReportReadPlan.ROWS_ONLY)) {
            for(int page=1;;page++) {
                var report=FinanceAuxiliaryReports.selectedBalances(em,access,preview.receivable(),preview.dateFrom(),preview.dateTo(),null,preview.sourceSystem(),selected,page,500);
                for(var row:report.rows())actual.put(row.get("accountCode")+"\u0000"+row.get("partyCode")+"\u0000"+row.get("__currencyId"),row);
                if(report.rows().size()<500)break;
                if(page>=40)throw invalid("辅助比对结果超过完整读取范围，请缩小原文件范围");
            }
        }
        var result=new ArrayList<Comparison>();
        var labels=new HashMap<String,String>();FinanceAuxiliaryReports.columns(preview.receivable()).forEach(column->labels.put(column.key(),column.label()));
        for(var source:preview.rows()) {
            if(!existing.containsKey(source.partyCode())){result.add(new Comparison(source.sourceRow(),source.accountCode(),source.partyCode(),"AUXILIARY_NOT_REGISTERED",List.of("原账套及辅助编号尚未维护"),Map.of()));continue;}
            var row=actual.get(source.accountCode()+"\u0000"+source.partyCode()+"\u0000"+source.currencyId());
            if(row==null){result.add(new Comparison(source.sourceRow(),source.accountCode(),source.partyCode(),"LEDGER_EVIDENCE_MISSING",List.of("缺少该科目+辅助项目+币别的受审GL/零余额依据，不能按零比对"),Map.of()));continue;}
            var differences=new ArrayList<String>();
            Map<String,BigDecimal> values=new LinkedHashMap<>();values.put("openingDebit",source.openingDebit());values.put("openingCredit",source.openingCredit());values.put("openingBalance",source.openingBalance());values.put("debit",source.debit());values.put("credit",source.credit());values.put("closingDebit",source.closingDebit());values.put("closingCredit",source.closingCredit());values.put("closingBalance",source.closingBalance());
            values.forEach((key,expected)->{var value=row.get(key);if(value==null)differences.add(labels.get(key)+"：总账依据待核验");else if(expected.compareTo(new BigDecimal(value.toString()))!=0)differences.add(labels.get(key)+"：金额不一致");});
            if(!Objects.equals(row.get("openingDirection"),source.openingDirection()))differences.add(labels.get("openingDirection")+"不一致");
            if(!Objects.equals(row.get("closingDirection"),source.closingDirection()))differences.add(labels.get("closingDirection")+"不一致");
            if(!Objects.equals(row.get("accountName"),source.accountName()))differences.add("科目名称：原用途名称尚未对应");
            result.add(new Comparison(source.sourceRow(),source.accountCode(),source.partyCode(),differences.isEmpty()?(Boolean.TRUE.equals(row.get("__pending"))?"PENDING":"MATCHED"):"DIFFERENT",List.copyOf(differences),row));
        }
        return List.copyOf(result);
    }
    private Map<String,Map<String,Object>> existing(Preview preview) {
        var codes=preview.rows().stream().map(Row::partyCode).distinct().toList();
        String placeholders=String.join(",",Collections.nCopies(codes.size(),"?"));var args=new ArrayList<Object>();args.add(preview.sourceSystem());args.add(preview.receivable()?"CUSTOMER":"SUPPLIER");args.addAll(codes);
        var result=new HashMap<String,Map<String,Object>>();
        for(var row:db.queryForList("SELECT id,source_code,party_id,row_version FROM finance_auxiliary_items WHERE source_system=? AND role=? AND source_code IN ("+placeholders+")",args.toArray()))result.put(row.get("source_code").toString(),row);
        return result;
    }
    private String encode(Object value){try{return json.writeValueAsString(value);}catch(Exception ex){throw new IllegalStateException("辅助预览保存失败",ex);}}
    private <T>T decode(String value,Class<T> type){try{return json.readValue(value,type);}catch(Exception ex){throw new IllegalStateException("辅助预览读取失败",ex);}}
    private static String kind(boolean receivable){return receivable?"AUXILIARY_RECEIVABLE":"AUXILIARY_PAYABLE";}
    private static ApiException invalid(String message){return new ApiException(ErrorCode.VALIDATION_FAILED,message);}

    /** Full selected lifecycle range through bounded summary batches; original detail/write contracts are unchanged. */
    public com.uten.imp.common.readsnapshot.VersionedSummaryPages.Page<Map<String,Object>> summaries(String requestedScope,int page,int size,String revision) {
        authorize();UUID actor=current.requireId();
        String scope=com.uten.imp.common.readsnapshot.VersionedSummaryPages.scope(requestedScope);
        String where="actor_id=?"+switch(scope) {
            case "active" -> " AND (directory_applied_at IS NULL)";
            case "history" -> " AND (directory_applied_at IS NOT NULL)";
            default -> "";
        };
        var request=new com.uten.imp.common.readsnapshot.VersionedSummaryPages.Request("finance-auxiliary-imports","finance",Map.of("actor",actor),scope,page,size,1000,revision);
        return summaryPages.page(request,()->{authorize();},
                ()->db.queryForObject("SELECT count(*) FROM finance_statement_source_reviews WHERE "+where,Long.class,actor),
                (readPage,readSize)->db.queryForList("SELECT id AS \"importId\",source_name AS \"sourceName\",kind,source_system AS \"sourceSystem\",date_from AS \"dateFrom\",date_to AS \"dateTo\",directory_applied_at AS \"directoryAppliedAt\" FROM finance_statement_source_reviews WHERE "+where+" ORDER BY created_at DESC,id DESC LIMIT ? OFFSET ?",actor,readSize,Math.multiplyExact((long)readPage-1,readSize)));
    }
}
