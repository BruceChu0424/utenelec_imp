
import org.apache.poi.xssf.usermodel.XSSFWorkbook;
import org.apache.poi.ss.usermodel.CellType;
import java.io.*;import java.util.*;
import com.uten.imp.features.master.goods.costing.GoodsCostWorkbookParser;
import com.uten.imp.common.importing.PlatformWorkbookSchema;
public class CostBoundaryMatrix {
 static byte[] file(String kind) throws Exception {
  try(var w=new XSSFWorkbook(new ByteArrayInputStream(CostColumnReview.file(false)));var out=new ByteArrayOutputStream()) {
   var s=w.getSheetAt(0);
   if(!Set.of("unknownNoHeader","duplicate").contains(kind)) {s.getRow(0).removeCell(s.getRow(0).getCell(3));s.getRow(1).removeCell(s.getRow(1).getCell(3));}
   switch(kind) {
    case "unknownNoHeader" -> s.getRow(0).removeCell(s.getRow(0).getCell(3));
    case "duplicate" -> s.getRow(0).getCell(3).setCellValue(s.getRow(0).getCell(0).getStringCellValue());
    case "hiddenRow" -> {var r=s.createRow(2);r.createCell(0).setCellValue(s.getRow(1).getCell(0).getStringCellValue());r.createCell(1).setCellValue(1);r.createCell(2).setCellValue(99);r.setZeroHeight(true);}
    case "hiddenSheet" -> {w.cloneSheet(0);w.setSheetHidden(1,true);}
    case "hiddenFormulaBlank" -> {s.getRow(1).createCell(3).setCellFormula("\"\"");s.setColumnHidden(3,true);}
    case "styleOnlyHidden" -> {var r=s.createRow(2);r.createCell(0,CellType.BLANK);r.setZeroHeight(true);s.setColumnHidden(3,true);}
    case "emptyHiddenSheet" -> {w.createSheet("empty").createRow(0).createCell(0,CellType.BLANK);w.setSheetHidden(1,true);}
    case "markerHidden" -> {w.createSheet("empty");w.setSheetHidden(1,true);w.getProperties().getCustomProperties().addProperty(PlatformWorkbookSchema.PROPERTY,"{}");}
    case "knownReadOnly" -> {s.getRow(0).createCell(3).setCellValue("\u91d1\u989d");s.getRow(1).createCell(3).setCellValue(2);}
   }
   w.write(out);return out.toByteArray();
  }
 }
 public static void main(String[] args) throws Exception {
  for(String kind:List.of("clean","unknownNoHeader","duplicate","hiddenRow","hiddenSheet","hiddenFormulaBlank","styleOnlyHidden","emptyHiddenSheet","markerHidden","knownReadOnly")) {
   boolean accepted=false;String note="";
   try{var p=GoodsCostWorkbookParser.parse(UUID.randomUUID(),"cost.xlsx","a".repeat(64),file(kind));accepted=true;note="blocks="+p.blocks().size();}catch(Exception e){note=e.getClass().getSimpleName();}
   boolean expected=Set.of("clean","styleOnlyHidden","emptyHiddenSheet","knownReadOnly").contains(kind);
   System.out.println(kind+" accepted="+accepted+" expected="+expected+" "+note);
   if(accepted!=expected)throw new AssertionError(kind);
  }
 }
}
