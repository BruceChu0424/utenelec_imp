package com.uten.imp.features.finance.gl;
import java.io.*;import java.nio.file.*;import java.util.*;
import org.apache.poi.hssf.usermodel.HSSFWorkbook;
import org.apache.poi.xssf.usermodel.XSSFWorkbook;
/** Local file construction/format check only; no Spring, database, preview or import API. */
public class PrepareRootWebAccountingPair {
 public static void main(String[] args)throws Exception {
  Path dir=Path.of(args[0]);Files.createDirectories(dir);var period=args.length>1?java.time.YearMonth.parse(args[1]):java.time.YearMonth.of(2026,11);String suffix=period.toString().replace("-","");
  String[] codes={"19019991","39019991"},names={"B网页接续合成资产","B网页接续合成权益"};
  byte[] vouchers,balances,chart;
  try(var book=new HSSFWorkbook();var out=new ByteArrayOutputStream()){
   var sheet=book.createSheet("凭证");var header=sheet.createRow(0);
   for(int col=0;col<82;col++)header.createCell(col).setCellValue("F"+(col+1)+"原字段");header.createCell(82).setCellValue("凭证输出：V800：BUI01：B网页合成验收：2026");
   for(int line=0;line<2;line++){
    var row=sheet.createRow(line+1);Map<Integer,String> text=Map.of(0,period.atDay(1).toString(),1,"记",2,"BUI0001",4,"合成验收：完整"+period.getMonthValue()+"月仅此一笔权益投入",5,codes[line],48,"BUI01",49,"B网页合成验收",61,names[line]);text.forEach((c,v)->row.createCell(c).setCellValue(v));
    row.createCell(line==0?6:7).setCellValue(100);row.createCell(50).setCellValue(period.getYear());row.createCell(51).setCellValue(period.getMonthValue());row.createCell(58).setCellValue(line+1);row.createCell(80).setCellValue(line+1);row.createCell(81).setCellValue(1);
   }book.write(out);vouchers=out.toByteArray();
  }
  try(var book=new HSSFWorkbook();var out=new ByteArrayOutputStream()){
   var sheet=book.createSheet("科目余额");var header=sheet.createRow(0);String[] labels={"会计年度","会计期间","科目编码","科目名称","外币名称","期初借方","期初贷方","本期发生借方","本期发生贷方","期末借方","期末贷方"};
   for(int c=0;c<labels.length;c++)header.createCell(c).setCellValue(labels[c]);
   double[][] amounts={{0,0,100,0,100,0},{0,0,0,100,0,100}};
   for(int i=0;i<2;i++){var row=sheet.createRow(i+1);row.createCell(0).setCellValue(period.getYear());row.createCell(1).setCellValue("月份："+period.toString().replace('-','.')+"-"+period.toString().replace('-','.'));row.createCell(2).setCellValue(codes[i]);row.createCell(3).setCellValue(names[i]);row.createCell(4).setCellValue("");for(int c=0;c<6;c++)row.createCell(c+5).setCellValue(amounts[i][c]);}book.write(out);balances=out.toByteArray();
  }
  try(var book=new XSSFWorkbook();var out=new ByteArrayOutputStream()){
   var sheet=book.createSheet("科目目录"+period);var h=sheet.createRow(0);h.createCell(0).setCellValue("科目编码");h.createCell(1).setCellValue("科目名称");h.createCell(2).setCellValue("外币名称");for(int i=0;i<2;i++){var row=sheet.createRow(i+1);row.createCell(0).setCellValue(codes[i]);row.createCell(1).setCellValue(names[i]);}book.write(out);chart=out.toByteArray();
  }
  var v=FinanceAccountingWorkbookParser.parse("VOUCHERS","legal-vouchers.xls",vouchers);var b=FinanceAccountingWorkbookParser.parse("BALANCE","legal-balances.xls",balances);var c=FinanceChartWorkbookParser.parse(UUID.randomUUID(),"legal-chart.xlsx","local-format-check",chart);
  if(!v.issues().isEmpty()||!b.issues().isEmpty()||!c.issues().isEmpty()||!FinanceAccountingWorkbookParser.reconcile(v,b).isEmpty())throw new AssertionError("Local pair shape/reconciliation invalid");
  if(v.vouchers().size()!=1||v.vouchers().getFirst().entries().size()!=2||b.balances().size()!=2||v.vouchers().getFirst().closingCandidate())throw new AssertionError("Unexpected synthetic facts");
  Files.write(dir.resolve("legal-vouchers-"+suffix+".xls"),vouchers,StandardOpenOption.CREATE_NEW);Files.write(dir.resolve("legal-balances-"+suffix+".xls"),balances,StandardOpenOption.CREATE_NEW);Files.write(dir.resolve("legal-chart-"+suffix+".xlsx"),chart,StandardOpenOption.CREATE_NEW);
  var report=Map.of("status","prep: LOCAL FILE CONSTRUCTION/PARSER CHECK ONLY; no Root service/API preview, submit, approve or DB access","columnContractVersion",v.columnContractVersion(),"ledger","BUI01","company","B网页合成验收","period",period.toString(),"voucherKey",v.vouchers().getFirst().key(),"voucherCount",1,"entryCount",2,"debit","100","credit","100");
  Files.writeString(dir.resolve("local-format-check.json"),new tools.jackson.databind.ObjectMapper().writerWithDefaultPrettyPrinter().writeValueAsString(report),StandardOpenOption.CREATE_NEW);
  System.out.println("LOCAL_ONLY pair ready: 83 literal columns, 11 literal balance columns, two directory rows, zero openings, one operating voucher, debit=credit=100; ROOT_UNTOUCHED");
 }
}
