package com.uten.imp.features.finance.gl;

import com.uten.imp.common.files.document.*;
import com.uten.imp.common.web.*;
import java.util.*;
import static com.uten.imp.features.finance.gl.FinanceExpenseAnalysisContracts.*;

/** Only the original 备注/差异原因 are imported; workbook amounts never post to a ledger. */
final class FinanceOperatingNoteParser {
    private FinanceOperatingNoteParser() { }
    static NoteImportPreview parse(UUID id,String period,String name,String hash,byte[] bytes,Map<String,Long> versions) {
        var kind=DocumentSniffer.sniff(bytes,name);if(kind!=DocumentKind.XLS&&kind!=DocumentKind.XLSX)throw invalid("备注导入支持原表XLS或XLSX");
        var grid=SpreadsheetGridReader.read(bytes,kind);SpreadsheetImportVisibility.requireCompleteLiteralIdentities(bytes,3);
        DocumentParseGate.run(deadline->{try(var book=org.apache.poi.ss.usermodel.WorkbookFactory.create(new java.io.ByteArrayInputStream(bytes))){for(var s:book)for(var r:s){deadline.check();for(int c:List.of(28,29))if(r.getCell(c)!=null&&r.getCell(c).getCellType()==org.apache.poi.ss.usermodel.CellType.FORMULA)throw invalid("备注/差异原因请使用文字原文，不能使用公式");}}catch(ApiException e){throw e;}catch(Exception e){throw invalid("备注单元格无法完整核对");}return true;});
        if(grid.sheets().size()!=1)throw invalid("请上传一张完整的公司经营损益工作表");
        var sheet=grid.sheets().getFirst();if(sheet.truncated()||sheet.skippedHiddenRows()!=0)throw invalid("工作表未完整读取，请核对隐藏行和范围");
        var headers=FinanceExpenseReports.operatingColumns(12);
        int header=-1;for(var row:sheet.rows())if(text(sheet,row.index0(),0).equals(headers.get(0).label())&&text(sheet,row.index0(),1).equals(headers.get(1).label())&&text(sheet,row.index0(),2).equals(headers.get(2).label())){
            if(header>=0)throw invalid("存在多个表头，请分开导入");header=row.index0();
        }
        if(header<0)throw invalid("未找到原表头：项目分类、分项、具体项目");
        for(int col:List.of(28,29))if(!text(sheet,header,col).equals(headers.get(col).label()))throw invalid("原表第"+(col+1)+"列应为"+headers.get(col).label());
        // Only these original read-only month/ratio columns may be ignored.
        // A replacement or duplicate inside the fixed width is not a month amount.
        for(int col=0;col<headers.size();col++) {
            String actual=text(sheet,header,col);
            boolean valid=col==27 ? actual.matches("1-(?:[1-9]|1[0-2])月平均值占销售比") : actual.equals(headers.get(col).label());
            if(!valid)throw invalid("原表第"+(col+1)+"列「"+actual+"」不是原字段「"+headers.get(col).label()+"」，请保留原月份及只读金额表头，不能忽略或按同名字段导入");
        }
        Map<String,List<FinanceExpenseTemplateCatalog.OperatingRow>> identities=new HashMap<>();
        for(var row:FinanceExpenseTemplateCatalog.operatingRows())identities.computeIfAbsent(identity(row.category(),row.sub(),row.item()),k->new ArrayList<>()).add(row);
        List<NoteImportRow> rows=new ArrayList<>();List<ImportIssue> issues=new ArrayList<>();Set<String> keys=new HashSet<>();
        for(var issue:com.uten.imp.common.importing.ImportColumnGuard.inspectExtraColumns(bytes,sheet,header,headers.size()))
            issues.add(new ImportIssue(issue.rowNum(),issue.column(),issue.message()));
        for(var row:sheet.rows()) {
            if(row.index0()<=header)continue;String remark=text(sheet,row.index0(),28),reason=text(sheet,row.index0(),29);if(remark.isBlank()&&reason.isBlank())continue;
            String category=text(sheet,row.index0(),0),sub=text(sheet,row.index0(),1),item=text(sheet,row.index0(),2);int line=row.index0()+1;
            var matches=identities.getOrDefault(identity(category,sub,item),List.of());
            if(matches.size()!=1){issues.add(new ImportIssue(line,"项目","未能唯一对应原表项目，请保留原分类、分项、具体项目及合并关系"));continue;}
            String key=matches.getFirst().key();if(!keys.add(key)){issues.add(new ImportIssue(line,"项目","同一原表项目重复"));continue;}
            if(remark.length()>2000||reason.length()>2000){issues.add(new ImportIssue(line,"备注/差异原因","单项不能超过2000字"));continue;}
            rows.add(new NoteImportRow(line,key,category,sub,item,remark,reason,versions.getOrDefault(key,-1L)));
        }
        if(rows.isEmpty()&&issues.isEmpty())throw invalid("未找到可导入的备注或差异原因，空白不会清除已保存内容");
        return new NoteImportPreview(id,period,name,hash,List.copyOf(rows),List.copyOf(issues),false);
    }
    private static String text(DocumentGrid.Sheet sheet,int row,int col){
        var merge=sheet.mergeAt(row,col);if(merge!=null&&merge.firstCol()==col)return sheet.text(merge.firstRow(),col).strip();return sheet.text(row,col).strip();
    }
    private static String identity(String a,String b,String c){return a.strip()+"\u001f"+b.strip()+"\u001f"+c.strip();}
    private static ApiException invalid(String message){return new ApiException(ErrorCode.VALIDATION_FAILED,message);}
}
