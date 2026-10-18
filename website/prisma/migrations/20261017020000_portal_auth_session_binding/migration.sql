ALTER TABLE "ImpPortalAuthorization" ADD COLUMN "authSessionId" TEXT;
ALTER TABLE "ImpPortalSession" ADD COLUMN "authSessionId" TEXT;
-- Grants made before the identity-session binding must be re-opened from IMP.
UPDATE "ImpPortalAuthorization" SET "consumedAt" = CURRENT_TIMESTAMP WHERE "consumedAt" IS NULL;
UPDATE "ImpPortalSession" SET "revokedAt" = CURRENT_TIMESTAMP WHERE "revokedAt" IS NULL;
