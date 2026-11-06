-- V1051 added delivery component goods references after the V1044 refresh.
-- Reuse the maintained V911 installer for the actual current catalog. It
-- installs the ordinary immediate capture triggers without inferring old use,
-- changing goods lifecycle facts, or removing historical identity evidence.
SELECT fn_refresh_goods_code_usage_tracking();
