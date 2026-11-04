package com.uten.imp.common.files.document;

/** Explicit server-selected intake contracts; never selected from an uploaded payload. */
public enum DocumentIntakeProfile {
    DEFAULT(15L*1024*1024,false),
    FINANCIAL_TEMPLATE(15L*1024*1024,true),
    FINANCIAL_ASSET(64L*1024*1024,true);

    private final long maxBytes;private final boolean includeHidden;
    DocumentIntakeProfile(long maxBytes,boolean includeHidden){this.maxBytes=maxBytes;this.includeHidden=includeHidden;}
    public long maxBytes(){return maxBytes;}
    public boolean includeHidden(){return includeHidden;}
    public int maxSheets(){return includeHidden?32:8;}
}
