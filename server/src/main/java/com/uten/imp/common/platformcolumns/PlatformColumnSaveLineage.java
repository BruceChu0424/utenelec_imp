package com.uten.imp.common.platformcolumns;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import java.util.*;

/** Explicit, in-process split lineage. Tokens never come from HTTP or persisted preferences. */
public final class PlatformColumnSaveLineage {
    private static final ThreadLocal<Context> CURRENT=new ThreadLocal<>();
    private PlatformColumnSaveLineage() { }
    public static void recordPersisted(UUID id) {
        for(Context context=CURRENT.get();context!=null;context=context.previous)if(id!=null)context.persistedIds.add(id);
    }
    public static boolean wasPersisted(UUID id) {Context context=CURRENT.get();return context!=null&&context.persistedIds.contains(id);}
    static Context begin(Set<UUID> tokens) {Context next=new Context(CURRENT.get(),Set.copyOf(tokens));CURRENT.set(next);return next;}
    public static void copyToken(PlatformColumnLineInput source,PlatformColumnLineInput target) {
        if(CURRENT.get()!=null&&source!=null&&target!=null)target.setPlatformSaveToken(source.getPlatformSaveToken());
    }
    public static void registerSaved(PlatformColumnLineInput source,UUID savedId) {
        Context context=CURRENT.get();if(context==null)return;
        UUID token=source==null?null:source.getPlatformSaveToken();
        if(token==null)return; // Domain-generated rows unrelated to a caller line carry no extensions.
        if(savedId==null||!context.tokens.contains(token)||!context.claimedIds.add(savedId))throw conflict("保存后的扩展字段来源编号无效或重复");
        context.targets.computeIfAbsent(token,ignored->new ArrayList<>()).add(savedId);
    }
    static final class Context implements AutoCloseable {
        private final Context previous;private final Set<UUID> tokens;private final Set<UUID> claimedIds=new HashSet<>();
        private final Set<UUID> persistedIds=new HashSet<>();
        private final Map<UUID,List<UUID>> targets=new HashMap<>();
        private Context(Context previous,Set<UUID> tokens){this.previous=previous;this.tokens=tokens;}
        List<UUID> targets(UUID token){return List.copyOf(targets.getOrDefault(token,List.of()));}
        public void close(){if(previous==null)CURRENT.remove();else CURRENT.set(previous);}
    }
    private static ApiException conflict(String message){return new ApiException(ErrorCode.CONFLICT,message);}
}
