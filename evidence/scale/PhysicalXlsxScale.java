package remediation;

import com.uten.imp.common.export.*;
import java.io.*;
import java.nio.file.*;
import java.util.*;
import java.util.concurrent.atomic.AtomicInteger;
import java.util.zip.ZipFile;
import org.xml.sax.Attributes;
import org.xml.sax.helpers.DefaultHandler;
import static org.assertj.core.api.Assertions.*;

/** Adapted in a new path from the preserved ExtraAudit.large; every physical output row is reread. */
public class PhysicalXlsxScale {
    public static void main(String[] args) throws Exception {
        Path out=Path.of(args[0]);Files.createDirectories(out);
        var writer=new XlsxExportService();
        var columns=List.of(new ExportColumn("code","源行号",ExportColumn.TEXT));
        int total=1_048_600;long start=System.nanoTime();
        var workbook=writer.buildSource(()->{
            for(int offset=0;offset<total;offset+=200) {
                var batch=new ArrayList<Map<String,Object>>();
                for(int row=offset;row<Math.min(total,offset+200);row++) batch.add(Map.of("code","R"+row));
                ExportPageSink.current().accept(new ExportPayload(columns,batch,offset+batch.size()));
            }
            return new ExportPayload(columns,List.of(),total);
        },null,null);
        long writeMs=(System.nanoTime()-start)/1000000;start=System.nanoTime();
        Path file=out.resolve("physical-1048600.xlsx");
        if(Files.exists(file))throw new IllegalStateException("Preserve the previous physical workbook");
        Files.write(file,workbook.bytes());
        var count=new AtomicInteger();int sheets=0;
        try(var zip=new ZipFile(file.toFile())) {
            for(int sheet=1;zip.getEntry("xl/worksheets/sheet"+sheet+".xml")!=null;sheet++) {
                sheets++;
                var factory=javax.xml.parsers.SAXParserFactory.newInstance();
                factory.setFeature("http://apache.org/xml/features/disallow-doctype-decl",true);
                var handler=new DefaultHandler(){
                    StringBuilder cell;int row;
                    public void startElement(String uri,String local,String tag,Attributes attributes){if(tag.equals("row"))row++;if(tag.equals("t"))cell=new StringBuilder();}
                    public void characters(char[] chars,int begin,int length){if(cell!=null)cell.append(chars,begin,length);}
                    public void endElement(String uri,String local,String tag){
                        if(!tag.equals("t"))return;
                        if(row==1)assertThat(cell.toString()).isEqualTo("源行号");
                        else assertThat(cell.toString()).isEqualTo("R"+count.getAndIncrement());
                        cell=null;
                    }
                };
                try(var input=zip.getInputStream(zip.getEntry("xl/worksheets/sheet"+sheet+".xml"))){factory.newSAXParser().parse(input,handler);}
            }
        }
        assertThat(count).hasValue(total);assertThat(sheets).isEqualTo(2);
        long readMs=(System.nanoTime()-start)/1000000;
        assertThatThrownBy(()->writer.buildSource(()->{
            ExportPageSink.current().accept(new ExportPayload(columns,List.of(Map.of("code","R0")),1));
            throw new java.util.concurrent.CancellationException("physical generation interrupted");
        },null,null)).isInstanceOf(java.util.concurrent.CancellationException.class);
        try(var files=Files.list(Path.of(System.getProperty("java.io.tmpdir")))) {
            assertThat(files.filter(p->p.getFileName().toString().startsWith("uten-table-sync-")).toList()).isEmpty();
        }
        System.out.println("D3_PHYSICAL_XLSX rows="+count+" sheets="+sheets+" last=R1048599 bytes="+Files.size(file)+" writerMs="+writeMs+" rereadMs="+readMs+" cancelledFilePublished=false leftoverTableTempDirs=0 file="+file.toAbsolutePath());
    }
}
