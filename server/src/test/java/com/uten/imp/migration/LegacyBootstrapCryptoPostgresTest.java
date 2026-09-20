package com.uten.imp.migration;

import com.fasterxml.jackson.databind.ObjectMapper;
import io.github.cdimascio.dotenv.Dotenv;
import org.junit.jupiter.api.*;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.datasource.DriverManagerDataSource;
import org.testcontainers.containers.BindMode;
import org.testcontainers.containers.Container;
import org.testcontainers.containers.PostgreSQLContainer;
import org.testcontainers.images.builder.ImageFromDockerfile;
import org.testcontainers.images.builder.Transferable;
import org.testcontainers.utility.DockerImageName;

import javax.crypto.Mac;
import javax.crypto.spec.SecretKeySpec;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.security.MessageDigest;
import java.util.HexFormat;
import java.util.Map;
import java.util.regex.Pattern;

import static org.junit.jupiter.api.Assertions.*;

/** Actual psql, application dotenv parsing and hostile server logging; synthetic secrets only. */
@EnabledIfEnvironmentVariable(named="UTEN_RUN_DB_TESTS",matches="(?i)true")
class LegacyBootstrapCryptoPostgresTest {
    private static final String ROOT="/tmp/uten-crypto-probe";
    private static final String PGP="SYNTHETIC_PRIVATE_PGP_CANARY_0123456789\\n\\t'原值'\\end";
    private static final String HMAC="SYNTHETIC_PRIVATE_HMAC_CANARY_0123456789\\n'字节'";
    private static final String PII="SYNTHETIC_PRIVATE_PII_CANARY_012345";
    private static final String PARAMETERS="log_min_messages,log_min_error_statement,log_statement,log_parameter_max_length";
    private static PostgreSQLContainer<?> postgres;
    private static JdbcTemplate jdbc;
    private static String options,preflight;

    @BeforeAll static void start() throws Exception {
        String script=Files.readString(Path.of("legacy_migration/migrate.sh"));
        var match=Pattern.compile("IMPORT_PGOPTIONS='([^']+)'").matcher(script);
        assertTrue(match.find());options=match.group(1);
        int start=script.indexOf("verify_import_connection_privileges () {");
        int end=script.indexOf("\n}\n",start);
        assertTrue(start>=0&&end>start);preflight=script.substring(start,end+3);
        var image=new ImageFromDockerfile().withDockerfileFromBuilder(builder->builder.from("postgres:16-alpine")
                .run("apk add --no-cache bash python3 git coreutils docker-cli").build());
        postgres=new PostgreSQLContainer<>(DockerImageName.parse(image.get()).asCompatibleSubstituteFor("postgres"))
                .withFileSystemBind("/var/run/docker.sock","/var/run/docker.sock",BindMode.READ_WRITE)
                .withCommand("postgres","-c","log_statement=all","-c","log_min_duration_statement=0",
                        "-c","log_duration=on","-c","log_parameter_max_length=-1","-c","log_parameter_max_length_on_error=-1");
        postgres.start();
        jdbc=new JdbcTemplate(new DriverManagerDataSource(postgres.getJdbcUrl(),postgres.getUsername(),postgres.getPassword()));
        jdbc.execute("CREATE ROLE uten_migrator LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE; CREATE ROLE uten LOGIN NOSUPERUSER; "
                +"CREATE EXTENSION pgcrypto; REVOKE ALL ON FUNCTION pg_catalog.pg_control_system() FROM PUBLIC");
        assertEquals(0,postgres.execInContainer("mkdir","-p",ROOT).getExitCode());
        put("prepare_hr_keys.py",Files.readString(Path.of("legacy_migration/prepare_hr_keys.py")));
    }
    @AfterAll static void stop(){if(postgres!=null)postgres.stop();}
    @BeforeEach void reset() throws Exception {
        jdbc.execute("REVOKE SET ON PARAMETER "+PARAMETERS+" FROM uten_migrator; "
                +"REVOKE EXECUTE ON FUNCTION pg_catalog.pg_control_system() FROM uten_migrator");
        postgres.execInContainer("rm","-f",ROOT+"/private.sql");
    }

