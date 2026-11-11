package com.uten.imp.features.finance.gl;

import com.uten.imp.common.files.document.*;
import com.uten.imp.common.web.*;
import com.fasterxml.jackson.annotation.JsonFormat;
import java.math.BigDecimal;
import java.time.*;
import java.util.*;
import java.util.regex.Pattern;

/** Literal source journals and local-currency balances. File flags never grant platform authority. */
public final class FinanceAccountingWorkbookParser {
    private FinanceAccountingWorkbookParser() { }
    public record Issue(int sourceRow,String field,String message) { }
    public record Entry(int sourceRow,LocalDate date,String type,String number,String summary,String accountCode,
                 @JsonFormat(shape=JsonFormat.Shape.STRING) BigDecimal debit,@JsonFormat(shape=JsonFormat.Shape.STRING) BigDecimal credit,
                 @JsonFormat(shape=JsonFormat.Shape.STRING) BigDecimal original,@JsonFormat(shape=JsonFormat.Shape.STRING) BigDecimal exchangeRate,
                 String ledger,String company,int year,int month,int lineNo,String currencyName,String accountName,
                 String customerCode,String customerName,String supplierCode,String supplierName,
                 String employeeCode,String departmentCode,String projectCode,String projectName,
                 String sourceEntryId,String sourceVoucherId,Map<String,String> source) {
        String voucherKey(){return ledger+"|"+year+"|"+month+"|"+type+"|"+number;}
        int direction(){return debit.signum()!=0?1:-1;}
        BigDecimal amount(){return debit.signum()!=0?debit:credit;}
    }
    public record Voucher(String key,String ledger,String company,int year,int month,String type,String number,
                   String sourceVoucherId,LocalDate date,boolean closingCandidate,@JsonFormat(shape=JsonFormat.Shape.STRING) BigDecimal debit,
                   @JsonFormat(shape=JsonFormat.Shape.STRING) BigDecimal credit,List<Entry> entries) { }
    public record Balance(int sourceRow,int year,int month,String accountCode,String accountName,String currencyName,
                   @JsonFormat(shape=JsonFormat.Shape.STRING) BigDecimal openingDebit,@JsonFormat(shape=JsonFormat.Shape.STRING) BigDecimal openingCredit,
                   @JsonFormat(shape=JsonFormat.Shape.STRING) BigDecimal debit,@JsonFormat(shape=JsonFormat.Shape.STRING) BigDecimal credit,
                   @JsonFormat(shape=JsonFormat.Shape.STRING) BigDecimal closingDebit,@JsonFormat(shape=JsonFormat.Shape.STRING) BigDecimal closingCredit) { }
    public record Parsed(String kind,List<Voucher> vouchers,List<Balance> balances,List<Issue> issues,List<String> headers,int columnContractVersion) {
        public Parsed(String kind,List<Voucher> vouchers,List<Balance> balances,List<Issue> issues,List<String> headers){this(kind,vouchers,balances,issues,headers,com.uten.imp.common.importing.ImportColumnGuard.VERSION);}
        public Parsed(String kind,List<Voucher> vouchers,List<Balance> balances,List<Issue> issues){this(kind,vouchers,balances,issues,List.of());}
    }
    private static final Pattern CODE=Pattern.compile("[0-9]{1,32}");
    static Parsed parse(String kind,String filename,byte[] bytes) {
        var document=DocumentSniffer.sniff(bytes,filename);
        if(document!=DocumentKind.XLS&&document!=DocumentKind.XLSX)throw invalid("原账套凭证或余额只支持完整XLS/XLSX文件");
        var grid=SpreadsheetGridReader.read(bytes,document,DocumentIntakeProfile.FINANCIAL_TEMPLATE);
        // Inspect physical cells before selecting a business sheet from the value grid.
        // Raw BIFF3 has no formula support. OLE/XML identity and amount fields must be literal.
        if(!LegacyBiffGridReader.isRaw(bytes))SpreadsheetImportVisibility.requireCompleteLiteralIdentities(bytes,83);
        if(grid.sheets().size()!=1)throw invalid("请上传一张完整的原账套工作表");
        var sheet=grid.sheets().getFirst();
        if(sheet.truncated()||sheet.skippedHiddenRows()!=0||sheet.rows().isEmpty())throw invalid("原账套文件未完整读取");
        return switch(kind){case "VOUCHERS"->vouchers(sheet,bytes);case "BALANCE"->balances(sheet,bytes);default->throw invalid("请选择凭证或科目余额文件类型");};
    }
    private static Parsed vouchers(DocumentGrid.Sheet sheet,byte[] bytes) {
        var header=sheet.rows().getFirst();
        for(int index=1;index<=82;index++)if(!Pattern.compile("^F"+index+"(?![0-9]).*",Pattern.DOTALL).matcher(text(header,index-1)).matches())
            throw invalid("原凭证第"+index+"列表头不符合F"+index+"，不能猜测列位置");
        if(sheet.maxColumn()!=82)throw invalid("原凭证须保留全部83列及输出签名");
        var signature=Pattern.compile("^凭证输出[：:]([^：:]+)[：:]([^：:]+)[：:]([^：:]+)[：:]([0-9]{4})$").matcher(text(header,82));
        if(!signature.matches())throw invalid("原凭证第83列输出签名缺损或格式不符，请从原账套重新导出");
        String signatureLedger=signature.group(2),signatureCompany=signature.group(3);int signatureYear=Integer.parseInt(signature.group(4));
        List<Issue> issues=new ArrayList<>();
        for(var issue:com.uten.imp.common.importing.ImportColumnGuard.inspectExtraColumns(bytes,sheet,header.index0(),83))
            issues.add(new Issue(issue.rowNum(),issue.column(),issue.message()));
        Map<String,List<Entry>> grouped=new LinkedHashMap<>();Set<String> sourceIds=new HashSet<>();
        for(var row:sheet.rows()) {
            if(row.index0()<=header.index0()||row.cells().isEmpty())continue;
            int line=row.index0()+1;
            try {
                String code=literal(row,5,"科目代码");if(!CODE.matcher(code).matches())throw invalid("科目代码必须是完整数字文本");
                LocalDate date=LocalDate.parse(text(row,0));int year=integer(row,50),month=integer(row,51),lineNo=integer(row,58);
                if(year!=date.getYear()||month!=date.getMonthValue()||lineNo<1)throw invalid("日期、会计年/期间或凭证行号不一致");
                String type=required(row,1,"凭证类别"),number=literal(row,2,"凭证号"),ledger=literal(row,48,"账套号");
                if(!ledger.equals(signatureLedger)||!text(row,49).equals(signatureCompany)||year!=signatureYear)
                    throw invalid("原凭证分录的账套、核算单位或年度与输出签名不一致");
                BigDecimal debit=number(row,6),credit=number(row,7),original=nullableNumber(row,9,false),rate=nullableNumber(row,10,false);
                if((debit.signum()==0)==(credit.signum()==0))throw invalid("借贷两列必须仅有一列为非零，红字保留原方向负金额");
                String entryId=required(row,80,"分录自动编号"),voucherId=required(row,81,"凭证唯一标识");
                if(!sourceIds.add(ledger+"|"+year+"|"+entryId))throw invalid("同一账套年度的分录自动编号重复，未忽略重复行");
                String currency=text(row,59);
                if(!currency.isBlank()&&(original==null||rate==null||rate.signum()<=0))throw invalid("外币分录缺少原币金额或有效汇率");
                Map<String,String> raw=new LinkedHashMap<>();for(var cell:row.cells())raw.put("F"+(cell.col0()+1),cell.text());
                var entry=new Entry(line,date,type,number,text(row,4),code,debit,credit,original,rate,ledger,text(row,49),year,month,lineNo,currency,text(row,61),
                        text(row,17),text(row,64),text(row,18),text(row,65),text(row,16),text(row,15),text(row,20),text(row,66),entryId,voucherId,Collections.unmodifiableMap(raw));
                grouped.computeIfAbsent(entry.voucherKey(),key->new ArrayList<>()).add(entry);
            }catch(RuntimeException error){issues.add(new Issue(line,"原始分录",message(error)));}
        }
        List<Voucher> vouchers=new ArrayList<>();
        for(var group:grouped.entrySet()) {
            var entries=group.getValue();var first=entries.getFirst();BigDecimal debit=BigDecimal.ZERO,credit=BigDecimal.ZERO;Set<Integer> lines=new HashSet<>();
            for(var entry:entries){debit=debit.add(entry.debit());credit=credit.add(entry.credit());
                if(!lines.add(entry.lineNo()))issues.add(new Issue(entry.sourceRow(),"凭证行号","同一凭证行号重复"));
                if(!entry.date().equals(first.date())||!entry.sourceVoucherId().equals(first.sourceVoucherId())||!entry.company().equals(first.company()))
                    issues.add(new Issue(entry.sourceRow(),"凭证身份","同一来源凭证的日期、唯一标识或核算单位不一致"));
            }
            if(entries.size()<2||debit.compareTo(credit)!=0)issues.add(new Issue(first.sourceRow(),"借贷合计","原凭证借贷不平，不能靠舍入或补差导入"));
            boolean closing=entries.stream().anyMatch(e->e.accountCode().equals("3103"))&&entries.stream().allMatch(e->e.accountCode().equals("3103")||e.accountCode().startsWith("5"));
            vouchers.add(new Voucher(group.getKey(),first.ledger(),first.company(),first.year(),first.month(),first.type(),first.number(),first.sourceVoucherId(),first.date(),closing,debit,credit,List.copyOf(entries)));
        }
        if(vouchers.isEmpty()&&issues.isEmpty())throw invalid("未读到原凭证分录");
        return new Parsed("VOUCHERS",List.copyOf(vouchers),List.of(),List.copyOf(issues),java.util.stream.IntStream.range(0,83).mapToObj(column->text(header,column)).toList());
    }
    private static Parsed balances(DocumentGrid.Sheet sheet,byte[] bytes) {
        List<String> expected=List.of("会计年度","会计期间","科目编码","科目名称","外币名称","期初借方","期初贷方","本期发生借方","本期发生贷方","期末借方","期末贷方");
        var header=sheet.rows().stream().filter(row->text(row,2).equals("科目编码")&&text(row,3).equals("科目名称")).findFirst().orElseThrow(()->invalid("缺少11列原科目余额表头（含会计年度、会计期间）"));
        for(int col=0;col<expected.size();col++)if(!text(header,col).equals(expected.get(col)))throw invalid("科目余额第"+(col+1)+"列表头应为"+expected.get(col));
        List<Balance> rows=new ArrayList<>();List<Issue> issues=new ArrayList<>();Set<String> codes=new HashSet<>();
        for(var issue:com.uten.imp.common.importing.ImportColumnGuard.inspectExtraColumns(bytes,sheet,header.index0(),expected.size()))
            issues.add(new Issue(issue.rowNum(),issue.column(),issue.message()));
        for(var row:sheet.rows()) {
            if(row.index0()<=header.index0())continue;
            String code=text(row,2);
            // Category/currency totals are presentation, never another posting account.
            if(code.isBlank()||code.contains("小计")||code.equals("合计")||code.equals("总计"))continue;
            try {
                code=literal(row,2,"科目代码");if(!CODE.matcher(code).matches()||!codes.add(code))throw invalid("科目代码无效或重复");
                int year=integer(row,0),month=balanceMonth(row,year);YearMonth.of(year,month);
                BigDecimal od=number(row,5),oc=number(row,6),debit=number(row,7),credit=number(row,8),cd=number(row,9),cc=number(row,10);
                if(od.signum()<0||oc.signum()<0||cd.signum()<0||cc.signum()<0||od.signum()*oc.signum()!=0||cd.signum()*cc.signum()!=0)throw invalid("期初或期末借贷余额方向不明确");
                if(od.subtract(oc).add(debit).subtract(credit).compareTo(cd.subtract(cc))!=0)throw invalid("期初+借方发生-贷方发生与期末余额不一致");
                rows.add(new Balance(row.index0()+1,year,month,code,required(row,3,"科目名称"),text(row,4),od,oc,debit,credit,cd,cc));
            }catch(RuntimeException error){issues.add(new Issue(row.index0()+1,"科目余额",message(error)));}
        }
        if(rows.isEmpty()&&issues.isEmpty())throw invalid("未读到完整科目余额，空白代码目录不能当期初余额");
        if(rows.stream().map(row->row.year()+"-"+row.month()).distinct().count()!=1)issues.add(new Issue(header.index0()+1,"会计期间","同一余额文件须属于一个会计期间"));
        BigDecimal net=rows.stream().map(row->row.openingDebit().subtract(row.openingCredit())).reduce(BigDecimal.ZERO,BigDecimal::add);
        if(net.signum()!=0)issues.add(new Issue(header.index0()+1,"期初合计","期初科目借贷不平"));
        return new Parsed("BALANCE",List.of(),List.copyOf(rows),List.copyOf(issues),java.util.stream.IntStream.range(0,11).mapToObj(column->text(header,column)).toList());
    }
    static List<Issue> reconcile(Parsed vouchers,Parsed balance) {
        var issues=new ArrayList<Issue>();Map<String,BigDecimal[]> totals=new HashMap<>();
        if(!vouchers.kind().equals("VOUCHERS")||!balance.kind().equals("BALANCE"))throw invalid("请选择原凭证及对应期间余额文件");
        for(var row:balance.balances()) {
            totals.put(row.accountCode(),new BigDecimal[]{BigDecimal.ZERO,BigDecimal.ZERO});
        }
        for(var voucher:vouchers.vouchers())for(var entry:voucher.entries()) {
            var original=balance.balances().getFirst();
            if(entry.year()!=original.year()||entry.month()!=original.month())issues.add(new Issue(entry.sourceRow(),"会计期间","凭证与余额的年度/期间不一致"));
            var sums=totals.get(entry.accountCode());
            if(sums==null)issues.add(new Issue(entry.sourceRow(),"科目代码","原凭证科目"+entry.accountCode()+"在余额文件中缺失"));
            else {sums[0]=sums[0].add(entry.debit());sums[1]=sums[1].add(entry.credit());}
        }
        for(var row:balance.balances()){var sums=totals.get(row.accountCode());if(sums[0].compareTo(row.debit())!=0||sums[1].compareTo(row.credit())!=0)
            issues.add(new Issue(row.sourceRow(),"本期发生额","科目余额表的当期借贷发生额与完整凭证不一致"));}
        return List.copyOf(issues);
    }
    private static String text(DocumentGrid.Row row,int col){var cell=row.cell(col);return cell==null?"":cell.text().strip();}
    private static String required(DocumentGrid.Row row,int col,String label){String value=text(row,col);if(value.isEmpty()||value.length()>500)throw invalid(label+"缺失或过长");return value;}
    private static String literal(DocumentGrid.Row row,int col,String label){String value=required(row,col,label);if(row.cell(col).kind()!=DocumentGrid.CellKind.TEXT)throw invalid(label+"须保留原始文本及前导0");return value;}
    private static int integer(DocumentGrid.Row row,int col){try{return new BigDecimal(required(row,col,"数字身份")).intValueExact();}catch(ArithmeticException|NumberFormatException error){throw invalid("年度/期间/行号须为整数");}}
    private static int balanceMonth(DocumentGrid.Row row,int year) {
        String value=required(row,1,"会计期间");
        if(value.matches("[0-9]{1,2}(?:[.]0+)?"))return new BigDecimal(value).intValueExact();
        var match=Pattern.compile("^月份[：:]\\s*([0-9]{4})[.]([0-9]{1,2})-([0-9]{4})[.]([0-9]{1,2})$").matcher(value);
        try{
            if(!match.matches()||Integer.parseInt(match.group(1))!=year||!match.group(1).equals(match.group(3))||Integer.parseInt(match.group(2))!=Integer.parseInt(match.group(4)))
                throw invalid("原会计期间须是同一年度的一个完整月份");
            return Integer.parseInt(match.group(2));
        }catch(NumberFormatException error){throw invalid("会计期间年份或月份须为有效数字");}
    }
    private static BigDecimal number(DocumentGrid.Row row,int col){var value=nullableNumber(row,col,true);return value==null?BigDecimal.ZERO:value;}
    private static BigDecimal nullableNumber(DocumentGrid.Row row,int col,boolean book){String value=text(row,col);if(value.isBlank())return null;try{var amount=new BigDecimal(value);return book?com.uten.imp.common.util.FinancialExactAmount.book(amount,"原账套本币金额"):com.uten.imp.common.util.FinancialExactAmount.require(amount,"原账套原币/汇率");}catch(NumberFormatException error){throw invalid("金额须为原始精确数字，不能静默舍入");}}
    private static String message(RuntimeException error){return error instanceof ApiException?error.getMessage():"原始值格式不正确";}
    private static ApiException invalid(String message){return new ApiException(ErrorCode.VALIDATION_FAILED,message);}
}
