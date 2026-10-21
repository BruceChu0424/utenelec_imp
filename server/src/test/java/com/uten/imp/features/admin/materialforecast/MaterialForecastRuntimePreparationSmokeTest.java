package com.uten.imp.features.admin.materialforecast;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.config.props.MaterialForecastProperties;
import com.uten.imp.config.props.StorageProperties;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.Timeout;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;

import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.time.Instant;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.concurrent.TimeUnit;

/** Actual production preparation boundary without Spring, a database or a worker. */
@EnabledIfEnvironmentVariable(named="UTEN_RUN_MARKET_PREPARATION_SMOKE",matches="(?i)true")
class MaterialForecastRuntimePreparationSmokeTest {
    @Test @Timeout(value=20,unit=TimeUnit.MINUTES)
    void actualProductionLauncherPreparesTheReviewedPayload() throws Exception { run(); }

    /** Allows a fast, explicitly configured probe using an already compiled test classpath. */
    public static void main(String[] arguments) throws Exception { run(); }

    private static void run() throws Exception {
        var properties=new MaterialForecastProperties();
        properties.setPayloadDirectory(required("uten.market.test.payload").toString());
        properties.setCacheDirectory(required("uten.market.test.cache").toString());
        properties.setBasePythonExecutable(required("uten.market.test.python").toString());
        var paths=new MaterialForecastHostPaths(new StorageProperties(),properties);
        var json=new ObjectMapper();
        var evidence=new LinkedHashMap<String,Object>();
        evidence.put("observedAt",Instant.now().toString());
        evidence.put("payload",paths.payloadDirectory().toRealPath().toString());
        evidence.put("cache",paths.cacheDirectory().toString());
        Path log=required("uten.market.test.preparationEvidence");
        Files.createDirectories(log.getParent());
        try {
            var ready=new MaterialForecastProcessLauncher(paths,properties,json).prepare(()->false);
            evidence.put("state","READY");
            evidence.put("python",ready.python().toString());
            evidence.put("worker",ready.worker().toString());
            evidence.put("catalog",ready.catalog().toString());
            evidence.put("lockDigest",ready.lockDigest());
        } catch(MaterialForecastProcessLauncher.Failure failure) {
            evidence.put("state","ERROR");evidence.put("code",failure.code());
            // Only in this opt-in local diagnostic: reproduce the exact production
            // child environment to distinguish helper failure from strict parsing.
            var command=new ArrayList<String>();
            Path payload=paths.payloadDirectory().toRealPath();
            if(MaterialForecastHostPaths.windows()) {
                command.addAll(List.of(Path.of(System.getenv().getOrDefault("SystemRoot","C:\\Windows"),"System32/WindowsPowerShell/v1.0/powershell.exe").toString(),
                    "-NoProfile","-NonInteractive","-ExecutionPolicy","Bypass","-File",payload.resolve("prepare_runtime.ps1").toString(),
                    "-Payload",payload.toString(),"-Cache",paths.cacheDirectory().toString(),"-BasePython",properties.getBasePythonExecutable()));
            } else command.addAll(List.of(properties.getBasePythonExecutable(),"-I",payload.resolve("prepare_runtime.py").toString(),"--payload",payload.toString(),"--cache",paths.cacheDirectory().toString()));
            Path raw=Files.createTempFile(log.getParent(),"preparation-probe-",".stdout");
            try {
                Process probe=MaterialForecastProcessLauncher.builder(command,payload).redirectOutput(raw.toFile()).start();
                if(!probe.waitFor(15,TimeUnit.MINUTES)) { MaterialForecastProcessLauncher.terminate(probe);throw new AssertionError("Diagnostic preparation timed out"); }
                if(Files.size(raw)>65536)throw new AssertionError("Diagnostic output exceeded its bounded protocol");
                evidence.put("rawExit",probe.exitValue());evidence.put("rawStdout",Files.readString(raw,StandardCharsets.UTF_8));
            } finally { Files.deleteIfExists(raw); }
            json.writerWithDefaultPrettyPrinter().writeValue(log.toFile(),evidence);
            throw new AssertionError("Production prepare failed; diagnostic evidence: "+log,failure);
        }
        json.writerWithDefaultPrettyPrinter().writeValue(log.toFile(),evidence);
        System.out.println(json.writeValueAsString(Map.of("state","READY","evidence",log.toString())));
    }

    private static Path required(String name) {
        String value=System.getProperty(name);
        if(value==null||value.isBlank()||!Path.of(value).isAbsolute())throw new IllegalArgumentException("Supply absolute -D"+name);
        return Path.of(value).normalize();
    }
}
