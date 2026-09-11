package com.uten.imp.features.admin.serverstatus;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.config.props.StorageProperties;
import io.micrometer.core.instrument.simple.SimpleMeterRegistry;
import org.junit.jupiter.api.Test;
import org.springframework.scheduling.support.ScheduledMethodRunnable;

import javax.sql.DataSource;
import java.sql.Connection;
import java.sql.PreparedStatement;
import java.sql.ResultSet;
import java.sql.SQLTimeoutException;
import java.time.Duration;
import java.time.Instant;
import java.time.OffsetDateTime;
import java.time.ZoneOffset;
import java.util.List;
import java.util.concurrent.atomic.AtomicInteger;
import java.util.concurrent.atomic.AtomicReference;

import static org.assertj.core.api.Assertions.*;
import static org.mockito.ArgumentMatchers.*;
import static org.mockito.Mockito.*;

/** Unit coverage of the extra probes with fakes; no JMX, filesystem or real database. */
class ServerStatusProbeTest {
    private final Instant now=Instant.parse("2026-09-10T08:00:00Z");
    private final ScheduledTaskRunRegistry registry=new ScheduledTaskRunRegistry();
    private final AtomicReference<Double> errorTotal=new AtomicReference<>(0d);
    private final AtomicInteger threads=new AtomicInteger(120);
    private final DataSource dataSource=mock(DataSource.class);
    private final Connection connection=mock(Connection.class);
    private final PreparedStatement statement=mock(PreparedStatement.class);
    private final ResultSet result=mock(ResultSet.class);

    private ServerStatusProbe probe() throws Exception {
        when(dataSource.getConnection()).thenReturn(connection);
        when(connection.prepareStatement(anyString())).thenReturn(statement);
        when(statement.executeQuery()).thenReturn(result);
        when(result.next()).thenReturn(true);
        return new ServerStatusProbe(dataSource,new StorageProperties(),new SimpleMeterRegistry(),new ObjectMapper(),
                registry,()->errorTotal.get(),threads::get,"/data","","","test",400,800);
    }

    @Test void threadCountUsesConfiguredThresholdsAndNeverInventsZero() throws Exception {
        var probe=probe();
        assertThat(probe.threads().status()).isEqualTo("NORMAL");
        threads.set(400);
        assertThat(probe.threads().status()).isEqualTo("WARNING");
        threads.set(800);
        var critical=probe.threads();
        assertThat(critical.status()).isEqualTo("CRITICAL");
        assertThat(critical.unit()).isEqualTo("COUNT");
        assertThat(critical.value()).isEqualTo(800d);
        threads.set(-1);
        assertThat(probe.threads().status()).isEqualTo("UNKNOWN");
        assertThat(probe.threads().value()).isNull();
    }

    @Test void recentErrorsAreTheDeltaOverTheRollingWindowNotTheLifetimeTotal() throws Exception {
        var probe=probe();
        errorTotal.set(500d);
        var first=probe.recentErrors();
        assertThat(first.value()).isEqualTo(0d);
        assertThat(first.status()).isEqualTo("NORMAL");
        assertThat(first.detail()).contains("累计 500 条");
        errorTotal.set(512d);
        assertThat(probe.recentErrors().value()).isEqualTo(12d);
        assertThat(probe.recentErrors().status()).isEqualTo("WARNING");
        errorTotal.set(650d);
        assertThat(probe.recentErrors().status()).isEqualTo("CRITICAL");
        errorTotal.set(Double.NaN);
        var unknown=probe.recentErrors();
        assertThat(unknown.status()).isEqualTo("UNKNOWN");
        assertThat(unknown.value()).isNull();
    }

    @Test void rollingWindowForgetsReadingsOlderThanItsSlots() {
        var window=new RecentCounterWindow(3);
        assertThat(window.record(10)).isEqualTo(0d);
        assertThat(window.record(14)).isEqualTo(4d);
        assertThat(window.record(20)).isEqualTo(10d);
        assertThat(window.record(21)).isEqualTo(7d);
        assertThat(window.record(Double.NaN)).isNull();
        assertThat(window.record(-1)).isNull();
        assertThatThrownBy(()->new RecentCounterWindow(1)).isInstanceOf(IllegalArgumentException.class);
    }

