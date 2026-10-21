package com.uten.imp.features.admin.materialforecast;

import com.fasterxml.jackson.databind.DeserializationFeature;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.application.port.MaterialForecastRuntimePort.Policy;
import com.uten.imp.config.props.MaterialForecastProperties;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Component;
import java.io.*;
import java.nio.charset.StandardCharsets;
import java.nio.file.*;
import java.time.Duration;
import java.util.*;
import java.util.concurrent.*;
import java.util.function.BooleanSupplier;

@Component
@RequiredArgsConstructor
public class MaterialForecastProcessLauncher {
    public record Prepared(Path python,Path worker,Path catalog,String lockDigest,String workerVersion) {}
    public static class Failure extends RuntimeException {
        private final String code;
        Failure(String code){super(code);this.code=code;}
        public String code(){return code;}
    }
    private final MaterialForecastHostPaths paths;
    private final MaterialForecastProperties properties;
    private final ObjectMapper json;
    private volatile Process preparation;
    public Prepared prepare(BooleanSupplier abort) {
        try {
            Path configuredPayload=paths.payloadDirectory(),cache=paths.cacheDirectory();
            if(!Files.isDirectory(configuredPayload))throw new Failure("RUNTIME_MISSING");
            Path payload=configuredPayload.toRealPath();
            if(!Files.isRegularFile(payload.resolve("prepare_runtime.py"),LinkOption.NOFOLLOW_LINKS))throw new Failure("RUNTIME_MISSING");
            MaterialForecastHostPaths.rejectLinks(cache);
            Files.createDirectories(cache);
            Path realCache=cache.toRealPath();
            MaterialForecastHostPaths.rejectLinks(realCache);
            List<String> command=new ArrayList<>();
            if(MaterialForecastHostPaths.windows()) {
                Path powershell=Path.of(System.getenv().getOrDefault("SystemRoot","C:\\Windows"),"System32/WindowsPowerShell/v1.0/powershell.exe");
                command.addAll(List.of(powershell.toString(),"-NoProfile","-NonInteractive","-ExecutionPolicy","Bypass","-File",payload.resolve("prepare_runtime.ps1").toString(),"-Payload",payload.toString(),"-Cache",cache.toString()));
                if(!properties.getBasePythonExecutable().isBlank())command.addAll(List.of("-BasePython",MaterialForecastHostPaths.absolute(properties.getBasePythonExecutable()).toString()));
            }else {
                String base=properties.getBasePythonExecutable().isBlank()?"/usr/bin/python3":MaterialForecastHostPaths.absolute(properties.getBasePythonExecutable()).toString();
                if(!Files.isExecutable(Path.of(base)))throw new Failure("BASE_PYTHON_UNAVAILABLE");
                command.addAll(List.of(base,"-I",payload.resolve("prepare_runtime.py").toString(),"--payload",payload.toString(),"--cache",cache.toString()));
            }
            if(abort.getAsBoolean())throw new Failure("CONFIGURATION_PENDING");
            Process process=builder(command,payload).start();preparation=process;
            var output=new BoundedOutput(process.getInputStream());Thread reader=new Thread(output,"material-runtime-preparation-output");reader.setDaemon(true);reader.start();
            long deadline=System.nanoTime()+Duration.ofMinutes(15).toNanos();
            while(!process.waitFor(250,TimeUnit.MILLISECONDS)) {
                if(abort.getAsBoolean()||System.nanoTime()>deadline){terminate(process);throw new Failure(abort.getAsBoolean()?"CONFIGURATION_PENDING":"PREPARATION_FAILED");}
            }
            reader.join(2000);
            if(output.failed||reader.isAlive())throw new Failure("PREPARATION_FAILED");
            var n=json.reader().with(DeserializationFeature.FAIL_ON_READING_DUP_TREE_KEY,DeserializationFeature.FAIL_ON_TRAILING_TOKENS).readTree(output.bytes.toByteArray());
            if(process.exitValue()!=0)throw new Failure(failureCode(n));
            Set<String> expected=Set.of("schemaVersion","state","platform","pythonExecutable","workerScript","catalog","lockDigest","workerVersion");
            Set<String> actual=new HashSet<>();n.fieldNames().forEachRemaining(actual::add);
            if(!actual.equals(expected)||!n.path("schemaVersion").isIntegralNumber()||!n.path("schemaVersion").canConvertToInt()||n.path("schemaVersion").intValue()!=1||!"READY".equals(n.path("state").asText())
                    ||!n.path("platform").asText().equals(MaterialForecastHostPaths.windows()?"windows-x86_64":"linux-x86_64"))throw new Failure("PREPARATION_FAILED");
            for(String field:List.of("pythonExecutable","workerScript","catalog","lockDigest","workerVersion")) {
                if(!n.path(field).isTextual())throw new Failure("PREPARATION_FAILED");
            }
            Path python=MaterialForecastHostPaths.absolute(n.path("pythonExecutable").asText()),worker=MaterialForecastHostPaths.absolute(n.path("workerScript").asText()),catalog=MaterialForecastHostPaths.absolute(n.path("catalog").asText());
            String digest=n.path("lockDigest").asText(),version=n.path("workerVersion").asText();
            if(python.getParent()==null||!python.getParent().toRealPath().startsWith(realCache)||!Files.isRegularFile(python)||!worker.equals(payload.resolve("worker.py"))||!catalog.equals(payload.resolve("material-benchmarks.json"))
                    ||!Files.isRegularFile(worker,LinkOption.NOFOLLOW_LINKS)||!Files.isRegularFile(catalog,LinkOption.NOFOLLOW_LINKS)||!digest.matches("[0-9a-f]{64}")||version.isBlank()||version.length()>128)throw new Failure("PREPARATION_FAILED");
            return new Prepared(python,worker,catalog,digest,version);
        }catch(Failure known){throw known;}catch(InterruptedException interrupted){Thread.currentThread().interrupt();throw new Failure("CONFIGURATION_PENDING");}
        catch(Exception invalid){throw new Failure("PREPARATION_FAILED");}
        finally{Process process=preparation;preparation=null;if(process!=null&&process.isAlive())terminate(process);}
    }
    public Process start(Prepared runtime,Policy policy,String runId)throws IOException {
        paths.ensureState();
        List<String> command=List.of(runtime.python().toString(),"-I",runtime.worker().toString(),"--auto","--output-directory",paths.stateDirectory().toString(),
                "--interval",Integer.toString(Math.multiplyExact(policy.intervalMinutes(),60)),"--history-days",Integer.toString(policy.historyDays()),
                "--backfill-budget",Integer.toString(policy.backfillBudget()),"--configuration-revision",policy.revision(),"--run-id",runId);
        return builder(command,paths.stateDirectory()).redirectOutput(ProcessBuilder.Redirect.DISCARD).start();
    }
    public void cancelPreparation(){Process process=preparation;if(process!=null)terminate(process);}
    static String failureCode(com.fasterxml.jackson.databind.JsonNode node) {
        if(node!=null&&node.isObject()&&node.path("schemaVersion").isIntegralNumber()&&node.path("schemaVersion").canConvertToInt()&&node.path("schemaVersion").intValue()==1
                &&"ERROR".equals(node.path("state").asText())&&node.path("errorCode").isTextual()) {
            String code=node.path("errorCode").asText();
            if(Set.of("BASE_PYTHON_UNAVAILABLE","RUNTIME_MISSING","PREPARATION_FAILED").contains(code))return code;
        }
        return "PREPARATION_FAILED";
    }
    static void requestStop(Process process,String runId) {
        if(process==null)return;
        try {
            if(runId!=null) {
                var input=process.getOutputStream();input.write(("STOP "+runId+"\n").getBytes(StandardCharsets.UTF_8));input.flush();
                if(process.waitFor(5,TimeUnit.SECONDS))return;
            }
        }catch(IOException|RuntimeException ignored) { }
        catch(InterruptedException interrupted){Thread.currentThread().interrupt();}
        terminate(process);
    }
    static ProcessBuilder builder(List<String> command,Path directory) {
        var builder=new ProcessBuilder(command).directory(directory.toFile()).redirectError(ProcessBuilder.Redirect.DISCARD);
        Map<String,String> original=new HashMap<>(builder.environment());builder.environment().clear();
        for(String name:List.of("SystemRoot","WINDIR","COMSPEC","TEMP","TMP","TMPDIR","LANG","LC_ALL","SSL_CERT_FILE","SSL_CERT_DIR")) {
            String value=original.get(name);if(value!=null)builder.environment().put(name,value);
        }
        if(MaterialForecastHostPaths.windows()) {
            Path systemRoot=MaterialForecastHostPaths.absolute(System.getenv().getOrDefault("SystemRoot","C:\\Windows"));
            Path drive=systemRoot.getRoot();
            if(drive==null||!drive.toString().matches("[A-Za-z]:[\\\\/]"))throw new IllegalStateException("Invalid Windows system drive");
            // Known-folder registry values expand this minimal OS variable even
            // when no application credentials or PATH are inherited by the child.
            builder.environment().put("SystemDrive",drive.toString().substring(0,2));
        }
        builder.environment().put("PYTHONUTF8","1");builder.environment().put("PYTHONIOENCODING","utf-8");
        for(String name:List.of("OMP_NUM_THREADS","OPENBLAS_NUM_THREADS","MKL_NUM_THREADS","NUMBA_NUM_THREADS"))builder.environment().put(name,"1");
        return builder;
    }
    static void terminate(Process process) {
        if(process==null)return;
        List<ProcessHandle> children;
        try{children=process.descendants().toList();}catch(RuntimeException unsupported){children=List.of();}
        children.forEach(ProcessHandle::destroy);process.destroy();
        try{
            process.waitFor(5,TimeUnit.SECONDS);
            children.stream().filter(ProcessHandle::isAlive).forEach(ProcessHandle::destroyForcibly);
            if(process.isAlive()){process.destroyForcibly();process.waitFor(5,TimeUnit.SECONDS);}
        }
        catch(InterruptedException interrupted){children.stream().filter(ProcessHandle::isAlive).forEach(ProcessHandle::destroyForcibly);process.destroyForcibly();Thread.currentThread().interrupt();}
    }
    private static final class BoundedOutput implements Runnable {
        final InputStream input;final ByteArrayOutputStream bytes=new ByteArrayOutputStream();volatile boolean failed;
        BoundedOutput(InputStream input){this.input=input;}
        @Override public void run(){try(input){byte[] buffer=new byte[4096];int count;while((count=input.read(buffer))!=-1){if(bytes.size()+count>65536){failed=true;return;}bytes.write(buffer,0,count);}}catch(IOException invalid){failed=true;}}
    }
}
