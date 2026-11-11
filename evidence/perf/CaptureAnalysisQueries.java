package remediation.perf;

import com.uten.imp.features.production.analysis.MaterialAnalysisService;
import jakarta.persistence.EntityManager;
import jakarta.persistence.Query;
import java.nio.file.*;
import java.nio.charset.StandardCharsets;
import java.util.*;
import org.springframework.test.util.ReflectionTestUtils;
import static org.mockito.Mockito.*;
import static org.mockito.ArgumentMatchers.*;

/** Capture actual unchanged private query builders without changing data or invoking a business command. */
public class CaptureAnalysisQueries {
    public static void main(String[] args)throws Exception {
        Path out=Path.of(args[0]);Files.createDirectories(out);
        var captured=new ArrayList<String>();EntityManager em=mock(EntityManager.class);Query query=mock(Query.class);
        when(em.createNativeQuery(anyString())).thenAnswer(call->{captured.add(call.getArgument(0));return query;});
        when(query.setParameter(anyString(),any())).thenReturn(query);when(query.getResultList()).thenReturn(List.of());
        var service=mock(MaterialAnalysisService.class,CALLS_REAL_METHODS);ReflectionTestUtils.setField(service,"em",em);
        UUID id=UUID.fromString("ed1c28cd-39f9-442d-8c17-5ff79caf2806");
        ReflectionTestUtils.invokeMethod(service,"loadSourceLines",id,false);
        if(captured.size()!=1)throw new AssertionError("Expected one actual source read");
        Files.writeString(out.resolve("load-source-lines.sql"),captured.removeFirst(),StandardCharsets.UTF_8,StandardOpenOption.CREATE_NEW);
        ReflectionTestUtils.invokeMethod(service,"downstreamReferences",id);
        if(captured.size()!=2)throw new AssertionError("Expected both actual downstream reads");
        for(int i=0;i<captured.size();i++)Files.writeString(out.resolve("downstream-"+i+".sql"),captured.get(i),StandardCharsets.UTF_8,StandardOpenOption.CREATE_NEW);
        System.out.println("Captured original loadSourceLines and both downstreamReferences SQL builders");
    }
}
