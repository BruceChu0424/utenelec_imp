package com.uten.imp.features.finance.gl;

import com.fasterxml.jackson.databind.JsonNode;
import java.util.*;

/** Stable identities and formulas; all Chinese captions remain in the reviewed source contract. */
final class FinanceExpenseTemplateCatalog {
    private FinanceExpenseTemplateCatalog() { }
    record OperatingRow(int sourceRow,String key,String category,String sub,String item,List<String> terms) {
        boolean total(){return !terms.isEmpty();}
        String label(){return !item.isBlank()?item:!sub.isBlank()?sub:category;}
    }
    static List<GlReportLine> lines(String template) {
        List<GlReportLine> result=new ArrayList<>();
        for(JsonNode row:FinanceTemplateContract.template(template).required("rows")) {
            String key=row.required("key").asText();
            var source=switch(key) {
                case "MFG_OUTPUT"->GlReportLine.Source.FINISHED_IN;
                case "LABOR_DIRECT","LABOR_INDIRECT"->GlReportLine.Source.PAYROLL;
                case "MFG_DEPRECIATION","ADM_DEPRECIATION"->GlReportLine.Source.DEPRECIATION;
                case "ADM_SALES"->GlReportLine.Source.SALES_INCOME;
                default->key.endsWith("_AMORT")?GlReportLine.Source.AMORTIZATION:GlReportLine.Source.STYLES;
            };
            result.add(new GlReportLine(key,row.required("label").asText(),source));
        }
        return List.copyOf(result);
    }
    static String text(String template,String field){return FinanceTemplateContract.template(template).required(field).asText();}
    private static final Map<Integer,String> OP_KEYS=Map.ofEntries(
        Map.entry(3,"OP_REVENUE"),Map.entry(30,"OP_PRIMARY_TOTAL"),Map.entry(41,"OP_PACK_TOTAL"),Map.entry(42,"OP_MATERIAL_TOTAL"),
        Map.entry(43,"LABOR_DIRECT"),Map.entry(44,"LABOR_INDIRECT"),Map.entry(45,"OP_MEAL"),Map.entry(46,"OP_SUBCONTRACT"),Map.entry(47,"OP_LABOR_TOTAL"),
        Map.entry(48,"OP_RENT"),Map.entry(49,"OP_DORM_RENT"),Map.entry(50,"OP_ELECTRICITY"),Map.entry(51,"OP_WATER"),
        Map.entry(52,"OP_DEPRECIATION_EQUIPMENT"),Map.entry(53,"OP_DEPRECIATION_MOULD"),Map.entry(54,"OP_ADVERTISING"),
        Map.entry(55,"OP_LOGISTICS"),Map.entry(56,"OP_HANDLING"),Map.entry(57,"OP_EXPRESS"),Map.entry(58,"OP_PROPERTY"),
        Map.entry(59,"OP_OFFICE"),Map.entry(60,"OP_PHONE"),Map.entry(61,"OP_REPAIR"),Map.entry(62,"OP_DESIGN"),
        Map.entry(63,"OP_TAX_FEE"),Map.entry(64,"OP_ACCOUNTING"),Map.entry(65,"OP_ENTERTAIN"),Map.entry(66,"OP_TRAVEL"),
        Map.entry(67,"OP_INSPECTION"),Map.entry(68,"OP_CUSTOMS"),Map.entry(69,"OP_FINANCE"),Map.entry(70,"OP_OTHER"),
        Map.entry(71,"OP_INTEREST"),Map.entry(72,"OP_SERVICE"),Map.entry(73,"OP_LAWYER"),Map.entry(74,"OP_CERT"),
        Map.entry(75,"OP_EXECUTIVE"),Map.entry(76,"OP_TAX"),Map.entry(77,"OP_SALES_MISC"),Map.entry(78,"OP_SALES_ENTERTAIN_TRAVEL"),
        Map.entry(79,"OP_SALES_EXHIBITION"),Map.entry(80,"OP_SALES_MATERIAL"),Map.entry(81,"OP_SALES_REBATE"),
        Map.entry(82,"OP_SALES_COMMISSION"),Map.entry(83,"OP_SALES_BONUS"),Map.entry(84,"OP_TOOLS"),Map.entry(85,"OP_CLEANING"),
        Map.entry(86,"OP_MOULD_REPAIR"),Map.entry(87,"OP_VEHICLE_FUEL"),Map.entry(88,"OP_VEHICLE_OTHER"),
        Map.entry(89,"OP_OTHER_ALLOCATION"),Map.entry(90,"OP_ADMIN_TOTAL"),Map.entry(91,"OP_COST_TOTAL"),Map.entry(92,"OP_PROFIT"));
    static List<OperatingRow> operatingRows() {
        var template=FinanceTemplateContract.template("operatingProfit");Map<Integer,JsonNode> source=new LinkedHashMap<>();
        for(var row:template.required("sourceRows"))source.put(row.required("sourceRow").asInt(),row);
        List<OperatingRow> result=new ArrayList<>();
        for(var row:source.values()) {
            int number=row.required("sourceRow").asInt();
            List<String> terms=switch(number) {
                case 30->range(4,29);case 41->range(31,40);case 42->List.of(key(30),key(41));
                case 47->range(43,46);case 90->range(48,89);case 91->List.of(key(42),key(47),key(90));
                case 92->List.of(key(3),"-"+key(91));default->List.of();
            };
            result.add(new OperatingRow(number,key(number),mergedText(template,source,number,0,"category"),
                    mergedText(template,source,number,1,"sub"),mergedText(template,source,number,2,"item"),terms));
        }
        return List.copyOf(result);
    }
    private static List<String> range(int from,int to){return java.util.stream.IntStream.rangeClosed(from,to).mapToObj(FinanceExpenseTemplateCatalog::key).toList();}
    private static String key(int row){return OP_KEYS.getOrDefault(row,"OP_MATERIAL_"+row);}
    private static String mergedText(JsonNode template,Map<Integer,JsonNode> rows,int row,int col,String field) {
        String direct=rows.get(row).path(field).asText("");if(!direct.isEmpty())return direct;
        for(var merge:template.path("merges")) {
            String[] cells=merge.asText().split(":");if(cells.length!=2)continue;
            int firstCol=column(cells[0]),lastCol=column(cells[1]);
            int firstRow=Integer.parseInt(cells[0].replaceAll("[A-Z]","")),lastRow=Integer.parseInt(cells[1].replaceAll("[A-Z]",""));
            // Repeat vertical group context, but never duplicate a horizontal merged caption.
            if(col==firstCol&&col<=lastCol&&row>=firstRow&&row<=lastRow&&rows.containsKey(firstRow))return rows.get(firstRow).path(field).asText("");
        }
        return "";
    }
    private static int column(String cell){int n=0;for(char c:cell.replaceAll("[0-9]","").toCharArray())n=n*26+c-'A'+1;return n-1;}
    static GlReportLine operatingLine(OperatingRow row) {
        var source=switch(row.key()) {
            case "LABOR_DIRECT","LABOR_INDIRECT"->GlReportLine.Source.PAYROLL;
            case "OP_DEPRECIATION_EQUIPMENT","OP_DEPRECIATION_MOULD"->GlReportLine.Source.DEPRECIATION;
            default->GlReportLine.Source.STYLES;
        };
        return new GlReportLine(row.key(),row.label(),source);
    }
}
