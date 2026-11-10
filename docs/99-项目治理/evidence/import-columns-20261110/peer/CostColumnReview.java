
import org.apache.poi.xssf.usermodel.XSSFWorkbook;
import java.io.ByteArrayOutputStream;
import java.util.UUID;
import com.uten.imp.features.master.goods.costing.GoodsCostWorkbookParser;
public class CostColumnReview {
 static byte[] file(boolean hidden) throws Exception {
  try(var w=new XSSFWorkbook();var out=new ByteArrayOutputStream()) {
   var s=w.createSheet("cost");var h=s.createRow(0);
   String[] names={"材料名称","用量","单价","运输费用"};
   for(int i=0;i<names.length;i++)h.createCell(i).setCellValue(names[i]);
   var r=s.createRow(1);r.createCell(0).setCellValue("铜料");r.createCell(1).setCellValue(1);r.createCell(2).setCellValue(2);r.createCell(3).setCellValue(99);
   s.setColumnHidden(3,hidden);w.write(out);return out.toByteArray();
  }
 }
 public static void main(String[] args) throws Exception {
  for(boolean hidden:new boolean[]{false,true}) try {
   var p=GoodsCostWorkbookParser.parse(UUID.randomUUID(),"cost.xlsx","a".repeat(64),file(hidden));
   System.out.println("hidden="+hidden+" ACCEPTED blocks="+p.blocks().size()+" warnings="+p.warnings());
  } catch(Exception e) {System.out.println("hidden="+hidden+" REJECTED "+e.getMessage());}
 }
}
