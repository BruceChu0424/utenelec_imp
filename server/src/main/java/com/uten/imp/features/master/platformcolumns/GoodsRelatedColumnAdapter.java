package com.uten.imp.features.master.platformcolumns;

import com.uten.imp.common.platformcolumns.PlatformColumnResourceAdapter;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.security.SecurityContextCurrentUser;
import org.springframework.jdbc.core.namedparam.NamedParameterJdbcTemplate;
import java.util.*;

/** Goods' registered mould display relation, using the same UUID-first/exact-legacy policy as standard goods columns. */
final class GoodsRelatedColumnAdapter implements PlatformColumnResourceAdapter {
    private static final Map<String,String> FIELDS;
    static {
        Map<String,String> fields = new LinkedHashMap<>();
        fields.put("mouldName","name"); fields.put("mouldCode","code"); fields.put("mouldQty","qty");
        fields.put("mouldSetCount","tqty"); fields.put("mouldManufacturer","manufacturer");
        fields.put("mouldPlace","place"); fields.put("mouldManufacturingMonth","mstatus");
        FIELDS = Collections.unmodifiableMap(fields);
    }
    private static final List<RelationDefinition> RELATIONS = List.of(
        new RelationDefinition("mouldName","模具 · 名称"), new RelationDefinition("mouldCode","模具 · 编号"),
        new RelationDefinition("mouldQty","模具 · 模数"), new RelationDefinition("mouldSetCount","模具 · 套数"),
        new RelationDefinition("mouldManufacturer","模具 · 制造商"), new RelationDefinition("mouldPlace","模具 · 存放位置"),
        new RelationDefinition("mouldManufacturingMonth","模具 · 制造年月"));
    private final PlatformColumnResourceAdapter delegate;
    private final SecurityContextCurrentUser current;
    private final NamedParameterJdbcTemplate jdbc;
    GoodsRelatedColumnAdapter(PlatformColumnResourceAdapter delegate,SecurityContextCurrentUser current,NamedParameterJdbcTemplate jdbc) {
        this.delegate=delegate;this.current=current;this.jdbc=jdbc;
    }
    @Override public String scope(){return delegate.scope();} @Override public String label(){return delegate.label();}
    @Override public void requireDefinitionAccess(boolean write){delegate.requireDefinitionAccess(write);}
    @Override public boolean canWrite(){return delegate.canWrite();} @Override public boolean canViewPrice(){return delegate.canViewPrice();}
    @Override public boolean canCreate(){return delegate.canCreate();} @Override public boolean preserveValuesOnReset(){return delegate.preserveValuesOnReset();}
    @Override public List<FactDefinition> facts(){return delegate.facts();}
    @Override public Map<UUID,RecordAccess> authorize(Set<UUID> ids,boolean write){return delegate.authorize(ids,write);}
    @Override public List<RelationDefinition> relations(){return canViewMoulds()?RELATIONS:List.of();}
    @Override public boolean canDefineRelatedColumns(){return canViewMoulds()&&current.get()
        .filter(user->!user.isVisitor()&&user.getImpersonatedBy()==null)
        .map(user->user.getPermissions().contains("goods:view")).orElse(false);}
    private boolean canViewMoulds(){return current.get().filter(user->!user.isVisitor()).map(user->user.getAuthorities().stream()
        .anyMatch(authority->"mould:view".equals(authority.getAuthority()))).orElse(false);}
    @Override public Map<UUID,Map<String,String>> relatedValues(Set<UUID> ids,Set<String> keys) {
        if(keys.isEmpty()||ids.isEmpty())return Map.of();
        delegate.requireDefinitionAccess(false);
        if(!canViewMoulds())throw new ApiException(ErrorCode.FORBIDDEN,"没有模具资料查看权限");
        if(!FIELDS.keySet().containsAll(keys))throw new ApiException(ErrorCode.VALIDATION_FAILED,"未注册的货品关联字段");
        // Source ids were authorized by PlatformColumnService. Only an absent canonical UUID may use the
        // exact, unique legacy master key, as in GoodsService.mouldNameOf/mouldCodeOf. An explicit UUID
        // pointing to a deleted mould must stay empty, never silently switch to the legacy target.
        // Resolve identity once for all projected fields; null field values do not choose another mould.
        String projection=keys.stream().sorted().map(key->"CAST(m."+FIELDS.get(key)+" AS text) AS \""+key+"\"").collect(java.util.stream.Collectors.joining(","));
        Map<UUID,Map<String,String>> result=new LinkedHashMap<>();
        jdbc.query("SELECT g.id,"+projection+" FROM goods g "
            +"LEFT JOIN moulds legacy ON g.mould_id IS NULL AND legacy.legacy_id=g.mould_legacy_id AND legacy.is_deleted=false "
            +"LEFT JOIN moulds m ON m.id=COALESCE(g.mould_id,legacy.id) AND m.is_deleted=false "
            +"WHERE g.id IN(:ids) AND g.is_deleted=false",Map.of("ids",ids),rs->{
                Map<String,String> values=new HashMap<>();
                for(String key:keys){String value=rs.getString(key);if(value!=null)values.put(key,value);}
                result.put(rs.getObject("id",UUID.class),Collections.unmodifiableMap(values));
            });
        return Collections.unmodifiableMap(result);
    }
}
