package com.uten.imp.features.master.goods.costing;

import com.uten.imp.application.port.MasterReferenceValidationPort;
import com.uten.imp.common.finance.BomConsumptionCurve;
import com.uten.imp.common.finance.CostFraction;
import com.uten.imp.common.util.FinancialExactAmount;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Component;
import java.math.BigDecimal;
import java.math.RoundingMode;
import java.time.OffsetDateTime;
import java.time.ZoneOffset;
import java.util.*;
import static com.uten.imp.features.master.goods.costing.GoodsCostContracts.*;
import static com.uten.imp.features.master.goods.costing.GoodsCostSourceReader.*;
import static com.uten.imp.common.finance.CostCalculationMath.*;

/** Server-only internal costing, with path identities and explicit missing-value propagation. */
@Component
@RequiredArgsConstructor
public class GoodsCostCalculator {
    public static final String ALGORITHM="GOODS_COST_V2_AUTO";
    private final GoodsCostSourceReader sources;
    private final MasterReferenceValidationPort references;
    private final GoodsCostJson json;
    /** Only a verified functional currency may default to one; foreign rates must be explicit evidence. */
    public String normalizeExchangeRate(UUID currencyId,String value) {
        boolean base=currencyId==null||sources.baseCurrency(currencyId);
        if(value==null||value.isBlank()) {
            if(!base)throw invalid("外币成本单缺少汇率，请明确填写后再计算");
            return "1";
        }
        BigDecimal rate=positive(value,"成本单汇率");
        if(base&&rate.compareTo(BigDecimal.ONE)!=0)throw invalid("本币成本单汇率必须为1");
        return text(rate);
    }
    public void validateTemplatePaths(UUID goodsId,List<FeeInput> fees) {
        Map<UUID,List<Edge>> cache=new HashMap<>();Set<String> checked=new HashSet<>();
        for(FeeInput fee:list(fees)) {
            String path=fee.targetPath();if(path==null||!checked.add(path))continue;
            if(goodsId==null)throw invalid("通用或客户通用模板不能绑定某个产品的BOM路径，请限定具体产品");
            if("ROOT".equals(path)) {
                if(!cache.computeIfAbsent(goodsId,sources::edges).isEmpty())throw invalid("模板费用「"+fee.name()+"」的根行已变为组装结构，请重新选择路径");
                continue;
            }
            UUID parent=goodsId;
            String[] parts=path.split("/");if(parts.length>30)throw invalid("模板费用路径层数超出范围");
            for(String part:parts) {
                UUID edgeId;try{edgeId=UUID.fromString(part);}catch(IllegalArgumentException invalidPath){throw invalid("模板费用「"+fee.name()+"」的BOM路径格式无效");}
                Edge edge=cache.computeIfAbsent(parent,sources::edges).stream().filter(candidate->candidate.id().equals(edgeId)).findFirst().orElse(null);
                if(edge==null)throw invalid("模板费用「"+fee.name()+"」的BOM路径不属于该产品或已失效，请重新选择");
                references.requireVisibleGoods(edge.goods().id());parent=edge.goods().id();
            }
        }
    }
    static void validateDefinitions(List<FeeInput> fees,List<PriceColumn> columns) {
        if(list(fees).size()>3000||list(columns).size()>32)throw invalid("费用或价格列数量超出范围");
        Map<String,FeeInput> feeKeys=new HashMap<>();Set<String> columnKeys=new HashSet<>();
        for(FeeInput fee:list(fees)) {
            key(fee.key());name(fee.name());type(fee.type());category(fee.category());
            if(feeKeys.putIfAbsent(fee.key(),fee)!=null)throw invalid("费用编码重复");
            if(fee.value()!=null&&!fee.value().isBlank())nonnegative(fee.value(),"费用参数");
            if(fee.quantity()!=null&&!("PER_CYCLE".equals(fee.type())&&fee.quantity().isBlank()))positive(fee.quantity(),"费用数量");
        }
        for(PriceColumn column:list(columns)) {
            key(column.key());name(column.name());type(column.type());category(column.category());
            if(column.key().contains(":"))throw invalid("价格列编码不能包含冒号");
            if(!columnKeys.add(column.key()))throw invalid("价格列编码重复");
        }
        for(String key:feeKeys.keySet())validateDependency(key,feeKeys,new HashSet<>(),new HashSet<>());
    }
    private static void validateDependency(String key,Map<String,FeeInput> fees,Set<String> path,Set<String> complete) {
        if(complete.contains(key))return;
        if(Set.of("MATERIAL","PROCESS","DIRECT_COST").contains(key)) {
            for(FeeInput candidate:fees.values()) {
                String category=candidate.category()==null?"OTHER":candidate.category();
                if("DIRECT_COST".equals(key)?Set.of("MATERIAL","PROCESS").contains(category):key.equals(category))
                    validateDependency(candidate.key(),fees,new HashSet<>(path),complete);
            }
            return;
        }
        if(!path.add(key))throw invalid("费用公式存在循环");
        FeeInput fee=fees.get(key);if(fee==null)throw invalid("费用基数引用不存在："+key);
        if("PERCENT".equals(fee.type()))for(String dependency:list(fee.baseKeys()))validateDependency(dependency,fees,new HashSet<>(path),complete);
        complete.add(key);
    }
    private static void type(String type) {if(type==null||!Set.of("PER_UNIT","PER_QUANTITY","FIXED_BATCH","PERCENT","PER_CYCLE").contains(type))throw invalid("费用算法无效");}
    private static void category(String category) {if(category!=null&&!Set.of("MATERIAL","PROCESS","MANAGEMENT","OTHER").contains(category))throw invalid("费用分类无效");}
    public Calculation calculate(DraftInput input) {
        if(input==null || input.goodsId()==null) throw invalid("请选择货品");
        validateDefinitions(input.fees(),input.priceColumns());
        BigDecimal batch=positive(input.batchQty(),"成本批量"),fx=new BigDecimal(normalizeExchangeRate(input.currencyId(),input.exchangeRateToLocal()));
        if(!Set.of("ACTUAL_FIRST","DESIGN").contains(input.usageStrategy())) throw invalid("成本用量策略无效");
        if(!Set.of("AUTO","APPROVED_PURCHASE","INVENTORY","MANUAL").contains(input.priceStrategy())) throw invalid("成本取价策略无效");
        if(input.effectiveDate()==null) throw invalid("请选择成本日期");
        GoodsInfo root=sources.goods(input.goodsId());
        String currency=sources.currency(input.currencyId());
        State s=new State(input,batch,fx);
        if(input.extraFields()!=null&&input.extraFields().containsKey("costTemplateSourceValues"))
            s.revisions.put("templates:fee-source-values",input.extraFields().get("costTemplateSourceValues"));
        for(LineOverride override:list(input.lineOverrides())) {
            if(override.path()==null || s.overrides.putIfAbsent(override.path(),override)!=null) throw invalid("物料覆盖路径重复或缺失");
            if((override.adoptedQty()!=null || override.unitPrice()!=null || override.route()!=null || override.taxMode()!=null)
                    && (override.reason()==null || override.reason().isBlank())) throw invalid("手工覆盖需填写原因");
        }
        List<Edge> edges=s.edges(root.id());
        s.revisions.put("goods:"+root.id(),root.revision());
        if(edges.isEmpty()) {
            Edge pseudo=new Edge(null,root.id(),root,BigDecimal.ONE,null,BigDecimal.ONE,"NO_DATA",0,null,null,
                    "PER_UNIT",BigDecimal.ONE,true,false,root.revision());
            visit(s,pseudo,"ROOT",null,0,CostFraction.of(batch),new HashSet<>(),false);
        } else for(Edge edge:edges) visit(s,edge,edge.id().toString(),null,0,CostFraction.of(batch),new HashSet<>(Set.of(root.id())),false);
        for(String path:s.overrides.keySet()) if(!s.lines.containsKey(path)) throw invalid("BOM结构已变化，覆盖路径不存在："+path);
        List<FeeInput> fees=new ArrayList<>(list(input.fees()));
        Map<String,PriceColumn> columns=new LinkedHashMap<>();
        for(PriceColumn column:list(input.priceColumns())) {
            key(column.key()); name(column.name());
            if(columns.putIfAbsent(column.key(),column)!=null) throw invalid("价格列编码重复");
        }
        Set<String> cells=new HashSet<>();
        for(PriceCell cell:list(input.priceCells())) {
            PriceColumn column=columns.get(cell.columnKey());
            if(column==null || !s.lines.containsKey(cell.path())) throw invalid("价格列或物料路径不存在");
            String cellKey="COLUMN:"+cell.columnKey()+":"+cell.path();
            if(!cells.add(cellKey)) throw invalid("同一物料价格列重复");
            fees.add(new FeeInput(cellKey,column.name(),column.type(),column.category(),cell.path(),cell.value(),
                    cell.quantity(),column.baseKeys(),"PRICE_COLUMN",cell.reason()));
        }
        List<FeeResult> feeResults=calculateFees(s,fees);
        Map<String,BigDecimal> categories=new LinkedHashMap<>();
        categories.put("MATERIAL",BigDecimal.ZERO);categories.put("PROCESS",BigDecimal.ZERO);
        categories.put("MANAGEMENT",BigDecimal.ZERO);categories.put("OTHER",BigDecimal.ZERO);
        int actual=0,design=0,missing=0;
        for(CostLine line:s.lines.values()) {
            if("ACTUAL".equals(line.usageBasis()))actual++;else design++;
            if(line.included() && line.amount()==null) missing++;
            if(line.included() && line.amount()!=null) {
                String category="SUBCONTRACT".equals(line.route())?"PROCESS":"MATERIAL";
                categories.merge(category,new BigDecimal(line.amount()),BigDecimal::add);
            }
        }
        for(FeeResult fee:feeResults) if(fee.amount()!=null) categories.merge(fee.category(),new BigDecimal(fee.amount()),BigDecimal::add);
        BigDecimal total=categories.values().stream().reduce(BigDecimal.ZERO,BigDecimal::add);
        FinancialExactAmount.book(total,"成本合计");
        boolean complete=s.issues.stream().noneMatch(Issue::blocksConfirmation);
        String state=complete?"COMPLETE":"INCOMPLETE";
        Map<String,String> categoryText=new LinkedHashMap<>();categories.forEach((k,v)->categoryText.put(k,text(v)));
        Totals totals=new Totals(text(categories.get("MATERIAL")),text(categories.get("PROCESS")),
                text(categories.get("MANAGEMENT")),text(categories.get("OTHER")),text(total),
                complete?text(divide(total,batch)):null,state,missing,actual,design,categoryText);
        List<CostLine> lines=decorateLines(s,feeResults);
        String digest=json.hash(Arrays.asList(ALGORITHM,input,lines,feeResults,totals,s.issues,s.revisions));
        return new Calculation(ALGORITHM,OffsetDateTime.now(ZoneOffset.UTC),digest,root.id(),root.code(),root.name(),
                root.unitId(),root.unitName(),input.currencyId(),currency,text(batch),text(fx),lines,feeResults,totals,
                List.copyOf(s.issues),Map.copyOf(s.revisions));
    }
    private void visit(State s,Edge edge,String path,String parent,int depth,CostFraction parentQty,Set<UUID> ancestors,boolean contractual) {
        if(depth>30 || s.lines.size()>=3000) throw invalid("BOM层数或明细数量超出成本计算范围");
        GoodsInfo goods=edge.goods();
        if(!ancestors.add(goods.id())) throw invalid("BOM存在循环，请修正后计算");
        references.requireVisibleGoods(goods.id());
        if(goods.unitId()==null) throw invalid("组件未维护基本单位");
        s.revisions.put("goods:"+goods.id(),goods.revision());
        s.revisions.put("edge:"+path,edge.revision()+"/"+text(edge.effectiveQty())+"/"+edge.samples());
        LineOverride override=s.overrides.get(path);
        List<Edge> children=s.edges(goods.id());
        String route=override!=null&&override.route()!=null?override.route():"AUTO";
        if("AUTO".equals(route)) route="外购".equals(goods.sourceType())||"采购".equals(goods.sourceType())?"BUY":
                "委外".equals(goods.sourceType())?"SUBCONTRACT":"自制".equals(goods.sourceType())?"MAKE":children.isEmpty()?"BUY":"MAKE";
        if(!Set.of("MAKE","BUY","SUBCONTRACT","CUSTOMER_SUPPLIED").contains(route)) throw invalid("成本路线无效");
        boolean actual="ACTUAL_FIRST".equals(s.input.usageStrategy())&&"ACTUAL".equals(edge.actualStatus())&&!contractual;
        BigDecimal adopted=actual?edge.effectiveQty():edge.designQty();
        String basis=actual?"ACTUAL":"DESIGN",reason=contractual?"SUBCONTRACT_CONTRACT":Objects.toString(edge.actualStatus(),"NO_DATA");
        if(override!=null&&override.adoptedQty()!=null) {adopted=positive(override.adoptedQty(),"采用量");basis="MANUAL";reason=override.reason();}
        if(adopted==null || adopted.signum()<=0) throw invalid("组件设计或采用用量必须大于零");
        CostFraction exactQty=BomConsumptionCurve.exact(parentQty,adopted,edge.basis(),edge.basisOutput(),edge.partial());
        BigDecimal qty=exactQty.project();s.quantities.put(path,exactQty);
        s.revisions.put("quantity:"+path,exactQty.numerator()+"/"+exactQty.denominator());
        FinancialExactAmount.book(qty,"成本用量");
        boolean included=!"MAKE".equals(route);
        PriceEvidence evidence=null;BigDecimal unitPrice=null,amount=null;
        if(included) {
            if("CUSTOMER_SUPPLIED".equals(route)) {
                if(override==null||override.reason()==null||override.reason().isBlank()) throw invalid("客供料需说明合同承担范围");
                unitPrice=BigDecimal.ZERO;amount=BigDecimal.ZERO;
                evidence=new PriceEvidence("CUSTOMER_SUPPLIED",null,null,null,null,"CONFIRMED_ASSUMPTION",null,s.input.currencyId(),null,
                        goods.unitId(),goods.unitName(),"1","0",text(s.fx),null,"AS_RECORDED",s.input.effectiveDate(),override.reason());
            } else {
                boolean searchIncomplete=false;
                try{evidence=price(s,goods,route,override);}
                catch(GoodsCostSourceReader.PriceSearchIncomplete incomplete) {
                    s.issues.add(new Issue("PRICE_SEARCH_INCOMPLETE",path,incomplete.getMessage(),true));searchIncomplete=true;
                }
                if(evidence!=null) {
                    if("UNCONFIRMED".equals(evidence.taxMode()))s.issues.add(new Issue("TAX_BASIS_UNCONFIRMED",path,"原扣税设置对应的价格来源已变化，现按原记录价展示，请复核该行扣税设置",true));
                    if("APPROVED_WITH_COMPONENTS".equals(evidence.approvalState()))s.issues.add(new Issue("PRICE_COMPONENTS_UNCONFIRMED",path,evidence.reason(),true));
                    BigDecimal original=nonnegative(evidence.originalUnitPrice(),"来源价格");
                    BigDecimal rate=positive(evidence.unitRate(),"来源单位换算率");
                    BigDecimal sourceFx=positive(evidence.exchangeRateToLocal(),"来源汇率");
                    CostFraction normalized=CostFraction.of(original).multiply(sourceFx).divide(rate).divide(s.fx);
                    if("EXCLUDE_TAX".equals(evidence.taxMode())) normalized=normalized.divide(
                            BigDecimal.ONE.add(divide(nonnegative(evidence.taxRate(),"税率"),new BigDecimal("100"))));
                    amount=FinancialExactAmount.book(exactQty.multiply(normalized).project(),"成本金额");
                    unitPrice=FinancialExactAmount.book(normalized.project(),"成本单价");
                    s.revisions.put("price:"+path,json.hash(evidence));
                } else if(!searchIncomplete)s.issues.add(new Issue("MISSING_PRICE",path,"缺少适用且来源完整的成本价格",true));
            }
        } else if(children.isEmpty()) s.issues.add(new Issue("MISSING_MAKE_BASIS",path,"自制件没有材料或已确认成本依据",true));
        CostLine line=new CostLine(path,parent,path,depth,edge.id(),goods.id(),goods.code(),goods.name(),goods.colorId(),goods.colorName(),
                goods.unitId(),goods.unitName(),goods.sourceType(),route,text(edge.designQty()),text(edge.actualQty()),text(adopted),basis,reason,
                edge.samples(),text(edge.output()),text(edge.net()),edge.basis(),text(edge.basisOutput()),edge.partial(),text(qty),
                text(exactQty.divide(s.batch).project()),text(unitPrice),evidence==null?null:evidence.unitRate(),text(amount),
                amount==null?null:text(divide(amount,s.batch)),included,included?(amount==null?"MISSING":evidence!=null&&("UNCONFIRMED".equals(evidence.taxMode())
                ||"APPROVED_WITH_COMPONENTS".equals(evidence.approvalState()))?"UNCONFIRMED":"KNOWN"):"ROLLUP",evidence,Map.of(),text(amount),"0");
        s.lines.put(path,line);
        if("MAKE".equals(route)||"SUBCONTRACT".equals(route)) {
            for(Edge child:children) visit(s,child,path+"/"+child.id(),path,depth+1,exactQty,new HashSet<>(ancestors),"SUBCONTRACT".equals(route)&&children.size()==1);
        }
    }
    private PriceEvidence price(State s,GoodsInfo goods,String route,LineOverride override) {
        if(override!=null&&override.unitPrice()!=null) {
            String mode=override.taxMode()==null?"AS_RECORDED":override.taxMode();
            if(!Set.of("AS_RECORDED","EXCLUDE_TAX").contains(mode)) throw invalid("成本税口径无效");
            BigDecimal unitRate=positive(override.priceUnitRate()==null?"1":override.priceUnitRate(),"来源单位换算率");
            boolean basicUnit=unitRate.compareTo(BigDecimal.ONE)==0;
            String priceUnitName=basicUnit?goods.unitName():text(unitRate)+" "+goods.unitName()+" (计价基数)";
            return new PriceEvidence("MANUAL",null,null,null,null,"CONFIRMED_ASSUMPTION",null,s.input.currencyId(),null,basicUnit?goods.unitId():null,priceUnitName,
                    text(unitRate),override.unitPrice(),
                    override.priceExchangeRateToLocal()==null?text(s.fx):override.priceExchangeRateToLocal(),override.taxRate(),mode,
                    s.input.effectiveDate(),override.reason());
        }
        UUID item=override==null?null:override.priceSourceItemId();
        boolean automatic="AUTO".equals(s.input.priceStrategy());
        if(item!=null || automatic || "APPROVED_PURCHASE".equals(s.input.priceStrategy())) {
            boolean taxOnly=override!=null&&override.taxMode()!=null;
            boolean pinned=override!=null&&Objects.toString(override.priceSourceType(),"").endsWith("_PINNED");
            PriceEvidence found=sources.approved(goods,"SUBCONTRACT".equals(route),s.input.effectiveDate(),taxOnly&&!pinned?null:item);
            if(found!=null&&override!=null&&override.taxMode()!=null) {
                if(!Set.of("AS_RECORDED","EXCLUDE_TAX").contains(override.taxMode()))throw invalid("成本税口径无效");
                if(!Objects.equals(override.priceSourceItemId(),found.sourceItemId())
                        ||!Objects.equals(override.priceSourceVersion(),found.sourceVersion())) {
                    if(!"EXCLUDE_TAX".equals(override.taxMode()))return found;
                    return new PriceEvidence(found.sourceType(),found.sourceId(),found.sourceItemId(),found.sourceNumber(),found.sourceVersion(),found.approvalState(),
                            found.supplierId(),found.currencyId(),found.currencyName(),found.unitId(),found.unitName(),found.unitRate(),found.originalUnitPrice(),
                            found.exchangeRateToLocal(),found.taxRate(),"UNCONFIRMED",found.sourceDate(),found.reason()
                            +"；原扣税设置尚未复核："+override.reason());
                }
                return new PriceEvidence(found.sourceType(),found.sourceId(),found.sourceItemId(),found.sourceNumber(),found.sourceVersion(),found.approvalState(),
                        found.supplierId(),found.currencyId(),found.currencyName(),found.unitId(),found.unitName(),found.unitRate(),found.originalUnitPrice(),
                        found.exchangeRateToLocal(),found.taxRate(),override.taxMode(),found.sourceDate(),
                        "APPROVED_WITH_COMPONENTS".equals(found.approvalState())?found.reason()+"；税口径确认："+override.reason():override.reason());
            }
            if(found==null&&automatic&&"BUY".equals(route)&&item==null&&(override==null||override.taxMode()==null))
                return sources.inventory(goods,s.input.effectiveDate());
            return found;
        }
        if("INVENTORY".equals(s.input.priceStrategy())&&"BUY".equals(route))return sources.inventory(goods,s.input.effectiveDate());
        return null;
    }
    private List<FeeResult> calculateFees(State s,List<FeeInput> fees) {
        if(fees.size()>3000) throw invalid("费用数量超出范围");
        LinkedHashMap<String,FeeInput> byKey=new LinkedHashMap<>();
        for(FeeInput fee:fees) { key(fee.key());name(fee.name());if(byKey.putIfAbsent(fee.key(),fee)!=null)throw invalid("费用编码重复："+fee.key()); }
        Map<String,FeeResult> results=new LinkedHashMap<>();
        for(String key:byKey.keySet()) fee(s,key,byKey,results,new HashSet<>());
        return List.copyOf(results.values());
    }
    private FeeResult fee(State s,String key,Map<String,FeeInput> inputs,Map<String,FeeResult> results,Set<String> visiting) {
        if(results.containsKey(key))return results.get(key);
        if(!visiting.add(key))throw invalid("费用公式存在循环");
        FeeInput f=inputs.get(key);if(f==null)throw invalid("费用基数引用不存在："+key);
        if(!Set.of("PER_UNIT","PER_QUANTITY","FIXED_BATCH","PERCENT","PER_CYCLE").contains(f.type()))throw invalid("费用算法无效");
        String category=f.category()==null?"OTHER":f.category();
        if(!Set.of("MATERIAL","PROCESS","MANAGEMENT","OTHER").contains(category))throw invalid("费用分类无效");
        CostLine line=f.targetPath()==null?null:s.lines.get(f.targetPath());
        if(f.targetPath()!=null&&line==null)throw invalid("费用物料路径不存在");
        CostFraction exactQuantity=line==null?CostFraction.of(s.batch):s.quantities.get(line.path());
        BigDecimal quantity=exactQuantity.project();
        boolean missingCycleQuantity="PER_CYCLE".equals(f.type())&&(f.quantity()==null||f.quantity().isBlank());
        if(f.quantity()!=null&&!missingCycleQuantity){quantity=positive(f.quantity(),"费用数量或每周期产出");exactQuantity=CostFraction.of(quantity);}
        BigDecimal base=BigDecimal.ZERO,amount=null;boolean complete=true;
        List<String> bases=list(f.baseKeys());if(bases.isEmpty())bases=List.of("MATERIAL");
        if(new HashSet<>(bases).size()!=bases.size())throw invalid("费用基数不能重复引用");
        Set<String> contributors=new HashSet<>();
        if("PERCENT".equals(f.type())) {
            for(String dependency:bases) {
                if(Set.of("MATERIAL","PROCESS","DIRECT_COST").contains(dependency)) {
                    for(CostLine item:s.lines.values())if(item.included() && (line==null||item.path().equals(line.path())||item.path().startsWith(line.path()+"/"))) {
                        boolean process="SUBCONTRACT".equals(item.route());
                        if("MATERIAL".equals(dependency)&&process||"PROCESS".equals(dependency)&&!process)continue;
                        if(!contributors.add("LINE:"+item.path()))throw invalid("费用基数重复计入同一物料，请移除重叠分组");
                        if(item.amount()==null||!"KNOWN".equals(item.valueState()))complete=false;
                        if(item.amount()!=null)base=base.add(new BigDecimal(item.amount()));
                    }
                    for(FeeInput candidate:inputs.values()) {
                        String candidateCategory=candidate.category()==null?"OTHER":candidate.category();
                        boolean belongs="DIRECT_COST".equals(dependency)?Set.of("MATERIAL","PROCESS").contains(candidateCategory):dependency.equals(candidateCategory);
                        boolean inScope=line==null||candidate.targetPath()!=null&&(candidate.targetPath().equals(line.path())||candidate.targetPath().startsWith(line.path()+"/"));
                        if(!belongs||!inScope)continue;
                        if(!contributors.add("FEE:"+candidate.key()))throw invalid("费用基数重复计入同一费用，请移除重叠分组");
                        FeeResult prior=fee(s,candidate.key(),inputs,results,new HashSet<>(visiting));
                        if(prior.amount()==null)complete=false;else base=base.add(new BigDecimal(prior.amount()));
                    }
                } else {
                    if(!contributors.add("FEE:"+dependency))throw invalid("费用基数重复计入同一费用");
                    FeeResult prior=fee(s,dependency,inputs,results,new HashSet<>(visiting));
                    if(prior.amount()==null)complete=false;else base=base.add(new BigDecimal(prior.amount()));
                }
            }
        }
        if(f.value()!=null&&!f.value().isBlank()&&complete&&!missingCycleQuantity) {
            BigDecimal value=nonnegative(f.value(),"费用参数");
            amount=switch(f.type()) {
                case "PER_UNIT" -> product(s.batch,value);
                case "PER_QUANTITY" -> FinancialExactAmount.book(exactQuantity.multiply(value).project(),"费用金额");
                case "FIXED_BATCH" -> value;
                case "PERCENT" -> FinancialExactAmount.book(CostFraction.of(base).multiply(value).divide(new BigDecimal("100")).project(),"费用金额");
                case "PER_CYCLE" -> product((line==null?CostFraction.of(s.batch):s.quantities.get(line.path())).divide(quantity).ceiling(),value);
                default -> throw new IllegalStateException();
            };
        }
        if(amount==null)s.issues.add(new Issue("MISSING_FEE",f.targetPath(),missingCycleQuantity
                ?"费用「"+f.name()+"」尚未填写每周期产出，请填写后再确认":"费用「"+f.name()+"」参数或基数尚未完整",true));
        String feeState=!complete?"INCOMPLETE":amount==null?"MISSING":"KNOWN";
        String feeReason=missingCycleQuantity?"每周期产出尚未填写"+(f.reason()==null?"":"；"+f.reason())
                :!complete?"计费基数尚未完整"+(f.reason()==null?"":"；"+f.reason()):f.reason();
        FeeResult result=new FeeResult(key,f.name(),f.type(),category,f.targetPath(),f.value(),f.quantity(),bases,text(base),text(amount),
                amount==null?null:text(divide(amount,s.batch)),feeState,f.source(),feeReason);
        results.put(key,result);return result;
    }
    private List<CostLine> decorateLines(State s,List<FeeResult> fees) {
        List<CostLine> output=new ArrayList<>();
        for(CostLine line:s.lines.values()) {
            Map<String,String> extras=new LinkedHashMap<>();
            for(FeeResult fee:fees) if(line.path().equals(fee.targetPath())&&fee.key().startsWith("COLUMN:")) {
                String column=fee.key().substring(7,fee.key().length()-line.path().length()-1);
                if(fee.amount()!=null)extras.put(column,fee.amount());
            }
            BigDecimal subtotal=line.amount()==null?null:new BigDecimal(line.amount());String state=line.valueState();
            BigDecimal ownFees=BigDecimal.ZERO;
            for(FeeResult fee:fees)if(line.path().equals(fee.targetPath())) {
                if(fee.amount()==null)state="INCOMPLETE";else ownFees=ownFees.add(new BigDecimal(fee.amount()));
            }
            if(line.included()&&subtotal!=null)subtotal=subtotal.add(ownFees);
            if(!line.included()) {
                subtotal=BigDecimal.ZERO;boolean complete=true;
                for(CostLine child:s.lines.values())if(child.included()&&child.path().startsWith(line.path()+"/")) {
                    if(child.amount()==null)complete=false;else subtotal=subtotal.add(new BigDecimal(child.amount()));
                }
                for(FeeResult fee:fees)if(fee.targetPath()!=null&&(fee.targetPath().equals(line.path())||fee.targetPath().startsWith(line.path()+"/"))) {
                    if(fee.amount()==null)complete=false;else subtotal=subtotal.add(new BigDecimal(fee.amount()));
                }
                state=complete?"ROLLUP":"INCOMPLETE_ROLLUP";
            }
            output.add(new CostLine(line.id(),line.parentId(),line.path(),line.depth(),line.bomItemId(),line.goodsId(),line.goodsCode(),line.goodsName(),
                    line.colorId(),line.colorName(),line.unitId(),line.unitName(),line.sourceType(),line.route(),line.designQty(),line.actualQty(),
                    line.adoptedQty(),line.usageBasis(),line.usageReason(),line.sampleCount(),line.actualOutputQty(),line.actualNetQty(),line.consumptionBasis(),
                    line.basisOutputQty(),line.allowPartialPackage(),line.batchQty(),line.perProductQty(),line.unitPrice(),line.priceUnitRate(),text(subtotal),
                    subtotal==null?null:text(divide(subtotal,s.batch)),line.included(),state,line.priceEvidence(),Map.copyOf(extras),
                    line.included()?line.amount():null,text(ownFees)));
        }
        return List.copyOf(output);
    }
    private static void key(String value) {if(value==null||value.isBlank()||value.length()>2048||Set.of("MATERIAL","PROCESS","DIRECT_COST").contains(value))throw invalid("费用编码无效或为保留编码");}
    private static void name(String value) {if(value==null||value.isBlank()||value.length()>160)throw invalid("费用名称不能为空或超过160字");}
    static <T> List<T> list(List<T> values) {
        if(values==null)return List.of();
        if(values.stream().anyMatch(Objects::isNull))throw invalid("成本输入不能含空明细");
        return values;
    }
    private final class State {
        final DraftInput input;final BigDecimal batch,fx;
        final Map<String,LineOverride> overrides=new HashMap<>();
        final LinkedHashMap<String,CostLine> lines=new LinkedHashMap<>();
        final List<Issue> issues=new ArrayList<>();final Map<String,String> revisions=new LinkedHashMap<>();
        final Map<UUID,List<Edge>> edgeCache=new HashMap<>();
        final Map<String,CostFraction> quantities=new HashMap<>();
        State(DraftInput input,BigDecimal batch,BigDecimal fx){this.input=input;this.batch=batch;this.fx=fx;}
        List<Edge> edges(UUID goods){return edgeCache.computeIfAbsent(goods,sources::edges);}
    }
}
