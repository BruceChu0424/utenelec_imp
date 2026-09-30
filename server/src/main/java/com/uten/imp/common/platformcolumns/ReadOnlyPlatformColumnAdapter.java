package com.uten.imp.common.platformcolumns;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.security.SecurityContextCurrentUser;
import java.math.BigDecimal;
import java.util.*;
import java.util.function.Function;

/** Private display formulas over real, independently authorized immutable records. */
public final class ReadOnlyPlatformColumnAdapter implements PlatformColumnResourceAdapter {
    private final String scope,label;
    private final SecurityContextCurrentUser current;
    private final ObjectMapper json;
    private final Set<String> readers,priceReaders;
    private final Function<UUID,Object> detail;
    private final List<FactDefinition> facts;
    public ReadOnlyPlatformColumnAdapter(String scope,String label,SecurityContextCurrentUser current,ObjectMapper json,
            Set<String> readers,Set<String> priceReaders,Function<UUID,Object> detail,List<FactDefinition> facts) {
        this.scope=scope;this.label=label;this.current=current;this.json=json;this.readers=Set.copyOf(readers);
        this.priceReaders=Set.copyOf(priceReaders);this.detail=detail;this.facts=List.copyOf(facts);
    }
    public String scope(){return scope;}public String label(){return label;}
    public boolean canWrite(){return false;}public boolean canViewPrice(){return hasAny(priceReaders);}
    public boolean personalDefinitions(){return true;}
    public List<FactDefinition> facts(){return facts;}
    public void requireDefinitionAccess(boolean write) {
        if(!hasAny(readers)||(write&&current.get().map(u->u.getImpersonatedBy()!=null).orElse(true)))throw new ApiException(ErrorCode.FORBIDDEN);
    }
    public void requireDocumentSaveAccess(boolean create){throw new ApiException(ErrorCode.FORBIDDEN,"历史记录只允许计算展示");}
    public Map<UUID,RecordAccess> authorize(Set<UUID> ids,boolean write) {
        requireDefinitionAccess(false);if(write)throw new ApiException(ErrorCode.FORBIDDEN,"历史记录只允许计算展示");
        Map<UUID,RecordAccess> result=new LinkedHashMap<>();
        for(UUID id:ids) {
            JsonNode row=json.valueToTree(detail.apply(id));
            if(row==null||row.isNull()||!id.toString().equals(row.path("id").asText()))throw new ApiException(ErrorCode.NOT_FOUND,"记录不存在或不在当前查看范围");
            boolean visible=canViewPrice()&&!row.path("priceMasked").asBoolean(false)&&!row.path("costMasked").asBoolean(false);
            Map<String,BigDecimal> values=new HashMap<>();
            for(var fact:facts) {
                if(fact.priceProtected()&&!visible)continue;
                JsonNode value=row.get(fact.key()+"Exact");if(value==null||value.isNull())value=row.get(fact.key());
                if(value==null||value.isNull()||!(value.isTextual()||value.isNumber()))continue;
                try{values.put(fact.key(),new BigDecimal(value.asText()));}catch(NumberFormatException ignored){ }
            }
            result.put(id,new RecordAccess(false,visible,values));
        }
        return result;
    }
    private boolean hasAny(Set<String> permissions){return current.get().filter(u->!u.isVisitor()).map(u->permissions.stream().anyMatch(u.getPermissions()::contains)).orElse(false);}
}
