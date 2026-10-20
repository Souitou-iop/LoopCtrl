// Lists every third-party component that ends up in the app:
// - Rust crates reachable through normal dependencies from the workspace
//   (macOS, Windows, Linux and Android targets, the ones we ship);
// - JS packages in the shipped bundle (runtime dependencies + Svelte's runtime);
// - the Android app's Maven libraries (listed below by hand).
// Writes ui/src/lib/licenses.json (shown in Settings), THIRD_PARTY_NOTICES.md
// with every component's license text (shown in the desktop app's Settings,
// and shipped in the CLI archives) and a copy of it in the Android app's
// assets (shown in its Settings).
import { execFileSync } from "node:child_process";
import { readFileSync, writeFileSync, existsSync, mkdirSync, readdirSync, statSync } from "node:fs";
import { join, dirname } from "node:path";

const root = new URL("..", import.meta.url).pathname;
const meta = JSON.parse(execFileSync("cargo", ["metadata", "--format-version", "1", "--locked", "--filter-platform", "aarch64-apple-darwin", "--filter-platform", "x86_64-apple-darwin", "--filter-platform", "x86_64-pc-windows-msvc", "--filter-platform", "aarch64-pc-windows-msvc", "--filter-platform", "x86_64-unknown-linux-gnu", "--filter-platform", "aarch64-unknown-linux-gnu", "--filter-platform", "aarch64-linux-android", "--filter-platform", "armv7-linux-androideabi", "--filter-platform", "x86_64-linux-android"], { cwd: root, maxBuffer: 1 << 28 }).toString());
const pkgs = new Map(meta.packages.map((p) => [p.id, p]));
const nodes = new Map(meta.resolve.nodes.map((n) => [n.id, n]));
const members = new Set(meta.workspace_members);
const seen = new Set();
const stack = [...members];
while (stack.length) {
  const id = stack.pop();
  if (seen.has(id)) continue;
  seen.add(id);
  for (const d of nodes.get(id)?.deps ?? []) {
    if (d.dep_kinds.some((k) => k.kind === null)) stack.push(d.pkg);
  }
}
const rust = [...seen].filter((id) => !members.has(id)).map((id) => pkgs.get(id)).map((p) => ({
  name: p.name, version: p.version, license: p.license ?? "see repository", repo: p.repository ?? `https://crates.io/crates/${p.name}`, kind: "rust",
  dir: dirname(p.manifest_path),
}));

const pj = JSON.parse(readFileSync(join(root, "package.json"), "utf8"));
const jsSeen = new Map();
function walk(name) {
  if (jsSeen.has(name)) return;
  const f = join(root, "node_modules", name, "package.json");
  if (!existsSync(f)) return;
  const p = JSON.parse(readFileSync(f, "utf8"));
  let repo = typeof p.repository === "string" ? p.repository : p.repository?.url ?? `https://www.npmjs.com/package/${name}`;
  repo = repo.replace(/^git\+/, "").replace(/\.git$/, "").replace(/^github:/, "https://github.com/");
  jsSeen.set(name, { name, version: p.version, license: p.license ?? "see repository", repo, kind: "js", dir: join(root, "node_modules", name) });
  for (const d of Object.keys(p.dependencies ?? {})) walk(d);
}
for (const d of [...Object.keys(pj.dependencies ?? {}), "svelte"]) walk(d);
const js = [...jsSeen.values()];

// android/gradle/libs.versions.toml. Their transitive AndroidX, Compose and
// Kotlin dependencies are Apache-2.0 as well. JNA is dual-licensed; we use it
// under Apache-2.0.
const android = [
  ["top.yukonga.miuix.kmp:miuix-ui", "0.9.4", "Apache-2.0", "https://github.com/compose-miuix-ui/miuix"],
  ["top.yukonga.miuix.kmp:miuix-icons", "0.9.4", "Apache-2.0", "https://github.com/compose-miuix-ui/miuix"],
  ["org.jetbrains.compose.foundation:foundation", "1.12.2", "Apache-2.0", "https://github.com/JetBrains/compose-multiplatform"],
  ["androidx.activity:activity-compose", "1.13.0", "Apache-2.0", "https://developer.android.com/jetpack/androidx"],
  ["org.jetbrains.androidx.lifecycle:lifecycle-viewmodel-compose", "2.11.0", "Apache-2.0", "https://github.com/JetBrains/compose-multiplatform"],
  ["org.jetbrains.androidx.lifecycle:lifecycle-runtime-compose", "2.11.0", "Apache-2.0", "https://github.com/JetBrains/compose-multiplatform"],
  ["org.jetbrains.kotlinx:kotlinx-coroutines-android", "1.10.2", "Apache-2.0", "https://github.com/Kotlin/kotlinx.coroutines"],
  ["org.jetbrains.kotlin:kotlin-stdlib", "2.4.21", "Apache-2.0", "https://github.com/JetBrains/kotlin"],
  ["net.java.dev.jna:jna", "5.17.0", "Apache-2.0 (dual: LGPL-2.1-or-later OR Apache-2.0)", "https://github.com/java-native-access/jna"],
].map(([name, version, license, repo]) => ({ name, version, license, repo, kind: "android" }));

