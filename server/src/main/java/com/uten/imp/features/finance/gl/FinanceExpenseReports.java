package com.uten.imp.features.finance.gl;

import com.uten.imp.common.finance.MoneyPolicy;
import com.uten.imp.common.finance.CostFraction;
import com.uten.imp.common.report.*;
import com.uten.imp.features.finance.report.*;
import java.math.*;
import java.util.*;

/** Source-template calculations shared by on-screen reads, print and both export paths. */
final class FinanceExpenseReports {
    private FinanceExpenseReports() { }
    static List<ReportColumn> pivotColumns(String template,int year) {
        List<ReportColumn> columns=new ArrayList<>();columns.add(ReportColumn.text("item",FinanceTemplateContract.header(template,0),260));
        for(int m=1;m<=12;m++)columns.add(ReportColumn.money("m"+m,FinanceTemplateContract.header(template,m)));
        columns.add(ReportColumn.money("yearTotal",year+"年全年合计"));return List.copyOf(columns);
    }
    static ReportTableResponse pivot(String template,int year,List<GlReportLine> definitions,List<GlReportLine> legacy,
            Map<String,BigDecimal[]> source,GlReportLineSource.Bindings bindings,Set<Integer> confirmedPolicy,
            FinanceReportColumnOptions options) {
        return pivot(template,year,12,definitions,legacy,source,bindings,confirmedPolicy,options);
    }
    static ReportTableResponse pivot(String template,int year,int throughMonth,List<GlReportLine> definitions,List<GlReportLine> legacy,
            Map<String,BigDecimal[]> source,GlReportLineSource.Bindings bindings,Set<Integer> confirmedPolicy,
            FinanceReportColumnOptions options) {
        List<Map<String,Object>> rows=new ArrayList<>();
        for(var line:definitions) {
            boolean known=!line.configurable()||bindings.bound(line.key());
            BigDecimal[] values=known&&!bindings.conflicting(line.key())?values(source.get(line.key())):unknown();
            String basis=bindings.conflicting(line.key())?"无业务确认与绑定冲突，请核对":line.configurable()?
                    bindings.confirmedZero().contains(line.key())?"财务已确认无业务":known?"按已确认科目/部门及实际过账事实归集":"待配置取数或确认无业务":"权威业务事实";
            if(line.source()!=GlReportLine.Source.FINISHED_IN&&source.containsKey("__LEDGER_READ_SCOPE")&&java.util.stream.IntStream.rangeClosed(1,throughMonth).anyMatch(m->source.get("__LEDGER_READ_SCOPE")[m]==null))basis+="；部分月份早于原账套接续起点，历史发生额尚未提供";
            var row=row(line.key(),line.label(),values,basis,throughMonth);
            if(line.key().equals("ADM_SALES"))row.put("__isBase",true);
            rows.add(row);
        }
        BigDecimal[] total=zero();List<String> issue=new ArrayList<>();
        for(int month=1;month<=throughMonth;month++) {
            for(var row:rows)if(!Boolean.TRUE.equals(row.get("__isBase"))&&!"MFG_OUTPUT".equals(row.get("__lineKey")))
                total[month]=add(total[month],decimal(row.get("m"+month)));
            final int selectedMonth=month;
            boolean nonzero=rows.stream().filter(r->!"MFG_OUTPUT".equals(r.get("__lineKey")))
                    .map(r->decimal(r.get("m"+selectedMonth))).anyMatch(v->v!=null&&v.signum()!=0);
            if(template.equals("manufacturingExpense")&&nonzero&&!confirmedPolicy.contains(month)){total[month]=null;issue.add("制造费用性质/部门及人工归集口径待核对，产值不入费用合计");}
            if(template.equals("manufacturingExpense")&&source.containsKey("__MFG_COVERAGE")&&source.get("__MFG_COVERAGE")[month]==null){total[month]=null;issue.add("存在未归入原表项目的4101实际发生，请核对来源覆盖");}
            for(var old:legacy) {
                BigDecimal[] data=source.get(old.key());
                if(data!=null&&data[month]!=null&&data[month].signum()!=0){total[month]=null;issue.add("存在未迁移到原表项目的旧绑定："+old.label());}
            }
        }
        String totalKey=template.equals("manufacturingExpense")?"MFG_TOTAL":"ADM_TOTAL";
        rows.add(row(totalKey,FinanceExpenseTemplateCatalog.text(template,"totalLabel"),total,
                issue.isEmpty()?"仅合计费用项目，基数/产值不参与":String.join("；",new LinkedHashSet<>(issue)),throughMonth));
        if(template.equals("adminExpense")) {
            var base=rows.stream().filter(r->Boolean.TRUE.equals(r.get("__isBase"))).findFirst().orElseThrow();
            BigDecimal[] ratio=unknown();for(int m=1;m<=12;m++)ratio[m]=percent(total[m],decimal(base.get("m"+m)));
            var row=row("ADM_RATIO",FinanceExpenseTemplateCatalog.text(template,"ratioLabel"),ratio,"费用合计÷同期间营业收入；收入为0时不适用",throughMonth);
            row.put("yearTotal",percent(sum(total,throughMonth),decimal(base.get("yearTotal"))));row.put("__ratioRow",true);
            row.put("__percentageKeys",java.util.stream.Stream.concat(java.util.stream.IntStream.rangeClosed(1,12).mapToObj(m->"m"+m),java.util.stream.Stream.of("yearTotal")).toList());
            row.put("__pending",Boolean.TRUE.equals(base.get("__pending"))||sum(total,throughMonth)==null);rows.add(row);
        }
        for(var row:rows) {
            if(!totalKey.equals(row.get("__lineKey"))&&!"ADM_RATIO".equals(row.get("__lineKey")))row.put("__context",List.of(totalKey));
        }
        return filtered(pivotColumns(template,year),rows,options);
    }
    static List<ReportColumn> operatingColumns(int throughMonth) {
        var result=new ArrayList<ReportColumn>();
        result.add(ReportColumn.text("category",FinanceTemplateContract.header("operatingProfit",0),130));
        result.add(ReportColumn.text("sub",FinanceTemplateContract.header("operatingProfit",1),170));
        result.add(ReportColumn.text("item",FinanceTemplateContract.header("operatingProfit",2),230));
        for(int month=1;month<=12;month++) {
            result.add(ReportColumn.money("m"+month,FinanceTemplateContract.header("operatingProfit",month*2+1)));
            result.add(ReportColumn.number("r"+month,FinanceTemplateContract.header("operatingProfit",month*2+2)).withUnitLabel("%"));
        }
        result.add(ReportColumn.number("averageRatio","1-"+throughMonth+"月平均值占销售比").withUnitLabel("%"));
        result.add(ReportColumn.text("remark",FinanceTemplateContract.header("operatingProfit",28),240));
        result.add(ReportColumn.text("varianceReason",FinanceTemplateContract.header("operatingProfit",29),260));return List.copyOf(result);
    }
    static ReportTableResponse operating(int throughMonth,Map<String,BigDecimal[]> source,GlReportLineSource.Bindings bindings,
            Map<Integer,FinancialStatementRevenue.Value> revenue,Set<Integer> policy,Map<String,Map<String,Object>> notes,
            FinanceReportColumnOptions options,int page,int size,Integer maximum) {
        var definitions=FinanceExpenseTemplateCatalog.operatingRows();Map<String,BigDecimal[]> amounts=new LinkedHashMap<>();
        Map<String,String> reasons=new LinkedHashMap<>();
        BigDecimal[] base=unknown();for(int month=1;month<=throughMonth;month++){
            var value=revenue.get(month);base[month]=value!=null&&value.complete()?value.amount():null;
        }amounts.put("OP_REVENUE",base);
        for(var definition:definitions) {
            if(definition.sourceRow()==3)continue;
            BigDecimal[] data=unknown();
            if(definition.total()) {
                for(int month=1;month<=throughMonth;month++) {
                    BigDecimal total=BigDecimal.ZERO;
                    for(String term:definition.terms()) {
                        boolean negative=term.startsWith("-");String key=negative?term.substring(1):term;
                        BigDecimal value=amounts.get(key)[month];total=add(total,value==null?null:negative?value.negate():value);
                    }
                    final int selectedMonth=month;
                    boolean nonzero=amounts.entrySet().stream().filter(e->!e.getKey().equals("OP_REVENUE"))
                            .map(e->e.getValue()[selectedMonth]).anyMatch(v->v!=null&&v.signum()!=0);
                    if((definition.key().equals("OP_COST_TOTAL")||definition.key().equals("OP_PROFIT"))&&nonzero&&!policy.contains(month))total=null;
                    data[month]=total;
                }
                reasons.put(definition.key(),"按原表项目合计；仅确认期间消耗/费用口径且排除资本化重复后形成完整成本和利润");
            } else {
                boolean known=bindings.bound(definition.key())&&!bindings.conflicting(definition.key());
                BigDecimal[] input=source.get(definition.key());for(int month=1;month<=throughMonth;month++)data[month]=known?input==null?BigDecimal.ZERO:input[month]:null;
                reasons.put(definition.key(),known?"按已确认科目/部门及实际费用事实归集":"待配置取数或确认无业务");
            }
            amounts.put(definition.key(),data);
        }
        List<Map<String,Object>> rows=new ArrayList<>();
        for(var definition:definitions) {
            var row=new LinkedHashMap<String,Object>();row.put("category",definition.category());row.put("sub",definition.sub());row.put("item",definition.item());
            row.put("__lineKey",definition.key());row.put("__sourceRow",definition.sourceRow());
            CostFraction average=CostFraction.of(BigDecimal.ZERO);boolean averageKnown=true,pending=false;
            for(int month=1;month<=12;month++) {
                BigDecimal amount=amounts.get(definition.key())[month],ratio=month<=throughMonth?percent(amount,base[month]):null;
                row.put("m"+month,amount);row.put("r"+month,ratio);
                if(month<=throughMonth){pending|=amount==null;if(ratio==null)averageKnown=false;else average=average.add(CostFraction.of(amount).multiply(BigDecimal.valueOf(100)).divide(base[month]));}
            }
            row.put("averageRatio",averageKnown?average.divide(BigDecimal.valueOf(throughMonth)).project("finance.operating.averageRatio","经营损益各月占销售比的算术平均",30):null);
            var note=notes.getOrDefault(definition.key(),Map.of());row.put("remark",note.getOrDefault("remark",""));row.put("varianceReason",note.getOrDefault("varianceReason",""));
            row.put("__noteVersion",note.getOrDefault("version",-1L));row.put("__pending",pending);
            row.put("__notApplicableMonths",java.util.stream.IntStream.rangeClosed(throughMonth+1,12).boxed().toList());
            row.put("__basis",definition.sourceRow()==3?revenue.values().stream().filter(v->!v.complete()).map(FinancialStatementRevenue.Value::basis).findFirst().orElse("与利润表营业收入同源"):
                    reasons.getOrDefault(definition.key(),"权威事实"));
            if(source.containsKey("__LEDGER_READ_SCOPE")&&java.util.stream.IntStream.rangeClosed(1,throughMonth).anyMatch(m->source.get("__LEDGER_READ_SCOPE")[m]==null))row.put("__basis",row.get("__basis")+"；部分月份接续前历史尚未提供");
            List<String> context=new ArrayList<>();for(var candidate:definitions)if(candidate.terms().stream().map(t->t.startsWith("-")?t.substring(1):t).anyMatch(definition.key()::equals))context.add(candidate.key());
            row.put("__context",context);rows.add(row);
        }
        var filtered=filtered(operatingColumns(throughMonth),rows,options);
        if(maximum!=null) {
            var sink=new com.uten.imp.common.export.ExportRowBatches(filtered.columns().stream().map(c->new com.uten.imp.common.export.ExportColumn(c.key(),c.label(),c.type(),null,c.unitLabel(),c.unitKey())).toList(),maximum);
            filtered.rows().forEach(sink);int total=sink.finish();return new ReportTableResponse(filtered.columns(),List.of(),Map.of(),1,500,total,ReportReadPlan.totalPages(total,500)).withColumnSearchKeys(filtered.columnSearchKeys());
        }
        var window=new ReportRowWindow(page,size);filtered.rows().forEach(window);
        long total=ReportReadPlan.current().includeCount()?window.count():ReportReadPlan.UNKNOWN_TOTAL;
        return new ReportTableResponse(filtered.columns(),window.rows(),filtered.facets(),window.page(),window.size(),total,
                ReportReadPlan.totalPages(total,window.size())).withColumnSearchKeys(filtered.columnSearchKeys());
    }
    static ReportTableResponse filtered(List<ReportColumn> columns,List<Map<String,Object>> rows,FinanceReportColumnOptions options) {
        var original=new ReportTableResponse(columns,rows,Map.of(),1,Math.max(1,rows.size()),rows.size(),rows.isEmpty()?0:1);
        var selected=GlComputedHeaders.apply("gl/analysis-template",original,options);
        Set<String> keys=new LinkedHashSet<>();selected.rows().forEach(row->keys.add(row.get("__lineKey").toString()));
        boolean changed;do{changed=false;for(var row:rows)if(keys.contains(row.get("__lineKey")))
            for(Object key:(List<?>)row.getOrDefault("__context",List.of()))changed|=keys.add(key.toString());}while(changed);
        List<Map<String,Object>> included=rows.stream().filter(row->keys.contains(row.get("__lineKey"))).toList();
        if(included.size()!=rows.size())included.forEach(row->row.put("__filteredTemplate",true));
        return new ReportTableResponse(columns,included,selected.facets(),1,Math.max(1,included.size()),included.size(),included.isEmpty()?0:1,
                List.of(),selected.readScopeVersion(),selected.statisticsGeneratedAt(),selected.columnSearchKeys());
    }
    static Map<String,Object> row(String key,String label,BigDecimal[] amounts,String basis) {
        return row(key,label,amounts,basis,12);
    }
    static Map<String,Object> row(String key,String label,BigDecimal[] amounts,String basis,int throughMonth) {
        Map<String,Object> row=new LinkedHashMap<>();row.put("item",label);row.put("__lineKey",key);row.put("__basis",basis);
        boolean pending=false;for(int month=1;month<=12;month++){row.put("m"+month,month<=throughMonth?amounts[month]:null);if(month<=throughMonth)pending|=amounts[month]==null;}
        row.put("yearTotal",sum(amounts,throughMonth));row.put("__notApplicableMonths",java.util.stream.IntStream.rangeClosed(throughMonth+1,12).boxed().toList());row.put("__pending",pending);return row;
    }
    static BigDecimal[] zero(){BigDecimal[] values=new BigDecimal[13];Arrays.fill(values,1,13,BigDecimal.ZERO);return values;}
    static BigDecimal[] unknown(){return new BigDecimal[13];}
    static BigDecimal[] values(BigDecimal[] input){return input==null?zero():input.clone();}
    static BigDecimal add(BigDecimal left,BigDecimal right){return left==null||right==null?null:left.add(right);}
    static BigDecimal decimal(Object value){return value instanceof BigDecimal d?d:null;}
    static BigDecimal sum(BigDecimal[] values,int through){BigDecimal sum=BigDecimal.ZERO;for(int month=1;month<=through;month++){sum=add(sum,values[month]);}return sum;}
    static BigDecimal percent(BigDecimal amount,BigDecimal base){return amount==null||base==null||base.signum()==0?null:MoneyPolicy.percentOf(amount,base);}
}
