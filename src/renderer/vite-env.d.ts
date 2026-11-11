/// <reference types="vite/client" />

import type { DjApi } from '../shared/ipc';

declare global {
  interface Window {
    dj: DjApi;
  }
}

export {};
