package com.uten.imp.features.admin.serverstatus;

import com.fasterxml.jackson.databind.ObjectMapper;
import org.junit.jupiter.api.Test;

import java.time.Clock;
import java.time.Instant;
import java.time.ZoneOffset;
import java.util.List;

import static org.assertj.core.api.Assertions.*;
import static org.mockito.Mockito.*;

class ServerStatusTest {
    private final Instant now=Instant.parse("2026-09-08T16:00:00Z");

    @Test void unavailableAndThresholdBoundariesNeverLookHealthy() {
        assertThat(ServerStatusProbe.severity(null,80,90)).isEqualTo("UNKNOWN");
        assertThat(ServerStatusProbe.severity(Double.NaN,80,90)).isEqualTo("UNKNOWN");
        assertThat(ServerStatusProbe.severity(79.999,80,90)).isEqualTo("NORMAL");
        assertThat(ServerStatusProbe.severity(80d,80,90)).isEqualTo("WARNING");
        assertThat(ServerStatusProbe.severity(90d,80,90)).isEqualTo("CRITICAL");
        assertThat(ServerStatusProbe.percent(0,0)).isNull();
        assertThat(ServerStatusProbe.percent(-1,100)).isNull();
        assertThat(ServerStatusProbe.percent(101,100)).isNull();
        assertThat(ServerStatusProbe.moreSevere("UNKNOWN","WARNING")).isEqualTo("WARNING");
        assertThat(ServerStatusProbe.moreSevere("CRITICAL","UNKNOWN")).isEqualTo("CRITICAL");
    }

    @Test void linuxFileCacheIsNotMisreportedAsExhaustedMemory() {
        assertThat(ServerStatusProbe.linuxMemoryPercent("MemTotal: 100000 kB\nMemFree: 1000 kB\nMemAvailable: 85000 kB\nCached: 84000 kB\n"))
                .isEqualTo(15d);
        assertThat(ServerStatusProbe.linuxMemoryPercent("MemTotal: 100000 kB\nMemFree: 1000 kB\n")).isNull();
        assertThat(ServerStatusProbe.linuxMemoryPercent("MemTotal: 100000 kB\nMemAvailable: 150000 kB\n")).isNull();
    }

    @Test void repeatedHttpReadsReuseOneBackgroundSample() {
        var probe=mock(ServerStatusProbe.class);
        var service=new ServerStatusService(probe,Clock.fixed(now,ZoneOffset.UTC));
        assertThat(service.current().status()).isEqualTo("UNKNOWN");
        verifyNoInteractions(probe);
        var view=view(now);
        when(probe.sample(now)).thenReturn(view);
        service.sample();
        for(int n=0;n<1000;n++)assertThat(service.current()).isSameAs(view);
        verify(probe,times(1)).sample(now);
    }

    @Test void staleOrFailedSamplingDoesNotKeepOldGreenNumbers() {
        var probe=mock(ServerStatusProbe.class);
        var service=new ServerStatusService(probe,Clock.fixed(now,ZoneOffset.UTC));
        when(probe.sample(now)).thenReturn(view(now.minusSeconds(46)));
        service.sample();
        assertThat(service.current().status()).isEqualTo("UNKNOWN");
        assertThat(service.current().metrics()).isEmpty();
        when(probe.sample(now)).thenThrow(new IllegalStateException("private host details"));
        service.sample();
        assertThat(service.current().toString()).doesNotContain("private host details");
        assertThat(service.current().database().responseMs()).isNull();
    }

    @Test void backupAgeAndFailedLatestAttemptHaveIndependentWarnings() throws Exception {
        assertThat(backup(29,"SUCCESS",0).status()).isEqualTo("NORMAL");
        assertThat(backup(30,"SUCCESS",0).status()).isEqualTo("WARNING");
        assertThat(backup(48,"SUCCESS",0).status()).isEqualTo("CRITICAL");
        var failed=backup(1,"FAILED",0);
        assertThat(failed.status()).isEqualTo("CRITICAL");
        assertThat(failed.lastSuccessAt()).isEqualTo(now.minusSeconds(3600));
        assertThat(backup(1,"SUCCESS",901).status()).isEqualTo("UNKNOWN");
        assertThat(backup(1,"CHECK_FAILED",0).status()).isEqualTo("CRITICAL");
        assertThat(backup(1,"RUNNING",0).status()).isEqualTo("UNKNOWN");
    }

    @Test void aDirectoryOrUnrecognizedReportIsNotBackupSuccess() throws Exception {
        var mapper=new ObjectMapper();
        assertThatThrownBy(()->ServerStatusProbe.backup(mapper.readTree("{\"status\":\"success\"}"),now))
                .isInstanceOf(IllegalArgumentException.class);
        var future=mapper.createObjectNode().put("format","uten-server-backup-status-v1")
                .put("sampledAt",now.toString()).put("lastSuccessAt",now.plusSeconds(600).toString())
                .put("lastAttemptStatus","SUCCESS");
        assertThatThrownBy(()->ServerStatusProbe.backup(future,now)).isInstanceOf(IllegalArgumentException.class);
    }

    private ServerStatusView.Backup backup(long ageHours,String attempt,long staleSeconds) {
        var node=new ObjectMapper().createObjectNode().put("format","uten-server-backup-status-v1")
                .put("sampledAt",now.minusSeconds(staleSeconds).toString())
                .put("lastSuccessAt",now.minusSeconds(ageHours*3600).toString()).put("lastAttemptStatus",attempt);
        return ServerStatusProbe.backup(node,now);
    }
    private static ServerStatusView view(Instant at) {
        return new ServerStatusView(at,15,"NORMAL","test","test",10,List.of(),List.of(),
                new ServerStatusView.Database("NORMAL",1d,2,100,""),
                new ServerStatusView.Backup("NORMAL",at,0d,30,48,""),List.of());
    }
}
