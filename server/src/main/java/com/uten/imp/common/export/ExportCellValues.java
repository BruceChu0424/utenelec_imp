package com.uten.imp.common.export;

import java.math.BigDecimal;
import java.util.Map;
import java.util.Objects;

/** One precision/unit authority for the XLSX and PDF renderers; it never calculates business totals. */
final class ExportCellValues {
    private ExportCellValues(){}
    static BigDecimal decimal(Object value) {
        if(value instanceof BigDecimal number)return number;
        if(value instanceof Number number)return new BigDecimal(number.toString());
        if(value instanceof String text&&!text.isBlank())try{return new BigDecimal(text.trim());}catch(NumberFormatException ignored){}
        return null;
    }
    static boolean bool(Object value) {
        if(value instanceof Boolean flag)return flag;
        if(value instanceof Number number)return number.intValue()!=0;
        return "true".equalsIgnoreCase(Objects.toString(value))||"1".equals(Objects.toString(value));
    }
    static String date(Object value) {
        if(value instanceof java.time.LocalDate date)return date.toString();
        if(value instanceof java.util.Date date)return new java.sql.Date(date.getTime()).toLocalDate().toString();
        return Objects.toString(value);
    }
    static String unit(ExportColumn column,Map<String,Object> row) {
        String unit=column.unitKey()==null?column.unitLabel():Objects.toString(row==null?null:row.get(column.unitKey()),"");
        if(unit==null||unit.isBlank())return "";
        unit=unit.strip();return "人民币".equals(unit)?"元":unit;
    }
    static String exactText(BigDecimal number) {
        long precision=number.precision(),scale=number.scale();
        long length=scale<=0?precision-scale:Math.max(precision+1,scale+2);
        if(number.signum()<0)length++;
        if(length>32767)throw new com.uten.imp.common.web.ApiException(com.uten.imp.common.web.ErrorCode.VALIDATION_FAILED,
                "精确数值超出导出单元格容量，请核查数据");
        return number.toPlainString();
    }
    static String display(ExportColumn column,Map<String,Object> row) {
        Object raw=row.get(column.key());if(raw==null)return "—";
        if(ExportColumn.BOOL.equals(column.type()))return bool(raw)?"是":"否";
        if(ExportColumn.DATE.equals(column.type()))return date(raw);
        boolean numeric=ExportColumn.MONEY.equals(column.type())||ExportColumn.NUMBER.equals(column.type())||ExportColumn.QTY.equals(column.type());
        BigDecimal number=numeric?decimal(raw):null;
        String value=number==null?Objects.toString(raw):exactText(number);
        String unit=number==null?"":unit(column,row);
        return unit.isEmpty()?value:value+" "+unit;
    }
}
