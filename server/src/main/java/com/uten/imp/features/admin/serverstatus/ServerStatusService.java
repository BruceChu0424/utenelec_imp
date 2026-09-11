package com.uten.imp.features.admin.serverstatus;

import jakarta.annotation.PostConstruct;
import jakarta.annotation.PreDestroy;
import org.springframework.stereotype.Service;

import java.time.Clock;
import java.time.Duration;
import java.util.List;
import java.util.concurrent.Executors;
import java.util.concurrent.ScheduledExecutorService;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicReference;

/** One bounded background sampler; reading the page never probes disks or waits for the database. */
@Service
public class ServerStatusService {
    static final int REFRESH_SECONDS = 15;
    private final ServerStatusProbe probe;
    private final Clock clock;
    private final AtomicReference<ServerStatusView> latest = new AtomicReference<>();
    private ScheduledExecutorService sampler;

    @org.springframework.beans.factory.annotation.Autowired
    public ServerStatusService(ServerStatusProbe probe) { this(probe, Clock.systemUTC()); }
    ServerStatusService(ServerStatusProbe probe, Clock clock) { this.probe = probe; this.clock = clock; }

    @PostConstruct
    void start() {
        sampler = Executors.newSingleThreadScheduledExecutor(task -> {
            Thread thread = new Thread(task, "server-status-sampler");
            thread.setDaemon(true);
            return thread;
        });
        sampler.scheduleWithFixedDelay(this::sample, 0, REFRESH_SECONDS, TimeUnit.SECONDS);
    }

    void sample() {
        try { latest.set(probe.sample(clock.instant())); }
        catch (RuntimeException failure) { latest.set(unavailable("服务器状态暂时读取失败，请稍后刷新。")); }
    }

    public ServerStatusView current() {
        ServerStatusView view = latest.get();
        if (view == null) return unavailable("正在读取服务器状态，请稍后刷新。");
        if (view.sampledAt() == null) return view;
        long age=Duration.between(view.sampledAt(), clock.instant()).getSeconds();
        if (age < -5) return unavailable("服务器采样时间异常，请检查系统时间。");
        if (age > 45)
            return unavailable("服务器状态已超过 45 秒未更新，请检查监控采样是否正常。");
        return view;
    }

    private static ServerStatusView unavailable(String message) {
        return new ServerStatusView(null, REFRESH_SECONDS, "UNKNOWN", "", "", 0,
                List.of(), List.of(), new ServerStatusView.Database("UNKNOWN", null, null, null, message),
                new ServerStatusView.Backup("UNKNOWN", null, null, 30, 48, "尚未取得备份状态"),
                List.of(new ServerStatusView.Alert("sampling", "UNKNOWN", message, "稍后刷新；持续无数据时联系维护人员。")),
                List.of(), List.of());
    }

    @PreDestroy void stop() { if (sampler != null) sampler.shutdownNow(); }
}