    @Test void onlineSessionsCountDistinctLiveSessionsForEmployeesAndVisitors() throws Exception {
        var probe=probe();
        when(result.getLong(1)).thenReturn(7L);
        when(result.getLong(2)).thenReturn(2L);
        var sessions=probe.sessions();
        assertThat(sessions.value()).isEqualTo(9d);
        assertThat(sessions.status()).isEqualTo("NORMAL");
        assertThat(sessions.detail()).contains("员工 7").contains("访客 2");
        verify(statement).setQueryTimeout(2);
        verify(connection).prepareStatement(argThat(sql->sql.contains("count(DISTINCT session_id)")
                &&sql.contains("revoked_at IS NULL")&&sql.contains("visitor_refresh_tokens")));
        when(statement.executeQuery()).thenThrow(new SQLTimeoutException("slow"));
        var unavailable=probe.sessions();
        assertThat(unavailable.status()).isEqualTo("UNKNOWN");
        assertThat(unavailable.value()).isNull();
        assertThat(unavailable.detail()).doesNotContain("slow");
    }

    @Test void outboxBacklogWarnsByCountOrAgeAndReadsBothOutboxes() throws Exception {
        assertThat(ServerStatusProbe.outboxMetric(0,0,0,0).status()).isEqualTo("NORMAL");
        assertThat(ServerStatusProbe.outboxMetric(50,50,0,5).status()).isEqualTo("NORMAL");
        assertThat(ServerStatusProbe.outboxMetric(51,51,0,0).status()).isEqualTo("WARNING");
        assertThat(ServerStatusProbe.outboxMetric(1,0,1,6).status()).isEqualTo("WARNING");
        assertThat(ServerStatusProbe.outboxMetric(501,500,1,0).status()).isEqualTo("CRITICAL");
        assertThat(ServerStatusProbe.outboxMetric(3,3,0,31).status()).isEqualTo("CRITICAL");
        var probe=probe();
        when(result.getLong(1)).thenReturn(4L);
        when(result.getLong(3)).thenReturn(2L);
        when(result.getObject(2,OffsetDateTime.class)).thenReturn(OffsetDateTime.ofInstant(now.minusSeconds(120),ZoneOffset.UTC));
        when(result.getObject(4,OffsetDateTime.class)).thenReturn(OffsetDateTime.ofInstant(now.minusSeconds(7*60),ZoneOffset.UTC));
        var outbox=probe.outbox(now);
        assertThat(outbox.value()).isEqualTo(6d);
        assertThat(outbox.status()).isEqualTo("WARNING");
        assertThat(outbox.detail()).contains("业务通知 4").contains("附件清理 2").contains("等待 7 分钟");
        verify(connection).prepareStatement(argThat(sql->sql.contains("business_outbox WHERE status=0")
                &&sql.contains("attachment_object_outbox WHERE status IN ('PENDING','FAILED')")));
        when(result.getObject(2,OffsetDateTime.class)).thenReturn(null);
        when(result.getObject(4,OffsetDateTime.class)).thenReturn(null);
        assertThat(probe.outbox(now).detail()).contains("等待 0 分钟");
    }

    @Test void attachmentVolumeSumsStoredSizeAndReportsUnknownOnTimeout() throws Exception {
        var probe=probe();
        when(result.getLong(1)).thenReturn(1200L);
        when(result.getLong(2)).thenReturn(5_368_709_120L);
        var volume=probe.attachments();
        assertThat(volume.unit()).isEqualTo("BYTES");
        assertThat(volume.value()).isEqualTo(5_368_709_120d);
        assertThat(volume.usedBytes()).isEqualTo(5_368_709_120L);
        assertThat(volume.detail()).contains("共 1200 个附件");
        verify(connection).prepareStatement(argThat(sql->sql.contains("COALESCE(SUM(COALESCE(stored_size_bytes,size_bytes)),0)")));
        when(statement.executeQuery()).thenThrow(new SQLTimeoutException("statement timeout"));
        var timedOut=probe.attachments();
        assertThat(timedOut.status()).isEqualTo("UNKNOWN");
        assertThat(timedOut.value()).isNull();
        assertThat(timedOut.usedBytes()).isNull();
    }

