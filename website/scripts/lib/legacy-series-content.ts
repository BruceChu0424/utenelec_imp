export const LEGACY_SOURCE_SYSTEM = 'ch-uten-v2';

export type LegacySeriesPublicNames = Readonly<{
  zh: string;
  en: string;
}>;

export type LegacySeriesContentRepair = Readonly<{
  sourceId: string;
  sourceIdentity: string;
  publicNames: LegacySeriesPublicNames;
  allowedSourceNames: Readonly<{
    zh: readonly (string | null)[];
    en: readonly (string | null)[];
  }>;
  reason: string;
}>;

type RepairGroup = Readonly<{
  sourceIds: readonly string[];
  publicNames: LegacySeriesPublicNames;
  allowedSourceNames: Readonly<{
    zh: readonly (string | null)[];
    en: readonly (string | null)[];
  }>;
  reason: string;
}>;

const GROUPS: readonly RepairGroup[] = [
  {
    sourceIds: ['8', '16', '18', '23', '26', '29', '32', '35', '40', '43', '48', '55', '71'],
    publicNames: { zh: '大跷板开关系列', en: 'Rocker Switches' },
    allowedSourceNames: {
      zh: ['大跷板&…', '大跷板开关系列'],
      en: ['Rocker Switch Series', 'Rocker switch series', 'Big button switch series', 'Rocker Switches'],
    },
    reason: 'Restore the complete Chinese detail breadcrumb and use one clean public English taxonomy label.',
  },
  {
    sourceIds: ['13', '15', '19', '24', '27', '30', '33', '36', '41', '44', '49'],
    publicNames: { zh: 'LED微点开关系列', en: 'LED Micro-Point Switches' },
    allowedSourceNames: {
      zh: ['LED微点ঀ…', 'LED微点开关系列'],
      en: ['LED Mirco-point switch', 'LED micro-point switch series', 'LED Micro-Point Switches'],
    },
    reason: 'Restore the complete Chinese detail breadcrumb and correct the legacy Mirco typo.',
  },
  {
    sourceIds: ['14', '17', '20', '25', '28', '31', '34', '37', '42', '45', '50', '56', '73'],
    publicNames: { zh: '通用电子插座系列', en: 'Electronic Switches & Sockets' },
    allowedSourceNames: {
      zh: ['通用电&…', '通用电子插座系列'],
      en: [
        'Electroic electronic switch&socket',
        'Electroic electronic swotcj&spclet',
        'Universal electronic socket series',
        'Electronic Switches & Sockets',
      ],
    },
    reason: 'Restore the complete Chinese detail breadcrumb and remove legacy English spelling pollution.',
  },
  {
    sourceIds: ['21', '39', '47', '52', '57'],
    publicNames: { zh: '通用电子插座功能件', en: 'Socket Function Modules' },
    allowedSourceNames: {
      zh: ['通用电&…', '通用电子插座功能件'],
      en: ['Function parts of electric socket', 'Socket Function Modules'],
    },
    reason: 'Restore the complete Chinese detail breadcrumb and use a concise public function-module label.',
  },
  {
    sourceIds: ['22', '38', '46', '51', '58'],
    publicNames: { zh: '开关功能件系列', en: 'Switch Function Modules' },
    allowedSourceNames: {
      zh: ['开关功&…', '开关功能件系列'],
      en: ['Function parts of electric switch socket', 'Switch Function Modules'],
    },
    reason: 'Restore the complete Chinese detail breadcrumb and use a concise public function-module label.',
  },
  {
    sourceIds: ['53'],
    publicNames: { zh: '液压缓冲式地面插座系列', en: 'Hydraulic-Damped Floor Sockets' },
    allowedSourceNames: {
      zh: ['液压缓&…', '液压缓冲式地面插座系列'],
      en: [null, 'Hydraulic-Damped Floor Sockets'],
    },
    reason: 'Restore the exact Chinese detail breadcrumb and add its reviewed public English translation.',
  },
  {
    sourceIds: ['59'],
    publicNames: { zh: '纯平开关系列', en: 'Flat Switches' },
    allowedSourceNames: {
      zh: ['纯平开&…', '纯平开关系列'],
      en: ['Flat screen siwtch series', 'Flat Switches'],
    },
    reason: 'Restore the complete Chinese detail breadcrumb and correct the legacy siwtch typo.',
  },
  {
    sourceIds: ['60'],
    publicNames: { zh: '出口产品', en: 'Export Products' },
    allowedSourceNames: {
      zh: ['出口产&…', '出口产品'],
      en: ['Export product', 'Export Products'],
    },
    reason: 'Restore the complete ancestor breadcrumb used by the export catalog container.',
  },
] as const;

export const LEGACY_SERIES_CONTENT_REPAIRS: readonly LegacySeriesContentRepair[] = Object.freeze(
  GROUPS.flatMap((group) => group.sourceIds.map((sourceId) => Object.freeze({
    sourceId,
    sourceIdentity: `${LEGACY_SOURCE_SYSTEM}:series:${sourceId}`,
    publicNames: Object.freeze({ ...group.publicNames }),
    allowedSourceNames: Object.freeze({
      zh: Object.freeze([...group.allowedSourceNames.zh]),
      en: Object.freeze([...group.allowedSourceNames.en]),
    }),
    reason: group.reason,
  }))),
);

const REPAIR_BY_SOURCE_ID = new Map(
  LEGACY_SERIES_CONTENT_REPAIRS.map((repair) => [repair.sourceId, repair]),
);

