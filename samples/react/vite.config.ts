import { defineConfig } from 'vite';
import react from '@vitejs/plugin-react';

// The React sample proxies /api/* to whatever mint-proxy server you're running.
// Default: reuse samples/vanilla_js's Node server on :5173.
// Override via VITE_API_PROXY=http://your.mint.proxy:port
export default defineConfig({
  plugins: [react()],
  server: {
    port: 5174,
    proxy: {
      '/api': process.env.VITE_API_PROXY || 'http://localhost:5173',
    },
  },
});
