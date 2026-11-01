package com.uten.imp.application.port;

import java.util.UUID;

public interface SalesManagerReviewNoticePort {
    void pending(String kind, UUID id);
    void pendingForUser(String kind, UUID id, UUID userId);
    void resolved(String kind, UUID id, String decision);
    void rejected(String kind, UUID id, String reason);
}
