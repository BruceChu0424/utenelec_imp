package com.uten.imp.features.finance.report;

import com.uten.imp.common.report.ReportTotal;
import com.uten.imp.common.web.*;
import com.uten.imp.features.finance.gl.FinanceTemplateContract;
import java.math.BigDecimal;
import java.util.*;

/** Source columns stay in their original positions; unclassified amounts cannot become labelled goods/tooling facts. */
final class FinancePartySummaryTemplate {
    private FinancePartySummaryTemplate() { }
    private static final String[] AR={"partyCode","partyName","partyFull","sellerName","director","region","district","settlement","creditFloor","prevBalance","shippedAmount","receivedAmount","returnAmount","offsetAmount","balance","overFloor","materialAmount"};
    private static final String[] AP={"partyCode","partyName","partyFull","settlement","prevBalance","goodsAmount","goodsPaidAmount","returnAmount","goodsOffsetAmount","goodsBalance","mouldAmount","mouldPaidAmount","mouldOffsetAmount","mouldBalance","totalBalance"};
    private static final Set<String> AP_KNOWN=Set.of("partyCode","partyName","partyFull","settlement","prevBalance","totalBalance");
    /** The category-tree screen follows the supplied legacy screenshot, which omits settlement. */
    static ReportTableResponse receivableOverview(ReportTableResponse source) {
        var template=present(true,source);
        var columns=template.columns().stream().filter(column->!column.key().equals("settlement")).toList();
        var keys=columns.stream().map(ReportColumn::key).collect(java.util.stream.Collectors.toSet());
        var searchable=new LinkedHashSet<>(template.columnSearchKeys());searchable.retainAll(keys);
        return new ReportTableResponse(columns,template.rows(),template.facets(),template.page(),template.size(),
                template.total(),template.totalPages(),template.totals(),template.readScopeVersion(),
                template.statisticsGeneratedAt(),searchable).withDocumentMetadata(template.documentMetadata());
    }
    static void requireOptions(boolean ar,FinanceReportColumnOptions options) {
        Set<String> keys=ar?Set.of(AR):AP_KNOWN;
        if(options.sort()!=null&&!options.sort().isBlank()&&!keys.contains(options.sort()))throw invalid("该原表列尚无已分类事实，不能排序");
        for(var input:options.filters().entrySet())if(input.getValue()!=null&&!input.getValue().isBlank()) {
            String key=input.getKey().startsWith("search.")?input.getKey().substring(7):input.getKey();
            if(!keys.contains(key))throw invalid("该原表列尚无已分类事实，不能检索："+key);
        }
    }
    static ReportTableResponse present(boolean ar,ReportTableResponse source) {
        String contract=ar?"receivableSummary":"payableSummary";String[] keys=ar?AR:AP;int texts=ar?8:4;
        var columns=new ArrayList<ReportColumn>();var labels=new HashMap<String,String>();
        for(int i=0;i<keys.length;i++) {
            String key=keys[i],label=FinanceTemplateContract.header(contract,i);labels.put(key,label);
            ReportColumn column=new ReportColumn(key,label,i<texts?"text":"money",i==2?230:120)
                    .withHeaderGroups(FinanceTemplateContract.headerGroups(contract,i));
            if(i>=texts){column=column.withUnitLabel("元");}columns.add(column);
        }
        var rows=new ArrayList<Map<String,Object>>();
        for(var original:source.rows()) {
            var row=new LinkedHashMap<>(original);
            if(ar) {
                boolean known=List.of("prevBalance","shippedAmount","returnAmount","receivedAmount","offsetAmount","balance").stream().allMatch(key->row.get(key)!=null);
                BigDecimal expected=known?decimal(row,"prevBalance").add(decimal(row,"shippedAmount")).add(decimal(row,"returnAmount"))
                        .subtract(decimal(row,"receivedAmount")).subtract(decimal(row,"offsetAmount")):null;
                row.put("__reconciliationDelta",known?decimal(row,"balance").subtract(expected):null);
                row.put("__exchangeDiff",row.get("exchangeDiff"));row.put("__arReductionAmount",row.get("arReductionAmount"));
                row.put("__pending",!known||row.get("materialAmount")==null||row.get("unverifiedOriginalCount")!=null&&decimal(row,"unverifiedOriginalCount").signum()!=0);
                row.put("__basis","总账本币；回款为实际到账，货款冲销保留原费用冲销；汇兑/账面核销差额见表外核对；物料金额缺少明确来源时保持待核验");
            } else {
                row.put("__sourceGoodsAmount",row.get("goodsAmount"));row.put("__sourceSubcontractAmount",row.get("subcontractAmount"));
                row.put("__sourcePurchaseReturnAmount",row.get("purchaseReturnAmount"));row.put("__sourceSubcontractReturnAmount",row.get("subcontractReturnAmount"));
                row.put("__sourcePaidAmount",row.get("paidAmount"));row.put("__sourceSettledAmount",row.get("settledAmount"));row.put("__sourceOffsetAmount",row.get("offsetAmount"));
                for(int i=5;i<14;i++){row.put(keys[i],null);row.remove(keys[i]+"Exact");}
                row.put("__pending",true);
                row.put("__basis","总账本币；上月余额和应付合计保留完整往来事实；货款/模具款及其付款、退货、冲销尚未明确分类，不将全部采购默认货款或模具款0");
            }
            com.uten.imp.common.report.ReportQueryKit.includeDecimalTexts(row);rows.add(row);
        }
        var totals=new ArrayList<ReportTotal>();
        for(var total:source.totals()) {
            String key=!ar&&total.key().equals("balance")?"totalBalance":total.key();
            if(labels.containsKey(key)&&(ar||key.equals("prevBalance")||key.equals("totalBalance")))
                totals.add(new ReportTotal(key,labels.get(key)+"合计",total.type(),total.groupKey(),total.groups(),"元"));
        }
        var searchable=new LinkedHashSet<>(source.columnSearchKeys());searchable.retainAll(ar?Set.of(AR):AP_KNOWN);
        return new ReportTableResponse(columns,rows,Map.of(),source.page(),source.size(),source.total(),source.totalPages(),totals,
                source.readScopeVersion(),source.statisticsGeneratedAt(),searchable).withDocumentMetadata(source.documentMetadata());
    }
    private static BigDecimal decimal(Map<String,Object> row,String key){var value=row.get(key);return value==null?null:new BigDecimal(value.toString());}
    private static ApiException invalid(String message){return new ApiException(ErrorCode.VALIDATION_FAILED,message);}
}
