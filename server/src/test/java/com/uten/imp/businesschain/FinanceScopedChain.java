package com.uten.imp.businesschain;
import java.lang.annotation.*;
import org.springframework.test.context.TestExecutionListeners;
/** Isolates financial policies, opening books and account mappings between classes. */
@Target(ElementType.TYPE) @Retention(RetentionPolicy.RUNTIME)
@TestExecutionListeners(listeners=FinanceScopedChainDatabase.Cleanup.class,
    mergeMode=TestExecutionListeners.MergeMode.MERGE_WITH_DEFAULTS)
public @interface FinanceScopedChain { }
