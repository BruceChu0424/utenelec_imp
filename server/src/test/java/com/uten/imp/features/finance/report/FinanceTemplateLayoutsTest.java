package com.uten.imp.features.finance.report;

import com.uten.imp.common.export.*;
import com.uten.imp.features.finance.gl.*;
import org.apache.poi.ss.usermodel.*;
import org.apache.poi.xssf.usermodel.XSSFWorkbook;
import org.junit.jupiter.api.Test;
import java.io.*;
import java.math.BigDecimal;
import java.util.*;
import static org.assertj.core.api.Assertions.*;

class FinanceTemplateLayoutsTest {
    @Test void balancePaperKeepsEightColumnsFiftyThreeLineNumbersBothSidesAndSourceBands()throws Exception {
        var facts=new ArrayList<Map<String,Object>>();
        FinanceTemplateContract.template("balanceSheet").path("rows").properties().forEach(entry->{
            int line;try{line=Integer.parseInt(entry.getKey());}catch(NumberFormatException failure){throw new IllegalArgumentException("Balance sheet contract row key is not numeric",failure);}facts.add(new LinkedHashMap<>(Map.of("lineNo",line,"item",entry.getValue().asText(),"periodEnd",BigDecimal.valueOf(line*100L),"yearStart",BigDecimal.valueOf(line*10L),"basis","匿名独立凭证")));
        });
        var source=new ReportTableResponse(List.of(),facts,Map.of(),1,53,53,1).withDocumentMetadata(Map.of("financialStatementContext",Map.of(
                "report","gl/balance-sheet","organizationName","匿名公司","organizationVersion",7,
                "dateFrom","2026-09-01","dateTo","2026-09-30","year",2026,"month",9)));
        var paper=FinancialStatementPresentation.apply("BALANCE","template",source);
        var columns=columns(paper);var query=Map.of("layout","template","dateTo","2026-09-30");
        var layout=FinanceTemplateLayouts.create("gl/balance-sheet",query,columns,paper.rows(),"匿名公司");
        var print=new com.fasterxml.jackson.databind.ObjectMapper().valueToTree(paper.documentMetadata()).path("paperLayout");
        assertThat(print.path("templateKey").asText()).isEqualTo("balanceSheet");
        assertThat(print.path("widths").size()).isEqualTo(8);
        for(int column=0;column<8;column++)assertThat(print.path("widths").path(column).asDouble()).isEqualTo(layout.widths().get(column));
        assertThat(print.path("bodyBands").size()).isEqualTo(7);
        assertThat(print.path("columnAlignments").path(1).asText()).isEqualTo("CENTER");
        assertThat(print.path("columnAlignments").path(2).asText()).isEqualTo("RIGHT");
        assertThat(print.path("footer").path("cells").path(0).path("value").asText()).contains("已归还投资");
        assertThat(print.path("headings").toString()).contains("匿名公司","2026年09月30日","会小企01表","单位：元");
        assertThat(print.path("keepWithNextRows").toString()).contains("25");
        String qaDirectory=System.getProperty("uten.finance.paper.qa-dir");
        if(qaDirectory!=null&&!qaDirectory.isBlank()){
            var directory=java.nio.file.Path.of(qaDirectory);java.nio.file.Files.createDirectories(directory);
            java.nio.file.Files.writeString(directory.resolve("synthetic-balance-paper.json"),new com.fasterxml.jackson.databind.ObjectMapper().writeValueAsString(paper),java.nio.file.StandardOpenOption.CREATE_NEW);
        }
        byte[] bytes=new XlsxExportService().build(new ExportPayload(columns,paper.rows(),32).withLayout(layout),null,null);
        try(var book=new XSSFWorkbook(new ByteArrayInputStream(bytes))) {
            var sheet=book.getSheetAt(0);assertThat(sheet.getSheetName()).isEqualTo("资产负债表");
            assertThat(sheet.getRow(0).getCell(0).getStringCellValue()).isEqualTo("资产负债表");
            assertThat(sheet.getRow(2).getCell(0).getStringCellValue()).isEqualTo("单位名称：匿名公司");
            assertThat(sheet.getRow(2).getCell(4).getStringCellValue()).isEqualTo("2026年09月30日");
            assertThat(sheet.getRow(2).getCell(6).getStringCellValue()).isEqualTo("单位：元");
            assertThat(sheet.getRow(3).getLastCellNum()).isEqualTo((short)8);
            assertThat(sheet.getRow(35).getCell(1).getStringCellValue()).isEqualTo("30");
            assertThat(sheet.getRow(35).getCell(5).getStringCellValue()).isEqualTo("53");
            assertThat(sheet.getRow(35).getCell(2).getNumericCellValue()).isEqualTo(3000);
            assertThat(sheet.getRow(4).getCell(0).getCellStyle().getFillForegroundColorColor().getARGBHex()).isEqualTo("FF808080");
            int grayCells=0;
            for(int row=4;row<36;row++)for(int column=0;column<8;column++) {
                var cell=sheet.getRow(row).getCell(column);if(cell==null)continue;
                var color=cell.getCellStyle().getFillForegroundColorColor();
                if(color!=null&&"FF808080".equals(color.getARGBHex()))grayCells++;
            }
            assertThat(grayCells).isEqualTo(7);
            assertThat(sheet.getRow(5).getCell(0).getStringCellValue()).startsWith("  ");
            assertThat(sheet.getRow(15).getCell(0).getStringCellValue()).startsWith("     ");
            assertThat(sheet.getRepeatingRows().formatAsString()).isEqualTo("1:4");
            assertThat(sheet.getPrintSetup().getPaperSize()).isEqualTo(PrintSetup.A4_PAPERSIZE);
            // Long original captions wrap at the original width and font. A
            // fixed 16pt row previously cut these captions across the border.
            for(int row:List.of(25,34,35))assertThat(sheet.getRow(row).getHeightInPoints()).isGreaterThan(layout.rowHeight());
            assertThat(sheet.getColumnWidth(0)).isEqualTo((int)Math.round(layout.widths().getFirst()*256));
            assertThat(book.getFontAt(sheet.getRow(25).getCell(0).getCellStyle().getFontIndex()).getFontHeightInPoints()).isEqualTo(layout.fontSize());
            assertThat(sheet.getRow(36).getCell(0).getStringCellValue()).contains("已归还投资");
            assertThat(sheet.getMergedRegions()).anySatisfy(region->assertThat(region.formatAsString()).isEqualTo("A1:H1"));
        }
    }
    @Test void financialPaperRejectsDifferentReportOrMissingCompanyRatherThanGuessingCurrentValues(){
        var wrong=new ReportTableResponse(List.of(),List.of(),Map.of(),1,1,0,0).withDocumentMetadata(Map.of("financialStatementContext",Map.of("report","gl/profit-monthly","organizationName","匿名公司")));
        assertThatThrownBy(()->FinanceTemplateLayouts.withFinancialPaper("BALANCE",wrong)).isInstanceOf(IllegalArgumentException.class);
        var missing=new ReportTableResponse(List.of(),List.of(),Map.of(),1,1,0,0).withDocumentMetadata(Map.of("financialStatementContext",Map.of("report","gl/balance-sheet","organizationName","")));
        assertThatThrownBy(()->FinanceTemplateLayouts.withFinancialPaper("BALANCE",missing)).isInstanceOf(IllegalArgumentException.class);
    }
    @Test void monthlyAndAnnualPaperKeepTheirOwnOriginalRowsColumnsAndCapturedPeriod()throws Exception{
        for(boolean annual:List.of(false,true)){
            String key=annual?"annualProfit":"monthlyProfit",report=annual?"gl/profit-annual":"gl/profit-monthly";
            var columns=new ArrayList<ReportColumn>();
            columns.add(ReportColumn.text("item",FinanceTemplateContract.header(key,0)));
            if(annual){
                for(int month=1;month<=12;month++)columns.add(ReportColumn.money("m"+month,FinanceTemplateContract.header(key,month)));
                columns.add(ReportColumn.money("yearTotal",FinanceTemplateContract.header(key,13)));
                columns.add(ReportColumn.number("profitRatio",FinanceTemplateContract.header(key,14)).withUnitLabel("%"));
            }else{
                columns.add(new ReportColumn("lineNo",FinanceTemplateContract.header(key,1),"int",65));
                columns.add(ReportColumn.money("yearAmount",FinanceTemplateContract.header(key,2)));
                columns.add(ReportColumn.money("monthAmount",FinanceTemplateContract.header(key,3)));
            }
            var rows=new ArrayList<Map<String,Object>>();
            for(var row:FinanceTemplateContract.template("monthlyProfit").path("rows").properties()){
                int number=Integer.parseInt(row.getKey());
                if(annual&&number==32)rows.add(syntheticProfitRow(33,FinanceTemplateContract.template("annualProfit").path("rows").path("33").asText(),true));
                rows.add(syntheticProfitRow(number,row.getValue().asText(),annual));
            }
            var context=Map.<String,Object>of("report",report,"organizationName","匿名公司","organizationVersion",7,"dateFrom","2026-09-01","dateTo","2026-09-30","year",2026,"month",9);
            var source=new ReportTableResponse(columns,rows,Map.of(),1,rows.size(),rows.size(),1).withDocumentMetadata(Map.of("financialStatementContext",context));
            var presented=FinancialStatementPresentation.apply(annual?"ANNUAL":"PROFIT","template",source);
            var paper=new com.fasterxml.jackson.databind.ObjectMapper().valueToTree(presented.documentMetadata()).path("paperLayout");
            assertThat(presented.rows()).hasSize(annual?21:20);
            assertThat(presented.columns()).hasSize(annual?15:4);
            assertThat(paper.path("templateKey").asText()).isEqualTo(key);
            assertThat(paper.path("headings").toString()).contains("匿名公司",annual?"2026年1至9月":"2026年09月");
            String qaDirectory=System.getProperty("uten.finance.paper.qa-dir");
            if(qaDirectory!=null&&!qaDirectory.isBlank()){
                var directory=java.nio.file.Path.of(qaDirectory);java.nio.file.Files.createDirectories(directory);
                java.nio.file.Files.writeString(directory.resolve(annual?"synthetic-annual-paper.json":"synthetic-monthly-paper.json"),new com.fasterxml.jackson.databind.ObjectMapper().writeValueAsString(presented),java.nio.file.StandardOpenOption.CREATE_NEW);
            }
        }
    }
    /** Geometry-only values; these rows are not a reconciled accounting book. */
    private static Map<String,Object> syntheticProfitRow(int number,String caption,boolean annual){
        var row=new LinkedHashMap<String,Object>();row.put("lineNo",number);row.put("item",caption);row.put("basis","匿名版式样例，不是实账勾稽");
        if(annual){for(int month=1;month<=12;month++){
            row.put("m"+month,month<=9?BigDecimal.ONE:null);
        }
        row.put("yearTotal",new BigDecimal("9"));if(number==32){
            row.put("profitRatio",new BigDecimal("19.5"));
        }
        row.put("__notApplicableMonths",List.of(10,11,12));}
        else{row.put("monthAmount",BigDecimal.ONE);row.put("yearAmount",new BigDecimal("9"));}
        return row;
    }
    @Test void groupedOriginalHeadersIgnoreLocalRenamingAndExactAmountsAndCashBookNotesRemainVisible()throws Exception {
        var columns=new ArrayList<ExportColumn>();for(int i=0;i<19;i++)columns.add(new ExportColumn("k"+i,FinanceTemplateContract.header("subcontractStatement",i),i==18?"money":"text"));
        String exact="12345678901234.0001";
        var rows=List.of(Map.<String,Object>of("k0","000017","k18",new BigDecimal(exact),"__basis","货款现金减账面差额=0.0001元"));
        var layout=FinanceTemplateLayouts.create("statements/subcontract",Map.of("dateFrom","2026-09-01","dateTo","2026-09-30"),columns,rows,"匿名公司");
        var projection=new TableColumnProjection("finance","view_finance",List.of(new TableColumnProjection.Column("k18","任意改名",50d,"money",null)));
        byte[] bytes=new XlsxExportService().build(new ExportPayload(columns,rows,1).withLayout(layout),projection,"view_finance");
        try(var book=new XSSFWorkbook(new ByteArrayInputStream(bytes))) {
            var sheet=book.getSheetAt(0);assertThat(sheet.getRow(layout.headerRow()).getLastCellNum()).isEqualTo((short)19);
            assertThat(sheet.getRow(layout.headerRow()+1).getCell(18).getCellType()).isEqualTo(CellType.STRING);
            assertThat(sheet.getRow(layout.headerRow()+1).getCell(18).getStringCellValue()).isEqualTo(exact);
            assertThat(sheet.getMergedRegions()).anySatisfy(region->assertThat(region.getFirstRow()).isGreaterThanOrEqualTo(layout.headerStartRow()));
            assertThat(book.getSheet("取数与核对").getRow(1).getCell(2).getStringCellValue()).contains("0.0001元");
        }
    }
    @Test void streamingPagesKeepHeaderOffsetProgressAndPercentagePointsWithoutMultiplyingAgain()throws Exception {
        var cols=List.of(new ExportColumn("item","项目","text"),new ExportColumn("m1","01月份","money",null,"元",null));
        var layout=new ExportTableLayout("匿名原表",2,2,List.of(new ExportTableLayout.Heading(0,0,"匿名原表",20,true,"CENTER")),
                List.of(new ExportTableLayout.Merge(0,0,0,1)),List.of(30d,18d),"宋体",(short)11,22,List.of(),List.of(),List.of(),false);
        var writer=new XlsxExportService().openStream(null,null);byte[] bytes;
        try(writer;var out=new ByteArrayOutputStream()) {
            writer.accept(new ExportPayload(cols,List.of(Map.of("item","比例","m1",new BigDecimal("14.25"),"__percentageKeys",List.of("m1"))),1).withLayout(layout));
            writer.accept(new ExportPayload(cols,List.of(Map.of("item","金额","m1",new BigDecimal("25.00"))),2).withLayout(layout));
            assertThat(writer.rowCount()).isEqualTo(2);writer.finish(out);bytes=out.toByteArray();
        }
        try(var book=new XSSFWorkbook(new ByteArrayInputStream(bytes))) {
            var sheet=book.getSheetAt(0);var formatter=new DataFormatter(Locale.CHINA);
            assertThat(sheet.getRow(3).getCell(1).getNumericCellValue()).isEqualTo(0.1425);
            assertThat(formatter.formatCellValue(sheet.getRow(3).getCell(1))).isEqualTo("14.25%");
            assertThat(formatter.formatCellValue(sheet.getRow(4).getCell(1))).isEqualTo("25.00");
        }
    }
    @Test void emptyDetailStillPrintsRealHeaderAndOpeningBalanceWithoutFabricatingAMovement()throws Exception {
        var cols=new ArrayList<ExportColumn>();for(int i=0;i<8;i++)cols.add(new ExportColumn("k"+i,FinanceTemplateContract.header("clientStatement",i),"text"));
        var metadata=Map.<String,Object>of("version",1,"title","匿名客户对账单","currencyName","人民币","footerLines",List.of(Map.of("key","closingBalance","label","历史未结：","value","125.00","basis","匿名原账","pending",false)));
        var layout=FinanceTemplateLayouts.create("statements/client",Map.of("dateTo","2026-09-30"),cols,List.of(),metadata,"匿名公司");
        byte[] bytes=new XlsxExportService().build(new ExportPayload(cols,List.of(),0).withLayout(layout).withDocumentMetadata(metadata),null,null);
        try(var book=new XSSFWorkbook(new ByteArrayInputStream(bytes))) {
            var sheet=book.getSheetAt(0);assertThat(sheet.getRow(0).getCell(0).getStringCellValue()).isEqualTo("匿名客户对账单");
            assertThat(sheet.getRow(96).getCell(0).getStringCellValue()).isEqualTo("历史未结：");
            assertThat(new DataFormatter(Locale.ROOT).formatCellValue(sheet.getRow(96).getCell(2))).isEqualTo("125.00");
            assertThat(sheet.getRow(layout.headerRow()+1).getCell(1).getCellType()).isEqualTo(CellType.BLANK);
        }
    }
    @Test void rightHandSourceCellsStayAtOriginalOffsetsAcrossStreamingPagesWithoutAddingMainColumns()throws Exception {
        var cols=new ArrayList<ExportColumn>();for(int i=0;i<10;i++)cols.add(new ExportColumn("k"+i,FinanceTemplateContract.header("otherReceivableStatement",i),i==9?"money":"text"));
        String exact="12345678901234.123456789012345678901234";
        var metadata=Map.<String,Object>of("canvasColumns",17,"sourceMainHeaderRow",3,"hiddenColumns",List.of(11,12,13,14,15,16),"supplementalWidths",List.of(5.5,24d,6.3,9d,7.7,9.8,11.6),"supplementalCells",List.of(
            Map.of("sourceCell","L4","value","名称","type","text","header",true),
            Map.of("sourceCell","P4","value","金额","type","text","header",true),
            Map.of("sourceCell","Q5","value",exact,"type","money"),
            Map.of("sourceCell","L12","value","名称","type","text","header",true),
            Map.of("sourceCell","N13","value","0.000000000123456789","type","qty")));
        var all=new ArrayList<Map<String,Object>>();for(int row=0;row<520;row++)all.add(Map.of("k0","原行"+row,"k9",new BigDecimal("1.23456789")));
        var layout=FinanceTemplateLayouts.create("statements/other-receivable",Map.of("dateTo","2026-09-30"),cols,all,metadata,"匿名公司");
        byte[] bytes;
        try(var writer=new XlsxExportService().openStream(null,null);var out=new ByteArrayOutputStream()){
            writer.accept(new ExportPayload(cols,all.subList(0,250),520).withLayout(layout));
            writer.accept(new ExportPayload(cols,all.subList(250,520),520).withLayout(layout));
            assertThat(writer.rowCount()).isEqualTo(520);writer.finish(out);bytes=out.toByteArray();
        }
        try(var book=new XSSFWorkbook(new ByteArrayInputStream(bytes))){
            var sheet=book.getSheetAt(0);var formatter=new DataFormatter(Locale.ROOT);int header=layout.headerRow();
            assertThat(cols).hasSize(10);assertThat(sheet.getRow(header).getLastCellNum()).isEqualTo((short)10);
            assertThat(sheet.getRow(header+1).getCell(11).getStringCellValue()).isEqualTo("名称");
            assertThat(sheet.getRow(header+2).getCell(16).getStringCellValue()).isEqualTo(exact);
            assertThat(sheet.getRow(header+9).getCell(11).getStringCellValue()).isEqualTo("名称");
            assertThat(formatter.formatCellValue(sheet.getRow(header+10).getCell(13))).isEqualTo("0.000000000123456789");
            assertThat(sheet.getRow(header+520).getCell(0).getStringCellValue()).isEqualTo("原行519");
            assertThat(formatter.formatCellValue(sheet.getRow(header+520).getCell(9))).isEqualTo("1.23456789");
            assertThat(book.getPrintArea(0)).contains("$Q$");
            assertThat(sheet.isColumnHidden(10)).isFalse();
            for(int col=11;col<=16;col++)assertThat(sheet.isColumnHidden(col)).isTrue();
            assertThat(sheet.getColumnWidth(10)).isEqualTo(1408);
            assertThat(sheet.getColumnWidth(11)).isEqualTo(6144);
            assertThat(sheet.getMergedRegions()).anySatisfy(region->assertThat(region.formatAsString()).isEqualTo("A1:J1"));
        }
    }
    @Test void emptyMainStatementKeepsUnlabelledRightHandValuesAndMainFooterWithoutInventingTaxHeaders()throws Exception {
        var cols=new ArrayList<ExportColumn>();for(int i=0;i<10;i++)cols.add(new ExportColumn("k"+i,FinanceTemplateContract.header("otherReceivableStatement",i),"text"));
        var pending=new LinkedHashMap<String,Object>();pending.put("sourceCell","Q5");pending.put("value",null);pending.put("type","money");
        var metadata=Map.<String,Object>of("canvasColumns",17,"sourceMainHeaderRow",3,"supplementalCells",List.of(
            pending,Map.of("sourceCell","L12","value","名称","type","text","header",true)),
            "footerLines",List.of(Map.of("key","closingBalance","label","期末结余","value","待核对","pending",true)));
        var layout=FinanceTemplateLayouts.create("statements/other-receivable",Map.of("dateTo","2026-09-30"),cols,List.of(),metadata,"匿名公司");
        byte[] bytes=new XlsxExportService().build(new ExportPayload(cols,List.of(),0).withLayout(layout),null,null);
        try(var book=new XSSFWorkbook(new ByteArrayInputStream(bytes))){
            var sheet=book.getSheetAt(0);int header=layout.headerRow();
            assertThat(sheet.getRow(42).getCell(0).getStringCellValue()).isEqualTo("期末结余");
            assertThat(sheet.getRow(42).getCell(4).getStringCellValue()).isEqualTo("待核对");
            assertThat(sheet.getRow(header+2).getCell(16).getCellType()).isEqualTo(CellType.BLANK);
            assertThat(sheet.getRow(header+9).getCell(11).getStringCellValue()).isEqualTo("名称");
            assertThat(sheet.getRow(header+1).getCell(16)).isNull();
            assertThat(sheet.getMergedRegions()).anySatisfy(region->assertThat(region.formatAsString()).isEqualTo("E43:F43"));
        }
    }
    @Test void quantityAndMixedUnitSourceFormsDoNotAcquireAGlobalYuanHeadingInSerializedXlsx()throws Exception {
        var cases=List.of(
                new String[]{"cost/copper-fee","copperFee","","2","3"},
                new String[]{"cost/copper-pickling","copperDetail","","3","4"},
                new String[]{"cost/plastic","plasticUsage","","1","2"},
                new String[]{"cost/plastic-detail","plasticIssue","issue","3","6"},
                new String[]{"cost/plastic-detail","plasticReturn","return","4","5"},
                new String[]{"cost/plastic-detail","plasticFinished","finished","4","7"});
        String exact="12345678901234.123456789012345678901234";
        for(var item:cases){
            var source=FinanceTemplateContract.template(item[1]);int quantity=Integer.parseInt(item[4]);
            var cols=new ArrayList<ExportColumn>();var row=new LinkedHashMap<String,Object>();
            for(int index=0;index<source.path("headers").size();index++){
                cols.add(new ExportColumn("k"+index,FinanceTemplateContract.header(item[1],index),index==quantity?"number":"text",null,index==quantity?"KG":null,null));
                row.put("k"+index,index==quantity?new BigDecimal(exact):"");
            }
            row.put("k"+item[3],item[1].equals("copperFee")?"只":"匿名材料");
            var query=new LinkedHashMap<>(Map.of("dateFrom","2026-09-01","dateTo","2026-09-30"));
            if(!item[2].isEmpty())query.put("kind",item[2]);
            var rows=List.<Map<String,Object>>of(row);var layout=FinanceTemplateLayouts.create(item[0],query,cols,rows,"匿名公司");
            byte[] bytes=new XlsxExportService().build(new ExportPayload(cols,rows,1).withLayout(layout),null,null);
            try(var book=new XSSFWorkbook(new ByteArrayInputStream(bytes))){
                var sheet=book.getSheetAt(0);var formatter=new DataFormatter(Locale.ROOT);
                assertThat(sheet.getRow(1).getCell(cols.size()-1)).as(item[1]+" global unit").isNull();
                assertThat(sheet.getRow(layout.headerRow()).getLastCellNum()).as(item[1]+" header count").isEqualTo((short)cols.size());
                assertThat(formatter.formatCellValue(sheet.getRow(layout.headerRow()+1).getCell(quantity))).as(item[1]+" exact quantity").isEqualTo(exact);
                assertThat(sheet.getRow(layout.headerRow()+1).getCell(Integer.parseInt(item[3])).getStringCellValue()).isEqualTo(item[1].equals("copperFee")?"只":"匿名材料");
                for(int index=0;index<cols.size();index++){
                    int headerRow=layout.headerRow(),headerColumn=index;
                    for(var merge:sheet.getMergedRegions())if(merge.isInRange(headerRow,headerColumn)){headerRow=merge.getFirstRow();headerColumn=merge.getFirstColumn();break;}
                    assertThat(sheet.getRow(headerRow).getCell(headerColumn).getStringCellValue()).as(item[1]+" header "+index).isEqualTo(cols.get(index).label());
                }
            }
        }
    }
    private static List<ExportColumn> columns(ReportTableResponse report){return report.columns().stream().map(column->new ExportColumn(column.key(),column.label(),column.type(),null,column.unitLabel(),column.unitKey())).toList();}
}
