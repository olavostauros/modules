/** @jsxImportSource jsx-md */

import { readFileSync, readdirSync, existsSync } from "fs";
import { join, resolve } from "path";

import {
  Heading, Paragraph, CodeBlock, LineBreak, HR,
  Bold, Italic, Code, Link,
  Badge, Badges, Center, Section,
  Table, TableHead, TableRow, Cell,
  List, Item,
  Raw, HtmlLink, Sub,
} from "readme/src/components";

// ── Dynamic data ─────────────────────────────────────────────

const REPO_DIR = resolve(import.meta.dirname);
const TASK_DIR = join(REPO_DIR, ".mise/tasks");
const TEST_DIR = join(REPO_DIR, "test");

// ── Parse tasks ──────────────────────────────────────────────

interface Command {
  name: string;
  description: string;
  args: string;
}

function parseTask(filepath: string, name: string): Command {
  const src = readFileSync(filepath, "utf-8");
  const lines = src.split("\n");

  const desc =
    lines
      .find((l) => l.startsWith("#MISE description="))
      ?.match(/#MISE description="(.+)"/)?.[1] ?? "";

  const hidden = lines.some((l) => l.includes("#MISE hide=true"));

  // Build usage string from #USAGE lines
  const argParts: string[] = [];
  for (const line of lines) {
    const reqArg = line.match(/#USAGE arg "<(.+?)>(\.\.\.)?"/);
    if (reqArg) { argParts.push(`<${reqArg[1]}>${reqArg[2] ?? ""}`); continue; }

    const optArg = line.match(/#USAGE arg "\[(.+?)\](\.\.\.)?"/);
    if (optArg) { argParts.push(`[${optArg[1]}]${optArg[2] ?? ""}`); continue; }

    const flag = line.match(/#USAGE flag "(--[\w-]+)(?:\s+<([\w-]+)>)?"/);
    if (flag) {
      argParts.push(`[${flag[1]}${flag[2] ? ` <${flag[2]}>` : ""}]`);
    }
  }

  return { name, description: desc, args: argParts.join(" ") };
}

function walkTasks(dir: string, prefix = ""): Command[] {
  const results: Command[] = [];
  if (!existsSync(dir)) return results;

  for (const entry of readdirSync(dir, { withFileTypes: true })) {
    if (entry.name.startsWith(".") || entry.name.startsWith("_")) continue;
    const fullPath = join(dir, entry.name);
    const taskName = prefix ? `${prefix}:${entry.name}` : entry.name;

    if (entry.isDirectory()) {
      results.push(...walkTasks(fullPath, taskName));
    } else {
      results.push(parseTask(fullPath, taskName));
    }
  }
  return results;
}

const commands = walkTasks(TASK_DIR)
  .filter((c) => c.name !== "test")
  .sort((a, b) => a.name.localeCompare(b.name));

// Count tests
const testFiles = readdirSync(TEST_DIR).filter((f) => f.endsWith(".bats"));
const testSrc = testFiles
  .map((f) => readFileSync(join(TEST_DIR, f), "utf-8"))
  .join("\n");
const testCount = [...testSrc.matchAll(/@test "/g)].length;

// ── README ─────────────────────────────────────���─────────────

const readme = (
  <>
    <Center>
      <Heading level={1}>modules</Heading>

      <Paragraph>
        <Bold>Opaque cross-repo dependencies for a public repo.</Bold>
      </Paragraph>

      <Paragraph>
        {"Manage repo-level dependencies with an encrypted manifest and a gitignored clone directory."}
        {"\n"}
        {"A public observer sees only 'this repo uses modules' \u2014 no names, no pinned commits, no count."}
      </Paragraph>

      <Badges>
        <Badge label="lang" value="bash" color="4EAA25" logo="gnubash" logoColor="white" />
        <Badge label="tests" value={`${testCount} passing`} color="brightgreen" href="test/" />
        <Badge label="License" value="MIT" color="blue" />
      </Badges>
    </Center>

    <LineBreak />

    <Section title="Why">
      <Paragraph>
        {"Git submodules require "}
        <Code>.gitmodules</Code>
        {", a plaintext file that exposes dependency URLs and paths. Git-crypt can't encrypt it (git needs to parse it as INI config)."}
      </Paragraph>

      <Paragraph>
        {"Naive "}
        <Code>git clone</Code>
        {" inside a parent repo does better — it creates a mode 160000 gitlink, no "}
        <Code>.gitmodules</Code>
        {" needed — but still leaks information: the directory name and the pinned commit SHA are both visible in the git tree, and the SHA is globally searchable on GitHub (it resolves back to the upstream repo)."}
      </Paragraph>

      <Paragraph>
        <Bold>modules</Bold>
        {" goes all the way: git tracks nothing under the clone directory. All submodule state — names, URLs, pinned commits — lives in an encrypted manifest at "}
        <Code>.modules/manifest</Code>
        {". Clones land in a gitignored "}
        <Code>modules/</Code>
        {" directory (path configurable). Public observers learn "}
        <Italic>that</Italic>
        {" the feature is in use; nothing else."}
      </Paragraph>
    </Section>

    <Section title="Quick start">
      <Paragraph>
        <Code>modules setup</Code>
        {" initializes git-crypt via rudi when needed, assigns the manifest for encryption, and installs hooks/merge driver. Pass "}
        <Code>--gpg-key</Code>
        {" when setting up a repo meant to be cloned elsewhere; without a collaborator key, the encrypted manifest is local-only until you add and commit a rudi user."}
      </Paragraph>
      <CodeBlock lang="bash">{`# Install
shiv install modules

# Initialize in your repo (defaults to modules/ as the clone root)
modules setup --gpg-key <your-fingerprint>
git commit -m "init modules"

# Or pick a different clone root
modules setup --path deps --gpg-key <your-fingerprint>

# Add a dependency
modules add https://github.com/org/repo.git --name my-dep
git commit -m "add my-dep"

# Add a dependency that should refresh from main during init
modules add https://github.com/org/shared-notes.git --name shared-notes --track main
git commit -m "add tracked shared-notes module"

# See what you have
modules list
modules status

# On a fresh clone: unlock, then populate from the manifest
modules unlock && modules init

# Or initialize only the modules this environment is expected to clone
modules init my-dep shared-notes`}</CodeBlock>
    </Section>

    <Section title="How it works">
      <Paragraph>
        {"Locally, after "}
        <Code>modules unlock && modules init</Code>
        {":"}
      </Paragraph>

      <CodeBlock>{[
        "  your-repo/",
        "  ├── .modules/",
        "  │   ├── manifest       ← encrypted TSV (name\\turl\\tpin[\\ttrack])",
        "  │   └── config         ← plaintext JSON ({\"path\": \"modules\"})",
        "  ├── modules/          ← gitignored; real git clones live here",
        "  │   ├── fold/",
        "  │   └── den/",
        "  ├── .gitignore        ← contains 'modules/'",
        "  └── .gitattributes    ← .modules/manifest filter=git-crypt merge=modules-manifest",
      ].join("\n")}</CodeBlock>

      <Paragraph>
        {"What a public observer sees on GitHub (locked):"}
      </Paragraph>

      <CodeBlock>{[
        "  your-repo/",
        "  ├── .git-crypt/",
        "  ├── .modules/",
        "  │   ├── manifest       (ciphertext, opaque)",
        "  │   └── config         ({\"path\": \"modules\"})",
        "  ├── .gitignore",
        "  └── .gitattributes",
      ].join("\n")}</CodeBlock>

      <List>
        <Item>
          <Bold>No gitlinks</Bold>
          {" — nothing under the clone directory is tracked by git. No pinned commit SHAs leak."}
        </Item>
        <Item>
          <Bold>Encrypted manifest</Bold>
          {" — "}
          <Code>.modules/manifest</Code>
          {" holds all submodule state (name, URL, pin, and optional tracking branch). "}
          <Code>modules setup</Code>
          {" initializes "}
          <Link href="https://github.com/KnickKnackLabs/rudi">rudi</Link>
          {" when needed and assigns the manifest to git-crypt."}
        </Item>
        <Item>
          <Bold>Readable names on disk</Bold>
          {" — no hashing. "}
          <Code>cd modules/fold</Code>
          {" just works."}
        </Item>
        <Item>
          <Bold>Optional branch tracking</Bold>
          {" — modules added with "}
          <Code>--track main</Code>
          {" refresh their local clone during "}
          <Code>modules init</Code>
          {" without updating the recorded pin. Use "}
          <Code>modules update</Code>
          {" when you want to advance and stage the durable pin."}
        </Item>
        <Item>
          <Bold>Selected initialization</Bold>
          {" — "}
          <Code>modules init fold den</Code>
          {" initializes only the named modules. With no names, "}
          <Code>modules init</Code>
          {" initializes every manifest entry. Failure is still fatal for every selected module."}
        </Item>
        <Item>
          <Bold>Custom clone root</Bold>
          {" — "}
          <Code>modules setup --path deps</Code>
          {" picks a different location (e.g., "}
          <Code>deps/</Code>
          {", "}
          <Code>third-party/vendored/</Code>
          {"). Stored in "}
          <Code>.modules/config</Code>
          {"."}
        </Item>
        <Item>
          <Bold>Merge-safe manifest</Bold>
          {" — a git-crypt-aware merge driver handles concurrent pin bumps without corrupting the manifest. Installed by default."}
        </Item>
      </List>
    </Section>

    <LineBreak />

    <Section title="Commands">
      <Table>
        <TableHead>
          <Cell>Command</Cell>
          <Cell>Description</Cell>
        </TableHead>
        {commands.map((cmd) => (
          <TableRow>
            <Cell><Code>{`modules ${cmd.name}${cmd.args ? " " + cmd.args : ""}`}</Code></Cell>
            <Cell>{cmd.description}</Cell>
          </TableRow>
        ))}
      </Table>
    </Section>

    <LineBreak />

    <Section title="Testing">
      <CodeBlock lang="bash">{`git clone https://github.com/KnickKnackLabs/modules.git
cd modules && mise trust && mise install
mise run test`}</CodeBlock>

      <Paragraph>
        <Bold>{`${testCount} tests`}</Bold>
        {` across ${testFiles.length} suites, using `}
        <Link href="https://github.com/bats-core/bats-core">BATS</Link>
        {". All tests use local git repos in temp directories — no network, no external dependencies."}
      </Paragraph>

      <Paragraph>
        {"The "}
        <Code>git-mechanics</Code>
        {" suite verifies git's behavior around gitignored nested repos. The "}
        <Code>merge-driver</Code>
        {" suite simulates concurrent pin bumps to validate the manifest merge logic. The "}
        <Code>roundtrip</Code>
        {" suite drives the full setup → add → lock → fresh-clone → unlock → init path end-to-end with git-crypt."}
      </Paragraph>
    </Section>

    <Section title="Architecture">
      <CodeBlock>{[
        "modules/",
        "├── .mise/tasks/",
        "│   ├── setup           # Initialize manifest, config, gitignore, hooks, merge driver",
        "│   ├── add             # Clone into modules/<name>, record in manifest",
        "│   ├── init            # Populate modules; refresh tracked clones from their branch",
        "│   ├── list            # Show modules (table or --json)",
        "│   ├── status          # Show at-pin / changed / missing",
        "│   ├── update          # Pull latest, update pinned SHA, optionally commit",
        "│   ├── remove          # Clean removal of clone + manifest entry",
        "│   ├── lock / unlock   # Wrappers around rudi lock / unlock",
        "│   ├── install-hooks   # Register the merge driver (called by setup)",
        "│   └── test            # Run BATS test suite",
        "├── lib/",
        "│   ├── common.sh                  # Shared helpers, manifest ops",
        "│   ├── hooks.sh                   # Merge-driver installer",
        "│   └── manifest-merge-driver.sh   # git-crypt-aware 3-way merge",
        "├── hooks/",
        "│   ├── dispatcher",
        "│   ├── gitmodules-guard           # Pre-commit: reject .gitmodules",
        "│   └── manifest-encryption        # Pre-commit: block plaintext manifest",
        "├── test/",
        "│   ├── test_helper.bash",
        "│   ├── common.bats",
        "│   ├── setup.bats",
        "│   ├── add.bats",
        "│   ├── list.bats",
        "│   ├── init.bats",
        "│   ├── update.bats",
        "│   ├── status.bats",
        "│   ├── remove.bats",
        "│   ├── hooks.bats",
        "│   ├── git-mechanics.bats         # Behavior around gitignored nested repos",
        "│   ├── merge-driver.bats          # Concurrent-edit regression tests",
        "│   └── roundtrip.bats             # Full setup → lock → clone → unlock → init",
        "└── mise.toml",
      ].join("\n")}</CodeBlock>
    </Section>

    <Section title="Migration from pre-v0.9.0">
      <Paragraph>
        {"v0.9.0 is a breaking change: old-layout repos (hashed paths under "}
        <Code>submodules/</Code>
        {", JSON manifest, gitlinks) need a one-shot migration to the new opacity layout. See the migration script and instructions at "}
        <Link href="https://github.com/KnickKnackLabs/modules/issues/16">modules#16</Link>
        {"."}
      </Paragraph>
      <Paragraph><Bold>Breaking changes:</Bold></Paragraph>
      <List>
        <Item>
          {"Clone-root is "}<Code>modules/</Code>{" (was "}<Code>submodules/</Code>
          {" with hashed paths). Configurable via "}<Code>modules setup --path &lt;dir&gt;</Code>{"."}
        </Item>
        <Item>
          {"Manifest is tab-separated (was JSON). No user-facing format; matters only for anyone scripting against "}
          <Code>.modules/manifest</Code>{" directly."}
        </Item>
        <Item>
          <Code>modules list --json</Code>
          {" schema: each module is now "}<Code>{"{url, pin}"}</Code>
          {". The pre-v0.9.0 schema included "}<Code>path</Code>
          {"; module paths are now derived from "}<Code>.modules/config</Code>{"'s "}<Code>path</Code>
          {" field, not stored per-module."}
        </Item>
        <Item>
          <Code>.modules/config</Code>
          {" carries a "}<Code>version</Code>
          {" field. Mismatched clients refuse to operate rather than silently misbehaving."}
        </Item>
      </List>
    </Section>

    <LineBreak />

    <Center>
      <HR />

      <Sub>
        {"Your dependencies, visible only to those who should see them."}
        <Raw>{"<br />"}</Raw>{"\n"}
        <Raw>{"<br />"}</Raw>{"\n"}
        {"This README was generated from "}
        <HtmlLink href="https://github.com/KnickKnackLabs/readme">README.tsx</HtmlLink>
        {"."}
      </Sub>
    </Center>
  </>
);

console.log(readme);
