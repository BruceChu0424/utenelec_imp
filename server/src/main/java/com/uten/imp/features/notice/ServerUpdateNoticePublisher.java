package com.uten.imp.features.notice;

import com.uten.imp.features.admin.serveroperations.ServerOperationsActorAuthority;
import com.uten.imp.features.auth.PermissionResolver;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.security.NoSuchAlgorithmException;
import java.util.HexFormat;
import java.util.List;
import java.util.Set;
import java.util.UUID;
import lombok.RequiredArgsConstructor;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.stereotype.Component;
import org.springframework.transaction.annotation.Transactional;

/** A durable per-recipient event receipt is the existing selected notice, not process memory. */
@Component
@RequiredArgsConstructor
class ServerUpdateNoticePublisher {
    private final ServerOperationsActorAuthority authority;
    private final PermissionResolver permissions;
    private final NoticeService notices;
    private final JdbcTemplate jdbc;

    @Transactional
    public void publishOnce(UUID recipient, String revision, String version) {
        if (!authority.mayUpdate(recipient)
                || permissions.usersGrantedAll(List.of(recipient), Set.of("notice:read")).isEmpty()) return;
        String event = sourceEvent(revision, version);
        // The transaction lock spans both existence check and NoticeService's joined transaction.
        jdbc.queryForObject("SELECT pg_advisory_xact_lock(?, ?)", Object.class,
                recipient.hashCode(), event.hashCode());
        Integer count = jdbc.queryForObject("""
                SELECT count(*) FROM notices notice
                JOIN notice_user_states state ON state.notice_id=notice.id
                WHERE state.user_id=? AND notice.source_event=?
                """, Integer.class, recipient, event);
        if (count != null && count > 0) return;
        notices.publishForUser(recipient, "服务器有新版本 " + version,
                "已手动检查到新版本。请进入服务器运维页核对，并选择立即更新或预约服务器当地凌晨更新。",
                "system", "系统", "/admin/server-operations", event, "normal");
    }

    static String sourceEvent(String revision, String version) {
        try {
            return "SERVER_UPDATE:" + HexFormat.of().formatHex(MessageDigest.getInstance("SHA-256")
                    .digest((revision + "|" + version).getBytes(StandardCharsets.UTF_8)));
        } catch (NoSuchAlgorithmException impossible) { throw new IllegalStateException("SHA-256 unavailable"); }
    }
}
