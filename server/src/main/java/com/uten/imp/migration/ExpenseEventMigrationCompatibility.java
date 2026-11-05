package com.uten.imp.migration;

import org.flywaydb.core.api.CoreErrorCode;
import org.flywaydb.core.api.CoreMigrationType;
import org.flywaydb.core.api.ErrorDetails;
import org.flywaydb.core.api.FlywayException;
import org.flywaydb.core.api.callback.Context;
import org.flywaydb.core.api.callback.Event;
import org.flywaydb.core.api.exception.FlywayBlockStatementExecutionException;

import java.io.BufferedReader;
import java.io.File;
import java.io.IOException;
import java.io.StringReader;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.net.URLDecoder;
import java.security.MessageDigest;
import java.security.NoSuchAlgorithmException;
import java.sql.Connection;
import java.sql.SQLException;
import java.util.HashSet;
import java.util.HexFormat;
import java.util.Map;
import java.util.Objects;
import java.util.Set;
import java.util.regex.Pattern;
import java.util.zip.CRC32;

/**
 * Executes only the proven missing enum member in immutable V1000/V1002.
 * Flyway still resolves/checksums/records the original SQL resources. Its public
 * statement-callback control signal prevents the original, narrower CHECK from
 * running after the validated replacement on the same migration transaction.
 * No event rows, audit triggers or history/checksum rows are rewritten.
 */
final class ExpenseEventMigrationCompatibility {
    private static final String STATE="uten.compat_expense_event_check";
    private static final String CONSTRAINT_PREFIX="ALTERTABLEexpense_claim_eventsADDCONSTRAINTexpense_claim_events_type_chk";
    private static final Pattern CHECK=Pattern.compile("ALTER TABLE expense_claim_events ADD CONSTRAINT expense_claim_events_type_chk\\s+CHECK\\(event_type IN\\s*\\([^;]+;");
    private static final Pattern EVENT=Pattern.compile("'([A-Z_]+)'");
    private static final Map<String,Plan> PLANS=Map.of(
            "1000",load("V1000__expense_department_finance_executive_workflow.sql",
                    "1826c869dbf9e306c25458ec689d8c8cf09b5bb4316e97c3946b6f89b15b786e"),
            "1002",load("V1002__department_approval_substitution_policy.sql",
                    "b8c390e8969153bb65ab05c956cc61cc36886bdd3baf80f47d2ee1fa13758f26"));

    private ExpenseEventMigrationCompatibility() { }

    record Plan(String script,String sha256,int checksum,String original,String replacement,Set<String> events) { }
    static Plan plan(String version){return PLANS.get(version);}

    static boolean supports(Event event,Context context) {
        return (event==Event.BEFORE_EACH_MIGRATE||event==Event.BEFORE_EACH_MIGRATE_STATEMENT||event==Event.AFTER_EACH_MIGRATE)
                &&context.getMigrationInfo()!=null&&context.getMigrationInfo().getVersion()!=null
                &&PLANS.containsKey(context.getMigrationInfo().getVersion().getVersion());
    }

    static void handle(Event event,Context context) {
        var migration=context.getMigrationInfo();
        String version=migration.getVersion().getVersion();Plan plan=PLANS.get(version);
        if(plan==null||!plan.script().equals(migration.getScript())||!Objects.equals(plan.checksum(),migration.getChecksum())
                ||!CoreMigrationType.SQL.equals(migration.getType()))
            throw new FlywayException("Expense event compatibility requires the exact reviewed immutable SQL identity");
        if(event==Event.BEFORE_EACH_MIGRATE)verifyResolvedBytes(context,plan);
        Connection connection=context.getConnection();
        try {
            if(connection.getAutoCommit())throw new FlywayException("Expense event compatibility requires Flyway's migration transaction");
            if(event==Event.BEFORE_EACH_MIGRATE) {
                if(!"public".equals(scalar(connection,"SELECT current_schema()"))||!state(connection).isEmpty())
                    throw new FlywayException("Expense event compatibility requires the original public schema and an unused transaction window");
                setState(connection,version+":pending");
            } else if(event==Event.BEFORE_EACH_MIGRATE_STATEMENT) {
                if(context.getStatement()==null)return;
                String sql=context.getStatement().getSql();String compact=compact(sql);
                if(!compact.startsWith(CONSTRAINT_PREFIX))return;
                if(!compact.equals(compact(plan.original()))||!(version+":pending").equals(state(connection)))
                    throw new FlywayException("Expense event CHECK differs from the single reviewed immutable statement");
                try(var statement=connection.createStatement()){statement.execute(plan.replacement());}
                setState(connection,version+":applied");
                // Public Flyway control signal, deliberately outside the SQLException
                // handler: DefaultSqlScriptExecutor consumes it and continues normally.
                throw new FlywayBlockStatementExecutionException(new ErrorDetails(CoreErrorCode.CONFIGURATION,
                        "Reviewed expense event CHECK executed with its prior PAYMENT_REVERSED member"),
                        "The original narrower statement is replaced within the same transaction");
            } else if(event==Event.AFTER_EACH_MIGRATE) {
                if(!(version+":applied").equals(state(connection)))
                    throw new FlywayException("The reviewed expense event CHECK was not executed exactly once");
                try(var statement=connection.createStatement();var result=statement.executeQuery("""
                        SELECT convalidated,pg_get_constraintdef(oid) FROM pg_constraint
                        WHERE conrelid='public.expense_claim_events'::regclass AND conname='expense_claim_events_type_chk'
                        """)) {
                    if(!result.next()||!result.getBoolean(1)||!events(result.getString(2)).equals(plan.events())||result.next())
                        throw new FlywayException("The replacement expense event CHECK is not the validated reviewed vocabulary");
                }
                setState(connection,"");
            }
        } catch(SQLException failure) {
            throw new FlywayException("Unable to preserve the immutable expense event migration transaction",failure);
        }
    }

