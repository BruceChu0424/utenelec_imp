package com.uten.imp.features.finance.statement;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.application.port.FinanceMaterialStatementSourcePort;
import com.uten.imp.application.port.FinanceSubcontractQuantityEvidenceReadPort;
import com.uten.imp.common.report.ReportQueryKit;
import com.uten.imp.common.finance.BusinessPrecisionContext;
import com.uten.imp.common.finance.BusinessPrecisionRequiredException;
import com.uten.imp.common.storage.ImmutableDocumentStore;
import com.uten.imp.common.files.document.DocumentIntakeProfile;
import com.uten.imp.common.util.FinancialExactAmount;
import com.uten.imp.common.web.*;
import com.uten.imp.features.finance.*;
import com.uten.imp.security.*;
import lombok.RequiredArgsConstructor;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;
import java.math.BigDecimal;
import java.time.LocalDate;
import java.util.*;
import static com.uten.imp.application.port.FinanceSubcontractQuantityEvidenceReadPort.*;
import static com.uten.imp.features.finance.statement.FinanceSubcontractQuantityEvidenceContracts.*;

/** Reviewed sources for financial original quantities only; no stock, ERP consumption, cost or money mutation. */
@Service @RequiredArgsConstructor
public class FinanceSubcontractQuantityEvidenceService implements FinanceSubcontractQuantityEvidenceReadPort {
    private final JdbcTemplate db;private final ObjectMapper json;private final TxSessionVars tx;
    private final SecurityContextCurrentUser current;private final FinanceDocumentAccessPolicy access;
    private final FinanceMaterialStatementSourcePort physical;private final ImmutableDocumentStore files;
    private void read(){CurrentAuthorityGuard.requireAll("finance_report:view");FinanceCompanyReportAccess.require(access);}
    private record Resolved(SourceSnapshot snapshot,UUID orderItemId,UUID relatedIssueId) { }
    private record Validated(Input input,String scopeKey,String statementKey,SourceSnapshot source,SourceSnapshot material,BigDecimal applied,BigDecimal estimate,String estimateBasis) { }
    @Transactional(readOnly=true)
    public Map<String,Object> list(Scope scope,int page,int size){
        read();scope(scope);int p=Math.max(1,page),s=Math.max(1,Math.min(100,size));
        var named=new org.springframework.jdbc.core.namedparam.NamedParameterJdbcTemplate(db);var parameters=new HashMap<String,Object>(Map.of("partyId",scope.supplierId(),"from",scope.dateFrom(),"to",scope.dateTo()));
        String selection=" FROM finance_subcontract_quantity_evidence evidence WHERE "+scopeSelection();
        long total=Objects.requireNonNull(named.queryForObject("SELECT count(*)"+selection,parameters,Long.class));parameters.put("size",s);parameters.put("offset",(long)(p-1)*s);
        var rows=named.queryForList("SELECT evidence.*"+selection+" ORDER BY evidence.submitted_at DESC,evidence.id LIMIT :size OFFSET :offset",parameters);
        return Map.of("items",rows.stream().map(this::view).toList(),"page",p,"size",s,"total",total,"totalPages",(total+s-1)/s);
    }
    @Transactional(readOnly=true)
    public Map<String,Object> sourceChoices(Scope scope,SourceKind kind,String keyword,int page,int size,UUID orderItemId){
        read();scope(scope);if(kind==null)throw invalid("请选择原发料、退料、回厂或成品退货来源类型");
        String headers=switch(kind){case MATERIAL_ISSUE->"subcontract_material_issues";case MATERIAL_RETURN->"subcontract_material_returns";case RECEIPT->"subcontract_receipts";case PRODUCT_RETURN->"subcontract_returns";};
        String items=switch(kind){case MATERIAL_ISSUE->"subcontract_material_issue_items";case MATERIAL_RETURN->"subcontract_material_return_items";case RECEIPT->"subcontract_receipt_items";case PRODUCT_RETURN->"subcontract_return_items";};
        String parent=switch(kind){case MATERIAL_ISSUE->"issue_id";case MATERIAL_RETURN->"material_return_id";case RECEIPT->"receipt_id";case PRODUCT_RETURN->"return_id";};
        boolean linkedIssue=orderItemId!=null&&kind==SourceKind.MATERIAL_ISSUE;
        String period=linkedIssue?"COALESCE(item.bill_date,document.bill_date)<=?":"COALESCE(item.bill_date,document.bill_date) BETWEEN ? AND ?";
        String from=" FROM "+items+" item JOIN "+headers+" document ON document.id=item."+parent+" JOIN goods ON goods.id=item.goods_id WHERE document.supplier_id=? AND "+period+" AND((document.status=1 AND NOT document.is_deleted AND NOT item.is_deleted) OR document.status=-1)";
        var args=new ArrayList<Object>();args.add(scope.supplierId());if(!linkedIssue){args.add(scope.dateFrom());}args.add(scope.dateTo());
        if(orderItemId!=null){from+=" AND item.order_item_id=?";args.add(orderItemId);}
        if(keyword!=null&&!keyword.isBlank()){from+=" AND lower(concat_ws(' ',document.bill_no,goods.code,goods.name)) LIKE '%'||lower(?)||'%'";args.add(keyword.strip());}
        long total=Objects.requireNonNull(db.queryForObject("SELECT count(*)"+from,Long.class,args.toArray()));int p=Math.max(1,page),n=Math.max(1,Math.min(100,size));args.add(n);args.add((long)(p-1)*n);
        var ids=db.queryForList("SELECT item.id"+from+" ORDER BY COALESCE(item.bill_date,document.bill_date),document.bill_no,item.id LIMIT ? OFFSET ?",UUID.class,args.toArray());
        return Map.of("items",ids.stream().map(id->sourceChoice(new SourceRef(kind,id),scope.supplierId())).toList(),"page",p,"size",n,"total",total,"totalPages",(total+n-1)/n);
    }
    @Transactional(readOnly=true)public Map<String,Object> sourceChoice(SourceRef ref,UUID supplier){
        read();if(ref==null||ref.kind()==null||ref.itemId()==null||supplier==null)throw invalid("请选择真实来源类型、来源行及供应商");
        var resolved=resolve(ref);if(!supplier.equals(resolved.snapshot().supplierId()))throw invalid("原业务来源不属于本供应商");
        var result=new LinkedHashMap<String,Object>();result.put("source",resolved.snapshot());result.put("orderItemId",resolved.orderItemId());result.put("materialIssueItemId",ref.kind()==SourceKind.MATERIAL_ISSUE?ref.itemId():resolved.relatedIssueId());return result;
    }
    @Transactional(readOnly=true)public List<Map<String,Object>> pcsUnits(){read();return db.queryForList("SELECT id,code,name FROM units WHERE upper(btrim(code))='PCS' AND NOT is_deleted ORDER BY id");}
    @Transactional(readOnly=true)public Map<String,Object> get(UUID id){read();return view(row(id,false));}
    @Transactional(readOnly=true)public Map<String,Object> operation(UUID request){
        read();var rows=db.queryForList("SELECT * FROM finance_subcontract_quantity_evidence WHERE request_id=? AND submitted_by=?",request,current.requireId());
        if(rows.size()!=1)throw new ApiException(ErrorCode.NOT_FOUND,"本人原数量提交尚未取得成功回执，请保留原请求");return view(rows.getFirst());
    }
    @Override @Transactional(readOnly=true)
    public Snapshot approved(Scope scope){
        read();scope(scope);var rows=db.queryForList("SELECT * FROM v_finance_subcontract_quantity_evidence_current WHERE enabled AND supplier_id=? AND date_from=? AND date_to=? ORDER BY goods_id,color_id NULLS FIRST,pcs_unit_id,purpose,source_kind,source_item_id,material_issue_item_id,id LIMIT 20001",scope.supplierId(),scope.dateFrom(),scope.dateTo());
        if(rows.size()>20000)throw invalid("原表数量证据超过本次完整读取范围，请按真实期间分段核对，不能截断确认");
        var result=new ArrayList<Approved>();for(var row:rows){verifySources(row);result.add(approvedRow(row));}
        return new Snapshot(scope,List.copyOf(result),hash(result));
    }
    @Transactional(readOnly=true)
    public Snapshot relevant(Scope scope){
        read();scope(scope);var named=new org.springframework.jdbc.core.namedparam.NamedParameterJdbcTemplate(db);
        String sql="SELECT evidence.* FROM v_finance_subcontract_quantity_evidence_current evidence WHERE evidence.enabled AND "+scopeSelection()+" ORDER BY evidence.goods_id,evidence.color_id NULLS FIRST,evidence.pcs_unit_id,evidence.purpose,evidence.source_kind,evidence.source_item_id,evidence.material_issue_item_id,evidence.id LIMIT 20001";
        var rows=named.queryForList(sql,Map.of("partyId",scope.supplierId(),"from",scope.dateFrom(),"to",scope.dateTo()));
        if(rows.size()>20000)throw invalid("本期原表数量证据超过完整读取范围，不能截断后确认");
        var result=new ArrayList<Approved>();for(var row:rows){verifySources(row);result.add(approvedRow(row));}return new Snapshot(scope,List.copyOf(result),hash(result));
    }
    private String scopeSelection(){return "evidence.supplier_id=:partyId AND((evidence.purpose<>'ROW_CORRESPONDENCE' AND evidence.date_from=:from AND evidence.date_to=:to) OR(evidence.purpose='ROW_CORRESPONDENCE' AND EXISTS(SELECT 1 FROM ("+FinanceSubcontractTemplateSql.relevantSourcesSql()+") source WHERE source.id=evidence.source_item_id AND source.source_kind=evidence.source_kind)))";}
    public String statementJson(Snapshot snapshot){
        var result=new ArrayList<Map<String,Object>>();for(var evidence:snapshot.evidence())if(Boolean.TRUE.equals(evidence.input().applyToStatement())){
            Input input=evidence.input();var row=new LinkedHashMap<String,Object>();row.put("id",evidence.id());row.put("purpose",input.purpose());row.put("evidence_type",input.evidenceType());row.put("source_kind",input.source()==null?null:input.source().kind());row.put("source_item_id",input.source()==null?null:input.source().itemId());row.put("material_issue_item_id",input.materialIssueItemId());row.put("goods_id",input.stockGroup().goodsId());row.put("color_id",input.stockGroup().colorId());row.put("unit_id",input.stockGroup().pcsUnitId());row.put("quantity",evidence.appliedQuantityPcs().toPlainString());row.put("order_item_id",evidence.source()==null?null:evidence.source().orderItemId());row.put("goods_code",evidence.materialSource()==null?null:evidence.materialSource().goodsCode());row.put("goods_name",evidence.materialSource()==null?null:evidence.materialSource().goodsName());result.add(row);
        }return encode(result);
    }
    @Transactional
    public Map<String,Object> save(Save command,String filename,String contentType,byte[] bytes){
        read();CurrentAuthorityGuard.requireAll("payment_style:edit");
        if(command==null||command.requestId()==null||command.input()==null)throw invalid("请保留原数量请求编号并填写原表来源");
        String fileHash=bytes==null?null:ImmutableDocumentStore.digest(bytes);
        String payload=hash(Arrays.asList(command,filename,contentType,fileHash,new TreeMap<>(BusinessPrecisionContext.choices())));tx.bind();requestLock(command.requestId());
        var replay=db.queryForList("SELECT * FROM finance_subcontract_quantity_evidence WHERE request_id=?",command.requestId());
        if(!replay.isEmpty()){var old=replay.getFirst();if(!Objects.equals(old.get("submitted_by"),current.requireId())||!Objects.equals(old.get("payload_hash"),payload))throw conflict("原请求属于不同操作者、输入或附件，请保留本人原请求");return view(old);}
        var value=validate(command.input());scopeLock(value.scopeKey());
        long latest=Objects.requireNonNull(db.queryForObject("SELECT COALESCE(max(revision),-1) FROM finance_subcontract_quantity_evidence WHERE scope_key=?",Long.class,value.scopeKey()));
        if(latest!=command.expectedRevision())throw conflict("原表数量证据已有后续版本，请先读取原提交，不覆盖旧证据");
        ImmutableDocumentStore.Reference reference=null;Attachment attachment=null;
        if(command.attachmentEvidenceId()!=null){
            if(bytes!=null)throw invalid("请选择复用原附件或上传本次附件，不能同时替换");var prior=row(command.attachmentEvidenceId(),false);
            if(!Objects.equals(prior.get("supplier_id"),value.input().scope().supplierId())||!date(prior.get("date_from")).equals(value.input().scope().dateFrom())||!date(prior.get("date_to")).equals(value.input().scope().dateTo()))throw invalid("复用的实际凭据须属于同一供应商和原期间");
            reference=decode(prior.get("attachment_reference"),ImmutableDocumentStore.Reference.class);attachment=decode(prior.get("attachment_metadata"),Attachment.class);
        }else if(bytes!=null){
            if(filename==null||filename.isBlank()||filename.length()>240)throw invalid("请保留真实来源附件名称");
            reference=files.save("FINANCE_SUBCONTRACT_QUANTITY",filename,contentType,bytes,DocumentIntakeProfile.FINANCIAL_TEMPLATE);attachment=new Attachment(filename,contentType,reference.size(),reference.sha256());
        }
        if(value.input().enabled()&&reference==null)throw invalid("启用原表数量对应或实盘前，请附真实凭据；输入可先保存在本人草稿");
        UUID id=UUID.randomUUID();Input input=value.input();SourceRef source=input.source();StockGroup group=input.stockGroup();
        db.update("""
            INSERT INTO finance_subcontract_quantity_evidence(id,request_id,scope_key,statement_key,revision,supplier_id,date_from,date_to,purpose,evidence_type,
              source_kind,source_item_id,material_issue_item_id,goods_id,color_id,pcs_unit_id,quantity_pcs,evidence_date,enabled,apply_to_statement,source_reference,
              input_json,precision_policy,source_json,material_source_json,book_estimated_pcs,book_estimate_basis,attachment_metadata,attachment_reference,payload_hash,submitted_by)
            VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,CAST(? AS jsonb),CAST(? AS jsonb),CAST(? AS jsonb),CAST(? AS jsonb),?,?,CAST(? AS jsonb),CAST(? AS jsonb),?,?)
            """,id,command.requestId(),value.scopeKey(),value.statementKey(),Math.addExact(latest,1),input.scope().supplierId(),input.scope().dateFrom(),input.scope().dateTo(),input.purpose().name(),input.evidenceType().name(),
                source==null?null:source.kind().name(),source==null?null:source.itemId(),input.materialIssueItemId(),group.goodsId(),group.colorId(),group.pcsUnitId(),value.applied(),input.evidenceDate(),input.enabled(),input.applyToStatement(),input.sourceReference(),
                encode(input),usedPrecision(),encode(value.source()),encode(value.material()),value.estimate(),value.estimateBasis(),encode(attachment),encode(reference),payload,current.requireId());
        return get(id);
    }
    @Transactional public Map<String,Object> decide(UUID id,Decision command){
        read();CurrentAuthorityGuard.requireAll("payment_style:edit","finance_post:execute");if(command==null||command.approve()==null)throw invalid("请明确数量证据审核结果");String reason=reference(command.reason());tx.bind();
        var before=row(id,false);scopeLock(before.get("scope_key").toString());var saved=row(id,true);String status=command.approve()?"APPROVED":"REJECTED";
        if(!"SUBMITTED".equals(saved.get("status"))){if(Objects.equals(saved.get("status"),status)&&Objects.equals(saved.get("reviewed_by"),current.requireId())&&Objects.equals(saved.get("review_reason"),reason))return view(saved);throw conflict("此原数量版本已审核，请核对原回执");}
        if(Objects.equals(saved.get("submitted_by"),current.requireId()))throw conflict("原表数量提交人与审核人不可相同");
        if(command.approve()){verifySources(saved);if(Boolean.TRUE.equals(saved.get("enabled"))&&saved.get("attachment_reference")==null)throw invalid("启用的数量证据缺少真实附件");}
        db.update("UPDATE finance_subcontract_quantity_evidence SET status=?,reviewed_by=?,reviewed_at=now(),review_reason=? WHERE id=?",status,current.requireId(),reason,id);return get(id);
    }
    @Transactional(readOnly=true)public byte[] attachment(UUID id){read();var saved=row(id,false);var reference=decode(saved.get("attachment_reference"),ImmutableDocumentStore.Reference.class);if(reference==null)throw new ApiException(ErrorCode.NOT_FOUND,"此原数量证据没有附件");return files.read(reference,DocumentIntakeProfile.FINANCIAL_TEMPLATE);}
    @Transactional(readOnly=true)public String attachmentFilename(UUID id){read();var attachment=decode(row(id,false).get("attachment_metadata"),Attachment.class);if(attachment==null)throw new ApiException(ErrorCode.NOT_FOUND,"此原数量证据没有附件");return attachment.filename();}

