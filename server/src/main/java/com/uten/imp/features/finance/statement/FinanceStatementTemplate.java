package com.uten.imp.features.finance.statement;

import com.uten.imp.features.finance.gl.FinanceTemplateContract;
import com.uten.imp.features.finance.report.*;
import com.uten.imp.common.web.*;
import java.util.*;
import java.math.BigDecimal;

/** Original named columns are a presentation of the same authoritative facts, not another ledger. */
final class FinanceStatementTemplate {
    private FinanceStatementTemplate() { }
    static void requireContext(UUID partyId,UUID currencyId) {
        if(partyId==null||currencyId==null)throw new ApiException(ErrorCode.VALIDATION_FAILED,"请先选择单一往来单位和币别，再生成原表对账单");
    }
    static FinanceReportColumnOptions currency(FinanceReportColumnOptions options,UUID currencyId) {
        var filters=new LinkedHashMap<>(options.filters());
        String selected=filters.get("currencyCode");
        if(selected!=null&&!selected.equals(currencyId.toString()))throw new ApiException(ErrorCode.VALIDATION_FAILED,"币别筛选与对账单币别不一致");
        filters.put("currencyCode",currencyId.toString());
        return new FinanceReportColumnOptions(filters,options.sort(),options.order());
    }
    static List<ReportColumn> columns(String kind) {
        String contract=switch(kind){case "subcontract"->"subcontractStatement";case "supplier"->"supplierStatement";
            case "other-receivable"->"otherReceivableStatement";case "client"->"clientStatement";default->throw new IllegalArgumentException("statement kind");};
        String[] keys=switch(kind) {
            case "subcontract"->new String[]{"rowNo","goodsCode","goodsName","color","prevStock","issueBillNo","issueDate","issueQty","issueTotalQty","lossAllowed","receiptBillNo","receiptDate","receiptQty","receiptTotalQty","balance","processPrice","processAmount","materialPrice","materialAmount"};
            case "supplier"->new String[]{"billDate","goodsCode","goodsName","unit","qty","price","amount","remark"};
            case "client"->new String[]{"billDate","goodsName","color","unit","qty","price","amount","remark"};
            default->new String[]{"billDate","goodsName","spec","inWeight","outWeight","loss","balance","outQty","price","processAmount"};
        };
        Set<String> money=Set.of("price","amount","processPrice","processAmount","materialPrice","materialAmount");
        Set<String> quantities=Set.of("qty","prevStock","issueQty","issueTotalQty","lossAllowed","receiptQty","receiptTotalQty","balance","inWeight","outWeight","loss","outQty");
        Set<String> dates=Set.of("billDate","issueDate","receiptDate");
        var result=new ArrayList<ReportColumn>();
        for(int i=0;i<keys.length;i++) {
            String key=keys[i],label=FinanceTemplateContract.header(contract,i);
            String type=dates.contains(key)?"date":money.contains(key)?"money":quantities.contains(key)?"number":key.equals("rowNo")?"int":"text";
            result.add(new ReportColumn(key,label,type,Set.of("goodsName","remark").contains(key)?230:120)
                    .withHeaderGroups(FinanceTemplateContract.headerGroups(contract,i)));
        }
        return List.copyOf(result);
    }
    static ReportTableResponse present(String kind,ReportTableResponse source) {
        var columns=columns(kind);Set<String> keys=new LinkedHashSet<>();columns.forEach(c->keys.add(c.key()));
        var searchable=new LinkedHashSet<>(source.columnSearchKeys());searchable.retainAll(keys);
        return new ReportTableResponse(columns,source.rows(),Map.of(),source.page(),source.size(),source.total(),source.totalPages(),
                source.totals(),source.readScopeVersion(),source.statisticsGeneratedAt(),searchable).withDocumentMetadata(source.documentMetadata());
    }
    static BigDecimal periodAmount(String template,List<com.uten.imp.common.report.ReportTotal> totals,long rows){
        if(rows==0)return BigDecimal.ZERO;
        if(template.equals("subcontractStatement")){BigDecimal gross=total(totals,"processAmount"),material=total(totals,"materialAmount");return gross==null||material==null?null:gross.subtract(material);}
        if(template.equals("otherReceivableStatement"))return total(totals,"processAmount");
        return total(totals,"amount");
    }
    /** Whole-result aggregates already calculated by the authority; never sum a printed page or mix units. */
    static Map<String,Object> paperTotals(List<com.uten.imp.common.report.ReportTotal> totals){
        var result=new LinkedHashMap<String,Object>();
        for(var total:totals){var groups=new ArrayList<Map<String,Object>>();for(var group:total.groups()){
            var value=new LinkedHashMap<String,Object>();value.put("unit",group.unit());value.put("identity",group.identity());
            value.put("value",group.value()==null?null:group.value().toPlainString());groups.add(value);
        }result.put(total.key(),groups);}
        return result;
    }
    private static BigDecimal total(List<com.uten.imp.common.report.ReportTotal> totals,String key){for(var total:totals){if(total.key().equals(key)&&total.groups().size()==1)return total.groups().getFirst().value();}return null;}
}
