package com.uten.imp.features.master.goods.pricing;

import com.uten.imp.application.port.MasterReferenceValidationPort;
import com.uten.imp.common.time.BusinessTime;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.master.goods.costing.GoodsCostSheetService;
import com.uten.imp.features.master.goods.costing.GoodsCostCalculator;
import com.uten.imp.security.OwnerVisibility;
import lombok.RequiredArgsConstructor;
import org.springframework.jdbc.core.namedparam.NamedParameterJdbcTemplate;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Isolation;
import org.springframework.transaction.annotation.Transactional;
import java.math.*;
import java.time.OffsetDateTime;
import java.util.*;
import static com.uten.imp.features.master.goods.pricing.GoodsPriceContracts.*;
import static com.uten.imp.features.master.goods.pricing.GoodsPriceSourceReader.decimalText;

@Service
@RequiredArgsConstructor
@Transactional(readOnly=true,isolation=Isolation.REPEATABLE_READ)
public class GoodsPriceAnalysisService {
    private final GoodsPriceAccess access;
    private final MasterReferenceValidationPort references;
    private final GoodsPriceSourceReader sources;
    private final GoodsCostSheetService costs;
    private final NamedParameterJdbcTemplate db;

    /** Strictly one invocation: never shared between requests, actors or transactions. */
    private static final class ReadSession {
        final Set<UUID> validatedGoods=new HashSet<>();
        final Map<UUID,GoodsPriceSourceReader.Goods> goods=new HashMap<>();
        final Map<Kind,OwnerVisibility.OwnerScope> scopes=new EnumMap<>(Kind.class);
        final Map<Query,GoodsPriceSourceReader.Data> sources=new HashMap<>();
    }

