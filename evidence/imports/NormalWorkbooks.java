package audit;
import java.nio.file.*;
import java.io.*;
import org.apache.poi.ss.usermodel.*;
public class NormalWorkbooks {
    public static void main(String[] args)throws Exception {
        Path base=Path.of(args[0]);Files.createDirectories(base.resolve("web-fixtures"));
        for(String kind:new String[]{"chart","cost","goods","bom","note"}) {
            String source=switch(kind){case "chart"->"chart-true.xlsx";case "cost"->"cost-title-true.xlsx";case "goods"->"goods-extra-second-true.xlsx";case "bom"->"bom-extra-second-true.xlsx";default->"note-duplicate.xlsx";};
            try(var in=Files.newInputStream(base.resolve("baseline").resolve(source));var book=WorkbookFactory.create(in);var out=new ByteArrayOutputStream()) {
                var sheet=book.getSheetAt(0);
                if(kind.equals("chart")){for(var row:sheet)if(row.getCell(3)!=null)row.removeCell(row.getCell(3));sheet.getRow(1).getCell(0).setCellValue("100199991");sheet.getRow(1).getCell(1).setCellValue("合成导入现金核查");}
                if(kind.equals("cost")){for(var row:sheet)if(row.getCell(3)!=null)row.removeCell(row.getCell(3));}
                if(kind.equals("goods")||kind.equals("bom"))while(book.getNumberOfSheets()>1)book.removeSheetAt(1);
                if(kind.equals("note")){sheet.getRow(1).getCell(3).setCellValue(com.uten.imp.features.finance.gl.FinanceTemplateContract.header("operatingProfit",3));sheet.getRow(3).getCell(28).setCellValue("本地真实网页导入核验备注");}
                book.write(out);Files.write(base.resolve("web-fixtures").resolve(kind+"-legal.xlsx"),out.toByteArray());
            }
        }
    }
}
