import { defineConfig } from 'vite';
import react from '@vitejs/plugin-react';

export default defineConfig({
  plugins: [react()],
  // Relative paths: the built page is loaded from disk by Electron.
  base: './',
  build: {
    outDir: 'dist/renderer',
    // Never wipe dist: build:main already put dist/main there.
    emptyOutDir: false,
  },
  server: {
    port: 5173,
  },
});
