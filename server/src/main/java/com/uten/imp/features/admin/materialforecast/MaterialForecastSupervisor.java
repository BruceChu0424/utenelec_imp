package com.uten.imp.features.admin.materialforecast;

import com.fasterxml.jackson.databind.DeserializationFeature;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.application.port.MaterialForecastRuntimePort.Policy;
import com.uten.imp.application.port.MaterialForecastRuntimePort.State;
import com.uten.imp.config.props.DeploymentProperties;
import com.uten.imp.config.props.MaterialForecastProperties;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.context.SmartLifecycle;
import org.springframework.context.annotation.Profile;
import org.springframework.stereotype.Component;
import java.io.IOException;
import java.nio.ByteBuffer;
import java.nio.channels.*;
import java.nio.file.*;
import java.time.*;
import java.util.*;
import java.util.concurrent.*;

/** Owns one collector, with an OS lease and a run-specific acknowledgement. HTTP never starts work. */
@Component
@Profile("!cloud")
public class MaterialForecastSupervisor implements SmartLifecycle {
    private final MaterialForecastPolicyService policy;
    private final MaterialForecastHostPaths paths;
    private final MaterialForecastProcessLauncher launcher;
    private final MaterialForecastProperties properties;
    private final DeploymentProperties deployment;
    private final ObjectMapper json;
    private final Clock clock;
    private final Object processLock=new Object();
    private volatile boolean running;
    private volatile Process worker;
    private volatile String workerRevision,runId;
    private volatile Instant startedAt,lastExitAt,lastReconcileAt,nextStart=Instant.EPOCH;
    private volatile Instant lastAcknowledgedAt;
    private volatile Integer lastExitCode;
    private volatile String phase="UNAVAILABLE",error="CONFIGURATION_PENDING";
    private volatile String appliedDisabledRevision;
    private volatile MaterialForecastProcessLauncher.Prepared prepared;
    private ScheduledExecutorService executor;
    private FileChannel leaseChannel;
    private FileLock lease;
    private int failures;
    private record OwnedDescendant(ProcessHandle process,Instant started) {}
    private final ConcurrentMap<Long,OwnedDescendant> descendants=new ConcurrentHashMap<>();

