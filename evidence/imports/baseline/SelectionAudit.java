package audit;
import java.util.*;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.features.master.export.MasterReportExportSource;
import com.uten.imp.features.reporting.export.ReportExportRequest;
import static org.mockito.Mockito.*;
public class SelectionAudit {
 public static void main(String[] args)throws Exception {
   var mapper=new ObjectMapper();var adapter=new MasterReportExportSource(null,null,null,null,null,null,null,null,null,null,mapper,mock(jakarta.validation.Validator.class));
   for (int n:List.of(50000,50001)){
      var ids=java.util.stream.IntStream.rangeClosed(1,n).mapToObj(i->new UUID(1,i).toString()).toList();
      var list=mapper.writeValueAsString(ids);
      var request=new ReportExportRequest(UUID.randomUUID(),"master","mould",Map.of("filter","{}","selectedIds",list),null,null,null);
      try{adapter.validate(request);System.out.println("selectedIds="+n+" encodedIdsBytes="+list.getBytes(java.nio.charset.StandardCharsets.UTF_8).length+" bodyBytes="+mapper.writeValueAsBytes(request).length+" valid=true");}
      catch(com.uten.imp.common.web.ApiException e){System.out.println("selectedIds="+n+" encodedIdsBytes="+list.getBytes(java.nio.charset.StandardCharsets.UTF_8).length+" bodyBytes="+mapper.writeValueAsBytes(request).length+" valid=false reason="+e.getMessage());}
   }
 }
}
