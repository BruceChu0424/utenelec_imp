package com.uten.imp.features.finance.gl;

import com.uten.imp.common.files.document.*;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import java.util.*;
import static com.uten.imp.features.finance.gl.FinanceChartContracts.*;

/** The supplied XLS is a code directory: blank balances must never become opening entries. */
final class FinanceChartWorkbookParser {
    private FinanceChartWorkbookParser() { }
    static Preview parse(UUID id,String name,String hash,byte[] bytes) {
        DocumentKind kind=DocumentSniffer.sniff(bytes,name);
        if(kind!=DocumentKind.XLS && kind!=DocumentKind.XLSX)throw invalid("科目目录导入支持XLS或XLSX");
        var grid=SpreadsheetGridReader.read(bytes,kind);
        SpreadsheetImportVisibility.requireCompleteLiteralIdentities(bytes,3);
        if(grid.sheets().size()!=1)throw invalid("请上传一张完整的科目目录工作表");
        var sheet=grid.sheets().getFirst();
        if(sheet.truncated()||sheet.skippedHiddenRows()!=0)throw invalid("科目目录存在隐藏行或未完整读取，请先核对原文件");
        var header=sheet.rows().stream().filter(row->"科目编码".equals(text(row,0))&&"科目名称".equals(text(row,1)))
                .findFirst().orElseThrow(()->invalid("未找到原表头：科目编码、科目名称"));
        if(!Set.of("","外币名称").contains(text(header,2)))throw invalid("第三列应为外币名称");
        List<SourceRow> rows=new ArrayList<>();List<Issue> issues=new ArrayList<>();Set<String> codes=new HashSet<>();
        for(var issue:com.uten.imp.common.importing.ImportColumnGuard.inspectExtraColumns(bytes,sheet,header.index0(),3))
            issues.add(new Issue(issue.rowNum(),issue.column(),issue.message()));
        Set<String> currencyLabels=new HashSet<>();
        for(var source:sheet.rows())if(text(source,0).matches("[0-9]{1,32}")&&!text(source,2).isBlank())currencyLabels.add(text(source,2));
        var groupEnds=new TreeMap<Integer,String>();
        for(var group:FinanceTemplateContract.template("chartCodes").path("classifications"))for(var source:sheet.rows())
            if(text(source,0).equals(group.path("totalLabel").asText()))groupEnds.put(source.index0(),group.path("id").asText());
        boolean afterSubtotal=false;
        for(var row:sheet.rows()) {
            if(row.index0()<=header.index0())continue;
            String code=text(row,0),label=text(row,1);int line=row.index0()+1;
            if(row.cells().stream().allMatch(c->c.text().isBlank()))continue;
            if(code.matches(".*小计|合计|总计")){afterSubtotal=true;continue;}
            // The original directory has currency-only subtotal labels after
            // category/overall totals. An unnamed code on an ordinary data row
            // must instead remain in the preview with its located validation issue.
            if(code.isEmpty()&&afterSubtotal&&currencyLabels.contains(label)
                    &&row.cells().stream().allMatch(c->c.col0()==1||c.text().isBlank()))continue;
            afterSubtotal=false;
            if(!code.matches("[0-9]{1,32}"))issues.add(new Issue(line,"科目编码","代码须为1至32位数字文本"));
            if(row.cell(0)!=null&&row.cell(0).kind()!=DocumentGrid.CellKind.TEXT)
                issues.add(new Issue(line,"科目编码","科目代码请使用文本单元格，避免前导0或长代码丢失"));
            if(label.isBlank()||label.length()>240)issues.add(new Issue(line,"科目名称","名称不能为空且不能超过240字"));
            if(!codes.add(code))issues.add(new Issue(line,"科目编码","同一文件代码重复："+code));
            if(row.cells().stream().anyMatch(c->c.col0()>=3&&!c.text().isBlank()))
                issues.add(new Issue(line,"金额","此入口只导入科目目录；带金额的期初/发生额须另行受控接续"));
            var group=groupEnds.ceilingEntry(row.index0());
            rows.add(new SourceRow(code,label,text(row,2),line,null,FinanceChartClassification.resolve(code,group==null?null:group.getValue(),null)));
        }
        if(rows.isEmpty()||rows.size()>2000)throw invalid("科目目录需包含1至2000条代码");
        return new Preview(id,name,hash,List.copyOf(rows),List.copyOf(issues),false);
    }
    private static String text(DocumentGrid.Row row,int col) {
        var value=row.cell(col);return value==null?"":value.text().strip();
    }
    private static ApiException invalid(String message){return new ApiException(ErrorCode.VALIDATION_FAILED,message);}
}
