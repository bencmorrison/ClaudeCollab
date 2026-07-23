// Post-build: make dist/cli.js a directly-executable node bin.
//
// The tracked TS source carries no shebang (the repo shebang lint requires
// `#!/usr/bin/env bash` on every tracked script, and this is a node entry — so the
// shebang is added here, to the git-ignored dist output, instead). npm links the bin
// from dist/cli.js; a `#!/usr/bin/env node` shebang + 0755 makes it run cross-platform.
//
// Invoked as `node scripts/postbuild.mjs` from the build script. It is a .mjs, not a
// tracked shell script, so it needs no shebang and the lint ignores it.

import { readFileSync, writeFileSync, chmodSync, existsSync } from "node:fs";
import { fileURLToPath } from "node:url";

const cli = fileURLToPath(new URL("../dist/cli.js", import.meta.url));
if (!existsSync(cli)) {
  console.error(`postbuild: ${cli} not found — did tsc emit it?`);
  process.exit(1);
}
const shebang = "#!/usr/bin/env node\n";
const body = readFileSync(cli, "utf8");
if (!body.startsWith(shebang)) writeFileSync(cli, shebang + body);
chmodSync(cli, 0o755);
console.log("postbuild: dist/cli.js is executable with a node shebang");
