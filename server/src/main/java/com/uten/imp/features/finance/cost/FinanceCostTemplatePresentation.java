package com.uten.imp.features.finance.cost;

import com.uten.imp.features.finance.report.*;
import com.uten.imp.features.finance.gl.FinanceTemplateContract;
import java.util.*;

/** Original financial columns only; source, units and pending reasons remain in row metadata. */
final class FinanceCostTemplatePresentation {
    private FinanceCostTemplatePresentation() { }
    static ReportTableResponse apply(String template,ReportTableResponse source) {
        List<ReportColumn> columns=switch(template) {
            case "copperFee"->List.of(new ReportColumn("rowNo","序号","int",65),ReportColumn.text("goodsName","产品名称",220),
                    ReportColumn.text("unit","单位",70),ReportColumn.number("qty","数量").withUnitKey("unit"),
                    ReportColumn.money("price","单价").withUnitKey("currencyCode"),ReportColumn.money("amount","金额").withUnitKey("currencyCode"));
            case "copperDetail"->List.of(ReportColumn.date("billDate","时间"),ReportColumn.text("goodsName","货品名称",220),
                    ReportColumn.number("weight","重量").withUnitLabel("KG"),ReportColumn.text("weightUnit","单位",65),
                    ReportColumn.number("qty","数量").withUnitKey("unit"),ReportColumn.text("unit","单位",65));
            case "plasticUsage"->List.of(new ReportColumn("rowNo","序号","int",65),ReportColumn.text("goodsName","材料名称",220),
                    ReportColumn.number("prevBalance","上月结存").withUnitKey("unit"),ReportColumn.number("drawQty","本月仓库领用").withUnitKey("unit"),
                    ReportColumn.number("returnQty","退料").withUnitKey("unit"),ReportColumn.number("rejectReturnQty","安装挑选不良").withUnitKey("unit"),
                    ReportColumn.number("rejectIssueQty","安装挑选不良").withUnitKey("unit"),ReportColumn.number("finishedWeight","产品入库数").withUnitKey("unit"),
                    ReportColumn.number("bookBalance","账面结存").withUnitKey("unit"),ReportColumn.number("checkQty","实 际 盘 点 数").withUnitKey("unit"),
                    ReportColumn.number("diff","差异").withUnitKey("unit"),ReportColumn.number("usageRatio","成品占材料比例%").withUnitLabel("%"),
                    ReportColumn.text("reason","原因",220));
            case "plasticIssue"->List.of(ReportColumn.text("billNo","单号",140),ReportColumn.date("billDate","开单日期"),
                    ReportColumn.text("orderNo","订单号",140),ReportColumn.text("goodsName","货品名称",220),ReportColumn.text("model","型号",120),
                    ReportColumn.text("color","颜色",100),ReportColumn.number("qty","实发数量").withUnitKey("unit"),ReportColumn.text("remark","备注",180));
            case "plasticReturn"->List.of(ReportColumn.text("billNo","单号",140),ReportColumn.date("billDate","开单日期"),
                    ReportColumn.text("series","系列",100),ReportColumn.text("goodsCode","编号",140),ReportColumn.text("goodsName","货品名称",220),
                    ReportColumn.number("qty","实退数量").withUnitKey("unit"));
            case "plasticFinished"->List.of(ReportColumn.text("billNo","单号",140),ReportColumn.date("billDate","开单日期"),
                    ReportColumn.text("series","系列",100),ReportColumn.text("goodsCode","编号",140),ReportColumn.text("goodsName","货品名称",220),
                    ReportColumn.text("color","颜色",100),ReportColumn.text("material","材质",140),ReportColumn.number("weight","重量").withUnitKey("materialUnit"),
                    ReportColumn.number("qty","数量").withUnitKey("productUnit"),ReportColumn.text("remark","备注",220));
            case "salesCostSummary"->List.of(ReportColumn.text("clientName","客户名称",180),ReportColumn.text("sellerName","业务员",100),
                    ReportColumn.text("region","区域",100),ReportColumn.text("director","总监",100),ReportColumn.money("saleAmount","销售出货金额"),
                    ReportColumn.money("saleCost","销售成本"),ReportColumn.number("costRatio","含工本占销售比率").withUnitLabel("%"),
                    ReportColumn.money("manageFee","管理费8%"),ReportColumn.money("saleFee","销售费用OEM 1%    外贸 6%    内销 25%"),
                    ReportColumn.money("taxFee","税费10%"),ReportColumn.money("freight","运费"),ReportColumn.money("netProfit","净利润"),
                    ReportColumn.number("profitRate","净利润率").withUnitLabel("%"),ReportColumn.number("exchangeRate","汇率"));
            default->throw new IllegalArgumentException("Unknown financial cost template");
        };
        List<ReportColumn> named=new ArrayList<>();
        for(int i=0;i<columns.size();i++) {
            var column=columns.get(i);
            named.add(new ReportColumn(column.key(),FinanceTemplateContract.header(template,i),column.type(),column.width(),
                    column.totalLabel(),column.totalGroupKey(),column.unitLabel(),column.unitKey(),column.totalGroupIdentityKey())
                    .withHeaderGroups(FinanceTemplateContract.headerGroups(template,i)));
        }
        columns=List.copyOf(named);
        List<Map<String,Object>> rows=new ArrayList<>();
        for(var original:source.rows()) {
            var row=new LinkedHashMap<>(original);row.put("rowNo",row.get("__headerOrdinal"));
            if(template.equals("copperDetail"))row.put("weightUnit","KG");
            if(template.equals("copperDetail")&&row.get("__sectionKey")==null){row.put("__pending",true);row.put("__basis","原表插套酸洗/铜柱酸洗分类尚未明确，未按名称猜归属");}
            if(template.equals("copperDetail")&&(row.get("weight")==null||row.get("qty")==null||Objects.toString(row.get("unit"),"").isBlank())) {
                row.put("__pending",true);row.put("__basis","原入库重量或计价数量单位尚未明确，未按货品当前单位反推");
            }
            if(template.equals("copperFee")&&(row.get("qty")==null||row.get("price")==null||row.get("amount")==null)) {
                row.put("__pending",true);row.put("__basis","加工计价数量、原成交单价、币种或原金额依据未完整核对，未套最近价重算");
            }
            if(template.equals("copperFee")) {
                row.put("__showCurrencyInOriginal",true);
                String unit=Objects.toString(row.get("unit"),"").strip(),currency=Objects.toString(row.get("currencyCode"),"").strip();
                if(unit.isEmpty()||currency.isEmpty())row.put("__pending",true);
                String basis=Objects.toString(row.get("__basis"),"原成交数量、单价及金额");
                row.put("__basis",basis+"；数量单位："+(unit.isEmpty()?"待核对":unit)+"；单价及金额币别："+(currency.isEmpty()?"待核对":currency));
            }
            if(template.equals("plasticUsage")) {
                row.putIfAbsent("rejectReturnQty",null);row.putIfAbsent("rejectIssueQty",null);row.putIfAbsent("reason",null);
                boolean unclassified=row.get("__unclassifiedOtherQty") instanceof java.math.BigDecimal value&&value.signum()!=0;
                boolean mixed=row.get("__scopeCount") instanceof Number count&&count.longValue()>1;
                row.put("__pending",!Boolean.TRUE.equals(row.get("__templateReviewed"))||unclassified||mixed);
                row.put("__basis",mixed?"存在多个内料仓或结算期间，请明确原表作用域后核对":unclassified?
                        "仍有未对应原表栏目中的其它耗用，账面结存和差异未冒充完整结果":Boolean.TRUE.equals(row.get("__pending"))?
                        "KG换算、退料/安装挑选不良方向及原因待核对，未按单位名称猜换算":"按已结算内料仓与已核对原表补充项；比例按已结算实际耗用");
            }
            if(template.equals("plasticIssue")&&row.get("orderNo")==null){row.put("__pending",true);row.put("__basis","来源记录未携带权威订单号，未将领料单号冒充订单号");}
            if(template.equals("plasticFinished")&&(row.get("weight")==null||row.get("qty")==null)) {row.put("__pending",true);row.put("__basis","已结算材料KG换算或产品基本数量单位尚未核对，未把材料数量冒充重量");}
            if(template.equals("salesCostSummary")) {
                row.put("__pending",row.get("netProfit")==null||!Boolean.TRUE.equals(row.get("__inputConfirmed")));
                row.put("__basis",Boolean.TRUE.equals(row.get("__pending"))?
                        "实际销售成本、客户月度渠道、税费适用行或运费尚未核对完整，未以0补齐净利润":
                        "按原表管理分摊：管理费按成本8%，销售费用按明确渠道，税费仅适用行10%；与会计利润表分别勾稽");
            }
            rows.add(row);
        }
        Set<String> keys=new LinkedHashSet<>();for(var column:columns)if(source.columnSearchKeys().contains(column.key()))keys.add(column.key());
        return new ReportTableResponse(columns,rows,source.facets(),source.page(),source.size(),source.total(),source.totalPages(),source.totals(),
                source.readScopeVersion(),source.statisticsGeneratedAt(),keys);
    }
}
