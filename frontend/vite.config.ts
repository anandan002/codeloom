import { defineConfig } from 'vite'
import react from '@vitejs/plugin-react'
import tailwindcss from '@tailwindcss/vite'

// https://vite.dev/config/
// Set VITE_BASE_PATH=/codeloom/ (or any subpath) at build time to deploy under a subpath.
// Example: VITE_BASE_PATH=/codeloom/ npm run build
// Leave unset (or /) for root deployment.
export default defineConfig({
  base: process.env['VITE_BASE_PATH'] ?? '/',
  plugins: [react(), tailwindcss()],
  server: {
    // '::' creates a dual-stack IPv6 socket on Windows (IPV6_V6ONLY=0),
    // accepting both [::1] (nginx cached upstream) and 127.0.0.1 connections.
    host: '::',
    port: 5034,
    allowedHosts: process.env['VITE_ALLOWED_HOSTS']
      ? process.env['VITE_ALLOWED_HOSTS'].split(',').map(h => h.trim())
      : [],
    proxy: {
      '/api': {
        target: 'http://localhost:5033',
        changeOrigin: true,
      },
      '/chat': {
        target: 'http://localhost:5033',
        changeOrigin: true,
      },
      '/upload': {
        target: 'http://localhost:5033',
        changeOrigin: true,
      },
      '/image': {
        target: 'http://localhost:5033',
        changeOrigin: true,
      },
    },
  },
})
