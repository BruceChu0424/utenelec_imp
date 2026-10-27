package com.uten.imp.common.report;
import com.uten.imp.common.web.*;
import com.uten.imp.security.*;
import jakarta.servlet.http.*;

/** One immutable request proof for queries which share current object authorization. */
final class ReadScopePublication {
    static final String ATTRIBUTE=ReadScopePublication.class.getName()+".proof";
    static final String HEADER="X-Uten-Read-Scope-Version";
    record Proof(String domain,AuthUser subject,String version,boolean businessTasks) {
        Proof(String domain,AuthUser subject,String version){this(domain,subject,version,false);}
    }
    static String capture(HttpServletRequest request,
            ReadScopeVersionAuthority authority,SecurityContextCurrentUser users,String domain) {
        return capture(request,authority,users,domain,false);
    }
    static String capture(HttpServletRequest request,
            ReadScopeVersionAuthority authority,SecurityContextCurrentUser users,String domain,boolean businessTasks) {
        if(authority==null)return null;
        // An async redispatch must not replace the original read's proof.
        var existing=request.getAttribute(ATTRIBUTE);
        if(existing instanceof Proof proof)return proof.version();
        var subject=users.get().orElseThrow(() -> new ApiException(ErrorCode.UNAUTHORIZED));
        String version=domain.startsWith("native_")||businessTasks
                ?authority.scopeFor(domain,subject,businessTasks):authority.scopeFor(domain,subject);
        request.setAttribute(ATTRIBUTE,new Proof(domain,subject,version,businessTasks));
        return version;
    }
}
