package com.uten.imp.features.finance.statement;

import com.uten.imp.common.files.document.*;
import com.uten.imp.common.web.*;
import com.uten.imp.features.finance.gl.FinanceTemplateContract;
import com.fasterxml.jackson.databind.annotation.JsonSerialize;
import com.uten.imp.common.finance.ExactDecimalText;
import com.uten.imp.common.util.FinancialExactAmount;
import java.math.BigDecimal;
import java.util.*;

/** External balance reports are evidence to compare, never an instruction to create GL amounts. */
public final class FinanceAuxiliaryWorkbookParser {
    private FinanceAuxiliaryWorkbookParser() { }
    public record Issue(int sourceRow,String field,String message) { }
    public record Row(int sourceRow,String accountCode,String accountName,String partyCode,String partyName,
                      String openingDirection,@JsonSerialize(using=ExactDecimalText.class) BigDecimal openingDebit,
                      @JsonSerialize(using=ExactDecimalText.class) BigDecimal openingCredit,@JsonSerialize(using=ExactDecimalText.class) BigDecimal openingBalance,
                      @JsonSerialize(using=ExactDecimalText.class) BigDecimal debit,@JsonSerialize(using=ExactDecimalText.class) BigDecimal credit,
                      @JsonSerialize(using=ExactDecimalText.class) BigDecimal closingDebit,@JsonSerialize(using=ExactDecimalText.class) BigDecimal closingCredit,
                      String closingDirection,@JsonSerialize(using=ExactDecimalText.class) BigDecimal closingBalance,
                      UUID currencyId,Long currencyChartVersion) {
        public Row(int sourceRow,String accountCode,String accountName,String partyCode,String partyName,
                String openingDirection,BigDecimal openingDebit,BigDecimal openingCredit,BigDecimal openingBalance,
                BigDecimal debit,BigDecimal credit,BigDecimal closingDebit,BigDecimal closingCredit,String closingDirection,BigDecimal closingBalance) {
            this(sourceRow,accountCode,accountName,partyCode,partyName,openingDirection,openingDebit,openingCredit,openingBalance,debit,credit,closingDebit,closingCredit,closingDirection,closingBalance,null,null);
        }
        public Row withCurrency(UUID id,Long version){return new Row(sourceRow,accountCode,accountName,partyCode,partyName,openingDirection,openingDebit,openingCredit,openingBalance,debit,credit,closingDebit,closingCredit,closingDirection,closingBalance,id,version);}
    }
    public record Parsed(List<Row> rows,List<Issue> issues) { }
    public static Parsed parse(boolean receivable,String filename,byte[] bytes) {
        DocumentKind kind=DocumentSniffer.sniff(bytes,filename);
        if(kind!=DocumentKind.XLS&&kind!=DocumentKind.XLSX)throw invalid("辅助明细导入支持XLS或XLSX");
        var grid=SpreadsheetGridReader.read(bytes,kind);
        SpreadsheetImportVisibility.requireCompleteLiteralIdentities(bytes,4);
        if(grid.sheets().size()!=1)throw invalid("请选择单张完整的应收或应付账款明细表");
        var sheet=grid.sheets().getFirst();
        if(sheet.truncated()||sheet.skippedHiddenRows()!=0)throw invalid("原明细存在隐藏行或未完整读取，请核对原文件");
        String key=receivable?"receivableAuxiliaryDetail":"payableAuxiliaryDetail",prefix=receivable?"1122":"2202";
        var header=sheet.rows().stream().filter(r->text(r,0).equals("科目编码")&&text(r,2).equals(receivable?"客户编号":"供应商编号"))
                .findFirst().orElseThrow(()->invalid("未找到财务提供的14列表头"));
        for(int col=0;col<14;col++)if(!FinanceTemplateContract.header(key,col).equals(text(header,col)))
            throw invalid("第"+(col+1)+"列表头应为原文："+FinanceTemplateContract.header(key,col));
        if(sheet.maxColumn()>13)throw invalid("辅助明细应为原14列，请核对额外列中的数据");
        var rows=new ArrayList<Row>();var issues=new ArrayList<Issue>();var identities=new HashSet<String>();
        for(var row:sheet.rows()) {
            if(row.index0()<=header.index0()||row.cells().isEmpty())continue;
            int line=row.index0()+1;String code=text(row,0),party=text(row,2),name=text(row,3);
            if(code.isBlank()&&party.isBlank()) {
                if(row.cells().stream().allMatch(c->c.text().isBlank()))continue;
                if(row.cells().stream().anyMatch(c->Set.of("合计","总计","小计").contains(c.text().strip())))continue;
                issues.add(new Issue(line,"科目编码/辅助编号","非空行缺少身份，不能静默跳过"));continue;
            }
            if(!code.matches("[0-9]{1,32}")||!code.startsWith(prefix))issues.add(new Issue(line,"科目编码","科目代码与所选明细用途不符"));
            for(int col:List.of(0,2))if(row.cell(col)==null||row.cell(col).kind()!=DocumentGrid.CellKind.TEXT)
                issues.add(new Issue(line,FinanceTemplateContract.header(key,col),"原编号请使用文本，避免丢失前导0或长代码"));
            if(party.isBlank()||party.length()>240||name.isBlank()||name.length()>240||text(row,1).isBlank())issues.add(new Issue(line,"原项目","编号及名称不能为空或过长"));
            if(!identities.add(code+"\u0000"+party))issues.add(new Issue(line,"辅助编号","同一科目和辅助编号出现重复，需先核对来源粒度"));
            int direction=receivable?4:6,openingDebit=receivable?5:4,openingCredit=receivable?6:5;
            Row value=new Row(line,code,text(row,1),party,name,text(row,direction),
                    amount(row,openingDebit,key,issues),amount(row,openingCredit,key,issues),amount(row,7,key,issues),
                    amount(row,8,key,issues),amount(row,9,key,issues),amount(row,10,key,issues),amount(row,11,key,issues),text(row,12),amount(row,13,key,issues));
            validate(value,issues);rows.add(value);
        }
        if(rows.isEmpty()||rows.size()>2000)throw invalid("辅助明细需包含1至2000条完整来源记录");
        return new Parsed(List.copyOf(rows),List.copyOf(issues));
    }
    private static BigDecimal amount(DocumentGrid.Row row,int col,String key,List<Issue> issues) {
        var cell=row.cell(col);BigDecimal result=cell==null?null:cell.number();
        if(result==null&&cell!=null&&cell.kind()==DocumentGrid.CellKind.TEXT&&!cell.text().isBlank()) {
            try{result=new BigDecimal(cell.text().strip());}catch(NumberFormatException ignored){ }
        }
        if(result==null)issues.add(new Issue(row.index0()+1,FinanceTemplateContract.header(key,col),"金额缺失或不是完整数值；不能按零导入"));
        else try{result=FinancialExactAmount.book(result,FinanceTemplateContract.header(key,col));}
        catch(ApiException invalid){issues.add(new Issue(row.index0()+1,FinanceTemplateContract.header(key,col),"金额超出可无损保存范围；原文件和错误位置保留，不自动舍入或按零计算"));result=null;}
        return result;
    }
    private static void validate(Row row,List<Issue> issues) {
        var values=Arrays.asList(row.openingDebit(),row.openingCredit(),row.openingBalance(),row.debit(),row.credit(),row.closingDebit(),row.closingCredit(),row.closingBalance());
        if(values.contains(null))return;
        BigDecimal opening=row.openingDebit().subtract(row.openingCredit()),closing=row.closingDebit().subtract(row.closingCredit());
        if(row.openingDebit().signum()<0||row.openingCredit().signum()<0||row.closingDebit().signum()<0||row.closingCredit().signum()<0)
            issues.add(new Issue(row.sourceRow(),"借贷余额","借方/贷方余额列必须按原方向分列为非负数"));
        if(opening.abs().compareTo(row.openingBalance())!=0||!direction(opening).equals(row.openingDirection()))
            issues.add(new Issue(row.sourceRow(),"期初余额/方向","与期初借方减贷方不一致"));
        if(closing.abs().compareTo(row.closingBalance())!=0||!direction(closing).equals(row.closingDirection()))
            issues.add(new Issue(row.sourceRow(),"期末余额/方向","与期末借方减贷方不一致"));
        if(opening.add(row.debit()).subtract(row.credit()).compareTo(closing)!=0)
            issues.add(new Issue(row.sourceRow(),"余额勾稽","期初借贷净额+本期借方-本期贷方不等于期末借贷净额"));
    }
    private static String direction(BigDecimal net){return net.signum()>0?"借":net.signum()<0?"贷":"平";}
    private static String text(DocumentGrid.Row row,int col){var cell=row.cell(col);return cell==null?"":cell.text().strip();}
    private static ApiException invalid(String message){return new ApiException(ErrorCode.VALIDATION_FAILED,message);}
}
