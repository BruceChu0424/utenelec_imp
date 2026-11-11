package com.uten.imp.features.master.goods.importing;
import com.uten.imp.features.master.goods.*;
import com.uten.imp.features.master.goods.dto.*;
import java.nio.file.*;import java.io.*;import java.util.*;
import org.apache.poi.xssf.usermodel.XSSFWorkbook;
import static org.mockito.Mockito.*;
public class BomAudit {
  public static void main(String[] args)throws Exception {
    var fixtures=new GoodsBomImportServiceTest();var m=fixtures.getClass().getDeclaredMethod("repoWithAllCodes");m.setAccessible(true);
    var repo=(GoodsRepository)m.invoke(fixtures);var k=fixtures.getClass().getDeclaredField("targetId");k.setAccessible(true);var target=(UUID)k.get(fixtures);
    var maker=fixtures.getClass().getDeclaredMethod("workbook",String[][].class);maker.setAccessible(true);
    var source=(byte[])maker.invoke(null,(Object)new String[][]{{"1","K01","1.2345"}});
    for(boolean second:List.of(false,true))try (var wb=new XSSFWorkbook(new ByteArrayInputStream(source));var bytes=new ByteArrayOutputStream()){
      var sheet=second?wb.createSheet("补充明细"):wb.getSheetAt(0);if(second){sheet.createRow(0);sheet.createRow(1);}
      sheet.getRow(0).createCell(5).setCellValue("自定义工序");sheet.getRow(1).createCell(5).setCellValue("需核对");
      wb.write(bytes); Files.write(Path.of(System.getProperty("audit.dir"),"bom-extra-second-"+second+".xlsx"),bytes.toByteArray());
      var paste=mock(GoodsBomPasteService.class);when(paste.pasteImported(any(),anySet(),anyMap())).thenReturn(new BomPasteResult(1,1,0,List.of(),List.of()));
      var service=new GoodsBomImportService(repo,paste);var report=service.detect(target,bytes.toByteArray());
      boolean reached=false;if(!report.hasErrors()){ service.commit(target,bytes.toByteArray(),BomPasteRequest.Mode.APPEND,report.stateFingerprint());verify(paste).pasteImported(any(),anySet(),anyMap());reached=true; }
      System.out.println("BOM unknown_on_second="+second+" issues="+report.errors().size()+" writeAdapterReached="+reached);
    }
  }
}