const all = [...rust, ...js, ...android].sort((a, b) => a.name.localeCompare(b.name));
writeFileSync(join(root, "ui/src/lib/licenses.json"),
  JSON.stringify(all.map(({ dir, ...c }) => c), null, 0) + "\n");

// The license texts themselves, which MIT, BSD and Apache-2.0 all require to
// travel with the binaries: each component's own LICENSE / COPYING / NOTICE
// files, identical texts printed once with everyone who uses them. Full
// Apache-2.0 copies differ only in layout and the appendix template, so they
// share one entry and keep any copyright line the crate added. A component
// that ships no file gets a text from scripts/license-texts/ or the standard
// text of its license (the Android libraries are all Apache-2.0, whose text is
// our own LICENSE).
const APACHE = readFileSync(join(root, "LICENSE"), "utf8").trim();
const MIT = `Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.`;
const FILES = /^(LICEN[CS]E|COPYING|NOTICE|UNLICENSE|COPYRIGHT)([-._].*)?$/i;
const flat = (t) => t.replace(/\s+/g, " ").trim();
function textsFor(c) {
  if (c.dir && existsSync(c.dir)) {
    const found = readdirSync(c.dir).sort()
      .filter((f) => FILES.test(f) && statSync(join(c.dir, f)).isFile())
      .map((f) => readFileSync(join(c.dir, f), "utf8").trim());
    if (found.length) return found;
  }
  // Kept in scripts/license-texts/: a crate's own text taken from its
  // repository (<crate>.txt), or the standard text of its license.
  for (const f of [`${c.name}.txt`, `${c.license}.txt`]) {
    const p = join(root, "scripts/license-texts", f);
    if (existsSync(p)) return [readFileSync(p, "utf8").trim()];
  }
  if (/Apache-2\.0/.test(c.license)) return [APACHE];
  if (/MIT/.test(c.license)) return [MIT];
  throw new Error(`${c.name} ${c.version}: no license file and no known text for ${c.license}`);
}
const groups = new Map();
for (const c of all) {
  for (let text of textsFor(c)) {
    let key = flat(text);
    let label = `${c.name} ${c.version}`;
    if (key.startsWith("Apache License Version 2.0, January 2004") && key.includes("END OF TERMS AND CONDITIONS")) {
      const extra = text.split("\n").map((l) => l.trim())
        .filter((l) => /^Copyright\b/.test(l) && !l.includes("[yyyy]") && !l.includes("[name of"));
      label += extra.map((l) => ` (${l})`).join("");
      key = "Apache-2.0";
      text = APACHE;
    }
    if (!groups.has(key)) groups.set(key, { text, labels: [] });
    groups.get(key).labels.push(label);
  }
}
const licenseTexts = [...groups.values()].sort((a, b) => a.labels[0].localeCompare(b.labels[0]))
  .map((g) => `### ${g.labels.join(", ")}\n\n\`\`\`\`\n${g.text}\n\`\`\`\``).join("\n\n");

const byLicense = new Map();
for (const c of all) byLicense.set(c.license, (byLicense.get(c.license) ?? 0) + 1);
let md = `# Third-party notices

LoopCtrl Pair is licensed under Apache-2.0 (see LICENSE). It includes the
components below, each under its own license. Generated by \`bun run licenses\`;
do not edit by hand.

Code taken from other projects:

- \`crates/usbmux\` (the built-in usbmuxd of the Android app and of the Linux
  app and CLI) and \`android/app/.../platform/UsbHost.kt\` come from the
  Android port of iloader (https://github.com/nab138/iloader), MIT, under the
  notice below. iloader's name and branding are not used.

On Linux the desktop app uses the system's GTK 3, WebKitGTK and libsoup
(LGPL), installed by the distribution as dependencies of the .deb and loaded
as shared system libraries, like the C library; they are not part of this
project or of the .deb. The CLI needs none of them. No usbmuxd, libusb,
libimobiledevice or other GPL/LGPL code is included: the system usbmuxd is
used only if the user installed it.

The desktop app recreates the miuix look in CSS from the values of
compose-miuix-ui/miuix (Apache-2.0); the Android app uses miuix itself. No
Xiaomi fonts, logos or assets are included.

The uniffi runtime crates (MPL-2.0) are used unmodified; their source is at
https://github.com/mozilla/uniffi-rs.

### iloader (MIT)

\`\`\`
${readFileSync(join(root, "crates/usbmux/LICENSE"), "utf8").trim()}
\`\`\`

## Licenses in use

${[...byLicense].sort((a, b) => b[1] - a[1]).map(([l, n]) => `- ${l}: ${n}`).join("\n")}

## Components

| Component | Version | License | Source |
|---|---|---|---|
${all.map((c) => `| ${c.name} | ${c.version} | ${c.license} | ${c.repo} |`).join("\n")}

## License texts

${licenseTexts}
`;
writeFileSync(join(root, "THIRD_PARTY_NOTICES.md"), md);
const assets = join(root, "android/app/src/main/assets");
mkdirSync(assets, { recursive: true });
writeFileSync(join(assets, "THIRD_PARTY_NOTICES.md"), md);
console.log(`${rust.length} Rust crates, ${js.length} JS packages, ${android.length} Android libraries, ${groups.size} license texts`);
