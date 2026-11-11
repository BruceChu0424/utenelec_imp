package remediation;

import java.nio.charset.StandardCharsets;
import java.nio.file.*;
import java.sql.*;
import java.util.*;
import static org.assertj.core.api.Assertions.*;

/** Exercise the server-prepared generic plan rather than relying only on a custom constant plan. */
public class PreparedSelectionProbe {
    public static void main(String[] args)throws Exception {
        Path out=Path.of(args[1]);
        try(var connection=DriverManager.getConnection(args[0],"test","local-d3-only")) {
            try(var settings=connection.createStatement()){settings.execute("SET plan_cache_mode=force_generic_plan");}
            try(var statement=connection.prepareStatement("SELECT count(*) FROM selection_probe WHERE owner_id=? AND code LIKE ? AND id = ANY(?)")) {
                ((org.postgresql.PGStatement)statement).setPrepareThreshold(1);
                var array=connection.createArrayOf("uuid",SelectionPredicateProbe.IDS.toArray(UUID[]::new));
                long started=System.nanoTime();
                for(int attempt=0;attempt<10;attempt++) {
                    SelectionPredicateProbe.bind(statement,array,SelectionPredicateProbe.OWNER,"SEL-%");
                    try(var result=statement.executeQuery()){assertThat(result.next()).isTrue();assertThat(result.getInt(1)).isEqualTo(50001);}
                }
                System.out.println("D3_PREPARED_ANY repeats=10 countEach=50001 totalWallMs="+(System.nanoTime()-started)/1_000_000);
                String name;
                try(var query=connection.createStatement();var result=query.executeQuery("SELECT name,generic_plans,custom_plans FROM pg_prepared_statements WHERE statement LIKE 'SELECT count(*) FROM selection_probe%'")) {
                    assertThat(result.next()).isTrue();name=result.getString(1);assertThat(name).matches("S_[0-9]+");
                    assertThat(result.getLong(2)).isGreaterThanOrEqualTo(10);assertThat(result.getLong(3)).isZero();
                    System.out.println("D3_PREPARED_CACHE name="+name+" genericPlans="+result.getLong(2)+" customPlans="+result.getLong(3));
                }
                String ids=String.join(",",SelectionPredicateProbe.IDS.stream().map(UUID::toString).toList());
                try(var query=connection.createStatement();var result=query.executeQuery("EXPLAIN (ANALYZE,BUFFERS,FORMAT JSON) EXECUTE \""+name+"\"('"+SelectionPredicateProbe.OWNER+"'::uuid,'SEL-%','{"+ids+"}'::uuid[])")) {
                    assertThat(result.next()).isTrue();String plan=result.getString(1);
                    Files.writeString(out.resolve("any-force-generic-count-plan.json"),plan,StandardCharsets.UTF_8,StandardOpenOption.CREATE_NEW);
                    var json=new com.fasterxml.jackson.databind.ObjectMapper().readTree(plan).get(0);
                    System.out.println("D3_PREPARED_ANY_PLAN actualExecutionMs="+json.get("Execution Time")+" planningMs="+json.get("Planning Time"));
                }
                array.free();
            }
        }
    }
}
