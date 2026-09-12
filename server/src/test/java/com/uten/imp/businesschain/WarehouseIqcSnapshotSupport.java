package com.uten.imp.businesschain;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.features.warehouse.inbound.ProcurementIqcStockInContracts.BatchConfirmRequest;
import org.springframework.test.util.ReflectionTestUtils;
import org.testcontainers.containers.PostgreSQLContainer;
import org.testcontainers.utility.MountableFile;

import java.io.OutputStream;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.security.DigestInputStream;
import java.security.MessageDigest;
import java.util.HexFormat;
import java.util.LinkedHashMap;
import java.util.Map;
import java.util.UUID;

/** Optional private checkpoints for isolated synthetic diagnostics; never enabled by normal CI. */
final class WarehouseIqcSnapshotSupport {
    private WarehouseIqcSnapshotSupport() {}
    static Path directory() {
        String configured=System.getProperty("uten.warehouse.scale.snapshotDirectory");
        if(configured==null||configured.isBlank())return null;
        Path path=Path.of(configured).toAbsolutePath().normalize();
        Path workspace=Path.of("").toAbsolutePath().normalize().getParent();
        if(!path.startsWith(workspace.resolve(".codex-tmp"))||!path.getFileName().toString().equals("private"))
            throw new IllegalArgumentException("Snapshots must be inside this workspace's ignored private diagnostic directory");
        return path;
    }
    record Restored(WarehouseIqcScaleFixture.Scenario scenario,BatchConfirmRequest request,int receipts,int lines,String sha256) {}
    /** Restore only an explicitly selected synthetic checkpoint into this new, empty test container. */
    static Restored restore(PostgreSQLContainer<?> database)throws Exception {
        String configured=System.getProperty("uten.warehouse.scale.restoreCheckpoint");
        if(configured==null||configured.isBlank())return null;
        Path metadata=Path.of(configured).toAbsolutePath().normalize();
        Path workspace=Path.of("").toAbsolutePath().normalize().getParent();
        if(!metadata.startsWith(workspace.resolve(".codex-tmp"))||!metadata.getParent().getFileName().toString().equals("private")
                ||!metadata.getFileName().toString().endsWith("-before-confirm.json"))
            throw new IllegalArgumentException("Restore requires a private synthetic before-confirm checkpoint");
        var mapper=new ObjectMapper().findAndRegisterModules();var saved=mapper.readTree(metadata.toFile());
        if(!saved.path("syntheticOnly").asBoolean()||!"before-confirm".equals(saved.path("phase").asText()))
            throw new IllegalArgumentException("Checkpoint is not a verified synthetic before-confirm input");
        Path dump=metadata.resolveSibling(metadata.getFileName().toString().replaceFirst("\\.json$",".dump"));
        MessageDigest digest=MessageDigest.getInstance("SHA-256");
        try(var input=new DigestInputStream(Files.newInputStream(dump),digest)){input.transferTo(OutputStream.nullOutputStream());}
        String actual=HexFormat.of().formatHex(digest.digest());
        if(!actual.equals(saved.path("sha256").asText())||Files.size(dump)!=saved.path("bytes").asLong())
            throw new IllegalStateException("Synthetic checkpoint digest mismatch");
        var empty=database.execInContainer("psql","-U",database.getUsername(),"-d",database.getDatabaseName(),"-Atc",
                "SELECT count(*) FROM pg_tables WHERE schemaname='public'");
        if(empty.getExitCode()!=0||!"0".equals(empty.getStdout().trim()))throw new IllegalStateException("Restore target must be this test's empty database");
        String temporary="/tmp/uten-iqc-restore-"+UUID.randomUUID()+".dump";
        database.copyFileToContainer(MountableFile.forHostPath(dump.toString()),temporary);
        var restored=database.execInContainer("pg_restore","--exit-on-error","--single-transaction","--no-owner","--no-acl",
                "--username="+database.getUsername(),"--dbname="+database.getDatabaseName(),temporary);
        if(restored.getExitCode()!=0){
            Files.writeString(metadata.getParent().resolve("restore-"+UUID.randomUUID()+".error.txt"),restored.getStderr());
            throw new IllegalStateException("Synthetic restore failed; details retained privately");
        }
        var analyzed=database.execInContainer("psql","-v","ON_ERROR_STOP=1","-U",database.getUsername(),"-d",database.getDatabaseName(),"-c","ANALYZE");
        if(analyzed.getExitCode()!=0)throw new IllegalStateException("Synthetic restored statistics could not be prepared");
        return new Restored(mapper.treeToValue(saved.path("scenario"),WarehouseIqcScaleFixture.Scenario.class),
                mapper.treeToValue(saved.path("request"),BatchConfirmRequest.class),saved.path("receiptCount").asInt(),
                saved.path("itemsPerReceipt").asInt(),actual);
    }
    static void checkpoint(PostgreSQLContainer<?> database,ObjectMapper json,
                           WarehouseIqcScaleFixture.Scenario scenario,BatchConfirmRequest request,
                           int receipts,int lines,int run,String phase) throws Exception {
        Path directory=directory();if(directory==null)return;
        Files.createDirectories(directory);
        String prefix="iqc-"+receipts+"x"+lines+"-r"+run+"-"+phase;
        Path destination=directory.resolve(prefix+".dump");
        if(Files.exists(destination))throw new IllegalStateException("Refusing to overwrite an earlier checkpoint");
        String temporary="/tmp/uten-iqc-checkpoint-"+UUID.randomUUID()+".dump";
        var result=database.execInContainer("pg_dump","--format=custom","--no-owner","--no-acl",
                "--username="+database.getUsername(),"--dbname="+database.getDatabaseName(),"--file="+temporary);
        if(result.getExitCode()!=0) {
            Files.writeString(directory.resolve(prefix+".error.txt"),result.getStderr());
            throw new IllegalStateException("Synthetic pg_dump failed; private diagnostic retained");
        }
        database.copyFileFromContainer(temporary,destination.toString());
        if(Files.size(destination)==0)throw new IllegalStateException("Synthetic checkpoint is empty");
        MessageDigest digest=MessageDigest.getInstance("SHA-256");
        try(var input=new DigestInputStream(Files.newInputStream(destination),digest)) { input.transferTo(OutputStream.nullOutputStream()); }
        json.writerWithDefaultPrettyPrinter().writeValue(directory.resolve(prefix+".json").toFile(),
                Map.of("syntheticOnly",true,"phase",phase,"receiptCount",receipts,"itemsPerReceipt",lines,
                        "sha256",HexFormat.of().formatHex(digest.digest()),"bytes",Files.size(destination),
                        "scenario",scenario,"request",request));
    }
    static void sqlShapes(ObjectMapper json,ProductionJdbcMeasurement.Sample sample,String phase,int receipts,int lines,int run) throws Exception {
        Path directory=directory();if(directory==null||!(phase.equals("warehouse.batchConfirm")||phase.equals("valuation.settleAfterStockIn")))return;
        Object metadata=ReflectionTestUtils.getField(ProductionJdbcMeasurement.class,"METADATA");
        if(!(metadata instanceof Map<?,?> statements))throw new IllegalStateException("Shared SQL metadata unavailable");
        Map<String,String> selected=new LinkedHashMap<>();
        for(Object key:statements.keySet()) {
            String normalized=((String)key).replaceAll("\\s+"," ").trim();
            String fingerprint=HexFormat.of().formatHex(MessageDigest.getInstance("SHA-256").digest(normalized.getBytes(StandardCharsets.UTF_8))).substring(0,16);
            if(!sample.fingerprints.containsKey(fingerprint))continue;
            // Prepared SQL has '?' in place of bindings. Redact UUID literals as
            // an extra guard against an incidental inline identifier.
            selected.put(fingerprint,normalized.replaceAll("(?i)'[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}'","'<uuid>'"));
        }
        Files.createDirectories(directory);
        String name="iqc-"+receipts+"x"+lines+"-r"+run+"-"+phase.replace('.','-')+"-sql.json";
        json.writerWithDefaultPrettyPrinter().writeValue(directory.resolve(name).toFile(),selected);
    }
}
