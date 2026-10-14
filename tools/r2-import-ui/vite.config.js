import { defineConfig } from 'vite';
import { fileURLToPath } from 'node:url';
export default defineConfig({
  base: '/r2-import/',
  build: { target: 'safari15', assetsInlineLimit: 0, outDir: '../../public/r2-import', emptyOutDir: true, rollupOptions: {
    input: { importer: fileURLToPath(new URL('./index.html', import.meta.url)), native: fileURLToPath(new URL('./src/native.js', import.meta.url)) },
    output: { entryFileNames: chunk => chunk.name === 'native' ? 'native.js' : 'assets/[name]-[hash].js' },
  } },
  worker: { format: 'es' },
});
