package com.uten.imp.features.finance;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import java.util.UUID;
import java.util.function.Supplier;
/** A review is checked only after the domain acquired its original document
 * lock. Trusted internal operations have no HTTP review context. */
public final class FinanceDocumentReviewContext {
    private FinanceDocumentReviewContext(){}
    private static final ThreadLocal<Expected> CURRENT=new ThreadLocal<>();
    private static final class Expected {
        final String family,action;final UUID id;final Runnable verify;boolean checked;
        Expected(String family,UUID id,String action,Runnable verify){this.family=family;this.id=id;this.action=action;this.verify=verify;}
    }
    public static <T>T run(String family,UUID id,String action,Runnable verify,Supplier<T> work){
        var previous=CURRENT.get();var expected=new Expected(family,id,action,verify);CURRENT.set(expected);
        try{T result=work.get();if(!expected.checked)throw new ApiException(ErrorCode.CONFLICT,"原单据代次已处理或未取得原锁后核对，请核对原回执和当前单据");return result;}
        finally{if(previous==null)CURRENT.remove();else CURRENT.set(previous);}
    }
    public static void afterDocumentLock(String family,UUID id,String action){
        var expected=CURRENT.get();if(expected==null||!expected.family.equals(family)||!expected.id.equals(id)||!expected.action.equals(action))return;
        if(!expected.checked){expected.verify.run();expected.checked=true;}
    }
}
