package com.uten.imp.features.production.execution;

import com.fasterxml.jackson.databind.ObjectMapper;
import jakarta.persistence.EntityManager;
import jakarta.persistence.Query;
import org.hibernate.SessionFactory;
import org.hibernate.Session;
import org.hibernate.query.NativeQuery;
import org.mockito.Answers;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.core.namedparam.NamedParameterJdbcTemplate;
import org.springframework.jdbc.datasource.SingleConnectionDataSource;
import org.springframework.test.util.ReflectionTestUtils;
import java.nio.file.*;
import java.security.MessageDigest;
import java.sql.Connection;
import java.util.*;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.Mockito.*;

/** Reproducible diagnostic only. Reuses the exact compiled fixture/public SQL builder;
 * it never changes product source, a shared database, or global PostgreSQL settings. */
public class ExecutionReadPlanDiagnostic {
    static final ObjectMapper JSON=new ObjectMapper();
    record Read(String sql,Map<String,Object> parameters) { }
    public static void main(String[] args) throws Exception {
        boolean measure=args.length>0&&args[0].equals("--measure");
        Path output=Path.of(args.length>1?args[1]:"build/loading-validation/execution-plan-diagnostic");
        Files.createDirectories(output);
        Object realFactory=null;
        if(measure){ProductionExecutionWorkbenchQueryPostgresTest.startPostgres();realFactory=ReflectionTestUtils.getField(ProductionExecutionWorkbenchQueryPostgresTest.class,"factory");}
        try {
            List<Read> reads=new ArrayList<>();Session recorder=mock(Session.class);
            when(recorder.createNativeQuery(anyString())).thenAnswer(call->{
                Read read=new Read(call.getArgument(0),new LinkedHashMap<>());reads.add(read);
                return mock(NativeQuery.class,invocation->{
                    String name=invocation.getMethod().getName();
                    if(name.equals("setParameter")){Object parameterName=invocation.getArgument(0);read.parameters().put(String.valueOf(parameterName),invocation.getArgument(1));return invocation.getMock();}
                    if(name.equals("getSingleResult"))return 0L;
                    if(name.equals("getResultList"))return List.of();
                    return Answers.RETURNS_DEFAULTS.answer(invocation);
                });
            });
            SessionFactory factory=mock(SessionFactory.class);when(factory.createEntityManager()).thenReturn(recorder);
            ReflectionTestUtils.setField(ProductionExecutionWorkbenchQueryPostgresTest.class,"factory",factory);
            var fixture=new ProductionExecutionWorkbenchQueryPostgresTest();fixture.createService();
            var access=(com.uten.imp.features.production.ProductionDocumentAccessPolicy)ReflectionTestUtils.getField(fixture,"access");
            when(access.hasAuthority("production_execution:start")).thenReturn(true);
            var service=(ProductionExecutionWorkbenchService)ReflectionTestUtils.getField(fixture,"service");
            service.workshopTasks(1,50,null,"PREPARING",null,null,null,"DRAW_NOT_REQUESTED");
            JSON.writerWithDefaultPrettyPrinter().writeValue(output.resolve("captured-reads.json").toFile(),reads);
            if(!measure){System.out.println("capturedQueries="+reads.size());return;}
            var fixtureJdbc=(JdbcTemplate)ReflectionTestUtils.getField(ProductionExecutionWorkbenchQueryPostgresTest.class,"jdbc");
            fixtureJdbc.update("UPDATE production_execution_segments SET material_discovery_required=TRUE WHERE id=?",new UUID(0,2));
            fixtureJdbc.update("UPDATE v_production_execution_workbench_segments SET zero_material=TRUE WHERE segment_id=?",new UUID(0,2));
            try(Connection connection=Objects.requireNonNull(fixtureJdbc.getDataSource()).getConnection()){
                connection.setReadOnly(true);connection.setTransactionIsolation(Connection.TRANSACTION_REPEATABLE_READ);connection.setAutoCommit(false);
                var jdbc=new NamedParameterJdbcTemplate(new SingleConnectionDataSource(connection,true));
                var report=new LinkedHashMap<String,Object>();report.put("scope","Owned exact normalized execution fixture, same RR read-only connection/role/parameters, no company database");
                report.put("version",jdbc.queryForMap("SELECT version(),current_user,current_database()",Map.of()));
                report.put("fixtureRows",jdbc.queryForObject("SELECT count(*) FROM v_production_execution_workbench_segments",Map.of(),Long.class));
                List<Map<String,Object>> measurements=new ArrayList<>();
                for(int index=0;index<reads.size();index++){
                    Read read=reads.get(index);if(!read.sql().contains("v_production_execution_workbench_segments"))continue;
                    Map<String,Object> item=new LinkedHashMap<>();item.put("queryIndex",index);item.put("sqlSha256",hash(read.sql().getBytes(java.nio.charset.StandardCharsets.UTF_8)));item.put("sql",read.sql());item.put("parameters",read.parameters());
                    String reference=null;
                    for(String mode:List.of("on","off")){
                        try(var statement=connection.createStatement()){statement.execute("SET LOCAL jit="+mode);}
                        long started=System.nanoTime();
                        var rows=jdbc.queryForList(read.sql(),read.parameters());
                        double elapsed=(System.nanoTime()-started)/1_000_000.0;
                        String fingerprint=hash(JSON.writeValueAsBytes(rows));
                        if(reference==null)reference=fingerprint;else if(!reference.equals(fingerprint))throw new AssertionError("JIT changed read result");
                        String plan=jdbc.queryForObject("EXPLAIN (ANALYZE,BUFFERS,FORMAT JSON) "+read.sql(),read.parameters(),String.class);
                        var planPath=output.resolve("query-"+index+"-jit-"+mode+"-plan.json");Files.writeString(planPath,plan+System.lineSeparator());
                        item.put(mode,Map.of("rowCount",rows.size(),"rowFingerprintSha256",fingerprint,"queryMillis",elapsed,"plan",planPath.toString(),"planSha256",hash(Files.readAllBytes(planPath))));
                    }
                    measurements.add(item);System.out.println("measuredQuery="+index);
                }
                report.put("queries",measurements);JSON.writerWithDefaultPrettyPrinter().writeValue(output.resolve("receipt.json").toFile(),report);connection.rollback();
            }
        } finally {
            if(measure){ReflectionTestUtils.setField(ProductionExecutionWorkbenchQueryPostgresTest.class,"factory",realFactory);ProductionExecutionWorkbenchQueryPostgresTest.stopPostgres();}
        }
    }
    static String hash(byte[] bytes)throws Exception{return java.util.HexFormat.of().formatHex(MessageDigest.getInstance("SHA-256").digest(bytes));}
}
