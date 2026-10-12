package com.uten.imp.common.finance;

import com.uten.imp.application.port.DocumentUnapprovalPort;
import com.uten.imp.common.web.ApiException;
import jakarta.persistence.EntityManager;
import org.springframework.security.access.AccessDeniedException;
import org.springframework.security.core.context.SecurityContextHolder;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.util.HexFormat;
import java.util.UUID;

/** Domain checks only; this class never calls a mutation or simulates a rollback. */
public final class ProcurementUnapprovalPreflight {
    private ProcurementUnapprovalPreflight(){}
    public record Check(String code,Runnable verify){}
    public static Check check(String code,Runnable verify){return new Check(code,verify);}
    public static DocumentUnapprovalPort.Eligibility evaluate(EntityManager em,String family,String table,UUID id,
            String reversePermission,java.util.function.Supplier<String> dependencyFacts,Check... checks){
        var authentication=SecurityContextHolder.getContext().getAuthentication();
        if(authentication==null || authentication.getAuthorities().stream().noneMatch(a->reversePermission.equals(a.getAuthority())))
            return DocumentUnapprovalPort.Eligibility.blocked("MISSING_REVERSE_PERMISSION","没有该单据的反审权限",null);
        String before=snapshot(em,table,id,dependencyFacts);
        for(Check check:checks){
            try{check.verify().run();}
            catch(AccessDeniedException denied){return DocumentUnapprovalPort.Eligibility.blocked("DOCUMENT_SCOPE_DENIED","该单据不在当前可操作的职责范围内",null);}
            catch(ApiException blocked){return DocumentUnapprovalPort.Eligibility.blocked(check.code(),blocked.getMessage().replace("红冲","反审"),null);}
        }
        String after=snapshot(em,table,id,dependencyFacts);
        if(!before.equals(after))return DocumentUnapprovalPort.Eligibility.blocked("PREFLIGHT_CHANGED","核对期间相关业务已变化，请重新读取后再操作",null);
        try{
            String facts=family+"\n"+id+"\n"+authentication.getName()+"\n"+after;
            return DocumentUnapprovalPort.Eligibility.ready(HexFormat.of().formatHex(MessageDigest.getInstance("SHA-256")
                    .digest(facts.getBytes(StandardCharsets.UTF_8))));
        }catch(java.security.NoSuchAlgorithmException impossible){throw new IllegalStateException(impossible);}
    }
    private static String snapshot(EntityManager em,String table,UUID id,java.util.function.Supplier<String> dependencies){
        if(!table.matches("[a-z_]+"))throw new IllegalArgumentException("Invalid internal source table");
        return String.valueOf(em.createNativeQuery("SELECT to_jsonb(document)::text FROM "+table+" document WHERE id=:id")
                .setParameter("id",id).getSingleResult())+"\n"+dependencies.get();
    }
}
