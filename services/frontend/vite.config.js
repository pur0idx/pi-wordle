import { defineConfig } from 'vite';
import react from '@vitejs/plugin-react';

// `npm run dev` proxies the API to a gateway on localhost:8000
// (e.g. from `docker compose up`), mirroring what nginx does in the cluster.
export default defineConfig({
  plugins: [react()],
  server: {
    proxy: { '/api': process.env.GATEWAY_URL || 'http://localhost:8000' },
  },
});
