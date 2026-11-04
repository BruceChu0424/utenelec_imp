package com.uten.imp.features.finance.application;

/** Narrow application responsibilities; they never grant company reporting or the legacy expense pool. */
public final class FinanceApplicationPermissions {
    private FinanceApplicationPermissions() { }
    public static final String VIEW="finance_application:view",APPLY="finance_application:apply",
            REVIEW="finance_application:review",EXECUTE="finance_application:execute",CONFIRM="finance_application:confirm",
            REVERSE="finance_application:reverse",SETTINGS="expense:settings";
}
