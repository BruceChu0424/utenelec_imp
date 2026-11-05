package com.uten.imp.common.platformcolumns;

import com.fasterxml.jackson.databind.JsonNode;
import com.uten.imp.security.AuthUser;
import org.springframework.security.core.Authentication;
import org.springframework.security.core.context.SecurityContextHolder;
import org.springframework.transaction.support.TransactionSynchronization;
import org.springframework.transaction.support.TransactionSynchronizationManager;
import java.sql.Connection;
import java.util.*;
import java.util.function.Supplier;

/** Request-scoped reuse of the adapter's own authorized parent projection, only
 * inside its exact read-only RR transaction. It never accepts a caller's DTO as
 * authorization, and never replaces current membership/field-permission checks. */
public final class DocumentPlatformReadContext {
    private DocumentPlatformReadContext() { }
    private static final ThreadLocal<State> CURRENT=new ThreadLocal<>();
    public static Scope open(){
        if(!readonlySnapshot())throw new IllegalStateException("Platform read reuse requires its active read-only repeatable-read snapshot");
        State active=state();if(active!=null)return new Scope(active,null,false);
        State previous=CURRENT.get(),state=new State();
        TransactionSynchronizationManager.registerSynchronization(state.marker);CURRENT.set(state);
        return new Scope(state,previous,true);
    }
    private static boolean readonlySnapshot(){return TransactionSynchronizationManager.isActualTransactionActive()
            &&TransactionSynchronizationManager.isSynchronizationActive()&&TransactionSynchronizationManager.isCurrentTransactionReadOnly()
            &&Integer.valueOf(Connection.TRANSACTION_REPEATABLE_READ).equals(TransactionSynchronizationManager.getCurrentTransactionIsolationLevel());}
    static Projection projection(Object adapter,UUID parent,Supplier<JsonNode> originalAuthorization){
        State state=state();if(state==null)return null;
        return state.projections.computeIfAbsent(adapter,ignored->new HashMap<>())
                .computeIfAbsent(parent,ignored->new Projection(originalAuthorization.get()));
    }
    private static State state(){
        State state=CURRENT.get();if(state==null||state.closed||!readonlySnapshot()
                ||!TransactionSynchronizationManager.getSynchronizations().contains(state.marker))return null;
        Identity identity=Identity.current();
        if(identity.authentication()==null||!identity.authenticated())return null;
        if(!identity.same(state.identity)){state.clear();state.identity=identity;}return state;
    }
    /** Reuse only pure labels of exact persisted references after the owning
     * document's normal authorization. No directory rows or caller DTO enter
     * this map, and a different set/owner/identity/transaction re-runs the read. */
    public static Map<UUID,String> referencedLabels(Class<?> namespace,Object readOwner,Collection<UUID> exactIds,Supplier<Map<UUID,String>> originalRead){
        State state=state();if(state==null)return originalRead.get();
        var key=new ReferenceKey(namespace,new ReadOwner(readOwner),List.copyOf(new TreeSet<>(exactIds)));
        return state.references.computeIfAbsent(key,ignored->Map.copyOf(originalRead.get()));
    }
    /** History and write authorizers must never borrow current-read caches. */
    public static <T>T withoutReuse(Supplier<T> originalRead){
        State previous=CURRENT.get();CURRENT.remove();
        try{return originalRead.get();}finally{if(previous!=null&&!previous.closed)CURRENT.set(previous);}
    }
    private record ReferenceKey(Class<?> namespace,ReadOwner owner,List<UUID> ids) { }
    private static final class ReadOwner {
        private final Object owner;ReadOwner(Object owner){this.owner=Objects.requireNonNull(owner);}
        @Override public boolean equals(Object other){return other instanceof ReadOwner value&&value.owner==owner;}
        @Override public int hashCode(){return System.identityHashCode(owner);}
    }
    static final class Projection {
        final JsonNode header;private final Map<String,JsonNode> items;
        Projection(JsonNode header){
            this.header=header;var index=new LinkedHashMap<String,JsonNode>();
            JsonNode rows=header==null?null:header.get("items");
            if(rows!=null&&rows.isArray())for(JsonNode row:rows)index.putIfAbsent(row.path("id").asText(),row);
            items=Collections.unmodifiableMap(index);
        }
        JsonNode item(UUID id){return items.get(id.toString());}
    }
    private record Identity(Authentication authentication,Object principal,boolean authenticated,Set<String> authorities,Set<String> permissions){
        static Identity current(){
            Authentication auth=SecurityContextHolder.getContext().getAuthentication();Object principal=auth==null?null:auth.getPrincipal();
            Set<String> granted=new TreeSet<>();if(auth!=null)auth.getAuthorities().forEach(authority->granted.add(authority.getAuthority()));
            return new Identity(auth,principal,auth!=null&&auth.isAuthenticated(),Set.copyOf(granted),principal instanceof AuthUser user?Set.copyOf(user.getPermissions()):Set.of());
        }
        boolean same(Identity other){return other!=null&&authentication==other.authentication&&principal==other.principal
                &&authenticated==other.authenticated&&authorities.equals(other.authorities)&&permissions.equals(other.permissions);}
    }
    private static final class State {
        boolean closed;Identity identity=Identity.current();
        final IdentityHashMap<Object,Map<UUID,Projection>> projections=new IdentityHashMap<>();
        final Map<ReferenceKey,Map<UUID,String>> references=new HashMap<>();
        void clear(){projections.clear();references.clear();}
        final TransactionSynchronization marker=new TransactionSynchronization(){
            @Override public void afterCompletion(int status){closed=true;clear();if(CURRENT.get()==State.this)CURRENT.remove();}
        };
    }
    public static final class Scope implements AutoCloseable {
        private final State state,previous;private final boolean owns;private final Thread owner=Thread.currentThread();private boolean closed;
        private Scope(State state,State previous,boolean owns){this.state=state;this.previous=previous;this.owns=owns;}
        @Override public void close(){
            if(Thread.currentThread()!=owner)throw new IllegalStateException("Platform read scope belongs to its original request thread");
            if(closed)return;closed=true;if(!owns)return;state.closed=true;state.clear();
            if(CURRENT.get()==state){if(previous==null||previous.closed)CURRENT.remove();else CURRENT.set(previous);}
        }
    }
}