if (REPAIR_BY_SOURCE_ID.size !== 50 || REPAIR_BY_SOURCE_ID.size !== LEGACY_SERIES_CONTENT_REPAIRS.length) {
  throw new Error('Legacy series content repair manifest must contain exactly 50 unique source IDs.');
}

export function legacySeriesContentRepair(sourceId: string): LegacySeriesContentRepair | null {
  return REPAIR_BY_SOURCE_ID.get(sourceId) ?? null;
}

export type LegacySeriesContentSnapshot = Readonly<{
  id: string;
  sourceIdentity: string | null;
  legacySource: string | null;
  legacyId: string | null;
  i18n: string;
  rowVersion: number;
}>;

export type LegacySeriesContentUpdate = Readonly<{
  id: string;
  sourceId: string;
  sourceIdentity: string;
  expectedRowVersion: number;
  expectedI18n: string;
  i18n: string;
  before: Readonly<{ zh: string | null; en: string | null }>;
  after: LegacySeriesPublicNames;
  reason: string;
}>;

export type LegacySeriesContentPlan = Readonly<{
  updates: readonly LegacySeriesContentUpdate[];
  issues: readonly string[];
  summary: Readonly<{
    expectedSeries: number;
    locatedSeries: number;
    alreadyClean: number;
    changes: number;
    chineseAnomaliesBefore: number;
    englishPollutionBefore: number;
  }>;
}>;

function jsonObject(value: unknown): Record<string, unknown> | null {
  return value && typeof value === 'object' && !Array.isArray(value)
    ? value as Record<string, unknown>
    : null;
}

function localizedName(i18n: Record<string, unknown>, locale: 'zh' | 'en'): string | null {
  const localized = jsonObject(i18n[locale]);
  const name = localized?.name;
  return typeof name === 'string' && name.trim() ? name.trim() : null;
}

function setLocalizedName(i18n: Record<string, unknown>, locale: 'zh' | 'en', name: string): void {
  const existing = jsonObject(i18n[locale]) ?? {};
  i18n[locale] = { ...existing, name };
}

function sourceNameIsAllowed(
  value: string | null,
  allowed: readonly (string | null)[],
): boolean {
  return allowed.includes(value);
}

export function buildLegacySeriesContentPlan(
  input: readonly LegacySeriesContentSnapshot[],
): LegacySeriesContentPlan {
  const issues: string[] = [];
  const updates: LegacySeriesContentUpdate[] = [];
  const byIdentity = new Map<string, LegacySeriesContentSnapshot>();
  for (const row of input) {
    if (!row.sourceIdentity) continue;
    if (byIdentity.has(row.sourceIdentity)) {
      issues.push(`Duplicate Series sourceIdentity ${row.sourceIdentity}.`);
      continue;
    }
    byIdentity.set(row.sourceIdentity, row);
  }

  let locatedSeries = 0;
  let alreadyClean = 0;
  let chineseAnomaliesBefore = 0;
  let englishPollutionBefore = 0;
  for (const repair of LEGACY_SERIES_CONTENT_REPAIRS) {
    const row = byIdentity.get(repair.sourceIdentity);
    if (!row) {
      issues.push(`Missing imported Series ${repair.sourceIdentity}.`);
      continue;
    }
    locatedSeries += 1;
    if (row.legacySource !== LEGACY_SOURCE_SYSTEM || row.legacyId !== repair.sourceId) {
      issues.push(
        `${repair.sourceIdentity} has inconsistent legacy identity fields `
        + `(legacySource=${String(row.legacySource)}, legacyId=${String(row.legacyId)}).`,
      );
      continue;
    }

    let i18n: Record<string, unknown>;
    try {
      const parsed = jsonObject(JSON.parse(row.i18n));
      if (!parsed) throw new Error('root is not an object');
      i18n = parsed;
    } catch (error) {
      issues.push(`${repair.sourceIdentity} has invalid i18n JSON: ${error instanceof Error ? error.message : String(error)}.`);
      continue;
    }
    const before = { zh: localizedName(i18n, 'zh'), en: localizedName(i18n, 'en') };
    if (before.zh && /[…�ঀ]/u.test(before.zh)) chineseAnomaliesBefore += 1;
    if (before.en && /Mirco|Electroic|swotcj|spclet|siwtch/iu.test(before.en)) {
      englishPollutionBefore += 1;
    }

    const unsafeLocales = (['zh', 'en'] as const).filter((locale) => (
      !sourceNameIsAllowed(before[locale], repair.allowedSourceNames[locale])
    ));
    if (unsafeLocales.length) {
      issues.push(
        `${repair.sourceIdentity} has a non-source/manual name in ${unsafeLocales.join(', ')}; `
        + `refusing to overwrite it (${JSON.stringify(before)}).`,
      );
      continue;
    }
    if (before.zh === repair.publicNames.zh && before.en === repair.publicNames.en) {
      alreadyClean += 1;
      continue;
    }

    setLocalizedName(i18n, 'zh', repair.publicNames.zh);
    setLocalizedName(i18n, 'en', repair.publicNames.en);
    updates.push({
      id: row.id,
      sourceId: repair.sourceId,
      sourceIdentity: repair.sourceIdentity,
      expectedRowVersion: row.rowVersion,
      expectedI18n: row.i18n,
      i18n: JSON.stringify(i18n),
      before,
      after: repair.publicNames,
      reason: repair.reason,
    });
  }

  return {
    updates,
    issues,
    summary: {
      expectedSeries: LEGACY_SERIES_CONTENT_REPAIRS.length,
      locatedSeries,
      alreadyClean,
      changes: updates.length,
      chineseAnomaliesBefore,
      englishPollutionBefore,
    },
  };
}
