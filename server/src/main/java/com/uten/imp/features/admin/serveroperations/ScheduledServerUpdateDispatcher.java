package com.uten.imp.features.admin.serveroperations;

import java.time.Clock;
import java.time.Instant;
import java.util.Map;
import java.util.UUID;
import lombok.extern.slf4j.Slf4j;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.context.annotation.Profile;
import org.springframework.scheduling.annotation.Scheduled;
import org.springframework.stereotype.Component;

/** Dispatches only an explicitly saved appointment. Reading status never contacts release storage. */
@Slf4j
@Component
@Profile("!cloud")
public class ScheduledServerUpdateDispatcher {
    private final ServerOperationsService operations;
    private final HostOperationsClient client;
    private final ServerOperationsActorAuthority authority;
    private final ServerOperationsRuntimeBinding runtimeBinding;
    private final Clock clock;

    @Autowired
    public ScheduledServerUpdateDispatcher(ServerOperationsService operations, HostOperationsClient client,
            ServerOperationsActorAuthority authority, ServerOperationsRuntimeBinding runtimeBinding) {
        this(operations, client, authority, runtimeBinding, Clock.systemUTC());
    }

    ScheduledServerUpdateDispatcher(ServerOperationsService operations, HostOperationsClient client,
            ServerOperationsActorAuthority authority, ServerOperationsRuntimeBinding runtimeBinding, Clock clock) {
        this.operations = operations; this.client = client; this.authority = authority; this.clock = clock;
        this.runtimeBinding = runtimeBinding;
    }

    @Scheduled(fixedDelayString = "30000", initialDelayString = "30000")
    public void dispatchDue() {
        try {
            var snapshot = operations.localSnapshot();
            var job = snapshot.latestJob();
            if (!snapshot.available() || job == null || !"SCHEDULED".equals(job.state())
                    || job.scheduledAt() == null || job.scheduledAt().toInstant().isAfter(Instant.now(clock))) return;
            // An unreadable DB throws and holds the appointment. Unknown authority must never dispatch or cancel.
            boolean allowed = authority.mayUpdate(job.actorId());
            client.call(allowed ? HostOperationsClient.Operation.UPDATE_DISPATCH : HostOperationsClient.Operation.UPDATE_CANCEL,
                    allowed ? Map.of("jobId", job.id().toString(), "runtimeBinding", runtimeBinding.capture())
                            : Map.of("jobId", job.id().toString(), "reason", "AUTHORIZATION_REVOKED"),
                    job.actorId(), UUID.randomUUID());
        } catch (Exception unavailable) {
            // Safe class only: helper/parser/DB messages and payloads never enter application logs.
            log.warn("服务器预约检查暂不可用，将保留预约并在下轮核对: {}", unavailable.getClass().getSimpleName());
        }
    }
}
