package com.uten.imp.application.port;

/** One authority for current operator eligibility, independent of a feature's owner scope. */
public interface ActiveOperatorPort {
    boolean isActiveOperator();
    void requireActiveOperator();
}
