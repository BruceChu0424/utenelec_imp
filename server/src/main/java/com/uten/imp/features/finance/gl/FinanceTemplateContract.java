package com.uten.imp.features.finance.gl;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;

/** Financial captions come from the reviewed source workbook contract, not developer synonyms. */
public final class FinanceTemplateContract {
    private FinanceTemplateContract() { }
    private static final JsonNode TEMPLATES=load();
    private static JsonNode load() {
        try(var input=FinanceTemplateContract.class.getResourceAsStream("/finance/template-contract-v1.json")) {
            if(input==null)throw new IllegalStateException("财务原表命名合同缺失");
            return new ObjectMapper().readTree(input).required("templates");
        }catch(java.io.IOException failure){throw new IllegalStateException("财务原表命名合同无效",failure);}
    }
    static String row(String sheet,int number) {
        String key=sheet.equals("BALANCE")?"balanceSheet":number==33?"annualProfit":"monthlyProfit";
        return TEMPLATES.required(key).required("rows").required(Integer.toString(number)).asText();
    }
    public static JsonNode template(String key){return TEMPLATES.required(key).deepCopy();}
    public static String entryName(String key){return TEMPLATES.required(key).required("entryName").asText();}
    public static String header(String template,int column){
        var parts=TEMPLATES.required(template).path("headerParts").path(column);
        return parts.isArray()&&!parts.isEmpty()?parts.get(parts.size()-1).required("label").asText():TEMPLATES.required(template).required("headers").required(column).asText();
    }
    public static java.util.List<com.uten.imp.features.finance.report.ReportColumn.HeaderGroup> headerGroups(String template,int column){
        var parts=TEMPLATES.required(template).path("headerParts").path(column);
        var groups=new java.util.ArrayList<com.uten.imp.features.finance.report.ReportColumn.HeaderGroup>();
        for(int i=0;i<parts.size()-1;i++)groups.add(new com.uten.imp.features.finance.report.ReportColumn.HeaderGroup(
                template+":"+parts.get(i).required("cell").asText(),parts.get(i).required("label").asText()));
        return java.util.List.copyOf(groups);
    }
    static String section(String cell){return TEMPLATES.required("balanceSheet").required("sectionNames").required(cell).asText();}
}
