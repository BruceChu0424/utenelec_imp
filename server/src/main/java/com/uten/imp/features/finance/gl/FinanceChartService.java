package com.uten.imp.features.finance.gl;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.application.concurrency.PaymentStyleHierarchyLock;
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
import java.util.*;
import static com.uten.imp.features.finance.gl.FinanceChartContracts.*;

@Service
@RequiredArgsConstructor
public class FinanceChartService {
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

    private void readAccess(){CurrentAuthorityGuard.requireAll("finance_report:view");FinanceCompanyReportAccess.require(access);}
    private void writeAccess(){readAccess();CurrentAuthorityGuard.requireAll("payment_style:edit");}
    private void lock(){db.query("SELECT pg_advisory_xact_lock(hashtextextended('uten:finance-chart',0))",rs->{});}

    @Transactional
    public CreateAccountResult createAccount(CreateAccount request) {
        writeAccess();
        if(request==null||request.requestId()==null||request.code()==null||!request.code().matches("[0-9]{1,32}")
                ||request.name()==null||request.name().isBlank()||request.name().strip().length()>240
                ||request.currencyName()==null||request.currencyName().length()>80
                ||request.sourceReference()==null||request.sourceReference().isBlank()||request.sourceReference().length()>1000)
            throw invalid("请填写完整数字文本代码、科目名称、外币名称属性和新增依据");
        if(request.category()!=null&&!Set.of("ACCOUNT","LIABILITY","EQUITY","INCOME","EXPENSE").contains(request.category()))throw invalid("核算类别不正确");
        if(request.category()!=null)CurrentAuthorityGuard.requireAll("payment_style:create");
        tx.bind();if(request.category()!=null){PaymentStyleHierarchyLock.lockForHierarchyChange(em);}lock();
        String fingerprint=ImmutableDocumentStore.digest(encode(request).getBytes(java.nio.charset.StandardCharsets.UTF_8));
        var previous=db.queryForList("SELECT actor_id,fingerprint,result::text FROM finance_chart_manual_operations WHERE request_id=?",request.requestId());
        if(!previous.isEmpty()) {
            var stored=previous.getFirst();if(!current.requireId().equals(stored.get("actor_id"))||!fingerprint.equals(stored.get("fingerprint")))throw conflict("同一新增请求已使用，请保留原参数核对结果");
            return decode(stored.get("result").toString(),CreateAccountResult.class);
        }
        String classification=FinanceChartClassification.resolve(request.code(),request.classification(),request.category());
        if(classification==null)throw invalid("请选择原表的财务类别：资产、负债、权益、成本或损益");
        UUID currency=currencyIdentity(request.currencyName(),request.currencyId(),null);
        if(db.queryForObject("SELECT count(*) FROM finance_chart_codes WHERE code=?",Integer.class,request.code())!=0)throw conflict("该财务代码已存在，请直接维护对应关系");
        db.update("INSERT INTO finance_chart_codes(code,name,currency_name,sort_order,source_row,source_kind,source_reference,classification,currency_id,updated_by) SELECT ?,?,?,COALESCE(max(sort_order),0)+1,1,'MANUAL',?,?,?,? FROM finance_chart_codes",
                request.code(),request.name().strip(),request.currencyName().strip(),request.sourceReference().strip(),classification,currency,current.requireId());
        if(request.category()!=null)createTarget(request.code(),new CreateTarget(0,request.category(),classification));
        var result=new CreateAccountResult(request.requestId(),request.code(),"CREATED");
        db.update("INSERT INTO finance_chart_manual_operations(request_id,actor_id,fingerprint,result) VALUES(?,?,?,?::jsonb)",request.requestId(),current.requireId(),fingerprint,encode(result));
        return result;
    }

