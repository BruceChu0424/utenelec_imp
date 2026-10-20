package com.uten.imp.application.port;
import java.util.UUID;

/** Reuses the goods domain's effective owner-write scope for specialized commands. */
public interface GoodsMasterWriteAccessPort {
    void requireWritable(UUID goodsId);
}
