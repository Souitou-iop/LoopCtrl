import { defineConfig } from "vite";
import { svelte, vitePreprocess } from "@sveltejs/vite-plugin-svelte";

// Tauri expects a fixed port and no clearing of its own output.
export default defineConfig({
  root: "ui",
  plugins: [svelte({ configFile: false, preprocess: vitePreprocess() })],
  clearScreen: false,
  server: { port: 1420, strictPort: true, watch: { ignored: ["**/src-tauri/**", "**/target/**"] } },
  build: { outDir: "dist", emptyOutDir: true, target: "es2021" },
});
