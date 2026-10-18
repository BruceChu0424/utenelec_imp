package com.uten.imp.features.notice;

import com.fasterxml.jackson.databind.JsonNode;
import com.uten.imp.application.port.BusinessOutboxDomainHandler;
import com.uten.imp.features.auth.PermissionResolver;
import lombok.RequiredArgsConstructor;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.stereotype.Component;
import java.util.List;
import java.util.Set;
import java.util.UUID;

/** Same-transaction outbox projection; recipients are current, active, genuinely granted sales operators. */
@Component
@RequiredArgsConstructor
public class WebsiteInquiryNoticeHandler implements BusinessOutboxDomainHandler {
    public static final String EVENT="WEBSITE_INQUIRY_NEW";
    private final JdbcTemplate jdbc;
    private final NoticeService notices;
    private final PermissionResolver permissions;
    private final NoticePermissionCandidateQuery candidates;

    @Override public boolean supports(String type){
        return "WEBSITE_INQUIRY_CREATED".equals(type) || "WEBSITE_INQUIRY_UPDATED".equals(type);
    }
    @Override public void handle(UUID eventId,String type,UUID inquiryId,JsonNode payload,UUID createdBy){
        var rows=jdbc.query("SELECT status,assignee_employee_id FROM website_inquiries WHERE id=?",
                (rs,n)->"new".equals(rs.getString(1)) && rs.getObject(2)==null,inquiryId);
        if(rows.isEmpty() || !rows.getFirst()){
            notices.resolveReviewNotices("WEBSITE_INQUIRY",inquiryId,"CLAIMED_OR_COMPLETED");return;
        }
        var possible=candidates.possibleUsers(Set.of("webinquiry:claim"));
        List<UUID> active=jdbc.query("""
                SELECT u.id FROM users u JOIN employees e ON e.id=u.employee_id
                WHERE u.is_deleted=false AND u.status='active' AND e.is_deleted=false
                AND e.status IN ('active','probation','onLeave') ORDER BY u.id
                """,(rs,n)->rs.getObject(1,UUID.class));
        if(possible.isPresent())active=active.stream().filter(possible.get()::contains).toList();
        for(UUID recipient:permissions.usersGrantedAll(active,Set.of("notice:read","webinquiry:view","webinquiry:claim"))){
            // Outbox worker holds the event row. This lock also serializes legacy/manual replays.
            jdbc.queryForObject("SELECT pg_advisory_xact_lock(hashtextextended(?,0))::text",String.class,
                    "website-notice:"+inquiryId+":"+recipient);
            Integer existing=jdbc.queryForObject("""
                    SELECT count(*) FROM notices WHERE source_event=? AND aggregate_id=? AND audience_user_id=?
                    """,Integer.class,EVENT,inquiryId,recipient);
            if(existing!=null && existing>0)continue;
            notices.publishForUser(recipient,"收到新的官网咨询",
                    "客户需求已进入官网询盘收件箱。请查看详情并认领跟进。","task","官网",
                    "/webinquiry/"+inquiryId,EVENT,"normal",inquiryId);
        }
    }
}
