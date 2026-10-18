package com.uten.imp.features.webinquiry;

import com.uten.imp.features.webinquiry.dto.InquiryTimelineEntry;
import com.uten.imp.security.SecurityContextCurrentUser;
import lombok.RequiredArgsConstructor;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.stereotype.Repository;
import java.util.List;
import java.util.UUID;

/** Immutable historical display snapshots, independent of later employee renames. */
@Repository
@RequiredArgsConstructor
public class WebsiteInquiryTimelineRepository {
    private final JdbcTemplate jdbc;
    private final SecurityContextCurrentUser current;

    public void append(UUID inquiryId,String kind,String note) {
        UUID actor=current.id().orElse(null);
        var names=actor==null ? List.<String[]>of() : jdbc.query("""
                SELECT coalesce(e.full_name,u.login_account),e.code FROM users u
                LEFT JOIN employees e ON e.id=u.employee_id WHERE u.id=?
                """,(rs,n)->new String[]{rs.getString(1),rs.getString(2)},actor);
        String[] display=names.isEmpty()?new String[]{null,null}:names.getFirst();
        jdbc.update("""
                INSERT INTO website_inquiry_events(inquiry_id,kind,note,actor_id,actor_name,actor_employee_code)
                VALUES(?,?,?,?,?,?)
                """,inquiryId,kind,note,actor,display[0],display[1]);
    }

    public List<InquiryTimelineEntry> list(UUID id) {
        return jdbc.query("""
                SELECT id,kind,note,actor_name,actor_employee_code,created_at
                FROM website_inquiry_events WHERE inquiry_id=? ORDER BY created_at,id
                """,(rs,n)->new InquiryTimelineEntry(rs.getObject("id",UUID.class),rs.getString("kind"),
                rs.getString("note"),rs.getString("actor_name"),rs.getString("actor_employee_code"),
                rs.getTimestamp("created_at").toInstant()),id);
    }
}
