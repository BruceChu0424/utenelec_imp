package com.uten.imp.application.port;

/** One shared transaction lock for recipe edits, publication and delivery snapshots. */
public interface BomGraphLockPort { void acquire(); }
