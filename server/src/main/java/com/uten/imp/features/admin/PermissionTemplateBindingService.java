package com.uten.imp.features.admin;

import com.uten.imp.features.admin.dto.PermissionTemplateDtos.Binding;
import jakarta.persistence.EntityManager;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Service;

import java.util.*;

/** Live source assignments; legacy V957 snapshot applications remain explicitly distinguishable. */
@Service
@RequiredArgsConstructor
class PermissionTemplateBindingService {
    private final EntityManager em;

    @SuppressWarnings("unchecked")
    List<Binding> list() {
        List<Object[]> rows=em.createNativeQuery("""
                SELECT 'user',b.user_id,b.template_id,t.name,t.row_version,false
                FROM user_permission_template_bindings b JOIN permission_templates t ON t.id=b.template_id
                UNION ALL SELECT 'department',b.department_id,b.template_id,t.name,t.row_version,false
                FROM department_permission_template_bindings b JOIN permission_templates t ON t.id=b.template_id
                UNION ALL SELECT 'user',b.user_id,b.template_id,t.name,b.applied_version,true
                FROM permission_template_applies b JOIN permission_templates t ON t.id=b.template_id
                WHERE NOT EXISTS(SELECT 1 FROM user_permission_template_bindings live WHERE live.user_id=b.user_id)
                ORDER BY 1,2
                """).getResultList();
        return rows.stream().map(row->new Binding(row[0].toString(),(UUID)row[1],(UUID)row[2],
                row[3].toString(),((Number)row[4]).longValue(),Boolean.TRUE.equals(row[5]))).toList();
    }
    void bind(String kind,UUID target,UUID template,UUID actor) {
        String table=kind.equals("user")?"user_permission_template_bindings":"department_permission_template_bindings";
        String column=kind.equals("user")?"user_id":"department_id";
        em.createNativeQuery("INSERT INTO "+table+" ("+column+",template_id,bound_by) VALUES (:target,:template,:actor) "
                +"ON CONFLICT ("+column+") DO UPDATE SET template_id=:template,bound_by=:actor,bound_at=now() "
                +"WHERE "+table+".template_id IS DISTINCT FROM :template")
                .setParameter("target",target).setParameter("template",template).setParameter("actor",actor).executeUpdate();
        if(kind.equals("user")) clearLegacyUsers(List.of(target));
    }
    void clearForUsers(Collection<UUID> ids) {
        if(ids==null || ids.isEmpty()) return;
        em.createNativeQuery("DELETE FROM user_permission_template_bindings WHERE user_id IN (:ids)").setParameter("ids",ids).executeUpdate();
        clearLegacyUsers(ids);
    }
    void clearForDepartments(Collection<UUID> ids) {
        if(ids==null || ids.isEmpty()) return;
        em.createNativeQuery("DELETE FROM department_permission_template_bindings WHERE department_id IN (:ids)").setParameter("ids",ids).executeUpdate();
    }
    private void clearLegacyUsers(Collection<UUID> ids) {
        em.createNativeQuery("DELETE FROM permission_template_applies WHERE user_id IN (:ids)").setParameter("ids",ids).executeUpdate();
    }
}
