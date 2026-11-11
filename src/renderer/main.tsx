// DJ v3.1 — renderer entry point.
// Wires the tiny local embedding model (embedder.ts) to the main process
// once, at startup, then renders the app inside the Astryx neutral theme
// in DARK mode — DJ looks like the Muse chat: dark background, light
// text, subtle borders, blue accent. The neutral theme's dark palette
// supplies the tones (body #1b1b1b, surface #262626, borders #303030),
// and index.css below uses the same values for the app's own surfaces.

import '@astryxdesign/core/reset.css';
import '@astryxdesign/core/astryx.css';
import '@astryxdesign/theme-neutral/theme.css';
import './index.css';

import React from 'react';
import { createRoot } from 'react-dom/client';
import { Theme } from '@astryxdesign/core/theme';
import { neutralTheme } from '@astryxdesign/theme-neutral/built';

import App from './App';
import { handleEmbedRequest, reportEmbedderState } from './embedder';

// Main asks this window to embed texts; answer with the local model.
window.dj.onEmbedRequest(handleEmbedRequest);
// Tell main the embedder's starting state (not-started until first use).
reportEmbedderState();

const root = document.getElementById('root');
if (!root) {
  throw new Error('DJ: no #root element in index.html');
}

createRoot(root).render(
  <React.StrictMode>
    <Theme theme={neutralTheme} mode="dark">
      <App />
    </Theme>
  </React.StrictMode>,
);