    public boolean available(Kind kind){return access.available(kind);}
    public History history(HistoryQuery request) {
        if(request==null||request.context()==null||request.context().goodsId()==null)throw invalid("请选择历史货品");
        access.requireHistory(request.context().kind());references.requireVisibleGoods(request.context().goodsId());
        return sources.history(request,access.sourceScope(request.context().kind()),access.has("sales_quote_finance:view"),access.available(request.context().kind()));
    }
    public Detail detail(UUID goodsId,DetailQuery request) {
        if(goodsId==null||request==null||request.kind()==null||request.sourceId()==null||request.sourceItemId()==null
                ||request.sourceType()==null||request.expectedSourceRevision()==null||!request.expectedSourceRevision().matches("[0-9a-f]{64}"))
            throw invalid("价格详情缺少有效来源或版本，请重新加载");
        Set<String> types=switch(request.kind()) {
            case PURCHASE -> Set.of("PURCHASE_ORDER","PURCHASE_ORDER_APPROVAL");
            case SUBCONTRACT -> Set.of("SUBCONTRACT_ORDER","SUBCONTRACT_ORDER_APPROVAL");
            case SALES -> Set.of("SALES_ORDER","SALES_ORDER_ARCHIVED","SALES_QUOTE_CONFIRMED");
        };
        if(!types.contains(request.sourceType())||request.historyVersionId()==null&&!request.sourceType().equals(request.kind().name()+"_ORDER"))
            throw invalid("价格来源类型或历史版本不正确，请重新加载");
        access.requireHistory(request.kind());references.requireVisibleGoods(goodsId);
        Observation row=sources.detail(goodsId,request,access.sourceScope(request.kind()),access.has("sales_quote_finance:view"),access.available(request.kind()));
        String summary=!"ACTIVE".equals(row.lifecycle())?"保留当时的价格记录，仅供追溯，不纳入当前参考价。"
                :row.comparable()?"已审核原币价格；比较时须保持币种、税率、单位和批量条件一致。":"本条计价依据尚待核对，暂不纳入参考价。";
        String partner=request.kind()==Kind.SALES?"客户":request.kind()==Kind.SUBCONTRACT?"委外商":"供应商";
        List<DetailField> fields=List.of(
                new DetailField("sourceNo","来源单号",row.sourceNo()),
                new DetailField("businessDate","单据日期",row.businessDate()==null?null:row.businessDate().toString()),
                new DetailField("recordedAt","批准或记录时间",row.recordedAt()==null?null:row.recordedAt().toString()),
                new DetailField("partnerName",partner,row.partnerName()),
                new DetailField("goodsCodeSnapshot","当时货品编号",row.goodsCodeSnapshot()),
                new DetailField("goodsNameSnapshot","当时货品名称",row.goodsNameSnapshot()),
                new DetailField("colorName","颜色",row.colorName()),new DetailField("unitName","计价单位",row.unitName()),
                new DetailField("unitRate","单位换算率",row.unitRate()),new DetailField("currencyName","币种",row.currencyName()),
                new DetailField("taxRate","原记录税率",row.taxRate()==null?null:row.taxRate()+"%"),
                new DetailField("quantity","计价数量",row.quantity()),new DetailField("unitPrice","本行折合单价",row.unitPrice()),
                new DetailField("amount","原币金额",row.amount()),
                new DetailField("exchangeRateToLocal","FINANCE_APPROVAL_CASE".equals(row.exchangeRateSource())?"财审汇率":"原记录汇率",row.exchangeRateToLocal()));
        return new Detail(row,"价格详情",summary,row.reasonCodes(),fields);
    }
    public Analysis analysis(Query q) {
        return analysis(q,new ReadSession());
    }
    private Analysis analysis(Query q,ReadSession session) {
        if(q==null||q.goodsId()==null)throw invalid("请选择货品");
        access.require(q.kind());validateGoods(q.goodsId(),session);
        int days=q.days()==null?180:q.days();if(days<1||days>730)throw invalid("统计期间应为 1 至 730 天；更早单据可按历史分页查询");
        BigDecimal quantity=q.quantity()==null?null:decimal(q.quantity(),"本次数量",true);
        if(q.taxRate()!=null)decimal(q.taxRate(),"税率",false);
        if(q.unitRate()!=null)decimal(q.unitRate(),"换算率",true);
        if(q.supplierId()!=null&&q.kind()==Kind.SALES)throw invalid("销售价格请按客户筛选");
        var goods=session.goods.computeIfAbsent(q.goodsId(),sources::goods);
        // Quantity affects estimation, not which immutable source rows SQL reads.
        Query sourceKey=new Query(q.goodsId(),q.kind(),days,q.supplierId(),q.colorId(),q.unitId()==null?goods.unitId():q.unitId(),q.currencyId(),
                q.taxRate()==null?null:decimalText(new BigDecimal(q.taxRate())),null,q.excludeOrderId(),q.clientId(),null,null,
                q.unitRate()==null?null:decimalText(new BigDecimal(q.unitRate())));
        var data=session.sources.computeIfAbsent(sourceKey,key->sources.read(key,goods,days,
                session.scopes.computeIfAbsent(q.kind(),access::sourceScope)));
        Context context=withQuantity(data.context(),q.quantity());
        var stats=GoodsPriceStatistics.calculate(data.observations(),BusinessTime.today(),quantity,data.complete());
        var cost=q.kind()==Kind.SALES?costSuggestion(q,context):null;
        List<String> reasons=new ArrayList<>(stats.reasons());
        if(data.observations().stream().anyMatch(o->!o.comparable()))reasons.add("NON_COMPARABLE_ROWS_EXCLUDED");
        String explanation="同货品、颜色、单位及换算率、原币和原记录税率的已审核订货价；不是结算成本或外部市场行情。"
                +"历史均价按金额合计÷收费数量合计；建议采用按源单合并的时间衰减加权中位数（半衰期90天），离散度采用MAD。"
                +"参考区间为历史稳健波动带，不是承诺置信区间。"
                +"当前版本采用至少3张独立订单、有效样本2.5、最小10%相对波动带；指定批量时无10倍范围内样本会提示不足。这些是初始策略，尚未代表本企业回测最优参数。"
                +(q.kind()==Kind.SUBCONTRACT?"委外为加工费口径，特殊工艺、供料范围请核对原单。":"")
                +(!data.complete()?"本窗口超过500条，请缩短统计期间；历史可分页查询，当前不输出统计结论。":"")
                +(stats.status().equals("STALE")?"最近记录超过90天，当前不作价格正常与否判断。":"");
        String token=GoodsPriceSourceReader.hash(GoodsPriceStatistics.VERSION+"|"+BusinessTime.today()+"|"+q+"|"+context+"|"+data.complete()+"|"
                +data.observations().stream().map(o->o.sourceItemId()+":"+o.sourceRevision()).toList()+"|"+cost);
        return new Analysis(q.goodsId(),goods.code(),goods.name(),q.kind(),context,stats.status(),decimalText(stats.reference()),decimalText(stats.average()),
                decimalText(stats.lower()),decimalText(stats.upper()),decimalText(stats.last()),stats.lastDate(),stats.samples(),stats.orders(),
                decimalText(BigDecimal.valueOf(stats.effective()).setScale(3,RoundingMode.HALF_UP)),OffsetDateTime.now(),List.copyOf(reasons),explanation,
                data.observations(),token,GoodsPriceStatistics.VERSION,data.complete(),cost);
    }
    /** Re-read permissions, source lifecycle, authoritative values and context before reusing an explanation. */
    public void requireCurrentEvidence(Query query,String token) {
        if(token==null||!token.equals(analysis(query).evidenceToken()))throw new ApiException(ErrorCode.CONFLICT,"价格依据已变化，请重新查询");
    }
    public CheckResult check(CheckRequest request) {
        if(request==null||request.items()==null||request.items().isEmpty()||request.items().size()>100){ throw invalid("每次价格核对须为 1 至 100 行"); }
        access.require(request.kind());
        Set<String> keys=new HashSet<>();List<CheckRow> rows=new ArrayList<>();
        ReadSession session=new ReadSession();
        // Duplicate contexts share one source query; the current document never becomes its own baseline.
        Map<Query,Analysis> cache=new HashMap<>();
        for(CheckItem item:request.items()) {
            if(item==null||item.goodsId()==null||item.rowKey()==null||item.rowKey().isBlank()||!keys.add(item.rowKey())){ throw invalid("核对行必须包含唯一行标识和货品"); }
            validateGoods(item.goodsId(),session);
            if(item.giftQuantity()!=null&&decimal(item.giftQuantity(),"赠品数量",false).signum()>0){
                rows.add(unavailable(item,"GIFT_COMPONENT","本行包含赠品，不能直接与无赠品单价相比；请核对整体商业条款"));continue;
            }
            if(item.unitId()==null||item.unitRate()==null||item.currencyId()==null||item.taxRate()==null||request.kind()!=Kind.SALES&&item.supplierId()==null){
                rows.add(unavailable(item,"CONTEXT_INCOMPLETE","请先填写供应商、计价单位、换算率、币种和税率"));continue;
            }
            BigDecimal qty=decimal(item.quantity(),"本次数量",false);
            if(qty.signum()==0){rows.add(unavailable(item,"NO_CHARGED_QUANTITY","本行为零收费量或赠品，不参与单价比较"));continue;}
            BigDecimal price=item.totalAmountInput()!=null
                    ?decimal(item.totalAmountInput(),"原币总价",false).divide(qty,MathContext.DECIMAL128):decimal(item.unitPrice(),"本次单价",false);
            // Posted server data has canonical operations. Untrusted input columns are never interpreted as proof of no fees.
            if(item.extraColumns()!=null&&!item.extraColumns().isEmpty()){
                rows.add(unavailable(item,"UNDIVIDED_PRICE_COMPONENTS","本行有附加列；请先核对并拆清计费项，再判断纯单价偏差"));continue;
            }
            Query q=new Query(item.goodsId(),request.kind(),request.days(),item.supplierId(),item.colorId(),item.unitId(),item.currencyId(),item.taxRate(),item.quantity(),request.excludeOrderId(),null,null,null,item.unitRate());
            Analysis a=cache.computeIfAbsent(q,key->analysis(key,session));
            Analysis peer=null;boolean fallback=false;
            if(item.supplierId()!=null){
                Query peerQuery=new Query(q.goodsId(),q.kind(),q.days(),null,q.colorId(),q.unitId(),q.currencyId(),q.taxRate(),q.quantity(),q.excludeOrderId(),q.clientId(),null,null,q.unitRate());
                peer=cache.computeIfAbsent(peerQuery,key->analysis(key,session));
                if(("INSUFFICIENT".equals(a.status())||"STALE".equals(a.status()))&&"READY".equals(peer.status())){a=peer;fallback=true;}
            }
            if(!"READY".equals(a.status())){
                rows.add(new CheckRow(item.rowKey(),item.goodsId(),a.status(),"INSUFFICIENT",decimalText(price),a.referencePrice(),a.weightedAveragePrice(),null,null,a.reasonCodes(),"可比记录不足、过旧或尚未查全，暂不能判断价格是否正常",a.evidenceToken(),a.sampleCount(),"INSUFFICIENT",null,null,a.context().currencyName(),a.context().unitName()));continue;
            }
            BigDecimal reference=new BigDecimal(a.referencePrice());
            boolean high=price.compareTo(new BigDecimal(a.upperReferencePrice()))>0,low=price.compareTo(new BigDecimal(a.lowerReferencePrice()))<0;
            BigDecimal deviation=price.subtract(reference).divide(reference,MathContext.DECIMAL128).multiply(BigDecimal.valueOf(100));
            BigDecimal impact=price.subtract(reference).multiply(qty);
            boolean peerHigh=false;String peerDeviation=null;
            if(peer!=null){
                if("READY".equals(peer.status())){
                    BigDecimal peerPrice=new BigDecimal(peer.referencePrice());
                    peerHigh=price.compareTo(new BigDecimal(peer.upperReferencePrice()))>0;
                    peerDeviation=decimalText(price.subtract(peerPrice).divide(peerPrice,MathContext.DECIMAL128).multiply(BigDecimal.valueOf(100)).setScale(2,RoundingMode.HALF_UP));
                }
            }
            String direction=high?"高于":low?"低于":"位于";
            List<String> alerts=new ArrayList<>();if(high){ alerts.add("PRICE_ABOVE_REFERENCE"); }if(low){ alerts.add("PRICE_BELOW_REFERENCE"); }if(peerHigh){ alerts.add("PEER_PRICE_ABOVE_REFERENCE"); }if(fallback){ alerts.add("SUPPLIER_SCOPE_FALLBACK"); }
            rows.add(new CheckRow(item.rowKey(),item.goodsId(),"READY",high||low||peerHigh?"WARNING":"NONE",decimalText(price),a.referencePrice(),a.weightedAveragePrice(),
                    decimalText(deviation.setScale(2,RoundingMode.HALF_UP)),decimalText(impact),List.copyOf(alerts),
                    (fallback?"当前供应商证据不足，采用同条件授权范围内供应商历史。":"")+"本次单价"+direction+"历史参考区间；近期参考 "+a.referencePrice()+"，加权均价 "+a.weightedAveragePrice()+"，共 "+a.independentOrderCount()+" 张独立订单。"
                    +(peerDeviation==null?"":"同条件授权范围内全部供应商参考 "+peer.referencePrice()+"，偏差 "+peerDeviation+"%。")
                    +"请结合批量及特殊条款核对。",a.evidenceToken(),a.sampleCount(),"REFERENCE_ONLY",peerDeviation==null?null:peer.referencePrice(),peerDeviation,a.context().currencyName(),a.context().unitName()));
        }
        return new CheckResult(List.copyOf(rows),GoodsPriceStatistics.VERSION,OffsetDateTime.now());
    }
    private static CheckRow unavailable(CheckItem item,String reason,String message){return new CheckRow(item.rowKey(),item.goodsId(),"INSUFFICIENT","INSUFFICIENT",null,null,null,null,null,List.of(reason),message,null,0,"INSUFFICIENT",null,null);}
    private void validateGoods(UUID id,ReadSession session){if(session.validatedGoods.add(id))references.requireVisibleGoods(id);}
    private static Context withQuantity(Context c,String quantity){return new Context(c.supplierId(),c.clientId(),c.colorId(),c.unitId(),c.unitName(),c.currencyId(),c.currencyName(),c.taxRate(),quantity,c.days(),c.taxMode(),c.priceBasis(),c.quantityBasis(),c.unitRate(),c.colorName());}
    private CostSummary costSuggestion(Query q,Context context) {
        if(!access.has("goods:cost:view"))return missingCost("COST_PERMISSION_REQUIRED","需要货品成本查看权限");
        UUID id=q.confirmedCostSnapshotId();
        if(id==null){
            var ids=db.queryForList("""
                    SELECT confirmed_snapshot_id FROM goods_cost_sheets
                    WHERE goods_id=:goods AND client_id IS NULL AND status='CONFIRMED'
                      AND calculation->'totals'->>'valueState'='COMPLETE'
                    ORDER BY (calculation->>'algorithmVersion'=:algorithm) DESC NULLS LAST,updated_at DESC,id DESC LIMIT 1
                    """,Map.of("goods",q.goodsId(),"algorithm",GoodsCostCalculator.ALGORITHM),UUID.class);
            if(ids.isEmpty())return missingCost("CONFIRMED_COST_REQUIRED","请先确认完整的货品成本测算单");id=ids.getFirst();
        }
        var snapshot=costs.readSnapshot(id);
        if(!q.goodsId().equals(snapshot.input().goodsId())||!"CONFIRMED".equals(snapshot.kind()))throw invalid("报价依据必须是本货品已确认成本版本");
        if(snapshot.input().clientId()!=null&&!Objects.equals(snapshot.input().clientId(),q.clientId()))throw invalid("该成本版本限定其他客户，不能用于本次建议");
        var totals=snapshot.calculation().totals();List<String> gaps=new ArrayList<>();
        boolean complete="COMPLETE".equals(totals.valueState())&&totals.unitCost()!=null;
        if(!complete)gaps.add("COST_COMPONENTS_INCOMPLETE");
        if(!GoodsCostCalculator.ALGORITHM.equals(snapshot.calculation().algorithmVersion()))gaps.add("COST_VERSION_REVIEW_REQUIRED");
        if(q.quantity()!=null&&decimal(q.quantity(),"批量",true).compareTo(new BigDecimal(snapshot.input().batchQty()))!=0)gaps.add("COST_BATCH_MISMATCH");
        if(context.currencyId()!=null&&!Objects.equals(context.currencyId(),snapshot.calculation().currencyId()))gaps.add("COST_CURRENCY_MISMATCH");
        if(context.unitId()!=null&&!Objects.equals(context.unitId(),snapshot.calculation().unitId()))gaps.add("COST_UNIT_MISMATCH");
        if(context.unitRate()!=null&&decimal(context.unitRate(),"换算率",true).compareTo(BigDecimal.ONE)!=0)gaps.add("COST_UNIT_RATE_MISMATCH");
        BigDecimal margin=q.targetMarginRate()==null?null:decimal(q.targetMarginRate(),"目标毛利率",false);
        if(margin!=null&&margin.compareTo(BigDecimal.ONE)>=0)throw invalid("目标毛利率应大于等于0且小于1");
        String suggested=complete&&gaps.isEmpty()&&margin!=null?decimalText(new BigDecimal(totals.unitCost()).divide(BigDecimal.ONE.subtract(margin),MathContext.DECIMAL128)):null;
        if(margin==null)gaps.add("TARGET_MARGIN_REQUIRED");
        var included=totals.byCategory()==null?List.<String>of():totals.byCategory().entrySet().stream().filter(e->e.getValue()!=null).map(Map.Entry::getKey).sorted().toList();
        return new CostSummary("CONFIRMED_ESTIMATE",id,snapshot.contentDigest(),snapshot.sheetNo(),snapshot.input().batchQty(),totals.unitCost(),snapshot.calculation().currencyId(),complete,false,List.copyOf(gaps),included,decimalText(margin),suggested,
                "按已确认测算成本÷(1−目标毛利率)给出报价参考，仅适用于所列成本版本、批量、币种及费用范围；不是完整实际制造成本，不自动加减税或修改单据。"
                +(gaps.contains("COST_VERSION_REVIEW_REQUIRED")?"旧算法成本须复制、重算复核并确认新版本后才能建议报价。":""),snapshot.calculation().currencyName(),snapshot.calculation().unitName());
    }
    private static CostSummary missingCost(String code,String message){return new CostSummary("UNAVAILABLE",null,null,null,null,null,null,false,false,List.of(code),List.of(),null,null,message,null,null);}
    static BigDecimal decimal(String text,String label,boolean positive){
        if(text==null||text.isBlank()||text.length()>80)throw invalid(label+"不能为空或过长");
        try{BigDecimal value=new BigDecimal(text);if(value.signum()<0||positive&&value.signum()==0||value.abs().compareTo(new BigDecimal("99999999999999.999999999999999999"))>0||value.scale()>18||value.scale()< -18)throw invalid(label+"超出有效范围");return value;}
        catch(NumberFormatException ex){throw invalid(label+"不是有效数字");}
    }
    static ApiException invalid(String message){return new ApiException(ErrorCode.VALIDATION_FAILED,message);}
}
