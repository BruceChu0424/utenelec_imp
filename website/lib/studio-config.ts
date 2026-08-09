export type StudioPlacement = {
  x: number;
  y: number;
  scale: number;
  rotation: number;
};

export const STUDIO_PLACEMENT_LIMITS = {
  x: { min: 8, max: 92 },
  y: { min: 12, max: 83 },
  scale: { min: 0.7, max: 1.55 },
  rotation: { min: -180, max: 180 },
} as const;

export const STUDIO_DEFAULT_PLACEMENT: StudioPlacement = {
  x: 52,
  y: 47,
  scale: 1,
  rotation: 0,
};

type StudioPlacementInput = Partial<Record<keyof StudioPlacement, unknown>>;

export function clampStudioValue(
  key: keyof StudioPlacement,
  value: unknown,
  fallback = STUDIO_DEFAULT_PLACEMENT[key],
) {
  const numericValue = typeof value === 'number' && Number.isFinite(value) ? value : fallback;
  const limits = STUDIO_PLACEMENT_LIMITS[key];
  return Math.min(limits.max, Math.max(limits.min, numericValue));
}

export function normalizeStudioPlacement(
  placement?: StudioPlacementInput | null,
  fallback: StudioPlacement = STUDIO_DEFAULT_PLACEMENT,
): StudioPlacement {
  return {
    x: clampStudioValue('x', placement?.x, fallback.x),
    y: clampStudioValue('y', placement?.y, fallback.y),
    scale: clampStudioValue('scale', placement?.scale, fallback.scale),
    rotation: clampStudioValue('rotation', placement?.rotation, fallback.rotation),
  };
}
