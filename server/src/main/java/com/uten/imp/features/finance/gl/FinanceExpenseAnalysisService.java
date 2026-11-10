package com.uten.imp.features.finance.gl;

import com.uten.imp.common.finance.FinancialSourceAllocationGuard;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.common.storage.ImmutableDocumentStore;
import com.uten.imp.common.web.*;
import com.uten.imp.features.finance.*;
import com.uten.imp.features.finance.report.*;
import com.uten.imp.security.*;
import jakarta.persistence.EntityManager;
import lombok.RequiredArgsConstructor;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.*;
import java.math.BigDecimal;
import java.time.YearMonth;
import java.util.*;
import static com.uten.imp.features.finance.gl.FinanceExpenseAnalysisContracts.*;

/** Reviewed analysis metadata. It never changes the original GL amount, payment or posting state. */
@Service
@RequiredArgsConstructor
public class FinanceExpenseAnalysisService {
    private final JdbcTemplate db;
    private final EntityManager em;
    private final ObjectMapper json;
    private final ImmutableDocumentStore files;
    private final SecurityContextCurrentUser current;
    private final FinanceDocumentAccessPolicy access;
    private final TxSessionVars tx;
    @org.springframework.beans.factory.annotation.Autowired
    private com.uten.imp.common.readsnapshot.VersionedSummaryPages summaryPages;
    private void read(){CurrentAuthorityGuard.requireAll("finance_report:view");FinanceCompanyReportAccess.require(access);}
    private void write(){read();CurrentAuthorityGuard.requireAll("payment_style:edit");}
    private void lock(String period){db.query("SELECT pg_advisory_xact_lock(hashtextextended(?,7103))",rs->{},"finance-expense-analysis:"+period);}
    private String period(String value){try{var month=YearMonth.parse(value);if(month.getYear()<1||month.getYear()>9999)throw new IllegalArgumentException();return month.toString();}catch(Exception error){throw invalid("会计期间必须为YYYY-MM");}}
    private void editable(String period){if(Boolean.TRUE.equals(db.query("SELECT locked FROM finance_expense_analysis_periods WHERE period=?",rs->rs.next()?rs.getBoolean(1):false,period)))throw conflict("本期间归属已锁定，请先核对并解除锁定");}
    @Transactional(readOnly=true,isolation=Isolation.REPEATABLE_READ)
    public List<Map<String,Object>> groups(String rawPeriod){read();String period=period(rawPeriod);return db.queryForList("""
            SELECT id,period,label_snapshot AS label,employee_id AS "employeeId",channel,
                sales_amount_local::text AS "salesAmountLocal",sales_confirmed AS "salesConfirmed",reviewed,
                source_reference AS "sourceReference",sort_order AS "sortOrder",row_version AS version
            FROM finance_sales_expense_groups WHERE period=? ORDER BY sort_order,id
            """,period);}
    @Transactional
    public List<Map<String,Object>> saveGroup(GroupInput input){
        write();if(input==null||input.id()==null)throw invalid("请保留原分组编号");String period=period(input.period());tx.bind();lock(period);editable(period);
        String label=text(input.label(),240,"销售费用项目"),reference=optional(input.sourceReference(),1000,"来源依据");
        if(input.reviewed()&&reference.strip().length()<4)throw invalid("核对分组需要填写来源依据");
        if(input.channel()!=null&&!Set.of("OEM","FOREIGN","DOMESTIC","MANAGEMENT").contains(input.channel()))throw invalid("渠道不正确");
        if(input.employeeId()!=null&&db.queryForObject("SELECT count(*) FROM employees WHERE id=?",Integer.class,input.employeeId())!=1)throw invalid("人员不存在");
        BigDecimal sales=money(input.salesAmountLocal(),true);if(input.salesConfirmed()&&sales==null)throw invalid("确认销售额需填写明确金额，0为合法值");
        var canonical=new GroupInput(input.id(),period,input.expectedVersion(),label,input.employeeId(),input.channel(),sales==null?null:sales.stripTrailingZeros().toPlainString(),input.salesConfirmed(),input.reviewed(),reference,input.sortOrder());
        String fingerprint=digest(List.of(input.id(),period,label,Objects.toString(input.employeeId(),""),Objects.toString(input.channel(),""),Objects.toString(canonical.salesAmountLocal(),""),input.salesConfirmed(),input.reviewed(),reference,input.sortOrder()));
        var old=db.queryForList("SELECT period,row_version,request_fingerprint FROM finance_sales_expense_groups WHERE id=? FOR UPDATE",input.id());
        if(!old.isEmpty()){
            var row=old.getFirst();if(!period.equals(row.get("period").toString()))throw conflict("分组不能移到另一会计期间");
            if(fingerprint.equals(row.get("request_fingerprint")))return groups(period);
            if(((Number)row.get("row_version")).longValue()!=input.expectedVersion())throw conflict("分组已变化，请刷新核对后重试");
        }else if(input.expectedVersion()!=-1)throw conflict("分组已不存在，请重新核对");
        if(db.queryForObject("SELECT count(*) FROM finance_sales_expense_groups WHERE period=? AND label_snapshot=? AND id<>?",Integer.class,period,label,input.id())!=0)throw conflict("本期间已存在同名分组");
        if(old.isEmpty()){
            if(db.queryForObject("SELECT count(*) FROM finance_sales_expense_groups WHERE period=?",Integer.class,period)>=500)throw invalid("单期间最多500个费用分组");
            db.update("""
                INSERT INTO finance_sales_expense_groups(id,period,label_snapshot,employee_id,channel,sales_amount_local,
                    sales_confirmed,reviewed,source_reference,sort_order,request_fingerprint,updated_by) VALUES(?,?,?,?,?,?,?,?,?,?,?,?)
                """,input.id(),period,label,input.employeeId(),input.channel(),sales,input.salesConfirmed(),input.reviewed(),reference,input.sortOrder(),fingerprint,current.requireId());
        }else db.update("""
                UPDATE finance_sales_expense_groups SET label_snapshot=?,employee_id=?,channel=?,sales_amount_local=?,sales_confirmed=?,
                    reviewed=?,source_reference=?,sort_order=?,request_fingerprint=?,row_version=row_version+1,updated_at=now(),updated_by=? WHERE id=?
                """,label,input.employeeId(),input.channel(),sales,input.salesConfirmed(),input.reviewed(),reference,input.sortOrder(),fingerprint,current.requireId(),input.id());
        return groups(period);
    }
    @Transactional
    public List<Map<String,Object>> seedGroups(String rawPeriod){
        write();String period=period(rawPeriod);tx.bind();lock(period);editable(period);int month=YearMonth.parse(period).getMonthValue();
        for(var row:FinanceTemplateContract.template("salesExpense").required("sourceGroups"))if(row.required("month").asInt()==month){
            String label=row.required("label").asText();UUID id=UUID.nameUUIDFromBytes(("finance-sales-template:"+period+":"+row.required("sourceRow").asText()).getBytes(java.nio.charset.StandardCharsets.UTF_8));
            if(db.queryForObject("SELECT count(*) FROM finance_sales_expense_groups WHERE period=? AND label_snapshot=?",Integer.class,period,label)==0)
                saveGroup(new GroupInput(id,period,-1,label,null,null,null,false,false,"原稿附件14分组目录，待对应本期真实人员/渠道",row.required("sourceRow").asInt()));
        }return groups(period);
    }
    @Transactional(readOnly=true,isolation=Isolation.REPEATABLE_READ)
    public ReportTableResponse entries(String rawPeriod,int page,int size,FinanceReportColumnOptions options){
        read();String period=period(rawPeriod);
        var columns=List.of(ReportColumn.text("entryId","来源分录编号",180),ReportColumn.date("date","日期"),ReportColumn.text("billNo","来源单号",180),
                ReportColumn.text("styleCode","科目编码",100),ReportColumn.text("styleName","科目名称",220),ReportColumn.money("amount","本币金额"),ReportColumn.text("status","归属状态",110));
        return FinanceProjectedReportTable.query(em,columns,"""
                SELECT p.entry_id AS "entryId",p.entry_date AS date,p.source_bill_no AS "billNo",s.code AS "styleCode",s.name AS "styleName",
                    p.amount_local AS amount,CASE WHEN p.pending THEN '待核对' ELSE '已核对' END AS status
                FROM v_finance_sales_expense_pool p LEFT JOIN payment_styles s ON s.id=p.style_id WHERE p.period=:period
                """,q->q.setParameter("period",period),"report.date,report.\"entryId\"",options.filters(),Set.of("status"),page,size,options.sort(),options.order(),false,List.of());
    }
    @Transactional(readOnly=true,isolation=Isolation.REPEATABLE_READ)
    public Map<String,Object> entry(UUID id){
        read();var rows=db.queryForList("""
                SELECT p.entry_id AS "entryId",p.period,p.entry_date AS date,p.source_bill_no AS "billNo",s.code AS "styleCode",s.name AS "styleName",
                    p.amount_local::text AS "amountLocal",p.source_fingerprint AS "sourceFingerprint",p.pending,
                    a.allocations::text AS allocations,COALESCE(a.row_version,-1) AS version,a.source_reference AS "sourceReference"
                FROM v_finance_sales_expense_pool p LEFT JOIN payment_styles s ON s.id=p.style_id
                LEFT JOIN finance_sales_expense_assignments a ON a.entry_id=p.entry_id WHERE p.entry_id=?
                """,id);
        if(rows.isEmpty())throw new ApiException(ErrorCode.NOT_FOUND,"来源分录不在当前销售费用范围内或已变化");
        var result=new LinkedHashMap<>(rows.getFirst());if(result.get("date")!=null)result.put("date",result.get("date").toString());
        result.put("allocations",result.get("allocations")==null?List.of():decode(result.get("allocations").toString(),List.class));return result;
    }
    @Transactional
    public Map<String,Object> assign(AssignmentInput input){
        write();if(input==null||input.entryId()==null||input.allocations()==null||input.allocations().isEmpty()||input.allocations().size()>500)throw invalid("请完整填写1至500条来源分配");
        tx.bind();var source=entry(input.entryId());String period=source.get("period").toString();lock(period);editable(period);
        if(source.get("sourceFingerprint")==null||!Objects.equals(source.get("sourceFingerprint"),input.sourceFingerprint()))throw conflict("来源已变化或已不在销售费用范围，请重新读取核对并保留原分配证据");
        BigDecimal original=money(source.get("amountLocal").toString(),false),sum=BigDecimal.ZERO;List<Allocation> lines=new ArrayList<>();
        for(var row:input.allocations()){
            if(row.groupId()==null||!FinanceSalesExpenseReport.FEES.contains(row.feeKey()))throw invalid("请选择真实分组与原费用项目");
            BigDecimal amount=money(row.amountLocal(),false);if(amount.signum()*original.signum()<0)throw invalid("分配方向须与原分录一致");sum=sum.add(amount);
            lines.add(new Allocation(row.groupId(),row.feeKey(),row.clientId(),amount.stripTrailingZeros().toPlainString()));
        }FinancialSourceAllocationGuard.singleSource(original,lines.stream().map(row->money(row.amountLocal(),false)).toList());
        String reference=text(input.sourceReference(),1000,"来源依据");if(reference.length()<4)throw invalid("请填写完整来源依据");
        String fingerprint=digest(List.of(input.entryId(),input.sourceFingerprint(),lines,reference));
        var old=db.queryForList("SELECT row_version,request_fingerprint FROM finance_sales_expense_assignments WHERE entry_id=? FOR UPDATE",input.entryId());
        if(!old.isEmpty()&&fingerprint.equals(old.getFirst().get("request_fingerprint")))return entry(input.entryId());
        if(old.isEmpty()?input.expectedVersion()!=-1:((Number)old.getFirst().get("row_version")).longValue()!=input.expectedVersion())throw conflict("归属分配已变化，请刷新核对后重试");
        db.update("""
                INSERT INTO finance_sales_expense_assignments(entry_id,period,source_fingerprint,source_snapshot,allocations,source_reference,request_fingerprint,updated_by)
                VALUES(?,?,?,?::jsonb,?::jsonb,?,?,?) ON CONFLICT(entry_id) DO UPDATE SET
                    source_fingerprint=excluded.source_fingerprint,source_snapshot=excluded.source_snapshot,allocations=excluded.allocations,
                    source_reference=excluded.source_reference,request_fingerprint=excluded.request_fingerprint,row_version=finance_sales_expense_assignments.row_version+1,updated_at=now(),updated_by=excluded.updated_by
                """,input.entryId(),period,input.sourceFingerprint(),encode(source),encode(lines),reference,fingerprint,current.requireId());
        return entry(input.entryId());
    }
    @Transactional(readOnly=true)
    public Map<String,Object> policy(String rawPeriod){read();String period=period(rawPeriod);return db.queryForList("SELECT period,policy_confirmed AS confirmed,policy_reference AS \"sourceReference\",locked,row_version AS version FROM finance_expense_analysis_periods WHERE period=?",period)
            .stream().findFirst().orElse(Map.of("period",period,"confirmed",false,"sourceReference","","locked",false,"version",-1));}
    @Transactional
    public Map<String,Object> savePolicy(PolicyInput input){
        write();if(input==null)throw invalid("请核对期间口径");String period=period(input.period());tx.bind();lock(period);
        String reference=optional(input.sourceReference(),1000,"口径依据");if(input.confirmed()&&reference.length()<8)throw invalid("确认口径需填写至少8字的核对依据（含排除资本化重复）");
        if(input.confirmed()&&YearMonth.parse(period).isAfter(YearMonth.from(com.uten.imp.common.time.BusinessTime.today())))throw invalid("未来期间不能提前确认为已核对");
        var old=policy(period);boolean same=Objects.equals(old.get("confirmed"),input.confirmed())&&Objects.equals(old.get("locked"),input.locked())&&Objects.equals(old.get("sourceReference"),reference);
        if(same)return old;
        if(((Number)old.get("version")).longValue()!=input.expectedVersion())throw conflict("期间口径已变化，请刷新后核对");
        if(Boolean.TRUE.equals(old.get("locked"))&&!input.locked()&&optional(input.unlockReason(),1000,"解锁原因").length()<4)throw invalid("解除锁定需填写核对原因");
        db.update("""
                INSERT INTO finance_expense_analysis_periods(period,policy_confirmed,policy_reference,locked,updated_by) VALUES(?,?,?,?,?)
                ON CONFLICT(period) DO UPDATE SET policy_confirmed=excluded.policy_confirmed,policy_reference=excluded.policy_reference,
                    locked=excluded.locked,row_version=finance_expense_analysis_periods.row_version+1,updated_at=now(),updated_by=excluded.updated_by
                """,period,input.confirmed(),reference,input.locked(),current.requireId());return policy(period);
    }
    @Transactional(readOnly=true)
    public List<Map<String,Object>> notes(String rawPeriod){read();String period=period(rawPeriod);var stored=FinanceExpenseAnalysisReader.notes(em,period);List<Map<String,Object>> rows=new ArrayList<>();
        for(var definition:FinanceExpenseTemplateCatalog.operatingRows()){var row=new LinkedHashMap<String,Object>();row.put("lineKey",definition.key());row.put("category",definition.category());row.put("sub",definition.sub());row.put("item",definition.item());row.putAll(stored.getOrDefault(definition.key(),Map.of("remark","","varianceReason","","version",-1L)));rows.add(row);}return List.copyOf(rows);}
    @Transactional
    public List<Map<String,Object>> saveNote(NoteInput input){
        write();if(input==null||FinanceExpenseTemplateCatalog.operatingRows().stream().noneMatch(r->r.key().equals(input.lineKey())))throw invalid("原表项目不存在");String period=period(input.period());tx.bind();lock(period);editable(period);
        String remark=optional(input.remark(),2000,"备注"),reason=optional(input.varianceReason(),2000,"差异原因");
        var old=db.queryForList("SELECT remark,variance_reason,row_version FROM finance_operating_report_notes WHERE period=? AND line_key=? FOR UPDATE",period,input.lineKey());
        if(!old.isEmpty()&&remark.equals(old.getFirst().get("remark"))&&reason.equals(old.getFirst().get("variance_reason")))return notes(period);
        if(old.isEmpty()?input.expectedVersion()!=-1:((Number)old.getFirst().get("row_version")).longValue()!=input.expectedVersion())throw conflict("备注已变化，请刷新核对，原输入请保留");
        db.update("""
                INSERT INTO finance_operating_report_notes(period,line_key,remark,variance_reason,updated_by) VALUES(?,?,?,?,?)
                ON CONFLICT(period,line_key) DO UPDATE SET remark=excluded.remark,variance_reason=excluded.variance_reason,
                    row_version=finance_operating_report_notes.row_version+1,updated_at=now(),updated_by=excluded.updated_by
                """,period,input.lineKey(),remark,reason,current.requireId());return notes(period);
    }
    @Transactional(readOnly=true,isolation=Isolation.REPEATABLE_READ)
    public Map<String,Object> labor(String rawPeriod){
        read();String period=period(rawPeriod);var source=db.queryForList("SELECT source_count AS \"sourceCount\",positive_amount::text AS \"positiveAmount\",negative_amount::text AS \"negativeAmount\",source_fingerprint AS \"sourceFingerprint\",source_snapshot::text AS sources FROM v_finance_manufacturing_labor_pool WHERE period=?",period);
        var result=new LinkedHashMap<String,Object>();result.put("period",period);result.put("sourceAvailable",!source.isEmpty());
        if(!source.isEmpty()){result.putAll(source.getFirst());result.put("sources",decode(result.get("sources").toString(),List.class));}
        var saved=db.queryForList("""
                SELECT direct_positive::text AS "directPositive",indirect_positive::text AS "indirectPositive",
                    direct_negative::text AS "directNegative",indirect_negative::text AS "indirectNegative",reviewed,
                    source_reference AS "sourceReference",row_version AS version,source_fingerprint AS "savedFingerprint"
                FROM finance_manufacturing_labor_splits WHERE period=?
                """,period);
        if(!saved.isEmpty())result.putAll(saved.getFirst());else{result.put("version",-1L);result.put("reviewed",false);result.put("sourceReference","");}
        result.put("pending",source.isEmpty()||!Boolean.TRUE.equals(result.get("reviewed"))||!Objects.equals(result.get("sourceFingerprint"),result.get("savedFingerprint")));return result;
    }
    @Transactional
    public Map<String,Object> saveLabor(LaborSplitInput input){
        write();if(input==null)throw invalid("请核对工资源池");String period=period(input.period());tx.bind();
        db.query("SELECT pg_advisory_xact_lock(hashtextextended('uten:finance-report-line-bindings',0))",rs->{});lock(period);editable(period);
        var source=labor(period);if(!Boolean.TRUE.equals(source.get("sourceAvailable"))||!Objects.equals(source.get("sourceFingerprint"),input.sourceFingerprint()))throw conflict("工资源池已变化或没有明确来源，请重新核对");
        var dp=money(input.directPositive(),false);var ip=money(input.indirectPositive(),false);var dn=money(input.directNegative(),false);var in=money(input.indirectNegative(),false);
        for(var amount:List.of(dp,ip,dn,in))if(amount.signum()<0)throw invalid("正向与红字池请分别填写非负金额");
        if(input.reviewed())FinancialSourceAllocationGuard.separatePools(money(source.get("positiveAmount").toString(),false),money(source.get("negativeAmount").toString(),false),dp,ip,dn,in);
        String reference=text(input.sourceReference(),1000,"来源依据");if(reference.length()<4)throw invalid("请填写原凭证、期间和分配依据");
        String fingerprint=digest(List.of(period,input.sourceFingerprint(),dp.stripTrailingZeros().toPlainString(),ip.stripTrailingZeros().toPlainString(),dn.stripTrailingZeros().toPlainString(),in.stripTrailingZeros().toPlainString(),input.reviewed(),reference));
        var old=db.queryForList("SELECT row_version,request_fingerprint FROM finance_manufacturing_labor_splits WHERE period=? FOR UPDATE",period);
        if(!old.isEmpty()&&fingerprint.equals(old.getFirst().get("request_fingerprint")))return labor(period);
        if(old.isEmpty()?input.expectedVersion()!=-1:((Number)old.getFirst().get("row_version")).longValue()!=input.expectedVersion())throw conflict("人工分配已变化，请刷新核对，原输入请保留");
        db.update("""
                INSERT INTO finance_manufacturing_labor_splits(period,source_fingerprint,source_snapshot,direct_positive,indirect_positive,
                    direct_negative,indirect_negative,reviewed,source_reference,request_fingerprint,updated_by)
                VALUES(?,?,'[]'::jsonb,?,?,?,?,?,?,?,?) ON CONFLICT(period) DO UPDATE SET source_fingerprint=excluded.source_fingerprint,
                    direct_positive=excluded.direct_positive,indirect_positive=excluded.indirect_positive,direct_negative=excluded.direct_negative,
                    indirect_negative=excluded.indirect_negative,reviewed=excluded.reviewed,source_reference=excluded.source_reference,
                    request_fingerprint=excluded.request_fingerprint,row_version=finance_manufacturing_labor_splits.row_version+1,updated_at=now(),updated_by=excluded.updated_by
                """,period,input.sourceFingerprint(),dp,ip,dn,in,input.reviewed(),reference,fingerprint,current.requireId());return labor(period);
    }
    @Transactional
    public NoteImportPreview previewNotes(String rawPeriod,String filename,byte[] bytes){
        write();String period=period(rawPeriod);tx.bind();lock(period);editable(period);String hash=ImmutableDocumentStore.digest(bytes);UUID actor=current.requireId();
        var previous=db.queryForList("SELECT id FROM finance_expense_note_imports WHERE actor_id=? AND period=? AND sha256=?",UUID.class,actor,period,hash);
        if(!previous.isEmpty()){
            files.checkLegacy("FINANCE_EXPENSE_NOTES_REPLAY",bytes);var original=importedNotes(previous.getFirst());
            if(!original.applied()&&original.columnContractVersion()!=com.uten.imp.common.importing.ImportColumnGuard.VERSION){
                throw invalid(com.uten.imp.common.importing.ImportColumnGuard.retiredPreviewMessage());
            }
            return original;
        }
        String name=filename==null?"经营损益.xlsx":filename.replaceAll("[\\\\/:*?\"<>|\\p{Cntrl}]","_");if(name.isBlank()||name.length()>240)throw invalid("文件名称无效");
        Map<String,Long> versions=new HashMap<>();db.query("SELECT line_key,row_version FROM finance_operating_report_notes WHERE period=?",rs->{versions.put(rs.getString(1),rs.getLong(2));},period);
        UUID id=UUID.randomUUID();var result=FinanceOperatingNoteParser.parse(id,period,name,hash,bytes,versions);
        var stored=files.save("FINANCE_EXPENSE_NOTES",name,name.toLowerCase(Locale.ROOT).endsWith(".xls")?"application/vnd.ms-excel":"application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",bytes);
        db.update("INSERT INTO finance_expense_note_imports(id,actor_id,period,source_name,sha256,storage_provider,storage_key,storage_version,storage_size,preview) VALUES(?,?,?,?,?,?,?,?,?,?::jsonb)",id,actor,period,name,hash,stored.provider(),stored.key(),stored.version(),stored.size(),encode(result));
        db.update("INSERT INTO attachment_object_outbox(operation,storage_provider,storage_key,storage_version,dedupe_key) VALUES('DELETE_STAGING',?,?,?,?) ON CONFLICT(dedupe_key) DO NOTHING",stored.provider(),stored.key(),stored.version(),stored.provider()+"|DELETE_STAGING|"+stored.key()+"|"+Objects.toString(stored.version(),"<local>"));return result;
    }
    /** Complete authorized import metadata, never the encrypted preview/body. */
    @Transactional(readOnly=true)
    public com.uten.imp.common.readsnapshot.VersionedSummaryPages.Page<Map<String,Object>> noteImportSummaries(
            String rawPeriod,String requestedScope,int page,int size,String revision) {
        write();String period=period(rawPeriod);
        String scope=com.uten.imp.common.readsnapshot.VersionedSummaryPages.scope(requestedScope);
        UUID actor=current.requireId();
        String where="actor_id=? AND period=?"+switch(scope) {
            case "active" -> " AND applied_at IS NULL";
            case "history" -> " AND applied_at IS NOT NULL";
            default -> "";
        };
        var request=new com.uten.imp.common.readsnapshot.VersionedSummaryPages.Request(
                "finance-expense-note-imports","finance",List.of("lifecycle-v1",actor,period,scope),
                scope,page,size,1000,revision);
        return summaryPages.page(request,this::write,
                ()->Objects.requireNonNull(db.queryForObject("SELECT count(*) FROM finance_expense_note_imports WHERE "+where,Long.class,actor,period)),
                (readPage,readSize)->db.queryForList("SELECT id AS \"importId\",source_name AS \"sourceName\",applied_at AS \"appliedAt\" FROM finance_expense_note_imports WHERE "+where+" ORDER BY created_at DESC,id DESC LIMIT ? OFFSET ?",actor,period,readSize,Math.multiplyExact((long)readPage-1,readSize)));
    }

