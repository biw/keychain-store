import { defineConfig } from "tsdown";
import swiftNodeNativeAssets from "swift-node-unplugin/rolldown";

export default defineConfig({
  entry: ["src/index.ts"],
  format: ["esm", "cjs"],
  platform: "node",
  fixedExtension: false,
  dts: true,
  plugins: [swiftNodeNativeAssets()],
});
