package com.uten.imp.features.finance.gl;
import java.util.*;
import java.nio.file.*;
import java.io.*;
import java.util.zip.*;
import java.util.concurrent.atomic.*;
import com.uten.imp.common.export.*;
import org.apache.poi.hssf.usermodel.HSSFWorkbook;
import org.xml.sax.Attributes;
import org.xml.sax.helpers.DefaultHandler;
import static org.assertj.core.api.Assertions.*;
import org.junit.platform.launcher.core.*;
import org.junit.platform.launcher.listeners.*;
import static org.junit.platform.engine.discovery.DiscoverySelectors.*;
public class ExtraAudit {
 static Path dir=Path.of(System.getProperty("audit.dir")),tmp=Path.of(System.getProperty("java.io.tmpdir"));
 static void voucher()throws Exception {
   var m=FinanceAccountingWorkbookParserTest.class.getDeclaredMethod("journals",boolean.class,boolean.class);
   m.setAccessible(true);byte[] data=(byte[])m.invoke(null,false,false);
   for (String kind:List.of("style","empty-formula","unknown-value","wrong-signature")) {
     try (var book=new HSSFWorkbook(new ByteArrayInputStream(data));var bytes=new ByteArrayOutputStream()) {
       var s=book.getSheetAt(0);
       if(kind.equals("wrong-signature")) s.getRow(0).getCell(82).setCellValue("合成无关签名");
       else {
         var cell=s.getRow(1).createCell(83);
         if(kind.equals("empty-formula")) {cell.setCellFormula("IF(1=1,\"\",\"x\")");book.getCreationHelper().createFormulaEvaluator().evaluateFormulaCell(cell);}
         if(kind.equals("unknown-value"))cell.setCellValue("需核对");
         if(kind.equals("style"))cell.setCellStyle(book.createCellStyle());
       }
       book.write(bytes);Files.write(dir.resolve("voucher-"+kind+".xls"),bytes.toByteArray());
       try {var p=FinanceAccountingWorkbookParser.parse("VOUCHERS","voucher.xls",bytes.toByteArray());
         System.out.println("voucher="+kind+" accepted issues="+p.issues().size()+" entries="+p.vouchers().getFirst().entries().size()+" version="+p.columnContractVersion());
       } catch(com.uten.imp.common.web.ApiException e){System.out.println("voucher="+kind+" blocked="+e.getMessage());}
     }
   }
 }
 static void large()throws Exception {
   var writer=new XlsxExportService(); var cols=List.of(new ExportColumn("code","源行号",ExportColumn.TEXT));int total=1_048_600;
   long start=System.nanoTime();List<String> before;
   try(var j=Files.list(tmp)){before=j.map(p->p.getFileName().toString()).sorted().toList();}
   var workbook=writer.buildSource(()->{
     for(int i=0;i<total;i+=200){
       var batch=new ArrayList<Map<String,Object>>();for(int j=i;j<Math.min(total,i+200);j++)batch.add(Map.of("code","R"+j));
       ExportPageSink.current().accept(new ExportPayload(cols,batch,i+batch.size()));}
     return new ExportPayload(cols,List.of(),total);
   },null,null);
   long writeMs=(System.nanoTime()-start)/1000000;start=System.nanoTime();
   Path f=dir.resolve("full-1048600.xlsx");Files.write(f,workbook.bytes());
   var n=new AtomicInteger();int sheets=0;
   try(var z=new ZipFile(f.toFile())) {
     for(int s=1;z.getEntry("xl/worksheets/sheet"+s+".xml")!=null;s++) {
       sheets++; var factory=javax.xml.parsers.SAXParserFactory.newInstance();factory.setFeature("http://apache.org/xml/features/disallow-doctype-decl",true);
       var handler=new DefaultHandler(){StringBuilder cell;int row=0;
         public void startElement(String u,String l,String tag,Attributes a){if(tag.equals("row"))row++;if(tag.equals("t"))cell=new StringBuilder();}
         public void characters(char[] ch,int st,int len){if(cell!=null)cell.append(ch,st,len);}
         public void endElement(String u,String l,String tag){if(!tag.equals("t"))return; if(row==1)assertThat(cell.toString()).isEqualTo("源行号");else assertThat(cell.toString()).isEqualTo("R"+n.getAndIncrement());cell=null;}
       };
       try(var in=z.getInputStream(z.getEntry("xl/worksheets/sheet"+s+".xml"))){factory.newSAXParser().parse(in,handler);}
     }
   }
   assertThat(n.get()).isEqualTo(total);assertThat(sheets).isEqualTo(2);
   long verifyMs=(System.nanoTime()-start)/1000000;
   try{writer.buildSource(()->{ ExportPageSink.current().accept(new ExportPayload(cols,List.of(Map.of("code","R0")),1));throw new java.util.concurrent.CancellationException(); },null,null);throw new AssertionError("partial workbook escaped");}
   catch(java.util.concurrent.CancellationException expected){ }
   List<String> after;try(var j=Files.list(tmp)){after=j.map(p->p.getFileName().toString()).filter(p->p.startsWith("uten-table-sync-")).sorted().toList();}
   assertThat(after).isEmpty();
   System.out.println("AUDIT_REAL_XLSX sequenceVerified="+n+" sheets="+sheets+" finalRow=R1048599 fileBytes="+Files.size(f)+" writerMillis="+writeMs+" verificationMillis="+verifyMs+" cancelledFilePublished=false leftoverUtenTableTempDirs="+after.size());
 }
 public static void main(String[] args)throws Exception{
   voucher();large();
   var listener=new SummaryGeneratingListener();var launcher=LauncherFactory.create(); launcher.registerTestExecutionListeners(listener);
   launcher.execute(LauncherDiscoveryRequestBuilder.request().selectors(selectClass("com.uten.imp.common.export.BoundedDocumentExportServiceTest"),selectClass("com.uten.imp.common.export.LegacyExportBudgetTest")).build());
   var result=listener.getSummary();result.printTo(new PrintWriter(System.out,true));result.printFailuresTo(new PrintWriter(System.out,true));if(!result.getFailures().isEmpty())throw new AssertionError();
 }
}
