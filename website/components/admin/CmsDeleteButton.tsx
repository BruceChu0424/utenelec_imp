'use client';

import type { ComponentProps } from 'react';
import { DeleteButton } from './DeleteButton';

type Options = Omit<ComponentProps<typeof DeleteButton>, 'action'> & {
  targetId: string;
  action: (id: string) => Promise<void>;
};

/** Share one original server action reference; keep each existing command owner mounted. */
export function CmsDeleteButton({ targetId, action, ...options }: Options) {
  return <DeleteButton {...options} action={() => action(targetId)} />;
}
