package com.uten.imp.common.platformcolumns;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.security.SecurityContextCurrentUser;
import java.util.*;

/** Personal display configuration, analogous to page preferences; never a record write authority. */
public final class DisplayPlatformColumnAdapter implements PlatformColumnResourceAdapter {
    private final String scope, label;
    private final Set<String> readers, priceReaders, requiredPermissions;
    private final SecurityContextCurrentUser current;
    private final List<FactDefinition> facts;
    public DisplayPlatformColumnAdapter(String scope, String label, Set<String> readers, Set<String> priceReaders,
            SecurityContextCurrentUser current, List<FactDefinition> facts) {
        this(scope,label,readers,priceReaders,current,facts,Set.of());
    }
    public DisplayPlatformColumnAdapter(String scope, String label, Set<String> readers, Set<String> priceReaders,
            SecurityContextCurrentUser current, List<FactDefinition> facts, Set<String> requiredPermissions) {
        this.scope=scope;this.label=label;this.readers=Set.copyOf(readers);this.priceReaders=Set.copyOf(priceReaders);
        this.current=current;this.facts=List.copyOf(facts);this.requiredPermissions=Set.copyOf(requiredPermissions);
    }
    @Override public String scope(){return scope;}
    @Override public String label(){return label;}
    @Override public boolean canWrite(){return false;}
    @Override public boolean canViewPrice(){return has(priceReaders);}
    @Override public boolean supportsValues(){return false;}
    @Override public boolean personalDefinitions(){return true;}
    @Override public List<FactDefinition> facts(){return facts;}
    @Override public void requireDefinitionAccess(boolean write){
        if(!has(readers)||(write && current.get().map(user->user.getImpersonatedBy()!=null).orElse(true)))
            throw new ApiException(ErrorCode.FORBIDDEN);
    }
    @Override public Map<UUID,RecordAccess> authorize(Set<UUID> ids,boolean write){
        requireDefinitionAccess(false);
        if(write||!ids.isEmpty())throw new ApiException(ErrorCode.VALIDATION_FAILED,"汇总视图只支持个人显示计算，不能保存业务字段");
        return Map.of();
    }
    private boolean has(Set<String> permissions){
        return current.get().filter(user->!user.isVisitor()).map(user->user.getPermissions()!=null
                && user.getPermissions().containsAll(requiredPermissions)
                && permissions.stream().anyMatch(user.getPermissions()::contains)).orElse(false);
    }
}
