package com.uten.imp.features.master.goods.importing;
import java.io.*;
import java.nio.file.*;
import java.util.*;
import org.apache.poi.xssf.usermodel.XSSFWorkbook;
public class GoodsSheetsAudit {
 public static void main(String[] args)throws Exception {
   var fixture=GoodsImportPlanSafetyTest.class.getDeclaredMethod("fixtures");fixture.setAccessible(true);
   var object=fixture.invoke(null);var field=object.getClass().getDeclaredMethod("service");field.setAccessible(true);
   var service=(GoodsImportService)field.invoke(object);
   var input=GoodsImportPlanSafetyTest.class.getDeclaredMethod("workbook",String.class,String.class,String.class,String.class,String.class);input.setAccessible(true);
   byte[] base=(byte[])input.invoke(null,"","合成货品","成品","红色","个");
   for(boolean second:List.of(false,true))try(var book=new XSSFWorkbook(new ByteArrayInputStream(base));var output=new ByteArrayOutputStream()){
      var sheet=second?book.createSheet("第二张货品"):book.getSheetAt(0);
      if(second){sheet.createRow(0);sheet.createRow(1);}
      sheet.getRow(0).createCell(5).setCellValue("新增列");sheet.getRow(1).createCell(5).setCellValue("合成需核对");
      book.write(output);Files.write(Path.of(System.getProperty("audit.dir"),"goods-extra-second-"+second+".xlsx"),output.toByteArray());
      var result=service.detect(output.toByteArray());
      System.out.println("goods_unknown_in_second_sheet="+second+" issues="+result.errors().size()+" hasExecutablePlan="+(result.planId()!=null)+" sourceRows="+result.totalRows());
   }
 }
}
