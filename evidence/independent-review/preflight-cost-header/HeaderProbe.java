package independent;
import org.apache.poi.xssf.usermodel.XSSFWorkbook;
import java.io.*;
import java.nio.file.*;
import java.util.*;
import com.uten.imp.features.master.goods.costing.GoodsCostWorkbookParser;

public class HeaderProbe {
  public static void main(String[] args) throws Exception {
    Path out=Path.of(args[0]);
    for(String variant:List.of("ordinary-control","reserved-name-control","mixed-header-tail","subtotal-name-control")) {
      try(var book=new XSSFWorkbook();var bytes=new ByteArrayOutputStream()) {
        var sheet=book.createSheet("成本");var header=sheet.createRow(0);
        for(int index=0;index<3;index++)header.createCell(index).setCellValue(List.of("材料名称","用量","单价").get(index));
        var first=sheet.createRow(1);first.createCell(0).setCellValue("铜钉");first.createCell(1).setCellValue(1);first.createCell(2).setCellValue(4);
        var second=sheet.createRow(2);
        second.createCell(0).setCellValue(variant.equals("ordinary-control")?"铜片":variant.equals("subtotal-name-control")?"小计数器件":"材料名称");
        second.createCell(1).setCellValue(1);second.createCell(2).setCellValue(4);
        if(variant.equals("mixed-header-tail"))second.createCell(3).setCellValue("数量");
        book.write(bytes);byte[] file=bytes.toByteArray();Files.write(out.resolve(variant+".xlsx"),file);
        try {
          var preview=GoodsCostWorkbookParser.parse(UUID.randomUUID(),variant+".xlsx","e".repeat(64),file);
          var rows=preview.blocks().stream().flatMap(block->block.rows().stream()).toList();
          System.out.println(variant+" ACCEPTED rows="+rows.size()+" names="+rows.stream().map(row->row.name()).toList()+" columnVersion="+preview.columnContractVersion());
        }catch(com.uten.imp.common.web.ApiException error){System.out.println(variant+" REJECTED code="+error.getCode()+" message="+error.getMessage());}
      }
    }
  }
}