    @Test void slowLaneRunsEveryFourthSampleAndAttachmentsAtMostEveryFiveMinutes() throws Exception {
        var probe=probe();
        Instant at=now;
        for(int sample=0;sample<9;sample++) {
            List<ServerStatusView.Metric> extras=probe.extras(at);
            assertThat(extras).extracting(ServerStatusView.Metric::key)
                    .containsExactly("threads","errors","sessions","outbox","attachments");
            assertThat(extras).extracting(ServerStatusView.Metric::status).doesNotContain("UNKNOWN");
            at=at.plusSeconds(15);
        }
        verify(connection,times(3)).prepareStatement(contains("refresh_tokens"));
        verify(connection,times(3)).prepareStatement(contains("business_outbox"));
        verify(connection,times(1)).prepareStatement(contains("FROM attachments"));
        for(int sample=9;sample<21;sample++) { probe.extras(at); at=at.plusSeconds(15); }
        verify(connection,times(2)).prepareStatement(contains("FROM attachments"));
    }

    @Test void slowLaneFailureIsReportedAsUnknownUntilTheNextSlowSample() throws Exception {
        var probe=probe();
        when(statement.executeQuery()).thenThrow(new SQLTimeoutException("busy"));
        var extras=probe.extras(now);
        var slowLane=extras.stream().filter(m->List.of("sessions","outbox","attachments").contains(m.key())).toList();
        assertThat(slowLane).hasSize(3);
        assertThat(slowLane).extracting(ServerStatusView.Metric::status).containsOnly("UNKNOWN");
        assertThat(slowLane).extracting(ServerStatusView.Metric::value).containsOnlyNulls();
        assertThat(extras.toString()).doesNotContain("busy");
    }

    @Test void scheduledMethodNamesComeFromDeclaringClassAndLambdasAreIgnored() throws Exception {
        var scheduled=new ScheduledMethodRunnable(new Sample(),Sample.class.getDeclaredMethod("tick"));
        assertThat(ScheduledTaskRunRegistry.nameOf(scheduled)).isEqualTo("Sample.tick");
        Runnable wrapper=new Runnable() {
            @Override public void run() {}
            @Override public String toString() { return "com.uten.imp.features.notice.CelebrationScheduler.publishDaily"; }
        };
        assertThat(ScheduledTaskRunRegistry.nameOf(wrapper)).isEqualTo("CelebrationScheduler.publishDaily");
        Runnable lambda=()->{};
        assertThat(ScheduledTaskRunRegistry.nameOf(lambda)).isNull();
        assertThat(registry.register(lambda,Duration.ofSeconds(5))).isNull();
        registry.started(null,now);
        registry.finished(null,now,null);
        assertThat(registry.snapshot()).isEmpty();
    }

    @Test void registryTracksStartEndDurationAndConsecutiveFailures() {
        Runnable task=named("com.uten.imp.jobs.OutboxScheduler.drain");
        assertThat(registry.register(task,Duration.ofSeconds(2))).isEqualTo("OutboxScheduler.drain");
        var fresh=registry.snapshot().get(0);
        assertThat(fresh.lastStart()).isNull();
        assertThat(fresh.period()).isEqualTo(Duration.ofSeconds(2));
        registry.started("OutboxScheduler.drain",now);
        assertThat(registry.snapshot().get(0).running()).isTrue();
        registry.finished("OutboxScheduler.drain",now.plusMillis(250),null);
        var done=registry.snapshot().get(0);
        assertThat(done.running()).isFalse();
        assertThat(done.lastDurationMs()).isEqualTo(250L);
        assertThat(done.runs()).isEqualTo(1L);
        for(int n=0;n<3;n++) {
            registry.started("OutboxScheduler.drain",now.plusSeconds(10+n));
            registry.finished("OutboxScheduler.drain",now.plusSeconds(11+n),new IllegalStateException("select * from secret"));
        }
        var failed=registry.snapshot().get(0);
        assertThat(failed.consecutiveFailures()).isEqualTo(3);
        assertThat(failed.lastErrorType()).isEqualTo("IllegalStateException");
        assertThat(failed.toString()).doesNotContain("secret");
        registry.started("OutboxScheduler.drain",now.plusSeconds(20));
        registry.finished("OutboxScheduler.drain",now.plusSeconds(21),null);
        assertThat(registry.snapshot().get(0).consecutiveFailures()).isZero();
        assertThat(registry.register(task,null).equals("OutboxScheduler.drain")).isTrue();
        assertThat(registry.snapshot().get(0).period()).isEqualTo(Duration.ofSeconds(2));
    }

