/**
 * Build the work-task tool into a self-contained, runnable bundle in `dist/`.
 *
 * Output layout (everything `cp -R`'d into Plans.app/Contents/Resources/work-task):
 *   dist/
 *     run-task.js              <- esbuilt entrypoint (our glue only)
 *     package.json             <- minimal ESM marker + dep pin
 *     node_modules/
 *       @anthropic-ai/claude-agent-sdk            <- the SDK (4.5M)
 *       @anthropic-ai/claude-agent-sdk-<platform> <- native CLI binary (~224M)
 *
 * Why we DON'T bundle the SDK into run-task.js:
 *   At query() time the SDK resolves a native CLI binary from a sibling
 *   optional package via createRequire(import.meta.url).resolve(...). That
 *   resolution is relative to the SDK's on-disk location and needs a real
 *   node_modules tree next to it. A single-file bundle would break it. So the
 *   SDK stays EXTERNAL and we ship a minimal production node_modules.
 *
 * Runnable with plain: node run-task.js --project-root <abs> --task-id <NNN>
 */

import { build } from "esbuild";
import { cpSync, mkdirSync, rmSync, writeFileSync, existsSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
const distDir = join(here, "dist");
const distModules = join(distDir, "node_modules", "@anthropic-ai");
const srcModules = join(here, "node_modules", "@anthropic-ai");

// 1. Clean dist.
rmSync(distDir, { recursive: true, force: true });
mkdirSync(distDir, { recursive: true });

// 2. esbuild our glue. SDK stays external (see header).
await build({
  entryPoints: [join(here, "run-task.ts")],
  bundle: true,
  platform: "node",
  format: "esm",
  target: "node18",
  external: ["@anthropic-ai/claude-agent-sdk"],
  outfile: join(distDir, "run-task.js"),
  banner: {
    js: "import { createRequire as __cr } from 'module'; const require = __cr(import.meta.url);",
  },
});

// 3. Copy the SDK and the current platform's native CLI binary package.
mkdirSync(distModules, { recursive: true });

const sdkName = "claude-agent-sdk";
const nativeName = `claude-agent-sdk-${process.platform}-${process.arch}`;

for (const pkg of [sdkName, nativeName]) {
  const from = join(srcModules, pkg);
  if (!existsSync(from)) {
    if (pkg === nativeName) {
      throw new Error(
        `Native CLI package not found: @anthropic-ai/${pkg}. Run \`npm install\` ` +
          `on this platform (${process.platform}-${process.arch}) first.`,
      );
    }
    throw new Error(`Expected dependency not found: @anthropic-ai/${pkg}`);
  }
  cpSync(from, join(distModules, pkg), { recursive: true, dereference: true });
}

// 4. Minimal package.json so Node treats run-task.js as ESM.
writeFileSync(
  join(distDir, "package.json"),
  JSON.stringify({ name: "work-task-dist", version: "0.1.0", type: "module", private: true }, null, 2) + "\n",
);

console.log("work-task build complete ->", distDir);