    @Transactional(readOnly=true)
    public List<Map<String,Object>> recentNoteImports(String rawPeriod){write();String period=period(rawPeriod);return db.queryForList("SELECT id AS \"importId\",source_name AS \"sourceName\",applied_at AS \"appliedAt\" FROM finance_expense_note_imports WHERE actor_id=? AND period=? ORDER BY created_at DESC,id LIMIT 10",current.requireId(),period);}
    @Transactional(readOnly=true)
    public NoteImportPreview importedNotes(UUID id){write();var rows=db.queryForList("SELECT preview::text,applied_at FROM finance_expense_note_imports WHERE id=? AND actor_id=?",id,current.requireId());if(rows.isEmpty())throw new ApiException(ErrorCode.NOT_FOUND,"导入批次不存在或不属于当前账号");var p=decode(rows.getFirst().get("preview").toString(),NoteImportPreview.class);return new NoteImportPreview(p.importId(),p.period(),p.sourceName(),p.sha256(),p.rows(),p.issues(),rows.getFirst().get("applied_at")!=null,p.columnContractVersion());}
    @Transactional
    public Map<String,Object> applyNotes(ImportApply request){
        write();if(request==null||request.importId()==null)throw invalid("请选择已预览的备注文件");tx.bind();var p=importedNotes(request.importId());lock(p.period());
        var row=db.queryForList("SELECT preview::text,applied_result::text FROM finance_expense_note_imports WHERE id=? AND actor_id=? FOR UPDATE",request.importId(),current.requireId()).getFirst();
        if(row.get("applied_result")!=null){try{return json.readValue(row.get("applied_result").toString(),new com.fasterxml.jackson.core.type.TypeReference<Map<String,Object>>(){});}catch(com.fasterxml.jackson.core.JsonProcessingException error){throw new IllegalStateException("归属记录无效",error);}}
        editable(p.period());
        p=decode(row.get("preview").toString(),NoteImportPreview.class);if(!p.issues().isEmpty())throw invalid("请先修正预览中的全部错误，未写入任何备注");
        com.uten.imp.common.importing.ImportColumnGuard.requireValidated(p.columnContractVersion());
        var currentNotes=FinanceExpenseAnalysisReader.notes(em,p.period());
        for(var item:p.rows()){
            var old=currentNotes.getOrDefault(item.lineKey(),Map.of("version",-1L,"remark","","varianceReason",""));
            if(((Number)old.get("version")).longValue()!=item.expectedVersion())throw conflict("备注已变化，请重新预览："+item.category()+"/"+item.sub()+"/"+item.item());
            saveNote(new NoteInput(p.period(),item.lineKey(),item.expectedVersion(),item.remark().isBlank()?old.get("remark").toString():item.remark(),item.varianceReason().isBlank()?old.get("varianceReason").toString():item.varianceReason()));
        }
        Map<String,Object> result=Map.of("importId",p.importId(),"period",p.period(),"count",p.rows().size(),"state","APPLIED");db.update("UPDATE finance_expense_note_imports SET applied_at=now(),applied_result=?::jsonb WHERE id=?",encode(result),p.importId());return result;
    }
    static BigDecimal money(String raw,boolean optional){return FinancialSourceAllocationGuard.amount(raw,optional);}
    static String text(String value,int limit,String label){String result=optional(value,limit,label).strip();if(result.isEmpty())throw invalid(label+"不能为空");return result;}
    static String optional(String value,int limit,String label){String result=value==null?"":value;if(result.length()>limit)throw invalid(label+"过长");return result;}
    private String digest(Object value){return ImmutableDocumentStore.digest(encode(value).getBytes(java.nio.charset.StandardCharsets.UTF_8));}
    private String encode(Object value){try{return json.writeValueAsString(value);}catch(Exception error){throw new IllegalStateException("归属记录序列化失败",error);}}
    private <T>T decode(String value,Class<T> type){try{return json.readValue(value,type);}catch(Exception error){throw new IllegalStateException("归属记录无效",error);}}
    private static ApiException invalid(String message){return new ApiException(ErrorCode.VALIDATION_FAILED,message);}
    private static ApiException conflict(String message){return new ApiException(ErrorCode.CONFLICT,message);}
}
