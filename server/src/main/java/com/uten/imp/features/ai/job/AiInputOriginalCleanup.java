package com.uten.imp.features.ai.job;
import org.springframework.context.annotation.Profile;
import org.springframework.scheduling.annotation.Scheduled;
import org.springframework.stereotype.Component;
@Component @Profile("!cloud")
public class AiInputOriginalCleanup {
    private final AiInputOriginalStore originals;
    public AiInputOriginalCleanup(AiInputOriginalStore originals){this.originals=originals;}
    @Scheduled(fixedDelayString="${uten.ai.original-cleanup-delay-ms:3600000}",initialDelayString="${uten.ai.original-cleanup-delay-ms:3600000}")
    public void purge(){originals.purgeExpiredTemporary();}
}