    @Test void exactCoordinatorEntryRejectsMissingPrivilegesAndAcceptsOnlyDedicatedNonSuperCapability() throws Exception {
        Container.ExecResult missing=runPreflight("uten_migrator");
        assertEquals(69,missing.getExitCode());assertTrue(missing.getStderr().contains("SET"));
        assertEquals(0,postgres.execInContainer("test","!","-e",ROOT+"/private.sql").getExitCode());
        jdbc.execute("GRANT SET ON PARAMETER "+PARAMETERS+" TO uten_migrator");
        Container.ExecResult noIdentity=runPreflight("uten_migrator");
        assertEquals(69,noIdentity.getExitCode());assertTrue(noIdentity.getStderr().contains("pg_control_system"));
        jdbc.execute("GRANT EXECUTE ON FUNCTION pg_catalog.pg_control_system() TO uten_migrator");
        Container.ExecResult allowed=runPreflight("uten_migrator");
        assertEquals(0,allowed.getExitCode(),allowed.getStderr());assertTrue(allowed.getStdout().contains("PREFLIGHT_READY"));
        assertFalse(jdbc.queryForObject("SELECT rolsuper FROM pg_roles WHERE rolname='uten_migrator'",Boolean.class));
        assertFalse(jdbc.queryForObject("SELECT pg_has_role('uten_migrator',?,'MEMBER')",Boolean.class,postgres.getUsername()));
        assertEquals(69,runPreflight("uten").getExitCode());
    }

    @Test void quotedFileKeysMatchTheApplicationAndRemainPrivateInClientAndHostileServerLogs() throws Exception {
        grant();
        String env="UTEN_PGP_MASTER_KEY=\""+PGP+"\"\r\nUTEN_HMAC_KEY="+HMAC+"\r\n";
        Path fixture=Files.createTempDirectory("uten-synthetic-dotenv-");
        try {
            Files.writeString(fixture.resolve("crypto.env"),env,StandardCharsets.UTF_8);
            Map<String,String> declared=Dotenv.configure().directory(fixture.toString()).filename("crypto.env").load()
                    .entries(Dotenv.Filter.DECLARED_IN_ENV_FILE).stream().collect(java.util.stream.Collectors.toMap(
                            io.github.cdimascio.dotenv.DotenvEntry::getKey,io.github.cdimascio.dotenv.DotenvEntry::getValue));
            assertEquals(PGP,declared.get("UTEN_PGP_MASTER_KEY"));assertEquals(HMAC,declared.get("UTEN_HMAC_KEY"));
        } finally {Files.deleteIfExists(fixture.resolve("crypto.env"));Files.deleteIfExists(fixture);}
        produce(env,null);
        Container.ExecResult result=psql(checks(PGP,HMAC,"1")+"ROLLBACK;\n");
        assertEquals(0,result.getExitCode(),result.getStderr());assertTrue(result.getStdout().contains("t|t|t|t"));
        assertPrivate(result);
        Container.ExecResult failure=psql("BEGIN;\n\\i "+ROOT+"/private.sql\nSELECT (:'pgp_key')::integer;\n");
        assertNotEquals(0,failure.getExitCode());assertTrue(failure.getStderr().contains("22P02"));assertPrivate(failure);
    }

    @Test void environmentOverrideRetainsRealLfLiteralSlashNAndUnicodeWithoutPrintingValues() throws Exception {
        grant();
        String pgp=PGP+"\n真实换行\tend",hmac=HMAC+"\r\n两字节";
        produce("UTEN_PGP_MASTER_KEY=file-placeholder\nUTEN_HMAC_KEY=file-placeholder\n",
                Map.of("UTEN_PGP_MASTER_KEY",pgp,"UTEN_HMAC_KEY",hmac,"UTEN_PGP_KEY_VERSION","release-v1"));
        Container.ExecResult result=psql(checks(pgp,hmac,"release-v1")+"ROLLBACK;\n");
        assertEquals(0,result.getExitCode(),result.getStderr());assertTrue(result.getStdout().contains("t|t|t|t"));assertPrivate(result);
    }

