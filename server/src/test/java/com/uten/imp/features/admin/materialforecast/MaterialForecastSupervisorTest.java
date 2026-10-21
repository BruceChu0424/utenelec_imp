package com.uten.imp.features.admin.materialforecast;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.application.port.MaterialForecastRuntimePort.Policy;
import com.uten.imp.config.props.DeploymentProperties;
import com.uten.imp.config.props.MaterialForecastProperties;
import com.uten.imp.config.props.StorageProperties;
import org.junit.jupiter.api.*;
import org.junit.jupiter.api.io.TempDir;
import org.springframework.test.util.ReflectionTestUtils;
import java.io.*;
import java.nio.channels.FileChannel;
import java.nio.file.*;
import java.time.*;
import java.util.*;
import java.util.concurrent.*;
import java.util.concurrent.atomic.AtomicReference;
import java.util.function.BooleanSupplier;
import static org.assertj.core.api.Assertions.*;
import static org.mockito.Mockito.*;

class MaterialForecastSupervisorTest {
    @TempDir Path directory;
    final ObjectMapper json=new ObjectMapper();
    final MutableClock clock=new MutableClock();
    final List<MaterialForecastSupervisor> supervisors=new ArrayList<>();
    MaterialForecastProperties properties;DeploymentProperties deployment;MaterialForecastHostPaths paths;
    MaterialForecastPolicyService policies;MaterialForecastProcessLauncher launcher;
    AtomicReference<Policy> desired;final List<OwnedProcess> children=new ArrayList<>();
    final AtomicReference<String> run=new AtomicReference<>();
    @BeforeEach void setup()throws Exception {
        properties=new MaterialForecastProperties();properties.setSnapshotDirectory(directory.resolve("state").toString());
        properties.setCacheDirectory(directory.resolve("cache").toString());properties.setPayloadDirectory(directory.resolve("payload").toString());
        deployment=new DeploymentProperties();paths=new MaterialForecastHostPaths(new StorageProperties(),properties);
        policies=mock(MaterialForecastPolicyService.class);desired=new AtomicReference<>(MaterialForecastPolicyService.policy(true,15,1200,30));
        when(policies.current()).thenAnswer(call->desired.get());launcher=mock(MaterialForecastProcessLauncher.class);
        when(launcher.prepare(any(BooleanSupplier.class))).thenReturn(new MaterialForecastProcessLauncher.Prepared(directory.resolve("python"),directory.resolve("worker.py"),directory.resolve("catalog.json"),"a".repeat(64),"test"));
        when(launcher.start(any(),any(),anyString())).thenAnswer(call->{run.set(call.getArgument(2));var child=new OwnedProcess();children.add(child);return child;});
    }
    MaterialForecastSupervisor supervisor() {
        var value=new MaterialForecastSupervisor(policies,paths,launcher,properties,deployment,json,clock);
        // Exercise deterministic individual cycles; the real private scheduler is covered by opt-in runtime integration.
        ReflectionTestUtils.setField(value,"running",true);supervisors.add(value);return value;
    }
    @AfterEach void close()throws Exception {
        for(var supervisor:supervisors) { var stopped=new CountDownLatch(1);supervisor.stop(stopped::countDown);assertThat(stopped.await(5,TimeUnit.SECONDS)).isTrue(); }
    }
    void heartbeat(String revision,String id,Instant generated)throws Exception {
        paths.ensureState();Files.writeString(paths.stateDirectory().resolve("auto-feed-health.json"),json.writeValueAsString(Map.of(
                "schemaVersion",1,"workerVersion","test","generatedAt",generated.toString(),"autoUpdateEnabled",true,"configRevision",revision,"runId",id,"series",List.of())));
    }
    @Test void aSavedPolicyAndLiveProcessDoNotClaimApplicationBeforeItsOwnHeartbeat()throws Exception {
        var supervisor=supervisor();supervisor.reconcile();var state=supervisor.state(desired.get());
        assertThat(state.state()).isEqualTo("STARTING");assertThat(state.processRunning()).isTrue();assertThat(state.configurationApplied()).isFalse();
        heartbeat(desired.get().revision(),run.get(),clock.instant());
        state=supervisor.state(desired.get());assertThat(state.state()).isEqualTo("RUNNING");assertThat(state.configurationApplied()).isTrue();assertThat(state.appliedRevision()).isEqualTo(desired.get().revision());
    }
    @Test void restoredOldWrongRunOrStaleHeartbeatsCannotAcknowledgeANewProcess()throws Exception {
        var supervisor=supervisor();supervisor.reconcile();
        heartbeat(desired.get().revision(),run.get(),clock.instant().minusSeconds(1));assertThat(supervisor.state(desired.get()).configurationApplied()).isFalse();
        heartbeat(desired.get().revision(),UUID.randomUUID().toString(),clock.instant());assertThat(supervisor.state(desired.get()).configurationApplied()).isFalse();
        heartbeat(desired.get().revision(),run.get(),clock.instant());clock.advance(Duration.ofSeconds(91));assertThat(supervisor.state(desired.get()).configurationApplied()).isFalse();
    }
    @Test void changingPolicyStopsOnlyTheOwnedWorkerAndRequiresANewRunAcknowledgement()throws Exception {
        var supervisor=supervisor();supervisor.reconcile();String firstRun=run.get();
        heartbeat(desired.get().revision(),firstRun,clock.instant());assertThat(supervisor.state(desired.get()).configurationApplied()).isTrue();
        desired.set(MaterialForecastPolicyService.policy(true,30,1500,50));assertThat(supervisor.state(desired.get()).configurationApplied()).isFalse();
        supervisor.reconcile();assertThat(children).hasSize(2);assertThat(children.getFirst().alive).isFalse();assertThat(run.get()).isNotEqualTo(firstRun);
        assertThat(supervisor.state(desired.get()).configurationApplied()).isFalse();
        heartbeat(desired.get().revision(),run.get(),clock.instant());assertThat(supervisor.state(desired.get()).configurationApplied()).isTrue();
        assertThat(children.getFirst().commands.toString()).startsWith("STOP "+firstRun);
    }
    @Test void explicitDisableIsAppliedOnlyAfterTheOwnedCollectorHasStopped() {
        var supervisor=supervisor();supervisor.reconcile();desired.set(MaterialForecastPolicyService.policy(false,15,1200,30));
        assertThat(supervisor.state(desired.get()).configurationApplied()).isFalse();supervisor.reconcile();
        var state=supervisor.state(desired.get());assertThat(state.state()).isEqualTo("DISABLED");assertThat(state.processRunning()).isFalse();assertThat(state.configurationApplied()).isTrue();assertThat(state.appliedRevision()).isEqualTo(desired.get().revision());
    }
    @Test void anUnknownCollectorLeasePreventsFalseDisabledAcknowledgementWithoutKillingAnything()throws Exception {
        desired.set(MaterialForecastPolicyService.policy(false,15,1200,30));Path lock=paths.stateDirectory().resolve(".auto-feed/collector.lock");Files.createDirectories(lock.getParent());
        var supervisor=supervisor();
        try(var external=FileChannel.open(lock,StandardOpenOption.CREATE,StandardOpenOption.WRITE);var lease=external.lock(0,1,false)) {
            supervisor.reconcile();assertThat(supervisor.state(desired.get()).configurationApplied()).isFalse();assertThat(supervisor.state(desired.get()).lastErrorCode()).isEqualTo("COLLECTOR_BUSY");verifyNoInteractions(launcher);
        }
        supervisor.reconcile();assertThat(supervisor.state(desired.get()).configurationApplied()).isTrue();
    }
    @Test void twoSupervisorsSharingOneStateDirectoryCannotLaunchDuplicateCollectors()throws Exception {
        var first=supervisor();var second=supervisor();first.reconcile();second.reconcile();
        assertThat(children).hasSize(1);assertThat(second.state(desired.get()).lastErrorCode()).isEqualTo("COLLECTOR_BUSY");assertThat(children.getFirst().alive).isTrue();
        var closed=new CountDownLatch(1);first.stop(closed::countDown);assertThat(closed.await(5,TimeUnit.SECONDS)).isTrue();second.reconcile();assertThat(children).hasSize(2);
    }
    @Test void anUnexpectedCrashUsesBackoffBeforeLaunchingANewOwnedRun() {
        var supervisor=supervisor();supervisor.reconcile();children.getFirst().crash(7);supervisor.reconcile();
        assertThat(supervisor.state(desired.get()).lastExitCode()).isEqualTo(7);assertThat(supervisor.state(desired.get()).lastErrorCode()).isEqualTo("PROCESS_EXITED");
        supervisor.reconcile();assertThat(children).hasSize(1);clock.advance(Duration.ofSeconds(61));supervisor.reconcile();assertThat(children).hasSize(2);
    }
    @Test void aRedirectorParentCrashTerminatesItsPreviouslyObservedRealInterpreter()throws Exception {
        var supervisor=supervisor();supervisor.reconcile();
        var interpreter=mock(ProcessHandle.class);var info=mock(ProcessHandle.Info.class);var alive=new java.util.concurrent.atomic.AtomicBoolean(true);
        when(interpreter.pid()).thenReturn(4321L);when(interpreter.info()).thenReturn(info);when(info.startInstant()).thenReturn(Optional.of(clock.instant()));when(interpreter.isAlive()).thenAnswer(call->alive.get());
        when(interpreter.destroy()).thenAnswer(call->{alive.set(false);return true;});children.getFirst().nested.add(interpreter);
        heartbeat(desired.get().revision(),run.get(),clock.instant());assertThat(supervisor.state(desired.get()).configurationApplied()).isTrue();
        children.getFirst().crash(9);supervisor.reconcile();verify(interpreter).destroy();assertThat(alive.get()).isFalse();
    }
    @Test void aReusedPidIsNotMistakenForThePreviouslyOwnedChild()throws Exception {
        var supervisor=supervisor();supervisor.reconcile();var interpreter=mock(ProcessHandle.class);var info=mock(ProcessHandle.Info.class);
        when(interpreter.pid()).thenReturn(4321L);when(interpreter.info()).thenReturn(info);when(info.startInstant()).thenReturn(Optional.of(clock.instant()));when(interpreter.isAlive()).thenReturn(true);children.getFirst().nested.add(interpreter);
        supervisor.state(desired.get());when(info.startInstant()).thenReturn(Optional.of(clock.instant().plusSeconds(1)));children.getFirst().crash(9);supervisor.reconcile();
        verify(interpreter,never()).destroy();verify(interpreter,never()).destroyForcibly();
    }
    @Test void nonlocalAndTestDisabledModesNeverPrepareOrLaunchAProcess() {
        var supervisor=supervisor();deployment.setSite("cloud");supervisor.reconcile();assertThat(supervisor.state(desired.get()).state()).isEqualTo("NOT_LOCAL");
        deployment.setSite("local");properties.setManageRuntime(false);supervisor.reconcile();assertThat(supervisor.state(desired.get()).state()).isEqualTo("UNAVAILABLE");verifyNoInteractions(launcher);
        assertThat(Files.exists(paths.stateDirectory())).isFalse();
    }
    @Test void disabledLifecycleCreatesNoSchedulerAndDoesNotPollTheDatabase() {
        properties.setManageRuntime(false);
        var supervisor=new MaterialForecastSupervisor(policies,paths,launcher,properties,deployment,json,clock);supervisors.add(supervisor);
        assertThat(supervisor.isAutoStartup()).isFalse();supervisor.start();assertThat(supervisor.isRunning()).isFalse();
        verifyNoInteractions(policies,launcher);
        assertThat(supervisor.state(desired.get()).state()).isEqualTo("UNAVAILABLE");
    }
    @Test void policyRevisionIsPortableAndChangesWithEveryEffectiveSetting() {
        var base=MaterialForecastPolicyService.policy(true,15,1200,30);assertThat(base.revision()).matches("[0-9a-f]{64}");assertThat(MaterialForecastPolicyService.policy(true,15,1200,30)).isEqualTo(base);
        assertThat(List.of(MaterialForecastPolicyService.policy(false,15,1200,30),MaterialForecastPolicyService.policy(true,16,1200,30),MaterialForecastPolicyService.policy(true,15,1201,30),MaterialForecastPolicyService.policy(true,15,1200,31))).allMatch(p->!p.revision().equals(base.revision()));
    }
    static final class MutableClock extends Clock {
        Instant now=Instant.parse("2026-10-21T06:00:00Z");
        void advance(Duration amount){now=now.plus(amount);}
        @Override public ZoneId getZone(){return ZoneOffset.UTC;}
        @Override public Clock withZone(ZoneId zone){return this;}
        @Override public Instant instant(){return now;}
    }
    static final class OwnedProcess extends Process {
        boolean alive=true;int exit;final StringBuilder commands=new StringBuilder();
        final List<ProcessHandle> nested=new ArrayList<>();
        @Override public OutputStream getOutputStream(){return new OutputStream(){@Override public void write(int value){commands.append((char)value);}@Override public void flush(){if(commands.toString().startsWith("STOP ")){alive=false;}}};}
        @Override public InputStream getInputStream(){return InputStream.nullInputStream();}
        @Override public InputStream getErrorStream(){return InputStream.nullInputStream();}
        @Override public int waitFor(){return exit;}
        @Override public boolean waitFor(long timeout,TimeUnit unit){return !alive;}
        @Override public int exitValue(){if(alive){throw new IllegalThreadStateException();}return exit;}
        @Override public void destroy(){alive=false;}
        @Override public Process destroyForcibly(){alive=false;return this;}
        @Override public boolean isAlive(){return alive;}
        @Override public java.util.stream.Stream<ProcessHandle> descendants(){return nested.stream();}
        void crash(int code){exit=code;alive=false;}
    }
}
