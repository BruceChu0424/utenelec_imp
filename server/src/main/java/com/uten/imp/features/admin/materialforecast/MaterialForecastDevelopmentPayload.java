package com.uten.imp.features.admin.materialforecast;

import com.fasterxml.jackson.databind.DeserializationFeature;
import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.config.props.MaterialForecastProperties;
import lombok.RequiredArgsConstructor;
import org.springframework.context.annotation.Profile;
import org.springframework.stereotype.Component;

import java.io.IOException;
import java.nio.file.Files;
import java.nio.file.LinkOption;
import java.nio.file.Path;
import java.time.Duration;
import java.util.ArrayList;
import java.util.List;
import java.util.concurrent.TimeUnit;
import java.util.function.BooleanSupplier;

/** Source launches use the same Git-bound builder and verified cache as developer tooling. */
@Component
@Profile("dev")
@RequiredArgsConstructor
public class MaterialForecastDevelopmentPayload {
    private final MaterialForecastProperties properties;
    private final ObjectMapper json;
    private volatile Process preparation;

    Path resolve(Path applicationHome,BooleanSupplier abort) {
        Path repository=sourceCheckout(applicationHome);
        if(repository==null)return null;
        if(abort.getAsBoolean())throw new MaterialForecastProcessLauncher.Failure("CONFIGURATION_PENDING");
        Process process=null;
        try {
            MaterialForecastHostPaths.rejectLinks(repository);
            process=start(command(repository),repository);preparation=process;
            var output=new MaterialForecastProcessLauncher.BoundedOutput(process.getInputStream());
            Thread reader=new Thread(output,"material-development-payload-output");reader.setDaemon(true);reader.start();
            long deadline=System.nanoTime()+Duration.ofMinutes(15).toNanos();
            while(!process.waitFor(250,TimeUnit.MILLISECONDS)) {
                if(abort.getAsBoolean())throw new MaterialForecastProcessLauncher.Failure("CONFIGURATION_PENDING");
                if(System.nanoTime()>deadline)throw new MaterialForecastProcessLauncher.Failure("PREPARATION_FAILED");
            }
            reader.join(2000);
            if(output.failed||reader.isAlive())throw new MaterialForecastProcessLauncher.Failure("PREPARATION_FAILED");
            JsonNode receipt=json.reader().with(DeserializationFeature.FAIL_ON_READING_DUP_TREE_KEY,
                    DeserializationFeature.FAIL_ON_TRAILING_TOKENS).readTree(output.bytes.toByteArray());
            if(process.exitValue()!=0)throw new MaterialForecastProcessLauncher.Failure(MaterialForecastProcessLauncher.failureCode(receipt));
            return verifiedDirectory(receipt,repository);
        }catch(InterruptedException interrupted) {
            Thread.currentThread().interrupt();throw new MaterialForecastProcessLauncher.Failure("CONFIGURATION_PENDING");
        }catch(MaterialForecastProcessLauncher.Failure failure) {throw failure;}
        catch(Exception invalid) {throw new MaterialForecastProcessLauncher.Failure("PREPARATION_FAILED");}
        finally {
            preparation=null;
            if(process!=null&&process.isAlive())MaterialForecastProcessLauncher.terminate(process);
        }
    }

    /** Packaged JARs never acquire a source-checkout fallback, even with the dev profile. */
    static Path sourceCheckout(Path applicationHome) {
        Path home=applicationHome.toAbsolutePath().normalize();
        if(home.getFileName()==null||!"classes".equals(home.getFileName().toString()))return null;
        for(Path candidate=home.getParent();candidate!=null;candidate=candidate.getParent()) {
            if(Files.exists(candidate.resolve(".git"),LinkOption.NOFOLLOW_LINKS)
                    &&Files.isRegularFile(candidate.resolve("server/pom.xml"),LinkOption.NOFOLLOW_LINKS)
                    &&Files.isRegularFile(candidate.resolve("services/material_forecast/build_payload.py"),LinkOption.NOFOLLOW_LINKS)
                    &&home.startsWith(candidate.resolve("server")))return candidate;
        }
        return null;
    }

    List<String> command(Path repository) {
        List<String> command=new ArrayList<>();
        String base=properties.getBasePythonExecutable();
        if(MaterialForecastHostPaths.windows()) {
            Path powershell=Path.of(System.getenv().getOrDefault("SystemRoot","C:\\Windows"),"System32/WindowsPowerShell/v1.0/powershell.exe");
            command.addAll(List.of(powershell.toString(),"-NoProfile","-NonInteractive","-ExecutionPolicy","Bypass","-File",
                    repository.resolve("services/material_forecast/prepare_runtime.ps1").toString(),"-DevelopmentCache"));
            if(!base.isBlank())command.addAll(List.of("-BasePython",MaterialForecastHostPaths.absolute(base).toString()));
        }else {
            command.addAll(List.of(base.isBlank()?"/usr/bin/python3":MaterialForecastHostPaths.absolute(base).toString(),"-I",
                    repository.resolve("services/material_forecast/build_payload.py").toString(),"--development-cache"));
        }
        return command;
    }

    Process start(List<String> command,Path repository)throws IOException {
        var builder=MaterialForecastProcessLauncher.builder(command,repository);
        // Only developer builds need Git discovery and the user's payload-cache root.
        // The managed worker and production preparation retain the stricter environment.
        for(String name:List.of("PATH","LOCALAPPDATA","USERPROFILE","HOME")) {
            String value=System.getenv(name);if(value!=null)builder.environment().put(name,value);
        }
        return builder.redirectError(ProcessBuilder.Redirect.INHERIT).start();
    }

    static Path verifiedDirectory(JsonNode receipt,Path repository)throws IOException {
        if(receipt==null||!receipt.isObject()||!receipt.path("verified").isBoolean()||!receipt.path("verified").booleanValue()
                ||!"material-forecast".equals(receipt.path("component").asText())
                ||!receipt.path("payload").isTextual()||!receipt.path("sourceIdentity").isTextual()
                ||!receipt.path("sourceIdentity").asText().matches("[0-9a-f]{64}"))
            throw new MaterialForecastProcessLauncher.Failure("PREPARATION_FAILED");
        Path payload=MaterialForecastHostPaths.absolute(receipt.path("payload").asText());
        MaterialForecastHostPaths.rejectLinks(payload);
        if(payload.startsWith(repository)||payload.getFileName()==null
                ||!payload.getFileName().toString().equals(receipt.path("sourceIdentity").asText())
                ||!Files.isDirectory(payload,LinkOption.NOFOLLOW_LINKS)||!payload.toRealPath().equals(payload))
            throw new MaterialForecastProcessLauncher.Failure("PREPARATION_FAILED");
        return payload;
    }

    void cancel(){Process process=preparation;if(process!=null)MaterialForecastProcessLauncher.terminate(process);}
}