    private static void grant(){jdbc.execute("GRANT SET ON PARAMETER "+PARAMETERS+" TO uten_migrator; GRANT EXECUTE ON FUNCTION pg_catalog.pg_control_system() TO uten_migrator");}
    private static Container.ExecResult runPreflight(String user) throws Exception {
        put("preflight.sh","#!/usr/bin/env bash\nset -euo pipefail\nDOCKER=docker\nCONTAINER="+postgres.getContainerId()
                +"\nPG_USER="+user+"\nPG_DB="+postgres.getDatabaseName()+"\nIMPORT_PGOPTIONS='"+options+"'\n"
                +preflight+"\nverify_import_connection_privileges\nprintf 'PREFLIGHT_READY\\n'\n");
        return postgres.execInContainer("bash",ROOT+"/preflight.sh");
    }
    private static void produce(String env,Map<String,String> environment) throws Exception {
        put("crypto.env",env);
        assertEquals(0,postgres.execInContainer("sh","-c","umask 077; : > "+ROOT+"/private.sql").getExitCode());
        Container.ExecResult produced;
        if(environment==null) {
            produced=postgres.execInContainer("python3","-I",ROOT+"/prepare_hr_keys.py",ROOT+"/crypto.env",ROOT+"/private.sql");
        } else {
            put("environment.json",new ObjectMapper().writeValueAsString(environment));
            put("producer.py","import os,json,runpy\nwith open('"+ROOT+"/environment.json',encoding='utf-8') as source: os.environ.update(json.load(source))\n"
                    +"runpy.run_path('"+ROOT+"/prepare_hr_keys.py')['main'](['"+ROOT+"/crypto.env','"+ROOT+"/private.sql'])\n");
            produced=postgres.execInContainer("python3","-I",ROOT+"/producer.py");
        }
        assertEquals(0,produced.getExitCode(),produced.getStderr());assertEquals("",produced.getStdout());assertPrivate(produced);
        assertEquals("600",postgres.execInContainer("stat","-c","%a",ROOT+"/private.sql").getStdout().trim());
    }
    private static String checks(String pgp,String hmac,String version) throws Exception {
        Mac mac=Mac.getInstance("HmacSHA256");mac.init(new SecretKeySpec(hmac.getBytes(StandardCharsets.UTF_8),"HmacSHA256"));
        return "BEGIN;\n\\i "+ROOT+"/private.sql\nSELECT encode(digest(convert_to(:'pgp_key','UTF8'),'sha256'),'hex')='"+sha(pgp)+"',"
                +"encode(hmac('"+PII+"',:'hmac_key','sha256'),'hex')='"+HexFormat.of().formatHex(mac.doFinal(PII.getBytes(StandardCharsets.UTF_8)))+"',"
                +":'pgp_ver'='"+version+"',pgp_sym_decrypt(pgp_sym_encrypt('"+PII+"',:'pgp_key'),:'pgp_key')='"+PII+"';\n";
    }
    private static String sha(String value)throws Exception{return HexFormat.of().formatHex(MessageDigest.getInstance("SHA-256").digest(value.getBytes(StandardCharsets.UTF_8)));}
    private static Container.ExecResult psql(String sql) throws Exception {
        put("check.sql",sql);
        return postgres.execInContainer("env","PGOPTIONS="+options,"psql","-X","-U","uten_migrator","-d",postgres.getDatabaseName(),
                "-At","-v","ON_ERROR_STOP=1","-v","VERBOSITY=sqlstate","-v","SHOW_CONTEXT=never","-f",ROOT+"/check.sql");
    }
    private static void assertPrivate(Container.ExecResult result) {
        String outputs=result.getStdout()+result.getStderr()+postgres.getLogs();
        for(String marker:new String[]{"SYNTHETIC_PRIVATE_PGP_CANARY","SYNTHETIC_PRIVATE_HMAC_CANARY",PII}) {
            assertFalse(outputs.contains(marker),"Sensitive synthetic marker appeared in client or server diagnostics");
        }
    }
    private static void put(String name,String content){postgres.copyFileToContainer(Transferable.of(content.getBytes(StandardCharsets.UTF_8),0600),ROOT+"/"+name);}
}
