package com.uten.imp.features.master.goods.costing;

import com.uten.imp.application.port.MasterReferenceValidationPort;
import com.uten.imp.common.time.BusinessTime;
import com.uten.imp.common.finance.CostFraction;
import com.uten.imp.common.util.FinancialExactAmount;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.master.client.ClientAccessPolicy;
import com.uten.imp.features.master.goods.GoodsCostMasker;
import com.uten.imp.security.SecurityContextCurrentUser;
import com.uten.imp.security.TxSessionVars;
import lombok.RequiredArgsConstructor;
import org.springframework.jdbc.core.namedparam.MapSqlParameterSource;
import org.springframework.jdbc.core.namedparam.NamedParameterJdbcTemplate;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Isolation;
import org.springframework.transaction.annotation.Transactional;
import java.math.BigDecimal;
import java.time.OffsetDateTime;
import java.time.ZoneOffset;
import java.util.*;
import java.util.function.Supplier;
import static com.uten.imp.features.master.goods.costing.GoodsCostContracts.*;
import static com.uten.imp.common.finance.CostCalculationMath.*;

/** Cost sheets are separate business records. All totals and evidence are produced by the server. */
@Service
@RequiredArgsConstructor
@Transactional(readOnly=true)
public class GoodsCostSheetService {
    public static final String VIEW="goods:cost:view", EDIT="goods:cost:edit", CONFIRM="goods:cost:confirm", EXPORT="goods:cost:export", TEMPLATE="goods:cost:template";
    private final NamedParameterJdbcTemplate db;
    private final GoodsCostCalculator calculator;
    private final GoodsCostJson json;
    private final GoodsCostMasker mask;
    private final MasterReferenceValidationPort references;
    private final ClientAccessPolicy clients;
    private final SecurityContextCurrentUser current;
    private final TxSessionVars tx;
    private final CostImportEvidenceGuard imports;

