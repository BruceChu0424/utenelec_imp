package com.uten.imp.features.finance.gl;

import java.io.*;
import java.nio.file.*;
import java.util.*;
import org.apache.poi.xssf.usermodel.XSSFWorkbook;
import com.uten.imp.features.master.goods.costing.GoodsCostWorkbookParser;

// Each output is a genuine uploaded workbook processed by the product parser.
public class WorkbookAudit {
    static Path out = Path.of(System.getProperty("audit.dir"));
    public static void main(String[] args) throws Exception {
        for (boolean subtotal : List.of(false,true)) {
            try (var book = new XSSFWorkbook(); var bytes = new ByteArrayOutputStream()) {
                var s = book.createSheet("科目"); var h = s.createRow(0);
                String[] labels={"科目编码","科目名称","外币名称","追加约定"};
                for(int c=0;c<labels.length;c++) h.createCell(c).setCellValue(labels[c]);
                var row=s.createRow(1);row.createCell(0).setCellValue("1001");row.createCell(1).setCellValue("库存现金");
                var total=s.createRow(2);total.createCell(0).setCellValue("资产小计");
                (subtotal?total:row).createCell(3).setCellValue("合成保留值");
                book.write(bytes); Files.write(out.resolve("chart-"+subtotal+".xlsx"),bytes.toByteArray());
                var result=FinanceChartWorkbookParser.parse(UUID.randomUUID(),"chart.xlsx","synthetic",bytes.toByteArray());
                System.out.println("chart_extra_on_subtotal="+subtotal+" rows="+result.rows().size()+" issues="+result.issues().size()+" serverVersion="+result.columnContractVersion());
            }
        }
        for(String header:List.of("备注","自定义运费")) {
            byte[] bytes=FinanceOperatingNoteParserTest.book(s->{
                FinanceOperatingNoteParserTest.data(s,3,4,"原系统备注","");
                s.getRow(1).getCell(3).setCellValue(header); s.getRow(3).createCell(3).setCellValue("合成需核对");
            });
            Files.write(out.resolve(header.equals("备注")?"note-duplicate.xlsx":"note-unknown.xlsx"),bytes);
            var result=FinanceOperatingNoteParser.parse(UUID.randomUUID(),"2026-09","note.xlsx","synthetic",bytes,Map.of());
            System.out.println("note_inner_header="+header+" rows="+result.rows().size()+" issues="+result.issues().size()+" chooses="+result.rows().getFirst().remark()+" serverVersion="+result.columnContractVersion());
        }
        for (boolean withTitle : List.of(false,true)) {
            try(var book = new XSSFWorkbook();var bytes=new ByteArrayOutputStream()) {
                var s=book.createSheet("成本"); var h=s.createRow(0);String[] labels={"材料名称","用量","单价","运输费"};
                for(int c=0;c<labels.length;c++) h.createCell(c).setCellValue(labels[c]);
                var row=s.createRow(1);row.createCell(0).setCellValue("铜柱");row.createCell(1).setCellValue(1);row.createCell(2).setCellValue(2);
                var next=s.createRow(2);next.createCell(0).setCellValue("铜钉");
                next.createCell(1).setCellValue(1);next.createCell(2).setCellValue(4);next.createCell(3).setCellValue(withTitle?"产品名称：A":"需核对");
                book.write(bytes);Files.write(out.resolve("cost-title-"+withTitle+".xlsx"),bytes.toByteArray());
                try { var result=GoodsCostWorkbookParser.parse(UUID.randomUUID(),"cost.xlsx","synthetic",bytes.toByteArray());
                    System.out.println("cost_data_contains_title="+withTitle+" accepted blocks="+result.blocks().size()+" rows="+result.blocks().getFirst().rows().size()+" serverVersion="+result.columnContractVersion());
                } catch(com.uten.imp.common.web.ApiException rejected){ System.out.println("cost_data_contains_title="+withTitle+" rejected="+rejected.getMessage()); }
            }
        }
    }
}
