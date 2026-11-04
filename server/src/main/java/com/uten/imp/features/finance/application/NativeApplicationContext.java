package com.uten.imp.features.finance.application;
import java.util.*;
import java.util.function.Supplier;

/** Server-only, transaction-bound delegation. No HTTP field can mint this capability. */
final class NativeApplicationContext {
    enum Action { SUBMIT,WITHDRAW,DECIDE,VERIFY,PAY,REVERSE,CONFIRM,POST_PAYMENT,POST_EXPENSE }
    record Value(UUID applicationId,UUID sourceId,Action action) { }
    private static final ThreadLocal<Value> CURRENT=new ThreadLocal<>();
    private NativeApplicationContext() { }
    static Value current(){return CURRENT.get();}
    static <T>T call(Value value,Supplier<T> work){Value old=CURRENT.get();try{CURRENT.set(value);return work.get();}finally{if(old==null)CURRENT.remove();else CURRENT.set(old);}}
    static void run(Value value,Runnable work){call(value,()->{work.run();return null;});}
    static boolean matches(UUID source,Action action){Value value=CURRENT.get();return value!=null&&value.action()==action&&Objects.equals(value.sourceId(),source);}
}
