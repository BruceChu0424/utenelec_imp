package com.uten.imp.features.finance.application;

import com.uten.imp.application.port.AttachmentLinkedEvidencePort;
import com.uten.imp.application.port.NativeApplicationContinuationPort;
import com.uten.imp.security.AuthUser;
import lombok.RequiredArgsConstructor;
import org.springframework.beans.factory.ObjectProvider;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.stereotype.Component;
import java.util.*;

/** Only confirmed, exact original references can cross into a native reader. */
@Component @RequiredArgsConstructor
public class FinanceApplicationOriginalEvidence implements AttachmentLinkedEvidencePort {
    private final JdbcTemplate db;
    private final ObjectProvider<NativeApplicationContinuationPort> targets;
    @Override public List<Frozen> linkedEvidence(String type,UUID id){
        if(!Set.of("EXPENSE_CLAIM","BUSINESS_APPLICATION").contains(type)||id==null)return List.of();
        return db.query("""
            SELECT original.attachment_id,original.owner_type,original.owner_id,original.sha256,attachment_name
            FROM finance_application_native_mappings mapping
            JOIN finance_application_continued_originals original ON original.review_id=mapping.review_id
            WHERE mapping.native_kind=? AND mapping.native_id=? ORDER BY original.attachment_id
            """,(row,index)->new Frozen(row.getObject(1,UUID.class),row.getString(2),row.getObject(3,UUID.class),row.getString(4),row.getString(5)),type,id);
    }
    @Override public boolean immutableOriginal(UUID id){
        if(id==null)return false;
        return Boolean.TRUE.equals(db.queryForObject("""
            SELECT EXISTS(SELECT 1 FROM finance_application_continued_originals original
              JOIN finance_application_native_mappings mapping ON mapping.review_id=original.review_id
              WHERE original.attachment_id=?)
            """,Boolean.class,id));
    }
    @Override public Optional<Frozen> readableOriginal(UUID id,AuthUser actor){
        if(id==null||actor==null||actor.isVisitor()||actor.getEmployeeId()==null)return Optional.empty();
        var values=db.queryForList("""
            SELECT mapping.native_kind,mapping.native_id,original.owner_type,original.owner_id,original.sha256,attachment_name
            FROM finance_application_continued_originals original
            JOIN finance_application_native_mappings mapping ON mapping.review_id=original.review_id
            WHERE original.attachment_id=? ORDER BY mapping.created_at,mapping.origin_id
            """,id);
        for(var value:values){
            var target=targets.orderedStream().filter(port->port.targetType().equals(value.get("native_kind"))).findFirst().orElse(null);
            if(target!=null&&target.mayRead((UUID)value.get("native_id"),actor))
                return Optional.of(new Frozen(id,value.get("owner_type").toString(),(UUID)value.get("owner_id"),value.get("sha256").toString(),Objects.toString(value.get("attachment_name"),"")));
        }
        return Optional.empty();
    }
}
