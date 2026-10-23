package com.uten.imp.migration;

import com.uten.imp.support.ProductionProvenanceRoleFixture;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.testcontainers.postgresql.PostgreSQLContainer;
import java.nio.file.*;
import static org.junit.jupiter.api.Assertions.*;

/** Full original916 schema, genuine915 gap and normal917 with production roles. */
@EnabledIfEnvironmentVariable(named="UTEN_RUN_DB_TESTS",matches="(?i)true")
class ProductionProvenanceRuntimePrivilegesPostgresTest {
    @Test void realProductionOwnerAndRuntimeKeepOnlyReadAccessToOriginalSources() throws Exception {
        Path source=Files.createTempDirectory("r1-source-916-");Path full=Files.createTempDirectory("r1-release-917-");
        Path resources=Path.of("src/main/resources/db/migration");
        try(var files=Files.list(resources)) {
            for(Path file:files.filter(p->p.getFileName().toString().matches("V[0-9]+__.*\\.sql")).toList()) {
                String name=file.getFileName().toString();int version=Integer.parseInt(name.substring(1,name.indexOf("__")));
                if(version<=917)Files.copy(file,full.resolve(name));
                if(version<=916&&version!=915)Files.copy(file,source.resolve(name));
            }
        }
        try(var pg=new PostgreSQLContainer("postgres:16-alpine").withUsername("fixture_admin")) {
            pg.start();var result=ProductionProvenanceRoleFixture.run(pg.getJdbcUrl(),pg.getUsername(),pg.getPassword(),source,full);
            assertTrue((Boolean)result.get("ordinary_source_null_crud"));
            assertEquals((Integer)result.get("baseline_migrations")+2,result.get("final_migrations"));
            assertEquals(0,result.get("final_normal_migrate"));
            assertEquals(false,result.get("runtime_control_execute"));assertEquals(true,result.get("definer_owner_control_execute"));
        } finally {
            for(Path directory:new Path[]{source,full}) {
                try(var children=Files.list(directory)){for(Path child:children.toList())Files.delete(child);}
                Files.delete(directory);
            }
        }
    }
}
