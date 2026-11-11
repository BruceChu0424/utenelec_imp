package remediation;

import java.nio.charset.StandardCharsets;
import java.nio.file.*;
import java.math.BigDecimal;
import java.security.MessageDigest;
import java.sql.*;
import java.util.*;
import static org.assertj.core.api.Assertions.*;

/** Isolated operator comparison, not a business-service or ordinary-account acceptance claim. */
public class SelectionPredicateProbe {
    static final UUID OWNER=new UUID(11,1),OTHER=new UUID(11,2);
    static final List<UUID> IDS=java.util.stream.IntStream.range(0,50001).mapToObj(i->new UUID(1,i+1)).toList();
    record Result(int rows,BigDecimal sum,String orderHash,int denied,int filtered) { }
    public static void main(String[] args)throws Exception {
        Path out=Path.of(args[1]);Files.createDirectories(out);
        try(Connection connection=DriverManager.getConnection(args[0],"test","local-d3-only")) {
            try(var statement=connection.createStatement()) {
                statement.execute("CREATE TABLE selection_probe(id uuid PRIMARY KEY,code text NOT NULL,qty numeric NOT NULL,owner_id uuid NOT NULL)");
            }
            try(var statement=connection.prepareStatement("INSERT INTO selection_probe SELECT ('00000000-0000-0001-0000-'||lpad(to_hex(i+1),12,'0'))::uuid,'SEL-'||lpad(i::text,6,'0'),i+0.125,? FROM generate_series(0,50001) i")) {
                statement.setObject(1,OWNER);assertThat(statement.executeUpdate()).isEqualTo(50002);
            }
            try(var statement=connection.createStatement()){statement.execute("ANALYZE selection_probe");}
            Array ids=connection.createArrayOf("uuid",IDS.toArray(UUID[]::new));
            Result contains=run(connection,ids,"contains","? @> ARRAY[id]",out);
            Result any=run(connection,ids,"any","id = ANY(?)",out);
            assertThat(contains).isEqualTo(any);
            assertThat(any.rows()).isEqualTo(50001);assertThat(any.denied()).isZero();assertThat(any.filtered()).isZero();
            System.out.println("D3_PREDICATE_EQUIVALENCE realTableRows=50002 sameSelectedUuidCount=50001 selected=50001 excluded=1 permissionDenied=0 filterExcluded=0 sourceOrderAndExactQtyHash="+any.orderHash()+" exactSum="+any.sum().toPlainString()+" scalarBindMax=3 uuidArrayBinds=1");
            ids.free();
        }
    }
    static Result run(Connection connection,Array ids,String name,String predicate,Path out)throws Exception {
        String from=" FROM selection_probe WHERE owner_id=? AND code LIKE ? AND "+predicate;
        long started=System.nanoTime();
        try(var statement=connection.prepareStatement("EXPLAIN (ANALYZE,BUFFERS,FORMAT JSON) SELECT count(*)"+from)) {
            bind(statement,ids,OWNER,"SEL-%");
            try(var rows=statement.executeQuery()) {
                assertThat(rows.next()).isTrue();
                String plan=rows.getString(1);
                Files.writeString(out.resolve(name+"-count-plan.json"),plan,StandardCharsets.UTF_8,StandardOpenOption.CREATE_NEW);
                var json=new com.fasterxml.jackson.databind.ObjectMapper().readTree(plan).get(0);
                System.out.println("D3_PREDICATE_PLAN name="+name+" actualExecutionMs="+json.get("Execution Time")+" planningMs="+json.get("Planning Time")+" probeWallMs="+(System.nanoTime()-started)/1_000_000);
            }
        }
        MessageDigest digest=MessageDigest.getInstance("SHA-256");BigDecimal sum=BigDecimal.ZERO;int count=0;
        connection.setReadOnly(true);connection.setAutoCommit(false);started=System.nanoTime();
        try(var statement=connection.prepareStatement("SELECT code,qty"+from+" ORDER BY qty DESC,code,id")) {
            statement.setFetchSize(1000);bind(statement,ids,OWNER,"SEL-%");
            try(var rows=statement.executeQuery()) {
                while(rows.next()) {
                    String code=rows.getString(1);BigDecimal qty=rows.getBigDecimal(2);
                    assertThat(code).isEqualTo("SEL-%06d".formatted(50000-count));
                    assertThat(qty).isEqualByComparingTo(new BigDecimal(50000-count).add(new BigDecimal("0.125")));
                    digest.update((code+"\0"+qty.toPlainString()+"\n").getBytes(StandardCharsets.UTF_8));sum=sum.add(qty);count++;
                }
            }
        } finally {connection.rollback();connection.setAutoCommit(true);connection.setReadOnly(false);}
        System.out.println("D3_PREDICATE_ROWS name="+name+" actualRows="+count+" orderedReadMs="+(System.nanoTime()-started)/1_000_000);
        int denied=count(connection,ids,from,OTHER,"SEL-%"),filtered=count(connection,ids,from,OWNER,"NO-MATCH-%");
        return new Result(count,sum,HexFormat.of().formatHex(digest.digest()),denied,filtered);
    }
    static int count(Connection connection,Array ids,String from,UUID owner,String filter)throws SQLException {
        try(var statement=connection.prepareStatement("SELECT count(*)"+from)){bind(statement,ids,owner,filter);try(var rows=statement.executeQuery()){rows.next();return rows.getInt(1);}}
    }
    static void bind(PreparedStatement statement,Array ids,UUID owner,String filter)throws SQLException {
        statement.setObject(1,owner);statement.setString(2,filter);statement.setArray(3,ids);
    }
}
