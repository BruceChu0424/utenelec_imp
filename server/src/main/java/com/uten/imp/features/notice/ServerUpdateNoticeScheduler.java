package com.uten.imp.features.notice;

import com.uten.imp.features.admin.serveroperations.ServerOperationsActorAuthority;
import com.uten.imp.features.admin.serveroperations.ServerOperationsService;
import lombok.RequiredArgsConstructor;
import lombok.extern.slf4j.Slf4j;
import org.springframework.context.annotation.Profile;
import org.springframework.scheduling.annotation.Scheduled;
import org.springframework.stereotype.Component;

/** Reads only an explicitly populated local release cache; never polls OSS. */
@Slf4j
@Component
@Profile("!cloud")
@RequiredArgsConstructor
class ServerUpdateNoticeScheduler {
    private final ServerOperationsService operations;
    private final ServerOperationsActorAuthority authority;
    private final ServerUpdateNoticePublisher publisher;

    @Scheduled(fixedDelayString = "30000", initialDelayString = "45000")
    public void scan() {
        try {
            var status = operations.localSnapshot();
            if (!status.available() || !Boolean.TRUE.equals(status.updateAvailable())
                    || status.sourceRevision() == null || status.latestVersion() == null) return;
            for (var user : authority.currentUpdaters()) {
                try { publisher.publishOnce(user, status.sourceRevision(), status.latestVersion()); }
                catch (Exception failed) {
                    log.warn("服务器新版本通知暂未送达，将在下轮核对: {}", failed.getClass().getSimpleName());
                }
            }
        } catch (Exception unavailable) {
            log.warn("服务器本机版本提醒检查暂不可用: {}", unavailable.getClass().getSimpleName());
        }
    }
}
