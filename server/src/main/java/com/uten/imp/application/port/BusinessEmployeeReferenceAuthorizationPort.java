package com.uten.imp.application.port;

/** Authorizes minimal personnel references using the owning operation and fresh staff lifecycle. */
public interface BusinessEmployeeReferenceAuthorizationPort {
    void require(String purpose);
}