    @Test void jobStatusCoversNeverRanRunningFailedStaleAndHealthy() {
        var never=new ScheduledTaskRunRegistry.Run("A.run",null,null,null,null,null,0,0);
        assertThat(ServerStatusProbe.job(never,now).status()).isEqualTo("UNKNOWN");
        assertThat(ServerStatusProbe.job(never,now).detail()).contains("尚未执行").contains("按日程触发");
        var running=new ScheduledTaskRunRegistry.Run("A.run",Duration.ofSeconds(60),now.minusSeconds(30),null,null,null,0,0);
        assertThat(ServerStatusProbe.job(running,now).status()).isEqualTo("NORMAL");
        assertThat(ServerStatusProbe.job(running,now).lastDurationMs()).isNull();
        var stuck=new ScheduledTaskRunRegistry.Run("A.run",Duration.ofSeconds(60),now.minusSeconds(700),null,null,null,0,0);
        assertThat(ServerStatusProbe.job(stuck,now).status()).isEqualTo("WARNING");
        var failedOnce=new ScheduledTaskRunRegistry.Run("A.run",Duration.ofSeconds(60),now.minusSeconds(10),now.minusSeconds(9),1000L,"IllegalStateException",1,5);
        assertThat(ServerStatusProbe.job(failedOnce,now).status()).isEqualTo("WARNING");
        var failedThrice=new ScheduledTaskRunRegistry.Run("A.run",Duration.ofSeconds(60),now.minusSeconds(10),now.minusSeconds(9),1000L,"IllegalStateException",3,5);
        var critical=ServerStatusProbe.job(failedThrice,now);
        assertThat(critical.status()).isEqualTo("CRITICAL");
        assertThat(critical.lastErrorType()).isEqualTo("IllegalStateException");
        assertThat(critical.periodSeconds()).isEqualTo(60L);
        var stale=new ScheduledTaskRunRegistry.Run("A.run",Duration.ofSeconds(60),now.minusSeconds(130),now.minusSeconds(125),5000L,null,0,9);
        assertThat(ServerStatusProbe.job(stale,now).status()).isEqualTo("WARNING");
        assertThat(ServerStatusProbe.job(stale,now).detail()).contains("超过 2 个周期未执行");
        var cronStale=new ScheduledTaskRunRegistry.Run("A.run",null,now.minusSeconds(100_000),now.minusSeconds(99_000),5000L,null,0,9);
        assertThat(ServerStatusProbe.job(cronStale,now).status()).isEqualTo("NORMAL");
        var healthy=new ScheduledTaskRunRegistry.Run("A.run",Duration.ofSeconds(60),now.minusSeconds(70),now.minusSeconds(65),5000L,null,0,9);
        var job=ServerStatusProbe.job(healthy,now);
        assertThat(job.status()).isEqualTo("NORMAL");
        assertThat(job.detail()).contains("耗时 5 秒").contains("每 1 分钟");
        assertThat(ServerStatusProbe.humanDuration(Duration.ofMillis(40))).isEqualTo("40 毫秒");
        assertThat(ServerStatusProbe.humanDuration(Duration.ofHours(30))).isEqualTo("1 天");
    }

    @Test void jobsFromTheRegistryAreSortedAndOnlyFailingOrStaleOnesBecomeAlerts() throws Exception {
        var probe=probe();
        registry.register(named("x.ZetaScheduler.run"),Duration.ofSeconds(60));
        registry.register(named("x.AlphaScheduler.run"),Duration.ofSeconds(60));
        registry.started("AlphaScheduler.run",now.minusSeconds(5));
        registry.finished("AlphaScheduler.run",now.minusSeconds(4),new IllegalStateException("boom"));
        var jobs=probe.jobs(now);
        assertThat(jobs).extracting(ServerStatusView.Job::key).containsExactly("AlphaScheduler.run","ZetaScheduler.run");
        assertThat(jobs.get(0).status()).isEqualTo("WARNING");
        assertThat(jobs.get(1).status()).isEqualTo("UNKNOWN");
        assertThat(jobs.toString()).doesNotContain("boom");
    }

    private static Runnable named(String name) {
        return new Runnable() {
            @Override public void run() {}
            @Override public String toString() { return name; }
        };
    }

    static class Sample { public void tick() {} }
}
