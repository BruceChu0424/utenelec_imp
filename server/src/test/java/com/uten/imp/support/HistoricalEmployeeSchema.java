package com.uten.imp.support;

import com.uten.imp.testsupport.TestFlyway;
import java.sql.SQLException;
import org.testcontainers.postgresql.PostgreSQLContainer;

/** Real pre-V964 history, followed by actual forward migrations before exercising current services. */
public final class HistoricalEmployeeSchema {
    private HistoricalEmployeeSchema() { }
    private static final class Shared {
        private static final MigratedSchemaBaseline.TemplatePool POOL=new MigratedSchemaBaseline.TemplatePool(
                ()->new PostgreSQLContainer("postgres:16-alpine")
                        .withDatabaseName("uten_employee_history_963").withReuse(false)
                        .withCreateContainerCmdModifier(command->command.getHostConfig()
                                .withMemory(1024L*1024*1024).withNanoCPUs(1_000_000_000L)),
                postgres->TestFlyway.configure()
                        .dataSource(postgres.getJdbcUrl(),postgres.getUsername(),postgres.getPassword())
                        .locations("classpath:db/migration").target("963").load().migrate());
        static { Runtime.getRuntime().addShutdownHook(new Thread(POOL::close,"employee-history-schema-cleanup")); }
    }

    /** Only historical seed writes belong before upgradeToCurrent; never remove or disable guards. */
    public static MigratedSchemaBaseline.ScopedDatabase openDatabase(String label) throws SQLException {
        return Shared.POOL.open(label);
    }

    public static void upgradeToCurrent(MigratedSchemaBaseline.ScopedDatabase database) {
        TestFlyway.configure().dataSource(database.getJdbcUrl(),database.getUsername(),database.getPassword())
                .locations("classpath:db/migration").load().migrate();
    }
}
