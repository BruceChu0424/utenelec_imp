# International procurement guides

The guide seed is intentionally non-destructive and does not run as part of the normal database seed.

## Preview

```powershell
npm run content:guides
```

The default command only lists the four stable guide slugs. It does not connect to or write the database.

## Apply

Back up the target database first, verify `DATABASE_URL`, then run the script directly with both safeguards:

```powershell
npx tsx prisma/seed-international-guides.ts --apply --confirm=INTERNATIONAL_GUIDES_V1
```

The apply path:

- creates only missing records with category `guide`;
- rejects a slug already used by another category;
- never deletes news;
- preserves an existing guide so later CMS edits are not overwritten.

The four guides are bilingual Chinese/English source content. Other locale indexes intentionally exclude them until that locale has its own title and body in the CMS data.
