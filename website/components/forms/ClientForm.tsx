'use client';

import { createElement, useSyncExternalStore, type ComponentPropsWithoutRef } from 'react';

const subscribe = () => () => {};
const clientReady = () => true;
const serverReady = () => false;

/** Client-managed mutations must never fall back to GET before hydration.
 * Keep controls inert until their input/submit handlers are attached. Native
 * GET filters and progressively enhanced Server Action forms remain separate. */
export function ClientForm({ inert, 'aria-busy': busy, ...props }:
  Omit<ComponentPropsWithoutRef<'form'>, 'action' | 'method'>) {
  const ready = useSyncExternalStore(subscribe, clientReady, serverReady);
  return createElement('form', { ...props, method: 'post', inert: !ready || inert, 'aria-busy': !ready || busy });
}