    @Transactional
    public Preview preview(String filename,byte[] bytes) {
        writeAccess();tx.bind();lock();UUID actor=current.requireId();String hash=ImmutableDocumentStore.digest(bytes);
        var previous=db.queryForList("SELECT id FROM finance_chart_imports WHERE actor_id=? AND sha256=?",UUID.class,actor,hash);
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
    public List<Map<String,Object>> recent() {
        writeAccess();return db.queryForList("SELECT id AS \"importId\",source_name AS \"sourceName\",applied_at AS \"appliedAt\" FROM finance_chart_imports WHERE actor_id=? ORDER BY created_at DESC,id LIMIT 10",current.requireId());
    }

    @Transactional(readOnly=true)
    public Preview imported(UUID id) {
        writeAccess();var rows=db.queryForList("SELECT preview::text,applied_at FROM finance_chart_imports WHERE id=? AND actor_id=?",id,current.requireId());
        if(rows.isEmpty())throw new ApiException(ErrorCode.NOT_FOUND,"导入批次不存在或不属于当前账号");
        var p=decode((String)rows.getFirst().get("preview"),Preview.class);
        return new Preview(p.importId(),p.sourceName(),p.sha256(),p.rows(),p.issues(),rows.getFirst().get("applied_at")!=null);
    }

    @Transactional
    public Result apply(Apply request) {
        writeAccess();if(request==null||request.importId()==null)throw invalid("请选择已预览的科目文件");
        tx.bind();PaymentStyleHierarchyLock.lock(em);lock();UUID id=request.importId();
        var rows=db.queryForList("SELECT preview::text,applied_result::text FROM finance_chart_imports WHERE id=? AND actor_id=? FOR UPDATE",id,current.requireId());
        if(rows.isEmpty())throw new ApiException(ErrorCode.NOT_FOUND,"导入批次不存在或不属于当前账号");
        var data=rows.getFirst();if(data.get("applied_result")!=null)return decode((String)data.get("applied_result"),Result.class);
        Preview preview=decode((String)data.get("preview"),Preview.class);
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
        Result result=new Result(id,preview.rows().size(),"APPLIED");
        db.update("UPDATE finance_chart_imports SET applied_at=now(),applied_result=?::jsonb WHERE id=?",encode(result),id);
        return result;
    }

    @Transactional(readOnly=true)
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
        var currencies=chartCurrencies.read(codes);
        return db.query("SELECT code,name,currency_name,row_version,classification FROM finance_chart_codes ORDER BY sort_order,code",
                (rs,n)->new Account(rs.getString(1),rs.getString(2),rs.getString(3),rs.getLong(4),List.copyOf(targets.getOrDefault(rs.getString(1),List.of())),
                        List.copyOf(lineKeys.getOrDefault(rs.getString(1),List.of())),rs.getString(5),currencies.get(rs.getString(1)).currencyId()));
    }
    @Transactional(readOnly=true) public Map<String,Object> options(){readAccess();return Map.of("currencies",chartCurrencies.choices());}

    @Transactional
    public List<Account> createTarget(String code,CreateTarget request) {
        writeAccess();CurrentAuthorityGuard.requireAll("payment_style:create");
        if(request==null||request.category()==null||!Set.of("ACCOUNT","LIABILITY","EQUITY","INCOME","EXPENSE").contains(request.category()))
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
            return list();
        }
        if(((Number)row.get("row_version")).longValue()!=request.expectedVersion())throw conflict("科目目录已变化，请刷新后核对");
        if(db.queryForObject("SELECT count(*) FROM finance_chart_code_styles WHERE code=?",Integer.class,code)!=0)
            throw conflict("本财务科目已有对应，请核对现有取数，不能再创建一份");
        UUID style=accountCreation.create(code,(String)row.get("name"),request.category());
        db.update("UPDATE finance_chart_codes SET native_style_id=? WHERE code=?",style,code);
        return map(code,new Mapping(request.expectedVersion(),List.of(style),null,null,classification,request.currencyId()));
    }

    @Transactional
    public List<Account> map(String code,Mapping request) {
        writeAccess();if(request==null||code==null||!code.matches("[0-9]{1,32}"))throw invalid("请选择科目和当前版本");
        tx.bind();PaymentStyleHierarchyLock.lock(em);lock();
        // Same order as GlReportLineBindingService; no unguarded secondary report allocation.
        db.query("SELECT pg_advisory_xact_lock(hashtextextended('uten:finance-report-line-bindings',0))",rs->{});
        var version=db.queryForList("SELECT row_version FROM finance_chart_codes WHERE code=? FOR UPDATE",Long.class,code);
        if(version.size()!=1)throw new ApiException(ErrorCode.NOT_FOUND,"科目代码不存在");
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
        if(version.getFirst()!=request.expectedVersion()) {
            var saved=db.queryForObject("SELECT mapping_fingerprint FROM finance_chart_codes WHERE code=?",String.class,code);
            if(version.getFirst()==request.expectedVersion()+1&&before.equals(ids)&&fingerprint.equals(saved))return list();
            throw conflict("科目对应已变化，请刷新核对后重试");
        }
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
        return list();
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
    private <T>T decode(String value,Class<T> type){try{return json.readValue(value,type);}catch(Exception e){throw new IllegalStateException("科目批次记录无效",e);}}
    private static ApiException invalid(String message){return new ApiException(ErrorCode.VALIDATION_FAILED,message);}
    private static ApiException conflict(String message){return new ApiException(ErrorCode.CONFLICT,message);}
}