    @Autowired public MaterialForecastSupervisor(MaterialForecastPolicyService policy,MaterialForecastHostPaths paths,
            MaterialForecastProcessLauncher launcher,MaterialForecastProperties properties,DeploymentProperties deployment,ObjectMapper json) {
        this(policy,paths,launcher,properties,deployment,json,Clock.systemUTC());
    }
    MaterialForecastSupervisor(MaterialForecastPolicyService policy,MaterialForecastHostPaths paths,
            MaterialForecastProcessLauncher launcher,MaterialForecastProperties properties,DeploymentProperties deployment,ObjectMapper json,Clock clock) {
        this.policy=policy;this.paths=paths;this.launcher=launcher;this.properties=properties;this.deployment=deployment;this.json=json;this.clock=clock;
    }
    @Override public void start() {
        if(running) { return; }
        if(!properties.isManageRuntime()) { phase="UNAVAILABLE";error="CONFIGURATION_PENDING";return; }
        if(!local()) { phase="NOT_LOCAL";error=null;return; }
        running=true;
        executor=Executors.newSingleThreadScheduledExecutor(task->{var thread=new Thread(task,"material-forecast-supervisor");thread.setDaemon(true);return thread;});
        executor.scheduleWithFixedDelay(this::reconcileSafely,0,15,TimeUnit.SECONDS);
    }
    private void reconcileSafely() {
        try { reconcile(); }
        catch(RuntimeException failure) {
            phase="UNAVAILABLE";error="CONFIGURATION_PENDING";
            stopOwned();
        }
    }
    void reconcile() {
        if(!running) { return; }
        lastReconcileAt=clock.instant();
        Policy desired=policy.current();
        if(!local()) {
            stopOwned();phase="NOT_LOCAL";error=null;return;
        }
        if(!properties.isManageRuntime()) {
            stopOwned();phase="UNAVAILABLE";error="CONFIGURATION_PENDING";return;
        }
        try {
            paths.ensureState();
            if(!acquireLease()) { phase="UNAVAILABLE";error="COLLECTOR_BUSY";return; }
        }catch(IOException|RuntimeException unavailable) {
            phase="UNAVAILABLE";error="RUNTIME_MISSING";return;
        }
        if(!desired.enabled()) {
            phase="STOPPING";
            if(!stopOwned()) { phase="ERROR";error="WORKER_UNRESPONSIVE";return; }
            if(collectorBusy()) { phase="UNAVAILABLE";error="COLLECTOR_BUSY";appliedDisabledRevision=null;return; }
            phase="DISABLED";error=null;appliedDisabledRevision=desired.revision();releaseLease();return;
        }
        appliedDisabledRevision=null;
        Process current=worker;
        rememberDescendants(current);
        if(current!=null&&!current.isAlive()) {
            if(!stopKnownDescendants()) {phase="ERROR";error="WORKER_UNRESPONSIVE";return;}
            lastExitAt=clock.instant();lastExitCode=current.exitValue();worker=null;
            prepared=null;
            failures=Math.min(8,failures+1);nextStart=clock.instant().plusSeconds(Math.min(300,15L<<failures));
            phase="ERROR";error="PROCESS_EXITED";return;
        }
        if(current!=null&&desired.revision().equals(workerRevision)) {
            if(acknowledgedFile(desired)) { phase="RUNNING";error=null;failures=0; }
            else if(startedAt!=null&&startedAt.isBefore(clock.instant().minus(Duration.ofMinutes(3)))) {
                phase="ERROR";error="WORKER_UNRESPONSIVE";
                stopOwned();nextStart=clock.instant().plusSeconds(30);
            }else { phase="STARTING";error="CONFIGURATION_PENDING"; }
            return;
        }
        if(current!=null) {
            phase="STOPPING";
            if(!stopOwned()) { phase="ERROR";error="WORKER_UNRESPONSIVE";return; }
            nextStart=Instant.EPOCH;
        }
        if(clock.instant().isBefore(nextStart)) { return; }
        if(collectorBusy()) { phase="UNAVAILABLE";error="COLLECTOR_BUSY";return; }
        if(prepared==null) {
            phase="PREPARING";error=null;
            try {
                final long[] nextProbe={0};
                prepared=launcher.prepare(()->{
                    if(!running) { return true; }
                    if(System.nanoTime()<nextProbe[0]) { return false; }
                    nextProbe[0]=System.nanoTime()+TimeUnit.SECONDS.toNanos(15);
                    return !policy.current().revision().equals(desired.revision());
                });
            }catch(MaterialForecastProcessLauncher.Failure failure) {
                phase="UNAVAILABLE";error=failure.code();nextStart=clock.instant().plusSeconds(60);return;
            }
        }
        if(!running||!policy.current().revision().equals(desired.revision())) { phase="STARTING";error="CONFIGURATION_PENDING";return; }
        try {
            synchronized(processLock) {
                if(!running) { return; }
                runId=UUID.randomUUID().toString();workerRevision=desired.revision();startedAt=clock.instant();
                worker=launcher.start(prepared,desired,runId);
            }
            phase="STARTING";error="CONFIGURATION_PENDING";
        }catch(IOException|RuntimeException failure) {
            prepared=null;phase="ERROR";error="START_FAILED";nextStart=clock.instant().plusSeconds(60);
        }
    }
    public State state(Policy desired) {
        Process current=worker;boolean alive=current!=null&&current.isAlive();
        rememberDescendants(current);
        boolean applied=desired.enabled()?alive&&acknowledgedFile(desired):!alive&&desired.revision().equals(appliedDisabledRevision)
                &&lastReconcileAt!=null&&lastReconcileAt.isAfter(clock.instant().minusSeconds(30));
        String currentPhase=applied?(desired.enabled()?"RUNNING":"DISABLED"):phase;
        String currentError=applied?null:error;
        if(!applied&&"RUNNING".equals(currentPhase)) { currentPhase="STARTING";currentError="CONFIGURATION_PENDING"; }
        if(!applied&&!desired.enabled()&&alive) { currentPhase="STOPPING";currentError="CONFIGURATION_PENDING"; }
        return new State(currentPhase,prepared!=null,alive,desired.revision(),applied?desired.revision():null,applied,
                text(startedAt),text(lastExitAt),lastExitCode,currentError);
    }
    public boolean acknowledges(Instant generated,String revision,String acknowledgedRun,Policy desired) {
        Process current=worker;
        rememberDescendants(current);
        boolean accepted=running&&local()&&properties.isManageRuntime()&&current!=null&&current.isAlive()&&lease!=null&&lease.isValid()&&desired.enabled()
                &&desired.revision().equals(workerRevision)&&desired.revision().equals(revision)&&Objects.equals(runId,acknowledgedRun)
                &&generated!=null&&startedAt!=null&&!generated.isBefore(startedAt)&&!generated.isAfter(clock.instant())
                &&generated.isAfter(clock.instant().minusSeconds(90));
        if(accepted) { lastAcknowledgedAt=generated; }
        return accepted;
    }
    public Instant confirmationExpiresAt(Policy desired) {
        if(!desired.enabled()) { return lastReconcileAt==null?null:lastReconcileAt.plusSeconds(30); }
        return lastAcknowledgedAt==null?null:lastAcknowledgedAt.plusSeconds(90);
    }
    private boolean acknowledgedFile(Policy desired) {
        try {
            Path file=paths.stateDirectory().resolve("auto-feed-health.json");
            if(!Files.isRegularFile(file,LinkOption.NOFOLLOW_LINKS)||Files.size(file)>65536) { return false; }
            ByteBuffer bytes=ByteBuffer.allocate(65537);
            try(var channel=Files.newByteChannel(file,Set.of(StandardOpenOption.READ,LinkOption.NOFOLLOW_LINKS))) {
                while(bytes.hasRemaining()&&channel.read(bytes)!=-1) { }
            }
            if(bytes.position()>65536) { return false; }
            var n=json.reader().with(DeserializationFeature.FAIL_ON_READING_DUP_TREE_KEY,DeserializationFeature.FAIL_ON_TRAILING_TOKENS).readTree(Arrays.copyOf(bytes.array(),bytes.position()));
            if(!n.path("schemaVersion").isIntegralNumber()||n.path("schemaVersion").intValue()!=1||!n.path("autoUpdateEnabled").isBoolean()||!n.path("autoUpdateEnabled").booleanValue()
                    ||!n.path("configRevision").isTextual()||!n.path("runId").isTextual()||!n.path("generatedAt").isTextual()||!n.path("generatedAt").asText().endsWith("Z")) { return false; }
            return acknowledges(Instant.parse(n.path("generatedAt").asText()),n.path("configRevision").asText(),n.path("runId").asText(),desired);
        }catch(IOException|RuntimeException invalid) { return false; }
    }
    private boolean acquireLease()throws IOException {
        synchronized(processLock) {
            if(!running) { return false; }
            if(lease!=null&&lease.isValid()) { return true; }
            Path file=paths.stateDirectory().resolve("managed-supervisor.lock");
            if(Files.isSymbolicLink(file)) { return false; }
            leaseChannel=FileChannel.open(file,StandardOpenOption.CREATE,StandardOpenOption.WRITE,LinkOption.NOFOLLOW_LINKS);
            try { lease=leaseChannel.tryLock(0,1,false); }
            catch(OverlappingFileLockException occupied) { lease=null; }
            catch(IOException failed) { leaseChannel.close();leaseChannel=null;throw failed; }
            if(lease==null) { leaseChannel.close();leaseChannel=null;return false; }
            return true;
        }
    }
    private boolean collectorBusy() {
        try {
            Path file=paths.stateDirectory().resolve(".auto-feed/collector.lock");
            if(Files.notExists(file,LinkOption.NOFOLLOW_LINKS)) { return false; }
            MaterialForecastHostPaths.rejectLinks(file);
            try(var channel=FileChannel.open(file,StandardOpenOption.WRITE,LinkOption.NOFOLLOW_LINKS)) {
                try(var probe=channel.tryLock(0,1,false)) { return probe==null; }
                catch(OverlappingFileLockException occupied) { return true; }
            }
        }catch(IOException|RuntimeException unavailable) { return true; }
    }
    private boolean stopOwned() {
        synchronized(processLock) {
            Process current=worker;
            if(current==null) { return stopKnownDescendants(); }
            rememberDescendants(current);
            MaterialForecastProcessLauncher.requestStop(current,runId);
            if(!stopKnownDescendants()||current.isAlive()) { return false; }
            lastExitAt=clock.instant();lastExitCode=current.exitValue();worker=null;workerRevision=null;runId=null;
            return true;
        }
    }
    private void rememberDescendants(Process parent) {
        if(parent==null||!parent.isAlive()) { return; }
        try {
            parent.descendants().limit(64).forEach(child->{
                Instant started=child.info().startInstant().orElse(null);
                if(started!=null) { descendants.put(child.pid(),new OwnedDescendant(child,started)); }
            });
        }catch(RuntimeException unavailable) { /* A late exit never authorizes scanning unrelated processes. */ }
    }
    private boolean stopKnownDescendants() {
        var owned=descendants.values().stream().filter(this::stillOwned).toList();
        owned.forEach(child->child.process().destroy());
        long deadline=System.nanoTime()+TimeUnit.SECONDS.toNanos(5);
        try {
            while(owned.stream().anyMatch(this::stillOwned)&&System.nanoTime()<deadline) { Thread.sleep(20); }
            owned.stream().filter(this::stillOwned).forEach(child->child.process().destroyForcibly());
            deadline=System.nanoTime()+TimeUnit.SECONDS.toNanos(5);
            while(owned.stream().anyMatch(this::stillOwned)&&System.nanoTime()<deadline) { Thread.sleep(20); }
        }catch(InterruptedException interrupted) {
            owned.stream().filter(this::stillOwned).forEach(child->child.process().destroyForcibly());Thread.currentThread().interrupt();
        }
        descendants.entrySet().removeIf(entry->!stillOwned(entry.getValue()));
        return descendants.values().stream().noneMatch(this::stillOwned);
    }
    private boolean stillOwned(OwnedDescendant child) {
        return child.process().isAlive()&&child.process().info().startInstant().filter(child.started()::equals).isPresent();
    }
    private boolean local(){return "local".equalsIgnoreCase(deployment.getSite());}
    private void releaseLease() {
        synchronized(processLock) {
            try {
                if(lease!=null) { lease.release();lease=null; }
                if(leaseChannel!=null) { leaseChannel.close();leaseChannel=null; }
            }catch(IOException ignored) { }
        }
    }
    @Override public void stop(){stop(()->{});}
    @Override public void stop(Runnable callback) {
        running=false;
        Thread closing=new Thread(()->{
            try {
                if(executor!=null) { executor.shutdownNow(); }
                try { launcher.cancelPreparation(); }
                finally { stopOwned(); }
                if(executor!=null) { executor.awaitTermination(12,TimeUnit.SECONDS); }
            }catch(InterruptedException interrupted) { Thread.currentThread().interrupt(); }
            finally { releaseLease();callback.run(); }
        },"material-forecast-stop");closing.setDaemon(true);closing.start();
    }
    @Override public boolean isRunning(){return running;}
    @Override public boolean isAutoStartup(){return properties.isManageRuntime()&&local();}
    @Override public int getPhase(){return Integer.MAX_VALUE-100;}
    private static String text(Instant value){return value==null?null:value.toString();}
}