    private Validated validate(Input input){
        if(input==null||input.purpose()==null||input.evidenceType()==null||input.stockGroup()==null||input.enabled()==null||input.applyToStatement()==null||input.evidenceDate()==null)throw invalid("请明确原表数量用途、证据类型、真实材料、PCS单位和日期");scope(input.scope());
        StockGroup group=input.stockGroup();dictionary("goods",group.goodsId());dictionary("units",group.pcsUnitId());if(group.colorId()!=null)dictionary("colors",group.colorId());
        if(!Boolean.TRUE.equals(db.queryForObject("SELECT upper(btrim(code))='PCS' FROM units WHERE id=?",Boolean.class,group.pcsUnitId())))throw invalid("原表PCS须选择真实PCS单位，不能把其他单位按名称或前缀猜成PCS");
        var original=input.quantityPcs();if(original==null||original.signum()<0||original.abs().compareTo(BigDecimal.ONE.scaleByPowerOfTen(40))>=0||original.precision()>4096||Math.abs((long)original.scale())>1000)throw invalid("原表证据数量须为支持范围内的非负原值；正反方向由原业务来源决定");
        var quantity=BusinessPrecisionContext.limit(original,"finance.subcontract.statement-pcs","本次原表数量证据PCS采用量",24);
        if(quantity.abs().compareTo(BigDecimal.ONE.scaleByPowerOfTen(40))>=0)throw new BusinessPrecisionRequiredException("finance.subcontract.statement-pcs","本次原表数量证据PCS采用量",24,"PRECISION_LIMIT",true);
        quantity=FinancialExactAmount.require(quantity,"原表证据PCS采用量");reference(input.sourceReference());
        SourceSnapshot source=null,material=null;BigDecimal estimate=null;String estimateBasis="账载估算尚待核对；财务确认量不冒充账实一致";
        if(input.purpose()==Purpose.ROW_CORRESPONDENCE){
            if(input.source()==null||input.source().kind()==null||input.source().itemId()==null||input.materialIssueItemId()==null)throw invalid("请逐笔选择实际原发料、退料、回厂或成品退货行，并保留真实原发料行");
            if(input.evidenceType()==EvidenceType.PHYSICAL_COUNT)throw invalid("原行数量对应请选择双方结算当量或实际回厂耗用凭据；实盘使用期初/尾料核对");
            var resolved=resolve(input.source());source=resolved.snapshot();party(input.scope(),source);
            if(source.businessDate().isBefore(input.scope().dateFrom())||source.businessDate().isAfter(input.scope().dateTo()))throw invalid("原业务行日期不属于本次原表期间，不能换到其他期间重复对应");
            if(input.materialIssueItemId()!=null){var issued=resolve(new SourceRef(SourceKind.MATERIAL_ISSUE,input.materialIssueItemId()));material=issued.snapshot();party(input.scope(),material);
                if((!Objects.equals(issued.orderItemId(),resolved.orderItemId())||issued.orderItemId()==null)&&input.evidenceType()!=EvidenceType.BILATERAL_SETTLEMENT_EQUIVALENCE)throw invalid("原ERP订单对应缺失或不同，请以双方确认结算当量受审证明财务关系；不能冒称原ERP实际耗用");
                if(resolved.relatedIssueId()!=null&&!Objects.equals(resolved.relatedIssueId(),input.materialIssueItemId()))throw invalid("材料退回必须引用其实际原发料行");
            }
            if(input.source().kind()==SourceKind.MATERIAL_ISSUE&&input.materialIssueItemId()!=null&&!input.materialIssueItemId().equals(input.source().itemId()))throw invalid("原发料数量只能对应本条实际发料行，不可换到同单另一行");
            if(input.source().kind()==SourceKind.MATERIAL_RETURN&&input.materialIssueItemId()==null)throw invalid("材料退回须保留实际原发料行");
            if(input.source().kind()==SourceKind.RECEIPT||input.source().kind()==SourceKind.PRODUCT_RETURN){if(material==null)throw invalid("回厂或成品退货数量对应须选到实际原发料行，不能按货品名称猜配");}
            else if(material==null)material=source;
            if(!Objects.equals(material.goodsId(),group.goodsId())||!Objects.equals(material.colorId(),group.colorId()))throw invalid("对账材料SKU/颜色须保留所选实际原发料来源，不可换成同名货品");
            if(input.source().kind()==SourceKind.RECEIPT&&material.unitCode()!=null&&material.unitCode().strip().equalsIgnoreCase("PCS")){
                estimate=db.queryForObject("SELECT sum(qty_doc) FROM subcontract_receipt_material_consumptions WHERE receipt_item_id=? AND issue_item_id=? AND reversal_of IS NULL",BigDecimal.class,source.source().itemId(),material.source().itemId());
                estimateBasis="原回厂对该原发料的冻结BOM核销估算；不是逐批实测耗用，不随财务确认量改写";
            }else if(input.source().kind()==SourceKind.MATERIAL_ISSUE||input.source().kind()==SourceKind.MATERIAL_RETURN){
                estimate=source.unitCode()!=null&&source.unitCode().strip().equalsIgnoreCase("PCS")?source.quantityOriginal():null;estimateBasis="原业务行记录数量；非PCS来源不猜折算，不因财务原表对应改变库存";
            }else estimateBasis="成品退货不自动还原材料实耗；无逐退货材料份额时账载差异继续待核";
        }else{
            if(input.source()!=null||input.materialIssueItemId()!=null||input.evidenceType()!=EvidenceType.PHYSICAL_COUNT)throw invalid("期初/尾料核对须按实际材料、PCS和实盘日期独立登记，不冒充回厂核销");
            if(input.purpose()==Purpose.PERIOD_OPENING&&input.evidenceDate().isAfter(input.scope().dateFrom()))throw invalid("期初实盘日期不可晚于本期开始日");
            if(input.purpose()==Purpose.PERIOD_ENDING&&input.evidenceDate().isBefore(input.scope().dateTo()))throw invalid("尾料实盘日期不可早于本期截止日");
        }
        Object identity=input.purpose()==Purpose.ROW_CORRESPONDENCE?input.scope().supplierId():input.scope();
        String statementKey=hash(Arrays.asList(identity,input.purpose(),input.source(),input.materialIssueItemId(),input.stockGroup()));
        String key=hash(Arrays.asList(statementKey,input.evidenceType()));
        return new Validated(input,key,statementKey,source,material,quantity,estimate,estimateBasis);
    }
    private Resolved resolve(SourceRef ref){
        if(ref.kind()==SourceKind.MATERIAL_ISSUE||ref.kind()==SourceKind.MATERIAL_RETURN){
            var kind=ref.kind()==SourceKind.MATERIAL_ISSUE?FinanceMaterialStatementSourcePort.Kind.SUBCONTRACT_MATERIAL_ISSUE_LINE:FinanceMaterialStatementSourcePort.Kind.SUBCONTRACT_MATERIAL_RETURN_LINE;
            var fact=physical.readForIdentity(List.of(new FinanceMaterialStatementSourcePort.Key(kind,ref.itemId()))).getFirst();
            var lifecycle=fact.sourceSnapshot().get("currentStatus");int status;try{status=lifecycle instanceof Number number?number.intValue():Integer.parseInt(lifecycle.toString());}catch(NumberFormatException error){throw invalid("原材料来源审核状态须为有效数字，请核对原行");}
            if(!Set.of(1,-1).contains(status)||fact.goodsId()==null||!fact.identityComplete()&&!fact.effects().isEmpty())throw invalid("原材料来源未审核或实际效应与原行身份不一致，请核对原行；不能用财务资料覆盖原业务异常");
            var detail=db.queryForMap(ref.kind()==SourceKind.MATERIAL_ISSUE?"SELECT order_item_id,NULL::uuid AS related_issue_id FROM subcontract_material_issue_items WHERE id=?":"SELECT order_item_id,material_issue_item_id AS related_issue_id FROM subcontract_material_return_items WHERE id=?",ref.itemId());
            String unitCode=fact.unitId()==null?null:db.queryForObject("SELECT code FROM units WHERE id=?",String.class,fact.unitId());
            var source=new SourceSnapshot(ref,fact.documentId(),(UUID)detail.get("order_item_id"),fact.billNo(),date(fact.sourceSnapshot().get("business_date")),fact.supplierId(),fact.goodsId(),fact.colorId(),fact.unitId(),fact.goodsCode(),fact.goodsName(),unitCode,fact.unitName(),decimal(fact.sourceSnapshot().get("reported_quantity")),null,null,null,fact.identityComplete()?"ORIGINAL_PHYSICAL_SOURCE":"HISTORICAL_DOCUMENT_ONLY",fact.issues(),fact.identityFingerprint());
            return new Resolved(source,(UUID)detail.get("order_item_id"),(UUID)detail.get("related_issue_id"));
        }
        String headers=ref.kind()==SourceKind.RECEIPT?"subcontract_receipts":"subcontract_returns",items=ref.kind()==SourceKind.RECEIPT?"subcontract_receipt_items":"subcontract_return_items",parent=ref.kind()==SourceKind.RECEIPT?"receipt_id":"return_id";
        var rows=db.queryForList("SELECT document.id AS document_id,document.bill_no,COALESCE(item.bill_date,document.bill_date) AS business_date,document.supplier_id,document.currency_id,item.id,item.order_item_id,item.goods_id,item.color_id,item.unit_id,item.unit_rate,item.qty,item.price,item.amount_original,item.goods_code_snapshot,item.goods_name_snapshot,COALESCE(item.goods_code_snapshot,goods.code) goods_code,COALESCE(item.goods_name_snapshot,goods.name) goods_name,unit.code unit_code,unit.name unit_name FROM "+items+" item JOIN "+headers+" document ON document.id=item."+parent+" JOIN goods ON goods.id=item.goods_id LEFT JOIN units unit ON unit.id=item.unit_id WHERE item.id=? AND((document.status=1 AND NOT document.is_deleted AND NOT item.is_deleted) OR document.status=-1)",ref.itemId());
        if(rows.size()!=1)throw invalid("所选原回厂或成品退货行不存在或未经审核");var row=rows.getFirst();
        var core=new TreeMap<String,Object>();for(String key:List.of("document_id","bill_no","business_date","supplier_id","currency_id","id","order_item_id","goods_id","color_id","unit_id","unit_rate","qty","price","amount_original","goods_code_snapshot","goods_name_snapshot"))core.put(key,normal(row.get(key)));
        var source=new SourceSnapshot(ref,(UUID)row.get("document_id"),(UUID)row.get("order_item_id"),Objects.toString(row.get("bill_no"),""),date(row.get("business_date")),(UUID)row.get("supplier_id"),(UUID)row.get("goods_id"),(UUID)row.get("color_id"),(UUID)row.get("unit_id"),Objects.toString(row.get("goods_code"),""),Objects.toString(row.get("goods_name"),""),Objects.toString(row.get("unit_code"),""),Objects.toString(row.get("unit_name"),""),decimal(row.get("qty")),(UUID)row.get("currency_id"),decimal(row.get("price")),decimal(row.get("amount_original")),"ORIGINAL_APPROVED_DOCUMENT",List.of(),hash(core));
        return new Resolved(source,(UUID)row.get("order_item_id"),null);
    }
    private void verifySources(Map<String,Object> saved){
        var input=decode(saved.get("input_json"),Input.class);var expected=decode(saved.get("source_json"),SourceSnapshot.class);var material=decode(saved.get("material_source_json"),SourceSnapshot.class);
        if(expected!=null&&(!Objects.equals(resolve(expected.source()).snapshot().identityFingerprint(),expected.identityFingerprint())||!Objects.equals(resolve(expected.source()).snapshot().orderItemId(),expected.orderItemId())))throw conflict("原表数量的原业务行已变化，旧证据保留，请按真实源提交新版本");
        if(material!=null&&(!Objects.equals(resolve(material.source()).snapshot().identityFingerprint(),material.identityFingerprint())||!Objects.equals(resolve(material.source()).snapshot().orderItemId(),material.orderItemId())))throw conflict("原表数量的原发料来源已变化，旧证据保留，请重新核对");
        if(input==null)throw invalid("原数量证据缺少完整输入，不能采用");
    }
    private BigDecimal difference(Map<String,Object> row){var applied=decimal(row.get("quantity_pcs"));var estimate=decimal(row.get("book_estimated_pcs"));return applied==null||estimate==null?null:applied.subtract(estimate);}
    private Approved approvedRow(Map<String,Object> row){return new Approved((UUID)row.get("id"),row.get("scope_key").toString(),((Number)row.get("revision")).longValue(),decode(row.get("input_json"),Input.class),decode(row.get("source_json"),SourceSnapshot.class),decode(row.get("material_source_json"),SourceSnapshot.class),decimal(row.get("quantity_pcs")),decimal(row.get("book_estimated_pcs")),difference(row),Objects.toString(row.get("book_estimate_basis"),""),decode(row.get("attachment_metadata"),Attachment.class),(UUID)row.get("submitted_by"),(UUID)row.get("reviewed_by"));}
    private Map<String,Object> view(Map<String,Object> row){var out=new LinkedHashMap<String,Object>();out.put("id",row.get("id"));out.put("requestId",row.get("request_id"));out.put("scopeKey",row.get("scope_key"));out.put("revision",row.get("revision"));out.put("status",row.get("status"));out.put("input",decode(row.get("input_json"),Input.class));out.put("stockGroupReference",db.queryForMap("SELECT goods.code AS \"goodsCode\",goods.name AS \"goodsName\",color.name AS \"colorName\",unit.code AS \"unitCode\",unit.name AS \"unitName\" FROM goods LEFT JOIN colors color ON color.id=CAST(? AS uuid) JOIN units unit ON unit.id=? WHERE goods.id=?",row.get("color_id"),row.get("pcs_unit_id"),row.get("goods_id")));out.put("source",decode(row.get("source_json"),SourceSnapshot.class));out.put("materialSource",decode(row.get("material_source_json"),SourceSnapshot.class));out.put("appliedQuantityPcs",row.get("quantity_pcs"));out.put("precisionPolicy",decode(row.get("precision_policy"),Map.class));out.put("bookEstimatedPcs",row.get("book_estimated_pcs"));out.put("differencePcs",difference(row));out.put("bookEstimateBasis",row.get("book_estimate_basis"));out.put("attachment",decode(row.get("attachment_metadata"),Attachment.class));for(String key:List.of("submitted_by","submitted_at","reviewed_by","reviewed_at","review_reason")){out.put(key,row.get(key));}ReportQueryKit.includeDecimalTexts(out);return out;}
    private Map<String,Object> row(UUID id,boolean lock){var rows=db.queryForList("SELECT * FROM finance_subcontract_quantity_evidence WHERE id=?"+(lock?" FOR UPDATE":""),id);if(rows.size()!=1)throw new ApiException(ErrorCode.NOT_FOUND,"原表数量证据版本不存在");return rows.getFirst();}
    private void scope(Scope value){if(value==null||value.supplierId()==null||value.dateFrom()==null||value.dateTo()==null||value.dateFrom().isAfter(value.dateTo()))throw invalid("请选择真实委外供应商及完整原表期间");dictionary("suppliers",value.supplierId());}
    private void dictionary(String table,UUID id){if(id==null||!Boolean.TRUE.equals(db.queryForObject("SELECT EXISTS(SELECT 1 FROM "+table+" WHERE id=? AND NOT is_deleted)",Boolean.class,id)))throw invalid("请选择存在的真实供应商、商品、颜色及PCS单位");}
    private void party(Scope scope,SourceSnapshot source){if(!scope.supplierId().equals(source.supplierId()))throw invalid("原业务行不属于所选供应商，不能跨往来拼接");}
    private void requestLock(UUID request){db.query("SELECT pg_advisory_xact_lock(hashtextextended(?,1027))",rs->{},"quantity-request:"+request);}
    private void scopeLock(String key){db.query("SELECT pg_advisory_xact_lock(hashtextextended(?,1027))",rs->{},"uten:subcontract-quantity:"+key);}
    private String usedPrecision(){var value=BusinessPrecisionContext.usedChoices().get("finance.subcontract.statement-pcs");return encode(Map.of("version",1,"choices",value==null?Map.of():Map.of("finance.subcontract.statement-pcs",value)));}
    private String hash(Object value){return ImmutableDocumentStore.digest(encode(value).getBytes(java.nio.charset.StandardCharsets.UTF_8));}
    private String encode(Object value){if(value==null)return null;try{return json.writeValueAsString(value);}catch(Exception failure){throw new IllegalStateException("原数量来源无法保存",failure);}}
    private <T>T decode(Object value,Class<T> type){if(value==null)return null;try{return json.readValue(value.toString(),type);}catch(Exception failure){throw new IllegalStateException("原数量证据无法读取",failure);}}
    private static Object normal(Object value){return value==null?null:value instanceof BigDecimal number?number.stripTrailingZeros().toPlainString():value.toString();}
    private static LocalDate date(Object value){return value==null?null:value instanceof java.sql.Date date?date.toLocalDate():value instanceof LocalDate date?date:LocalDate.parse(value.toString());}
    private static BigDecimal decimal(Object value){return value==null?null:value instanceof BigDecimal number?number:new BigDecimal(value.toString());}
    private static String reference(String value){if(value==null||value.isBlank()||value.length()>2000)throw invalid("请填写1至2000字真实凭据/实盘依据");return value.strip();}
    private static ApiException invalid(String value){return new ApiException(ErrorCode.VALIDATION_FAILED,value);}
    private static ApiException conflict(String value){return new ApiException(ErrorCode.CONFLICT,value);}
}