    private static Plan load(String script,String expectedSha) {
        try(var stream=ExpenseEventMigrationCompatibility.class.getClassLoader().getResourceAsStream("db/migration/"+script)) {
            if(stream==null)throw new FlywayException("Reviewed immutable expense migration is missing");
            byte[] bytes=stream.readAllBytes();
            if(!HexFormat.of().formatHex(MessageDigest.getInstance("SHA-256").digest(bytes)).equals(expectedSha))
                throw new FlywayException("Reviewed immutable expense migration bytes changed");
            String source=new String(bytes,StandardCharsets.UTF_8);var match=CHECK.matcher(source);
            if(!match.find())throw new FlywayException("Reviewed immutable expense CHECK is missing");
            String original=match.group();
            if(match.find())throw new FlywayException("Reviewed immutable expense CHECK is ambiguous");
            String replacement=original.substring(0,original.lastIndexOf("))"))+",'PAYMENT_REVERSED'));";
            var crc=new CRC32();
            try(var lines=new BufferedReader(new StringReader(source))) {
                String line;while((line=lines.readLine())!=null)crc.update(line.getBytes(StandardCharsets.UTF_8));
            }
            return new Plan(script,expectedSha,(int)crc.getValue(),original,replacement,Set.copyOf(events(replacement)));
        } catch(IOException|NoSuchAlgorithmException failure) {
            throw new FlywayException("Unable to verify the immutable expense migration bytes",failure);
        }
    }
    private static void verifyResolvedBytes(Context context,Plan plan) {
        String physical=context.getMigrationInfo().getPhysicalLocation();
        if(physical==null)throw new FlywayException("The resolved immutable expense resource location is missing");
        try {
            // Use the same physical identity Flyway exposes for exploded classes
            // and jar resources. A filesystem fixture must prove its own bytes,
            // rather than borrowing the checksum/SHA of the packaged original.
            var resources=context.getConfiguration().getClassLoader().getResources("db/migration/"+plan.script());
            while(resources.hasMoreElements()) {
                var resource=resources.nextElement();
                String resourcePhysical=new File(URLDecoder.decode(resource.getPath(),StandardCharsets.UTF_8)).getAbsolutePath();
                if(physical.equals(resourcePhysical)) {
                    try(var input=resource.openStream()){requireSha(input.readAllBytes(),plan.sha256());return;}
                }
            }
            Path path=Path.of(physical);
            if(!Files.isRegularFile(path))throw new FlywayException("The resolved immutable expense resource cannot be verified");
            requireSha(Files.readAllBytes(path),plan.sha256());
        } catch(IOException|NoSuchAlgorithmException|java.nio.file.InvalidPathException failure) {
            throw new FlywayException("Unable to verify the resolved immutable expense migration bytes",failure);
        }
    }
    private static void requireSha(byte[] bytes,String expected)throws NoSuchAlgorithmException {
        if(!HexFormat.of().formatHex(MessageDigest.getInstance("SHA-256").digest(bytes)).equals(expected))
            throw new FlywayException("The resolved immutable expense migration bytes differ from the reviewed SHA-256");
    }
    private static Set<String> events(String sql) {
        var result=new HashSet<String>();var matcher=EVENT.matcher(sql);while(matcher.find())result.add(matcher.group(1));return result;
    }
    private static String compact(String sql){return sql.replaceAll("\\s+","");}
    private static String state(Connection connection)throws SQLException {
        return Objects.requireNonNullElse(scalar(connection,"SELECT current_setting('"+STATE+"',true)"),"");
    }
    private static void setState(Connection connection,String value)throws SQLException {
        try(var statement=connection.prepareStatement("SELECT set_config(?, ?, true)")) {
            statement.setString(1,STATE);statement.setString(2,value);statement.execute();
        }
    }
    private static String scalar(Connection connection,String sql)throws SQLException {
        try(var statement=connection.createStatement();var rows=statement.executeQuery(sql)) {
            if(!rows.next())throw new SQLException("Expected one migration policy row");return rows.getString(1);
        }
    }
}
