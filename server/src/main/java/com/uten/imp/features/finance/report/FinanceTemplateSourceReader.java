package com.uten.imp.features.finance.report;

import com.uten.imp.common.files.document.*;
import com.uten.imp.common.web.*;
import com.uten.imp.features.finance.gl.FinanceTemplateContract;
import java.time.YearMonth;
import java.util.*;

/** Read-only financial source, sharing the bounded spreadsheet engine; no formulas execute. */
public final class FinanceTemplateSourceReader {
    private FinanceTemplateSourceReader() { }
    public record Cell(int column,String text,String kind,String number) { }
    public record Row(int sourceRow,List<Cell> cells,List<String>issues) {
        public Row{cells=List.copyOf(cells);issues=issues==null?List.of():List.copyOf(issues);}
        public Row(int sourceRow,List<Cell>cells){this(sourceRow,cells,List.of());}
    }
    public record SupplementalCell(String sourceCell,String text,String kind,String number) { }
    public record Preview(UUID importId,String template,String period,String sourceName,String sha256,String sourceSheet,
            List<String> headers,List<Row> rows,List<String> issues,boolean hiddenIncluded,List<SupplementalCell> supplementalCells) {
        public Preview{supplementalCells=supplementalCells==null?List.of():List.copyOf(supplementalCells);}
        public Preview(UUID importId,String template,String period,String sourceName,String sha256,String sourceSheet,List<String> headers,List<Row> rows,List<String> issues,boolean hiddenIncluded){this(importId,template,period,sourceName,sha256,sourceSheet,headers,rows,issues,hiddenIncluded,List.of());}
    }

    public static Preview read(UUID id,String template,String period,String name,String hash,byte[] bytes,DocumentIntakeProfile profile) {
        return read(id,template,period,name,hash,bytes,profile,null);
    }
    public static Preview read(UUID id,String template,String period,String name,String hash,byte[] bytes,DocumentIntakeProfile profile,String sourceSheet) {
        if(sourceSheet!=null&&(sourceSheet.isBlank()||sourceSheet.length()>500||sourceSheet.chars().anyMatch(Character::isISOControl)))throw invalid("请按原文件填写有效的工作表名称");
        YearMonth month=period(period);
        var kind=DocumentSniffer.sniff(bytes,name);
        if(kind!=DocumentKind.XLS&&kind!=DocumentKind.XLSX)throw invalid("原表导入支持XLS或XLSX");
        var grid=SpreadsheetGridReader.read(bytes,kind,profile);
        if(sourceSheet!=null&&grid.sheets().stream().noneMatch(sheet->sourceSheet.equals(sheet.name())))throw invalid("原文件中没有所选工作表，请按原名重新选择");
        var contract=FinanceTemplateContract.template(template);int count=contract.required("headers").size();
        List<String> headers=new ArrayList<>();for(int i=0;i<count;i++)headers.add(shift(FinanceTemplateContract.header(template,i),template.equals("depreciationCompleted")?2026:month.getYear()));
        List<Match> matches=new ArrayList<>();
        for(var sheet:grid.sheets())for(var row:sheet.rows()) {
            if(sourceSheet!=null&&!sourceSheet.equals(sheet.name()))continue;
            if(row.index0()>30)break;
            int end=row.index0();boolean matched=true;
            for(int c=0;c<count;c++) {
                if(headers.get(c).isBlank())continue;
                int found=-1;
                for(int r=row.index0();r<=row.index0()+2;r++) {
                    String text=sheet.text(r,c);
                    if(equalHeader(headers.get(c),text)){found=r;break;}
                }
                if(found<0){matched=false;break;}end=Math.max(end,found);
            }
            if(matched){matches.add(new Match(sheet,end));break;}
        }
        if(matches.isEmpty())throw invalid("未找到与财务原表列名和顺序一致的表头，请核对所选入口和文件");
        if(matches.size()>1)throw new ApiException(ErrorCode.VALIDATION_FAILED,"同一文件有多张相同原表，请按原名选择工作表",
            matches.stream().map(match->new ApiError.FieldError("sourceSheet",match.sheet.name())).toList());
        var match=matches.getFirst();var sheet=match.sheet;List<String> issues=new ArrayList<>();
        if(sheet.truncated())issues.add("原表存在读取截断、错误单元格或超限内容，不能确认金额");
        if(sheet.skippedHiddenRows()!=0||!grid.hiddenIncluded())issues.add("原表隐藏内容未完整保留");
        List<Row> rows=new ArrayList<>();
        for(var row:sheet.rows())if(row.index0()>match.headerEnd) {
            List<Cell> cells=new ArrayList<>();for(var cell:row.cells())if(cell.col0()<count)cells.add(new Cell(cell.col0()+1,cell.text(),cell.kind().name(),cell.number()==null?null:cell.number().toPlainString()));
            if(!cells.isEmpty())rows.add(new Row(row.index0()+1,List.copyOf(cells),cells.stream().filter(c->c.kind.equals("ERROR")).map(c->"第"+c.column+"列原表值为"+c.text).toList()));
        }
        if(rows.size()>2000)issues.add("原表数据超过2000行，请按原工作表拆分后核对");
        List<SupplementalCell> supplemental=new ArrayList<>();
        if(template.equals("otherReceivableStatement"))for(var row:sheet.rows())for(var cell:row.cells())if(cell.col0()>=11&&cell.col0()<=16)supplemental.add(new SupplementalCell(Character.toString((char)('A'+cell.col0()))+(row.index0()+1),cell.text(),cell.kind().name(),cell.number()==null?null:cell.number().toPlainString()));
        return new Preview(id,template,period,name,hash,sheet.name(),List.copyOf(headers),List.copyOf(rows),List.copyOf(issues),grid.hiddenIncluded(),supplemental);
    }
    static YearMonth period(String value){
        try{var result=YearMonth.parse(value);if(!result.toString().equals(value))throw new IllegalArgumentException();return result;}
        catch(RuntimeException failure){throw invalid("请选择原表会计月份");}
    }
    static String shift(String value,int year){try{return java.util.regex.Pattern.compile("202[3-6]").matcher(value).replaceAll(m->Integer.toString(Integer.parseInt(m.group())+year-2026));}catch(NumberFormatException failure){throw new IllegalArgumentException("Source template header year is not numeric",failure);}}
    static boolean equalHeader(String expected,String value) {
        if(normal(expected).equals(normal(value)))return true;
        try {var source=java.time.LocalDate.parse(value);return expected.equals(source.getYear()+"/"+source.getMonthValue()+"/"+source.getDayOfMonth());}catch(RuntimeException ignored){return false;}
    }
    private static String normal(String value){return value.replaceAll("[\\s\\u3000]+","");}
    private record Match(DocumentGrid.Sheet sheet,int headerEnd) { }
    private static ApiException invalid(String m){return new ApiException(ErrorCode.VALIDATION_FAILED,m);}
}
