package remediation.perf;

import java.nio.file.*;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.math.BigDecimal;
import java.sql.*;
import java.util.*;
import java.util.regex.*;
import com.fasterxml.jackson.databind.*;

/** Read-only copied real fixture; every returned field is compared, including decimal JSON text. */
public class WarehouseEquivalenceProbe {
    static final String COLUMNS="goods_id,color_id,unit_id,warehouse_id,warehouse_code,warehouse_name,on_hand_qty,reserved_qty,available_qty,own_qty,min_qty,open_qty,public_allowed,main_warehouse_id";
    record Scope(UUID id,String goods) { }
    record Bound(String sql,List<String> parameters) { }
    static Bound bind(String sql) {
        var names=new ArrayList<String>();var matcher=Pattern.compile(":(analysisId|goodsIds)\\b").matcher(sql);var result=new StringBuilder();
        while(matcher.find()){names.add(matcher.group(1));matcher.appendReplacement(result,"?");}matcher.appendTail(result);
        return new Bound(result.toString(),List.copyOf(names));
    }
    static String rows(Connection connection,Bound bound,Scope scope)throws Exception {
        try(var statement=connection.prepareStatement(bound.sql())) {
            for(int i=0;i<bound.parameters().size();i++)if(bound.parameters().get(i).equals("analysisId"))statement.setObject(i+1,scope.id());else statement.setString(i+1,scope.goods());
            try(var result=statement.executeQuery()){if(!result.next())throw new AssertionError("Missing JSON row");return result.getString(1);}
        }
    }
    public static void main(String[] args)throws Exception {
        Path out=Path.of(args[0]);Files.createDirectories(out.resolve("rows"));
        String original=Files.readString(Path.of(args[1]),StandardCharsets.UTF_8),proposed=Files.readString(Path.of(args[2]),StandardCharsets.UTF_8);
        String prefix="WITH result("+COLUMNS+") AS (",suffix=") SELECT COALESCE(json_agg(row_to_json(result) ORDER BY warehouse_code,warehouse_id,goods_id,color_id NULLS FIRST,unit_id),'[]'::json) FROM result";
        Bound old=bind(prefix+original+suffix),next=bind(prefix+proposed+suffix);
        var mapper=new ObjectMapper().enable(DeserializationFeature.USE_BIG_DECIMAL_FOR_FLOAT);var receipts=new ArrayList<Map<String,Object>>();
        try(var connection=DriverManager.getConnection("jdbc:postgresql://localhost:52159/uten_imp","fixture_admin","local-perf-only")) {
            connection.setReadOnly(true);connection.setAutoCommit(false);connection.setTransactionIsolation(Connection.TRANSACTION_REPEATABLE_READ);
            var scopes=new ArrayList<Scope>();
            try(var statement=connection.createStatement();var result=statement.executeQuery("SELECT analysis_id,string_agg(DISTINCT goods_id::text,',' ORDER BY goods_id::text) FROM production_material_analysis_materials WHERE active GROUP BY analysis_id ORDER BY analysis_id")) {
                while(result.next())scopes.add(new Scope(result.getObject(1,UUID.class),result.getString(2)));
            }
            long started=System.nanoTime();int total=0,nonzero=0;
            for(Scope scope:scopes) {
                String before=rows(connection,old,scope),after=rows(connection,next,scope);
                byte[] raw=before.getBytes(StandardCharsets.UTF_8);String hash=HexFormat.of().formatHex(MessageDigest.getInstance("SHA-256").digest(raw));
                Files.write(out.resolve("rows/"+scope.id()+"-baseline.json"),raw,StandardOpenOption.CREATE_NEW);
                Files.write(out.resolve("rows/"+scope.id()+"-proposed.json"),after.getBytes(StandardCharsets.UTF_8),StandardOpenOption.CREATE_NEW);
                if(!before.equals(after))throw new AssertionError("Every field differs for scope "+scope.id());
                var array=mapper.readTree(before);BigDecimal own=BigDecimal.ZERO;for(var row:array)own=own.add(row.get("own_qty").decimalValue());
                int size=array.size();total+=size;if(own.signum()!=0)nonzero++;
                receipts.add(Map.of("analysis",scope.id().toString(),"rows",size,"ownSum",own.toPlainString(),"exactOrderedRawJsonEqual",true,"sha256",hash));
            }
            connection.rollback();
            var summary=Map.of("source","7b912287e53315228b469790ff066a9fab643e3c","database","read-only restored synthetic Root B snapshot","analysisScopes",scopes.size(),"totalComparedRows",total,"fieldsPerRow",14,"scopesWithNonzeroOwnQty",nonzero,"elapsedMs",(System.nanoTime()-started)/1_000_000,"scopeReceipts",receipts);
            Files.writeString(out.resolve("comparison.json"),mapper.writerWithDefaultPrettyPrinter().writeValueAsString(summary),StandardCharsets.UTF_8,StandardOpenOption.CREATE_NEW);
            System.out.println("WAREHOUSE_EQUIVALENCE scopes="+scopes.size()+" rows="+total+" fields=14 nonzeroOwnScopes="+nonzero+" exactOrderedRawJson=true elapsedMs="+(System.nanoTime()-started)/1_000_000);
        }
    }
}
