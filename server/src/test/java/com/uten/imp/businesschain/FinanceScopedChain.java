package com.uten.imp.businesschain;
import java.lang.annotation.*;
import org.springframework.test.annotation.DirtiesContext;
import org.springframework.test.context.ContextConfiguration;
import org.springframework.test.context.TestExecutionListeners;
/** Isolates financial policies and opening books; each context owns its database and pool lifetimes. */
@Target(ElementType.TYPE) @Retention(RetentionPolicy.RUNTIME)
@ContextConfiguration(initializers=FinanceScopedChainDatabase.Initializer.class)
@DirtiesContext(classMode=DirtiesContext.ClassMode.AFTER_CLASS)
@TestExecutionListeners(listeners=FinanceScopedChainDatabase.BoundaryEvidence.class,
    mergeMode=TestExecutionListeners.MergeMode.MERGE_WITH_DEFAULTS)
public @interface FinanceScopedChain { }