    public List<SheetSummary> list(UUID goodsId) {
        require(VIEW);references.requireVisibleGoods(goodsId);
        List<SheetSummary> result=new ArrayList<>();
        for(var row:db.queryForList("SELECT * FROM goods_cost_sheets WHERE goods_id=:goods ORDER BY updated_at DESC,id LIMIT 250",Map.of("goods",goodsId))) {
            if(!canClient((UUID)row.get("client_id")))continue;
            Sheet sheet=sheet(row);assertScope(sheet.input(),sheet.calculation());
            result.add(new SheetSummary(sheet.id(),sheet.input().goodsId(),sheet.input().clientId(),sheet.input().name(),sheet.status(),sheet.version(),
                    sheet.input().batchQty(),sheet.calculation().totals().knownTotal(),sheet.calculation().totals().unitCost(),
                    sheet.calculation().totals().valueState(),sheet.confirmedSnapshotId(),sheet.updatedAt()));
        }
        return List.copyOf(result);
    }
    public Sheet get(UUID id) {require(VIEW);Sheet s=load(id,false);assertScope(s.input(),s.calculation());return s;}
    @Transactional
    public Sheet create(SaveRequest request) {
        require(EDIT);tx.bind();
        Sheet result=command("CREATE",request.idempotencyKey(),request,Sheet.class,()->{
            DraftInput input=prepare(request.input());Calculation calculation=stableCalculation(input);
            UUID id=UUID.randomUUID();OffsetDateTime at=now();
            String no="CB-"+id.toString().replace("-","").substring(0,16).toUpperCase(Locale.ROOT);
            db.update("""
                    INSERT INTO goods_cost_sheets(id,sheet_no,goods_id,client_id,name,input,calculation,created_by,updated_by,created_at,updated_at)
                    VALUES(:id,:no,:goods,:client,:name,CAST(:input AS jsonb),CAST(:calculation AS jsonb),:actor,:actor,:at,:at)
                    """,params().addValue("id",id).addValue("no",no).addValue("goods",input.goodsId()).addValue("client",input.clientId())
                    .addValue("name",input.name()).addValue("input",json.write(input)).addValue("calculation",json.write(calculation)).addValue("at",at));
            return load(id,false);
        });assertScope(result.input(),result.calculation());return permissions(result);
    }
    @Transactional
    public Sheet save(UUID id,SaveRequest request) {
        require(EDIT);tx.bind();
        Sheet result=command("SAVE",request.idempotencyKey(),Arrays.asList(id,request),Sheet.class,()->{
            Sheet previous=load(id,true);assertScope(previous.input(),previous.calculation());
            editable(previous);version(previous.version(),request.expectedVersion());
            DraftInput input=prepare(request.input());
            if(!Objects.equals(input.goodsId(),previous.input().goodsId()))throw invalid("成本单货品不能更换，请新建成本单");
            Calculation calculation=stableCalculation(input);
            db.update("""
                    UPDATE goods_cost_sheets SET client_id=:client,name=:name,input=CAST(:input AS jsonb),
                      calculation=CAST(:calculation AS jsonb),row_version=row_version+1,updated_by=:actor,updated_at=:at
                    WHERE id=:id AND row_version=:version AND status='DRAFT'
                    """,params().addValue("id",id).addValue("version",previous.version()).addValue("client",input.clientId())
                    .addValue("name",input.name()).addValue("input",json.write(input)).addValue("calculation",json.write(calculation)).addValue("at",now()));
            return load(id,false);
        });assertScope(result.input(),result.calculation());return permissions(result);
    }
    @Transactional(readOnly=true,isolation=Isolation.REPEATABLE_READ)
    public Calculation preview(DraftInput input) { require(VIEW);return calculator.calculate(prepare(input)); }
    /** The UI receives the exact normalized inputs used by this calculation, before any draft is persisted. */
    @Transactional(readOnly=true,isolation=Isolation.REPEATABLE_READ)
    @SuppressWarnings("unchecked")
    public Map<String,Object> previewPayload(DraftInput input) {
        require(VIEW);DraftInput resolved=prepare(input);Calculation calculation=calculator.calculate(resolved);
        Map<String,Object> payload=json.read(json.write(calculation),LinkedHashMap.class);
        payload.put("resolvedInput",resolved);return payload;
    }
    /** Changes the monetary unit of a draft simulation, never a stored sheet or an actual posting. */
    @Transactional(readOnly=true,isolation=Isolation.REPEATABLE_READ)
    public ConvertedCurrency convertCurrency(ConvertCurrencyRequest request) {
        require(VIEW);
        if(request==null||request.input()==null)throw invalid("请选择需要换算的成本输入");
        if(request.input().exchangeRateToLocal()==null||request.input().exchangeRateToLocal().isBlank()
                ||request.targetExchangeRateToLocal()==null||request.targetExchangeRateToLocal().isBlank())
            throw invalid("币种换算必须明确填写源汇率和目标汇率");
        DraftInput source=prepare(request.input());Calculation sourceCalculation=calculator.calculate(source);
        String targetRateText=calculator.normalizeExchangeRate(request.targetCurrencyId(),request.targetExchangeRateToLocal());
        BigDecimal sourceRate=new BigDecimal(source.exchangeRateToLocal()),targetRate=new BigDecimal(targetRateText);
        if(Objects.equals(source.currencyId(),request.targetCurrencyId())&&sourceRate.compareTo(targetRate)==0)
            return new ConvertedCurrency(source,sourceCalculation);
        Map<String,CostLine> lines=new HashMap<>();sourceCalculation.lines().forEach(line->lines.put(line.path(),line));
        String sourceName=currencyName(source.currencyId()),targetName=currencyName(request.targetCurrencyId());
        String note="币种换算: "+sourceName+" ("+text(sourceRate)+") → "+targetName+" ("+text(targetRate)+")";
        List<Map<String,Object>> changes=new ArrayList<>();
        List<LineOverride> overrides=new ArrayList<>();
        for(LineOverride override:GoodsCostCalculator.list(source.lineOverrides())) {
            if(override.unitPrice()==null) {overrides.add(override);continue;}
            CostLine line=lines.get(override.path());
            if(line==null||line.unitPrice()==null)throw invalid("某行手工价格没有可核对的基础单位单价，请先核对该行计价方式");
            String converted=convertedMoney(line.unitPrice(),sourceRate,targetRate);
            overrides.add(new LineOverride(override.path(),override.adoptedQty(),override.route(),converted,"1",targetRateText,
                    null,"AS_RECORDED",null,"MANUAL",appendReason(override.reason(),note),null));
            Map<String,Object> change=new LinkedHashMap<>();change.put("kind","MATERIAL_OVERRIDE");change.put("path",override.path());
            change.put("before",override);change.put("normalizedUnitPrice",line.unitPrice());change.put("afterUnitPrice",converted);
            change.put("priceEvidence",line.priceEvidence());changes.add(change);
        }
        List<FeeInput> fees=new ArrayList<>();
        for(FeeInput fee:GoodsCostCalculator.list(source.fees())) {
            if(fee.source()!=null&&fee.source().startsWith("TEMPLATE:")||"PERCENT".equals(fee.type())){fees.add(fee);continue;}
            String converted=convertedMoney(fee.value(),sourceRate,targetRate);
            fees.add(new FeeInput(fee.key(),fee.name(),fee.type(),fee.category(),fee.targetPath(),converted,fee.quantity(),fee.baseKeys(),
                    fee.source(),appendReason(fee.reason(),note)));
            changes.add(monetaryChange("FEE",fee.key(),fee.value(),converted));
        }
        Map<String,PriceColumn> columns=new HashMap<>();source.priceColumns().forEach(column->columns.put(column.key(),column));
        List<PriceCell> cells=new ArrayList<>();
        for(PriceCell cell:GoodsCostCalculator.list(source.priceCells())) {
            PriceColumn column=columns.get(cell.columnKey());if(column==null)throw invalid("价格列定义缺失，不能换算");
            if("PERCENT".equals(column.type())){cells.add(cell);continue;}
            String converted=convertedMoney(cell.value(),sourceRate,targetRate);
            cells.add(new PriceCell(cell.path(),cell.columnKey(),converted,cell.quantity(),appendReason(cell.reason(),note)));
            changes.add(monetaryChange("PRICE_CELL",cell.path()+"/"+cell.columnKey(),cell.value(),converted));
        }
        Map<String,Object> trace=new LinkedHashMap<>();trace.put("sourceCurrencyId",source.currencyId());trace.put("sourceCurrencyName",sourceName);
        trace.put("sourceExchangeRateToLocal",source.exchangeRateToLocal());trace.put("targetCurrencyId",request.targetCurrencyId());
        trace.put("targetCurrencyName",targetName);trace.put("targetExchangeRateToLocal",targetRateText);
        trace.put("sourceCalculationDigest",sourceCalculation.contentDigest());trace.put("convertedAt",now());trace.put("changes",changes);
        trace.put("method","EXACT_RATIONAL_WITH_COST_PROJECTION");
        Map<String,String> extra=new LinkedHashMap<>(source.extraFields());extra.put("costCurrencyConversion",json.write(trace));
        DraftInput target=new DraftInput(source.goodsId(),source.clientId(),source.name(),source.batchQty(),request.targetCurrencyId(),targetRateText,
                source.effectiveDate(),source.usageStrategy(),source.priceStrategy(),source.templateId(),overrides,fees,source.priceColumns(),cells,extra,source.notes());
        DraftInput resolved=prepare(target);return new ConvertedCurrency(resolved,calculator.calculate(resolved));
    }
    @Transactional
    public Sheet confirm(UUID id,Command request) {
        require(CONFIRM);tx.bind();
        Sheet result=command("CONFIRM",request.idempotencyKey(),Arrays.asList(id,request),Sheet.class,()->{
            Sheet sheet=load(id,true);assertScope(sheet.input(),sheet.calculation());editable(sheet);version(sheet.version(),request.expectedVersion());
            Calculation fresh=stableCalculation(prepare(sheet.input()));
            if(!fresh.contentDigest().equals(sheet.calculation().contentDigest()))
                throw conflict("成本来源或模板已变化，请重新计算并保存后确认");
            if(!"COMPLETE".equals(fresh.totals().valueState()))throw invalid("存在缺价、缺参数或未核清项目，不能确认成本版本");
            Snapshot snapshot=insertSnapshot(sheet,"CONFIRMED");
            db.update("""
                    UPDATE goods_cost_sheets SET status='CONFIRMED',confirmed_snapshot_id=:snapshot,
                      row_version=row_version+1,updated_by=:actor,updated_at=:at WHERE id=:id AND status='DRAFT'
                    """,params().addValue("snapshot",snapshot.id()).addValue("id",id).addValue("at",now()));
            return load(id,false);
        });assertScope(result.input(),result.calculation());return permissions(result);
    }
    @Transactional
    public Sheet copy(UUID id,CopyCommand request) {
        require(EDIT);tx.bind();
        Sheet result=command("COPY",request.idempotencyKey(),Arrays.asList(id,request),Sheet.class,()->{
            Sheet source=load(id,false);assertScope(source.input(),source.calculation());version(source.version(),request.expectedVersion());
            DraftInput old=source.input();
            DraftInput copy=new DraftInput(old.goodsId(),old.clientId(),request.name()==null?old.name()+" (副本)":request.name(),
                    old.batchQty(),old.currencyId(),old.exchangeRateToLocal(),old.effectiveDate(),old.usageStrategy(),old.priceStrategy(),
                    old.templateId(),old.lineOverrides(),old.fees(),old.priceColumns(),old.priceCells(),old.extraFields(),old.notes());
            return create(new SaveRequest(null,"copy-"+json.hash(Arrays.asList(id,request)).substring(0,48),copy));
        });assertScope(result.input(),result.calculation());return permissions(result);
    }
    @Transactional
    public Snapshot snapshot(UUID id,Command request) {
        require(EXPORT);tx.bind();
        Snapshot result=command("SNAPSHOT",request.idempotencyKey(),Arrays.asList(id,request),Snapshot.class,()->{
            Sheet sheet=load(id,true);assertScope(sheet.input(),sheet.calculation());version(sheet.version(),request.expectedVersion());
            if(sheet.confirmedSnapshotId()!=null)return snapshotRecord(sheet.confirmedSnapshotId());
            return insertSnapshot(sheet,"DRAFT_EXPORT");
        });assertScope(result.input(),result.calculation());return result;
    }
    public List<SnapshotSummary> snapshots(UUID id) {
        get(id);
        return db.query("SELECT id,sheet_version,kind,content_digest,created_at FROM goods_cost_snapshots WHERE sheet_id=:id ORDER BY created_at DESC,id",
                Map.of("id",id),(r,n)->new SnapshotSummary(r.getObject("id",UUID.class),r.getLong("sheet_version"),r.getString("kind"),
                        r.getString("content_digest"),r.getObject("created_at",OffsetDateTime.class)));
    }
    public Snapshot readSnapshot(UUID id) {
        require(VIEW);Snapshot snapshot=snapshotRecord(id);assertScope(snapshot.input(),snapshot.calculation());return snapshot;
    }
    /** Public export boundary: immutable, already authorized data for all file/rendering adapters. */
    public Snapshot exportSnapshot(UUID sheetId,UUID snapshotId) {
        require(EXPORT);Snapshot snapshot=readSnapshot(snapshotId);
        if(!snapshot.sheetId().equals(sheetId))throw new ApiException(ErrorCode.NOT_FOUND,"成本版本不存在");
        return snapshot;
    }
    public List<Template> templates(UUID goodsId,UUID clientId) {
        require(VIEW);if(goodsId!=null)references.requireVisibleGoods(goodsId);requireClient(clientId);
        List<Template> result=new ArrayList<>();
        for(var row:db.queryForList("""
                SELECT * FROM goods_cost_templates WHERE (goods_id IS NULL OR goods_id=CAST(:goods AS uuid))
                  AND (client_id IS NULL OR client_id=CAST(:client AS uuid)) ORDER BY name,id LIMIT 250
                """,new MapSqlParameterSource().addValue("goods",goodsId).addValue("client",clientId))) result.add(template(row));
        return List.copyOf(result);
    }
    @Transactional
    public Template saveTemplate(UUID id,TemplateSave request) {
        require(TEMPLATE);tx.bind();
        Template result=command("TEMPLATE",request.idempotencyKey(),Arrays.asList(id,request),Template.class,()->{
            TemplateInput input=request.input();validateTemplate(input);
            input=new TemplateInput(input.name(),input.goodsId(),input.clientId(),input.validFrom(),input.validTo(),input.minBatchQty(),input.maxBatchQty(),
                    input.fees(),input.priceColumns(),input.notes(),input.currencyId(),calculator.normalizeExchangeRate(input.currencyId(),input.exchangeRateToLocal()));
            UUID target=id==null?UUID.randomUUID():id;
            if(id!=null) {
                var rows=db.queryForList("SELECT * FROM goods_cost_templates WHERE id=:id FOR UPDATE",Map.of("id",id));
                if(rows.isEmpty())throw new ApiException(ErrorCode.NOT_FOUND,"成本模板不存在");
                Template previous=template(rows.getFirst());scope(previous.input().goodsId(),previous.input().clientId());
                version(previous.version(),request.expectedVersion());
                db.update("""
                        UPDATE goods_cost_templates SET name=:name,goods_id=:goods,client_id=:client,input=CAST(:input AS jsonb),
                          row_version=row_version+1,updated_by=:actor,updated_at=:at WHERE id=:id
                        """,templateParams(target,input));
            } else db.update("""
                    INSERT INTO goods_cost_templates(id,name,goods_id,client_id,input,created_by,updated_by,created_at,updated_at)
                    VALUES(:id,:name,:goods,:client,CAST(:input AS jsonb),:actor,:actor,:at,:at)
                    """,templateParams(target,input));
            return template(db.queryForMap("SELECT * FROM goods_cost_templates WHERE id=:id",Map.of("id",target)));
        });scope(result.input().goodsId(),result.input().clientId());return result;
    }
    private DraftInput prepare(DraftInput raw) {
        if(raw==null || raw.goodsId()==null)throw invalid("请选择成本货品");
        scope(raw.goodsId(),raw.clientId());String name=raw.name()==null||raw.name().isBlank()?"成本测算":raw.name().strip();
        if(name.length()>160)throw invalid("成本单名称最多160字");
        if(raw.notes()!=null&&raw.notes().length()>4000)throw invalid("备注最多4000字");
        if(json.write(raw).length()>1_000_000)throw invalid("成本输入过大，请拆分成本单");
        List<FeeInput> manual=GoodsCostCalculator.list(raw.fees()).stream().filter(f->f.source()==null||!f.source().startsWith("TEMPLATE:")).toList();
        Set<String> manualKeys=new HashSet<>();for(FeeInput fee:manual)if(!manualKeys.add(fee.key()))throw invalid("手工费用编码重复");
        LinkedHashMap<String,FeeInput> fees=new LinkedHashMap<>();
        LinkedHashMap<String,PriceColumn> columns=new LinkedHashMap<>();
        LinkedHashMap<String,PriceColumn> previousColumns=new LinkedHashMap<>();
        for(PriceColumn column:GoodsCostCalculator.list(raw.priceColumns())) {
            if(column.key()==null||column.key().isBlank()||previousColumns.putIfAbsent(column.key(),column)!=null)throw invalid("价格列编码重复或缺失");
        }
        Set<String> previousAutoColumns=new HashSet<>();
        String autoColumns=raw.extraFields()==null?null:raw.extraFields().get("costAutoPriceColumnKeys");
        if(autoColumns!=null&&!autoColumns.isBlank()) {
            try{previousAutoColumns.addAll(Arrays.asList(json.read(autoColumns,String[].class)));}
            catch(IllegalStateException error){throw invalid("自动价格列来源格式无效");}
            if(previousAutoColumns.size()>32||previousAutoColumns.contains(null))throw invalid("自动价格列来源无效");
        }
        Set<String> referencedColumns=new HashSet<>();
        for(PriceCell cell:GoodsCostCalculator.list(raw.priceCells())) {
            // A present empty cell means applicable-but-incomplete; only absent cells are not applicable.
            referencedColumns.add(cell.columnKey());
        }
        Set<String> excluded=new HashSet<>();
        Set<String> excludedColumns=new HashSet<>();
        String exclusions=raw.extraFields()==null?null:raw.extraFields().get("costExcludedFeeKeys");
        if(exclusions!=null&&!exclusions.isBlank()) {
            try {excluded.addAll(Arrays.asList(json.read(exclusions,String[].class)));}
            catch(IllegalStateException ex){throw invalid("排除费用列表格式无效");}
            if(excluded.size()>3000||excluded.contains(null))throw invalid("排除费用数量或编码无效");
        }
        String columnExclusions=raw.extraFields()==null?null:raw.extraFields().get("costExcludedPriceColumnKeys");
        if(columnExclusions!=null&&!columnExclusions.isBlank()) {
            try {excludedColumns.addAll(Arrays.asList(json.read(columnExclusions,String[].class)));}
            catch(IllegalStateException ex){throw invalid("排除价格列列表格式无效");}
            if(excludedColumns.size()>32||excludedColumns.contains(null))throw invalid("排除价格列数量或编码无效");
        }
        java.time.LocalDate date=raw.effectiveDate()==null?BusinessTime.today():raw.effectiveDate();
        BigDecimal quantity=positive(raw.batchQty()==null?"1":raw.batchQty(),"成本批量");
        String sheetRateText=calculator.normalizeExchangeRate(raw.currencyId(),raw.exchangeRateToLocal());
        BigDecimal sheetRate=new BigDecimal(sheetRateText);
        List<Template> candidates=new ArrayList<>(templates(raw.goodsId(),raw.clientId()));
        if(raw.templateId()!=null) {
            candidates.removeIf(t->!t.id().equals(raw.templateId()));
            if(candidates.isEmpty())throw invalid("成本模板不在本产品或客户范围");
        }
        Map<String,Integer> priorities=new HashMap<>();
        Map<String,Integer> columnPriorities=new HashMap<>();
        Map<String,Long> templateVersions=new LinkedHashMap<>();
        Map<String,Map<String,Object>> templateFeeSources=new LinkedHashMap<>();
        for(Template template:candidates) {
            TemplateInput in=template.input();
            if(in.validFrom()!=null&&date.isBefore(in.validFrom())||in.validTo()!=null&&date.isAfter(in.validTo())
                    ||in.minBatchQty()!=null&&quantity.compareTo(nonnegative(in.minBatchQty(),"最小批量"))<0
                    ||in.maxBatchQty()!=null&&quantity.compareTo(positive(in.maxBatchQty(),"最大批量"))>0) {
                if(raw.templateId()!=null)throw invalid("模板不适用于成本日期或批量");continue;
            }
            int priority=(in.clientId()!=null?2:0)+(in.goodsId()!=null?1:0);
            String templateRateText=calculator.normalizeExchangeRate(in.currencyId(),in.exchangeRateToLocal());
            BigDecimal templateRate=new BigDecimal(templateRateText);
            templateVersions.put(template.id().toString(),template.version());
            for(FeeInput fee:GoodsCostCalculator.list(in.fees())) {
                if(excluded.contains(fee.key()))continue;
                Integer old=priorities.get(fee.key());
                if(old!=null&&old==priority)throw invalid("同一费用命中相同优先级模板："+fee.name());
                if(old==null||priority>old) {
                    priorities.put(fee.key(),priority);
                    String value="PERCENT".equals(fee.type())?fee.value():convertedMoney(fee.value(),templateRate,sheetRate);
                    fees.put(fee.key(),new FeeInput(fee.key(),fee.name(),fee.type(),fee.category(),fee.targetPath(),value,fee.quantity(),
                            fee.baseKeys(),"TEMPLATE:"+template.id()+":"+template.version(),fee.reason()));
                    Map<String,Object> source=new LinkedHashMap<>();source.put("templateId",template.id());source.put("version",template.version());
                    source.put("currencyId",in.currencyId());source.put("currencyName",currencyName(in.currencyId()));source.put("exchangeRateToLocal",templateRateText);
                    source.put("originalFee",fee);source.put("resolvedValue",value);source.put("sheetExchangeRateToLocal",sheetRateText);
                    templateFeeSources.put(fee.key(),source);
                }
            }
            for(PriceColumn c:GoodsCostCalculator.list(in.priceColumns())) {
                if(excludedColumns.contains(c.key()))continue;
                Integer previousPriority=columnPriorities.get(c.key());
                PriceColumn previous=columns.get(c.key());
                if(previousPriority!=null&&previousPriority==priority&&!previous.equals(c))throw invalid("同一价格列命中相同优先级模板："+c.name());
                if(previousPriority==null||priority>previousPriority){columns.put(c.key(),c);columnPriorities.put(c.key(),priority);}
            }
        }
        for(FeeInput f:manual){fees.put(f.key(),f);templateFeeSources.remove(f.key());}
        Set<String> resolvedAutoColumns=new HashSet<>(columns.keySet());
        for(PriceColumn previous:previousColumns.values()) {
            if(!previousAutoColumns.contains(previous.key())) {
                columns.put(previous.key(),previous);resolvedAutoColumns.remove(previous.key());
            } else if(referencedColumns.contains(previous.key())&&!previous.equals(columns.get(previous.key()))) {
                // A typed price is bound to its old definition. Never reinterpret it as a new rate/algorithm.
                columns.put(previous.key(),previous);resolvedAutoColumns.remove(previous.key());
            }
        }
        List<PriceCell> resolvedCells=new ArrayList<>();
        for(PriceCell cell:GoodsCostCalculator.list(raw.priceCells())) {
            if(columns.containsKey(cell.columnKey()))resolvedCells.add(cell);
            else throw invalid("价格列已缺失，不能丢弃本单费用，请先核对列定义");
        }
        Map<String,String> extra=new LinkedHashMap<>(imports.validate(raw.goodsId(),raw.extraFields()==null?Map.of():Map.copyOf(raw.extraFields())));
        extra.put("costAutoPriceColumnKeys",json.write(resolvedAutoColumns.stream().sorted().toList()));
        extra.put("costTemplateVersions",json.write(templateVersions));
        extra.put("costTemplateSourceValues",json.write(templateFeeSources));
        extra.remove("serverClientName");
        if(raw.clientId()!=null) {
            List<String> names=db.queryForList("SELECT name FROM clients WHERE id=:id AND NOT is_deleted",Map.of("id",raw.clientId()),String.class);
            if(names.size()!=1)throw new ApiException(ErrorCode.NOT_FOUND,"成本客户不存在");
            if(names.getFirst()!=null)extra.put("serverClientName",names.getFirst());
        }
        return new DraftInput(raw.goodsId(),raw.clientId(),name,text(quantity),raw.currencyId(),sheetRateText,
                date,raw.usageStrategy()==null?"ACTUAL_FIRST":raw.usageStrategy(),raw.priceStrategy()==null?"APPROVED_PURCHASE":raw.priceStrategy(),raw.templateId(),
                List.copyOf(GoodsCostCalculator.list(raw.lineOverrides())),List.copyOf(fees.values()),List.copyOf(columns.values()),
                List.copyOf(resolvedCells),Map.copyOf(extra),raw.notes());
    }
    private Snapshot insertSnapshot(Sheet sheet,String kind) {
        var existing=db.queryForList("SELECT payload::text payload FROM goods_cost_snapshots WHERE sheet_id=:sheet AND sheet_version=:version AND kind=:kind",
                Map.of("sheet",sheet.id(),"version",sheet.version(),"kind",kind));
        if(!existing.isEmpty())return json.read((String)existing.getFirst().get("payload"),Snapshot.class);
        Snapshot snapshot=new Snapshot(UUID.randomUUID(),sheet.id(),sheet.sheetNo(),sheet.version(),kind,sheet.input(),sheet.calculation(),
                sheet.calculation().contentDigest(),current.requireId(),now());
        db.update("""
                INSERT INTO goods_cost_snapshots(id,sheet_id,sheet_version,kind,payload,content_digest,created_by,created_at)
                VALUES(:id,:sheet,:version,:kind,CAST(:payload AS jsonb),:digest,:actor,:at)
                """,params().addValue("id",snapshot.id()).addValue("sheet",sheet.id()).addValue("version",sheet.version()).addValue("kind",kind)
                .addValue("payload",json.write(snapshot)).addValue("digest",snapshot.contentDigest()).addValue("at",snapshot.createdAt()));
        return snapshot;
    }
    /** Stable source versions without making concurrent command replay read an obsolete MVCC snapshot. */
    private Calculation stableCalculation(DraftInput input) {
        Calculation first=calculator.calculate(input),second=calculator.calculate(prepare(input));
        if(!first.contentDigest().equals(second.contentDigest()))throw conflict("成本来源正在变化，请重新计算后保存");
        return second;
    }
    private Snapshot snapshotRecord(UUID id) {
        var rows=db.queryForList("SELECT payload::text payload FROM goods_cost_snapshots WHERE id=:id",Map.of("id",id));
        if(rows.isEmpty())throw new ApiException(ErrorCode.NOT_FOUND,"成本版本不存在");
        return json.read((String)rows.getFirst().get("payload"),Snapshot.class);
    }
    private Sheet load(UUID id,boolean lock) {
        var rows=db.queryForList("SELECT * FROM goods_cost_sheets WHERE id=:id"+(lock?" FOR UPDATE":""),Map.of("id",id));
        if(rows.isEmpty())throw new ApiException(ErrorCode.NOT_FOUND,"成本单不存在");
        return sheet(rows.getFirst());
    }
    private Sheet sheet(Map<String,Object> row) {
        return new Sheet((UUID)row.get("id"),(String)row.get("sheet_no"),(String)row.get("status"),((Number)row.get("row_version")).longValue(),
                json.read(row.get("input").toString(),DraftInput.class),json.read(row.get("calculation").toString(),Calculation.class),
                (UUID)row.get("confirmed_snapshot_id"),offset(row.get("updated_at")),has(EDIT)&&"DRAFT".equals(row.get("status")),
                has(CONFIRM)&&"DRAFT".equals(row.get("status")),has(EXPORT));
    }
    private Sheet permissions(Sheet s) {return new Sheet(s.id(),s.sheetNo(),s.status(),s.version(),s.input(),s.calculation(),s.confirmedSnapshotId(),s.updatedAt(),
            has(EDIT)&&"DRAFT".equals(s.status()),has(CONFIRM)&&"DRAFT".equals(s.status()),has(EXPORT));}
    private Template template(Map<String,Object> row) {return new Template((UUID)row.get("id"),((Number)row.get("row_version")).longValue(),
            json.read(row.get("input").toString(),TemplateInput.class),offset(row.get("updated_at")));}
    private MapSqlParameterSource templateParams(UUID id,TemplateInput in) {return params().addValue("id",id).addValue("name",in.name()).addValue("goods",in.goodsId())
            .addValue("client",in.clientId()).addValue("input",json.write(in)).addValue("at",now());}
    private void validateTemplate(TemplateInput in) {
        if(in==null||in.name()==null||in.name().isBlank()||in.name().length()>160)throw invalid("模板名称不能为空或超过160字");
        scope(in.goodsId(),in.clientId());
        if(in.validFrom()!=null&&in.validTo()!=null&&in.validFrom().isAfter(in.validTo()))throw invalid("模板结束日不得早于开始日");
        if(in.minBatchQty()!=null)nonnegative(in.minBatchQty(),"最小批量");
        if(in.maxBatchQty()!=null&&positive(in.maxBatchQty(),"最大批量").compareTo(in.minBatchQty()==null?BigDecimal.ZERO:new BigDecimal(in.minBatchQty()))<0)
            throw invalid("模板最大批量小于最小批量");
        if(json.write(in).length()>250_000)throw invalid("模板过大");
        GoodsCostCalculator.validateDefinitions(in.fees(),in.priceColumns());
        calculator.validateTemplatePaths(in.goodsId(),in.fees());
        calculator.normalizeExchangeRate(in.currencyId(),in.exchangeRateToLocal());
    }
    private String currencyName(UUID id) {
        if(id==null)return "本币";
        List<String> names=db.queryForList("SELECT name FROM currencies WHERE id=:id AND NOT is_deleted",Map.of("id",id),String.class);
        if(names.size()!=1)throw invalid("币种不存在或已删除");return names.getFirst();
    }
    private static String convertedMoney(String value,BigDecimal sourceRate,BigDecimal targetRate) {
        if(value==null||value.isBlank())return value;
        BigDecimal converted=CostFraction.of(nonnegative(value,"换算金额")).multiply(sourceRate).divide(targetRate).project();
        return text(FinancialExactAmount.require(converted,"换算后的成本参数"));
    }
    private static String appendReason(String reason,String note){return reason==null||reason.isBlank()?note:reason+"；"+note;}
    private static Map<String,Object> monetaryChange(String kind,String key,String before,String after) {
        Map<String,Object> change=new LinkedHashMap<>();change.put("kind",kind);change.put("key",key);change.put("before",before);change.put("after",after);return change;
    }
    public void require(String permission) {
        if(!mask.canView()||!has("goods:view")||!has(permission))throw new ApiException(ErrorCode.FORBIDDEN,"无访问或操作货品成本权限");
    }
    public void requireGoodsScope(UUID goodsId) {require(VIEW);references.requireVisibleGoods(goodsId);}
    /** Rechecks both scopes before an import receipt may reveal or restore older manual inputs. */
    public void requireInputScope(DraftInput input) {
        require(VIEW);
        if(input==null||input.goodsId()==null)throw invalid("成本输入缺少货品");
        scope(input.goodsId(),input.clientId());
    }
    private boolean has(String permission) {return current.get().map(u->u.getPermissions().contains(permission)).orElse(false);}
    private void scope(UUID goodsId,UUID clientId) {if(goodsId!=null)references.requireVisibleGoods(goodsId);requireClient(clientId);}
    private void requireClient(UUID id) {if(!canClient(id))throw new ApiException(ErrorCode.FORBIDDEN,"无权查看成本单关联客户");}
    private boolean canClient(UUID id) {
        if(id==null)return true;
        var rows=db.queryForList("SELECT owner_employee_id FROM clients WHERE id=:id AND NOT is_deleted",Map.of("id",id));
        return rows.size()==1&&clients.canRead(id,(UUID)rows.getFirst().get("owner_employee_id"),clients.evaluate());
    }
    private void assertScope(DraftInput in,Calculation calculation) {
        scope(in.goodsId(),in.clientId());
        Set<UUID> ids=new HashSet<>();for(CostLine line:calculation.lines())if(ids.add(line.goodsId()))references.requireVisibleGoods(line.goodsId());
    }
    private <T> T command(String kind,String key,Object request,Class<T> type,Supplier<T> work) {
        if(key==null||!key.matches("[A-Za-z0-9._:-]{8,128}"))throw invalid("请求号格式无效，请刷新后重试");
        String hash=json.hash(Arrays.asList(kind,request));MapSqlParameterSource p=params().addValue("key",key).addValue("hash",hash).addValue("kind",kind);
        db.queryForObject("SELECT count(*) FROM (SELECT pg_advisory_xact_lock(hashtextextended(:lock,753))) locked",
                Map.of("lock","cost:"+current.requireId()+":"+key),Long.class);
        var rows=db.queryForList("SELECT request_hash,result::text result FROM goods_cost_commands WHERE actor_id=:actor AND idempotency_key=:key",p);
        if(!rows.isEmpty()) {
            if(!hash.equals(rows.getFirst().get("request_hash")))throw conflict("相同请求号不能用于不同成本操作");
            return json.read((String)rows.getFirst().get("result"),type);
        }
        T result=work.get();db.update("INSERT INTO goods_cost_commands(actor_id,idempotency_key,command_kind,request_hash,result) VALUES(:actor,:key,:kind,:hash,CAST(:result AS jsonb))",
                p.addValue("result",json.write(result)));return result;
    }
    private MapSqlParameterSource params(){return new MapSqlParameterSource().addValue("actor",current.requireId());}
    private static void version(long actual,Long expected){if(expected==null||actual!=expected)throw conflict("成本单已被修改，请重新载入后再保存");}
    private static void editable(Sheet sheet){if(!"DRAFT".equals(sheet.status()))throw conflict("已确认成本版本不可修改，请复制为新草稿");}
    private static ApiException conflict(String message){return new ApiException(ErrorCode.CONFLICT,message);}
    private static OffsetDateTime now(){return OffsetDateTime.now(ZoneOffset.UTC);}
    private static OffsetDateTime offset(Object value){return value instanceof OffsetDateTime o?o:((java.sql.Timestamp)value).toInstant().atOffset(ZoneOffset.UTC);}
}
