package com.uten.imp.features.finance.report;

import com.fasterxml.jackson.databind.JsonNode;
import com.uten.imp.common.export.*;
import com.uten.imp.common.time.BusinessTime;
import com.uten.imp.features.finance.gl.FinanceTemplateContract;
import java.time.*;
import java.time.format.DateTimeFormatter;
import java.util.*;

/** Original paper headings and header groups; this class never computes a business amount. */
final class FinanceTemplateLayouts {
    private FinanceTemplateLayouts() { }
    static String key(String report,Map<String,String> query) {
        return switch(report) {
            case "gl/trial-balance"->"trialBalance";
            case "gl/chart-template"->"chartCodes";
            case "gl/balance-sheet"->"balanceSheet";case "gl/profit-monthly"->"monthlyProfit";case "gl/profit-annual"->"annualProfit";
            case "gl/manufacturing-expense"->"manufacturingExpense";case "gl/admin-expense"->"adminExpense";case "gl/sales-expense"->"salesExpense";case "gl/operating-pl"->"operatingProfit";
            case "statements/subcontract"->"subcontractStatement";case "statements/supplier"->"supplierStatement";case "statements/other-receivable"->"otherReceivableStatement";case "statements/client"->"clientStatement";
            case "ar-ap/summary"->"AP".equalsIgnoreCase(query.get("direction"))?"payableSummary":"receivableSummary";
            case "cost/copper-fee"->"copperFee";case "cost/copper-pickling"->"copperDetail";case "cost/plastic"->"plasticUsage";
            case "cost/plastic-detail"->switch(Objects.toString(query.get("kind"),"")){case "issue"->"plasticIssue";case "return"->"plasticReturn";case "finished"->"plasticFinished";default->null;};
            case "cost/sales-summary"->"salesCostSummary";
            case "fa/depreciation-schedule"->"depreciation";case "fa/amortization-schedule"->"amortization";case "fa/completed-depreciation-schedule"->"depreciationCompleted";
            case "auxiliary/receivable"->"receivableAuxiliaryDetail";case "auxiliary/payable"->"payableAuxiliaryDetail";
            default->null;
        };
    }
    static ExportTableLayout create(String report,Map<String,String> query,List<ExportColumn> columns,List<Map<String,Object>> rows,String company) {
        return create(report,query,columns,rows,Map.of(),company);
    }
    static ExportTableLayout create(String report,Map<String,String> query,List<ExportColumn> columns,List<Map<String,Object>> rows,Map<String,Object> documentMetadata,String company) {
        if(query==null){query=Map.of();}String key=key(report,query);if(key==null||columns.isEmpty())return null;
        if(Set.of("balanceSheet","monthlyProfit","annualProfit","payableSummary","receivableSummary").contains(key)&&!"template".equals(query.get("layout")))return null;
        var contract=FinanceTemplateContract.template(key);
        if(contract.path("headers").size()!=columns.size()) {
            if("template".equals(query.get("layout")))throw new com.uten.imp.common.web.ApiException(com.uten.imp.common.web.ErrorCode.CONFLICT,"报表列数与财务原表不一致，请先完成原表对应");
            return null;
        }
        LocalDate date=date(query.get("dateTo"),BusinessTime.today()),from=date(query.get("dateFrom"),date.withDayOfMonth(1));
        int year=integer(query.get("year"),date.getYear()),month=integer(query.get("month"),query.get("dateTo")==null&&year<BusinessTime.today().getYear()?12:date.getMonthValue());
        if(Set.of("annualProfit","manufacturingExpense","adminExpense","salesExpense","operatingProfit").contains(key)){from=LocalDate.of(year,1,1);date=YearMonth.of(year,month).atEndOfMonth();}
        String title=contract.path("reportTitle").asText(contract.path("entryName").asText()).replace("{year}",Integer.toString(year)).replace("{month}",Integer.toString(month));
        Map<?,?> metadata=documentMetadata==null||documentMetadata.isEmpty()?rows.stream().map(row->row.get("__documentMetadata")).filter(Map.class::isInstance).map(Map.class::cast).findFirst().orElse(Map.of()):documentMetadata;
        if(metadata.get("title") instanceof String caption&&!caption.isBlank())title=caption;
        if(Set.of("subcontractStatement","supplierStatement","otherReceivableStatement","clientStatement").contains(key)){
            var effective=new LinkedHashMap<String,Object>();metadata.forEach((name,value)->effective.put(name.toString(),value));effective.putIfAbsent("organizationName",Objects.toString(company,""));effective.putIfAbsent("title",title);effective.putIfAbsent("dateFrom",from.toString());effective.putIfAbsent("dateTo",date.toString());return statement(key,columns,effective);
        }
        String organization=metadata.get("organizationName") instanceof String owner&&!owner.isBlank()?owner:Objects.toString(company,"");
        List<?> headerLines=metadata.get("headerLines") instanceof List<?> lines?lines:List.of();
        var headings=new ArrayList<ExportTableLayout.Heading>();var merges=new ArrayList<ExportTableLayout.Merge>();
        var bands=new ArrayList<ExportTableLayout.Band>();var spans=new ArrayList<ExportTableLayout.TextSpan>();var notes=new ArrayList<String>();
        var print=contract.path("print");String font=print.path("fontName").asText("宋体");short fontSize=(short)print.path("fontSize").asInt(11);
        float height=(float)print.path("rowHeight").asDouble(22);var widths=new ArrayList<Double>();
        for(int i=0;i<columns.size();i++)widths.add(print.path("widths").has(i)?print.path("widths").path(i).asDouble():i==0?30d:16d);
        boolean balance=key.equals("balanceSheet"),monthly=key.equals("monthlyProfit"),annual=key.equals("annualProfit");
        int depth=0;for(var part:contract.path("headerParts"))depth=Math.max(depth,part.size()-1);
        int firstHeader=(balance||monthly||annual?3:2)+headerLines.size(),headerRow=firstHeader+Math.max(depth,0),last=columns.size()-1;
        headings.add(new ExportTableLayout.Heading(0,0,title,20,true,"CENTER"));merge(merges,0,0,0,last);
        // These source forms combine quantities, weights, ratios and, for the
        // copper fee form, source-currency amounts. Their columns carry the
        // actual units; a blanket yuan heading would mislabel those facts.
        boolean columnUnitsOnly=Set.of("copperFee","copperDetail","plasticUsage","plasticIssue","plasticReturn","plasticFinished").contains(key);
        String unit="元";
        if(balance||monthly||annual) {
            int metaRow=2,unitColumn=balance?6:last;
            headings.add(new ExportTableLayout.Heading(metaRow,0,"单位名称："+organization,fontSize,false,"LEFT"));
            merge(merges,metaRow,metaRow,0,balance?3:monthly?1:5);
            String period=balance?date.format(DateTimeFormatter.ofPattern("yyyy年MM月dd日")):monthly?"%d年%02d月".formatted(year,month):"%d年1至%d月".formatted(year,month);
            int periodColumn=balance?4:monthly?2:6;
            headings.add(new ExportTableLayout.Heading(metaRow,periodColumn,period,fontSize,false,"CENTER"));
            merge(merges,metaRow,metaRow,periodColumn,balance?5:monthly?2:last-1);
            headings.add(new ExportTableLayout.Heading(metaRow,unitColumn,"单位："+unit,fontSize,false,"RIGHT"));
            if(balance)merge(merges,metaRow,metaRow,6,7);
            if(balance||monthly){headings.add(new ExportTableLayout.Heading(1,unitColumn,balance?"会小企01表":"会小企02表",fontSize,false,"RIGHT"));if(balance)merge(merges,1,1,6,7);}
        }else {
            int companyEnd=Math.max(0,last/2-1),dateStart=companyEnd+1,dateEnd=Math.max(dateStart,last-1);
            headings.add(new ExportTableLayout.Heading(1,0,"单位名称："+organization,fontSize,false,"LEFT"));merge(merges,1,1,0,companyEnd);
            String sourcePeriod=metadata.get("dateFrom")!=null&&metadata.get("dateTo")!=null?metadata.get("dateFrom")+" 至 "+metadata.get("dateTo"):from+" 至 "+date;
            if(dateStart<last){headings.add(new ExportTableLayout.Heading(1,dateStart,sourcePeriod,fontSize,false,"CENTER"));merge(merges,1,1,dateStart,dateEnd);}
            if(!columnUnitsOnly)headings.add(new ExportTableLayout.Heading(1,last,"单位："+unit,fontSize,false,"RIGHT"));
        }
        int lineRow=balance||monthly||annual?3:2;
        for(Object entry:headerLines){
            if(entry instanceof Map<?,?> line){headings.add(new ExportTableLayout.Heading(lineRow,0,captionLine(line),fontSize,false,"LEFT"));merge(merges,lineRow,lineRow,0,last);}
            lineRow++;
        }
        Set<String> groups=new HashSet<>();
        for(int col=0;col<columns.size();col++) {
            var parts=contract.path("headerParts").path(col);int levels=Math.max(0,parts.size()-1);
            for(int level=0;level<levels;level++) {
                String anchor=parts.path(level).path("cell").asText();String group=level+":"+anchor;
                if(!groups.add(group))continue;
                int end=col;
                while(end+1<columns.size()) {var next=contract.path("headerParts").path(end+1);if(next.size()<=level+1||!next.path(level).path("cell").asText().equals(anchor))break;end++;}
                headings.add(new ExportTableLayout.Heading(firstHeader+level,col,parts.path(level).path("label").asText(),fontSize,true,"CENTER"));
                merge(merges,firstHeader+level,firstHeader+level,col,end);
            }
            if(levels<depth){headings.add(new ExportTableLayout.Heading(firstHeader+levels,col,columns.get(col).label(),fontSize,true,"CENTER"));merge(merges,firstHeader+levels,headerRow,col,col);}
        }
        if(balance) {
            for(int row=0;row<rows.size();row++)if(rows.get(row).get("__cellStyles") instanceof Map<?,?> styles)
                for(int column=0;column<columns.size();column++)if(styles.get(columns.get(column).key()) instanceof Map<?,?> style) {
                    Object raw=style.get("fillRgb");
                    if(raw instanceof String color&&color.matches("[0-9A-F]{6}")&&!color.equals("FFFFFF"))
                        bands.add(new ExportTableLayout.Band(row,column,column,color,false));
                }
            notes.add("小企业（中外合作经营）根据合同规定在合作期间归还投资者的投资，应在“实收资本（或股本）”项目下增加“已归还投资”项目单独列示。");
        }
        if(monthly)for(int row=0;row<rows.size();row++) {
            String text=Objects.toString(rows.get(row).get("item"),"");int start=text.indexOf('（');
            if(text.contains("退税收入+收客户税点")&&start>=0)spans.add(new ExportTableLayout.TextSpan(row,0,start,text.length(),"FF0000"));
        }
        if(key.equals("trialBalance"))for(int row=0;row<rows.size();row++)if(Set.of("SUBTOTAL","TOTAL","CURRENCY").contains(Objects.toString(rows.get(row).get("__rowKind"),"")))
            bands.add(new ExportTableLayout.Band(row,0,last,"D9D9D9",true));
        if(metadata.get("footerLines") instanceof List<?> footer)for(Object line:footer)if(line instanceof Map<?,?> value) {
            notes.add(captionLine(value));
        }
        var supplemental=new ArrayList<ExportTableLayout.SupplementalCell>();
        if(metadata.get("supplementalCells") instanceof List<?> sourceCells&&!sourceCells.isEmpty()) {
            int canvas=metadata.get("canvasColumns") instanceof Number number?number.intValue():columns.size();
            int sourceHeader=metadata.get("sourceMainHeaderRow") instanceof Number number?number.intValue():-1;
            if(canvas<columns.size()||canvas>160||sourceHeader<1||sourceHeader>13)
                throw new IllegalArgumentException("Invalid source report canvas");
            List<?> sourceWidths=metadata.get("supplementalWidths") instanceof List<?> values?values:List.of();
            for(int col=columns.size();col<canvas;col++) {
                Object requested=sourceWidths.size()==canvas?sourceWidths.get(col):sourceWidths.size()==canvas-columns.size()?sourceWidths.get(col-columns.size()):null;
                widths.add(requested instanceof Number number?number.doubleValue():col==columns.size()?3d:16d);
            }
            for(Object item:sourceCells) {
                if(!(item instanceof Map<?,?> cell))throw new IllegalArgumentException("Invalid supplemental source cell");
                var matcher=java.util.regex.Pattern.compile("^([A-Z]{1,2})([1-9][0-9]{0,3})$").matcher(Objects.toString(cell.get("sourceCell"),""));
                if(!matcher.matches())throw new IllegalArgumentException("Invalid supplemental source address");
                int col=0;for(char letter:matcher.group(1).toCharArray())col=col*26+letter-'A'+1;
                col--;if(col<columns.size()||col>=canvas)throw new IllegalArgumentException("Supplemental source overlaps main table");
                supplemental.add(new ExportTableLayout.SupplementalCell(Integer.parseInt(matcher.group(2))-sourceHeader,col,
                    Objects.toString(cell.get("type"),"text"),cell.get("value"),Boolean.TRUE.equals(cell.get("header"))));
            }
        }
        var hidden=new ArrayList<Integer>();
        if(metadata.get("hiddenColumns") instanceof List<?> hiddenColumns)for(Object column:hiddenColumns){
            if(!(column instanceof Number number)||number.doubleValue()!=number.intValue())throw new IllegalArgumentException("Invalid source hidden column");
            hidden.add(number.intValue());
        }
        return new ExportTableLayout(title,headerRow,firstHeader,headings,merges,widths,font,fontSize,height,bands,spans,notes,widths.size()>9,supplemental,hidden);
    }
    private static ExportTableLayout statement(String key,List<ExportColumn> columns,Map<String,Object> metadata){
        var paper=FinanceStatementPaperLayout.layout(key,metadata);var extra=new ArrayList<ExportTableLayout.SupplementalCell>();
        int sourceHeader=metadata.get("sourceMainHeaderRow") instanceof Number number?number.intValue():paper.headerRow()+1;
        if(metadata.get("supplementalCells") instanceof List<?> cells)for(Object raw:cells){if(!(raw instanceof Map<?,?> cell))throw new IllegalArgumentException("Invalid supplemental source cell");String address=Objects.toString(cell.get("sourceCell"),"");var match=java.util.regex.Pattern.compile("^([A-Z]{1,2})([1-9][0-9]{0,3})$").matcher(address);if(!match.matches())throw new IllegalArgumentException("Invalid supplemental source address");int col=0;for(char letter:match.group(1).toCharArray()){col=col*26+letter-'A'+1;}col--;if(col<columns.size()||col>=paper.canvasColumns())throw new IllegalArgumentException("Supplemental source overlaps main table");extra.add(new ExportTableLayout.SupplementalCell(Integer.parseInt(match.group(2))-sourceHeader,col,Objects.toString(cell.get("type"),"text"),cell.get("value"),Boolean.TRUE.equals(cell.get("header"))));}
        return new ExportTableLayout(FinanceTemplateContract.entryName(key),paper.headerRow(),paper.headerStartRow(),paper.headings(),paper.merges(),paper.widths(),paper.fontName(),(short)paper.fontSize(),paper.rowHeight(),List.of(),List.of(),List.of(),paper.landscape(),extra,paper.hiddenColumns(),paper.footer(),paper.headingRowHeights(),paper.sourcePrint());
    }
    private static String captionLine(Map<?,?> line){
        String caption=Objects.toString(line.get("label"),"");
        boolean signature=Set.of("counterpartConfirmation","internalConfirmation").contains(Objects.toString(line.get("key"),""));
        String content=Objects.toString(line.get("value"),signature?"________":"待维护/核对");
        return caption+(caption.endsWith(":")||caption.endsWith("：")||caption.isBlank()?"":"：")+content;
    }
    private static void merge(List<ExportTableLayout.Merge> result,int firstRow,int lastRow,int first,int last) {
        if(firstRow!=lastRow||first!=last)result.add(new ExportTableLayout.Merge(firstRow,lastRow,first,last));
    }
    private static LocalDate date(String value,LocalDate fallback){return value==null||value.isBlank()?fallback:LocalDate.parse(value);}
    private static int integer(String value,int fallback){if(value==null||value.isBlank())return fallback;try{return Integer.parseInt(value);}catch(NumberFormatException failure){throw new IllegalArgumentException("Invalid report year or month",failure);}}
}
