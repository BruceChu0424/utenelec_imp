import java.nio.file.*;
import java.util.*;
import org.flywaydb.core.Flyway;

class InitializeRehearsal {
    public static void main(String[] args) throws Exception {
        Map<String,String> values = new HashMap<>();
        for (String line : Files.readAllLines(Path.of(args[0]))) {
            int split=line.indexOf('=');
            if (split<1 || line.stripLeading().startsWith("#")) continue;
            String value=line.substring(split+1).trim();
            if (value.startsWith("\"") && value.endsWith("\"")) value=value.substring(1,value.length()-1);
            values.put(line.substring(0,split).trim(),value);
        }
        String database=args.length>2?args[2]:"uten_imp_rehearsal_20261022";
        if(!database.matches("[a-z_][a-z0-9_]*rehearsal[a-z0-9_]*")) throw new IllegalArgumentException("Explicit rehearsal database required");
        String url="jdbc:postgresql://localhost:5433/"+database;
        var flyway=Flyway.configure().dataSource(url,values.get("UTEN_DB_USER"),values.get("UTEN_DB_PASSWORD"))
            .locations("filesystem:"+args[1]).cleanDisabled(true).load();
        var result=flyway.migrate();
        System.out.println("REHEARSAL_SCHEMA_READY migrations="+result.migrationsExecuted+" target="+result.targetSchemaVersion);
    }
}
