package com.uten.imp.businesschain;

import java.nio.file.Files;
import java.nio.file.Path;
import java.time.Duration;
import java.util.Map;
import java.util.List;
import java.util.UUID;
import jdk.jfr.Configuration;
import jdk.jfr.Recording;
import jdk.jfr.RecordingState;

/** Explicit, test-only operation profiling; ordinary CI starts no recording. */
final class ProductionOperationProfile implements AutoCloseable {
    private final Recording recording;
    private final Path path;
    private boolean written;

    private ProductionOperationProfile(Recording recording, Path path) {
        this.recording=recording;
        this.path=path;
    }

    static ProductionOperationProfile start(String operation,int products) throws Exception {
        if(!operation.equals(System.getProperty("uten.production.jfr.operation"))
                ||products!=Integer.getInteger("uten.production.jfr.products",500)) {
            return new ProductionOperationProfile(null,null);
        }
        Path directory=Path.of(System.getProperty("uten.build.directory","target"),"jfr").toAbsolutePath();
        Files.createDirectories(directory);
        Path path=directory.resolve(operation.replaceAll("[^A-Za-z0-9._-]","_")+"-"+products+"-"+UUID.randomUUID()+".jfr");
        Recording recording=new Recording(Configuration.getConfiguration("profile"));
        recording.setName("material-"+operation+"-"+products);
        recording.setToDisk(true);
        recording.setMaxSize(256L*1024*1024);
        // Profiling needs stacks and allocation samples, never environment
        // values, process arguments or object-content descriptions.
        for(String event:List.of("jdk.InitialEnvironmentVariable","jdk.InitialSystemProperty",
                "jdk.InitialSecurityProperty","jdk.SystemProcess","jdk.JVMInformation","jdk.OldObjectSample")) {
            recording.disable(event);
        }
        recording.enable("jdk.ExecutionSample").withPeriod(Duration.ofMillis(10));
        recording.enable("jdk.NativeMethodSample").withPeriod(Duration.ofMillis(10));
        recording.start();
        return new ProductionOperationProfile(recording,path);
    }

    /** Stop before diagnostic response-size serialization; record the domain operation only. */
    void complete(Map<String,Object> measurement) throws Exception {
        if(recording==null)return;
        write();
        measurement.put("jfrFile",path.toString());
    }

    private void write() throws Exception {
        if(written)return;
        if(recording.getState()==RecordingState.RUNNING)recording.stop();
        recording.dump(path);
        written=true;
    }

    @Override public void close() throws Exception {
        if(recording==null)return;
        try { write(); }
        finally { recording.close(); }
    }
}
