#!/usr/bin/env node
import { createHash, randomUUID } from "node:crypto";
import {
  lstat,
  mkdir,
  open,
  readFile,
  readdir,
  realpath,
  rename,
  rm,
  writeFile,
} from "node:fs/promises";
import path from "node:path";
import process from "node:process";
import { pathToFileURL } from "node:url";

const DEFAULT_WORKSPACE_ROOT = "/srv/workspaces";
const DEFAULT_PASEO_HOME = "/srv/agents/paseo";
const DEFAULT_DAEMON_ENDPOINT = "127.0.0.1:6767";
const PAGE_LIMIT = 200;
const MAX_PAGINATION_ATTEMPTS = 3;
const SAFE_PROJECT_ID = /^(?!-)(?!\.\.?$)[A-Za-z0-9._-]+$/;

function diagnostic(message) {
  process.stderr.write(`paseo-sync-projects: ${message}\n`);
}

function parseArguments(argv) {
  const options = { force: false };
  for (const argument of argv) {
    if (argument === "--force") {
      options.force = true;
    } else {
      throw new Error(`unknown option: ${argument}`);
    }
  }
  return options;
}

function within(root, candidate) {
  return candidate === root || candidate.startsWith(`${root}${path.sep}`);
}

async function regularFile(file) {
  try {
    const info = await lstat(file);
    return info.isFile() && !info.isSymbolicLink();
  } catch {
    return false;
  }
}

export async function readInventory(workspaceRoot, warn = diagnostic) {
  const root = path.resolve(workspaceRoot);
  const physicalRoot = await realpath(root);
  const entries = await readdir(root, { withFileTypes: true });
  const inventory = [];
  for (const entry of entries.sort((left, right) => left.name.localeCompare(right.name))) {
    if (!entry.isDirectory() || !SAFE_PROJECT_ID.test(entry.name)) {
      if (entry.name !== "lost+found") warn(`ignored invalid workspace entry ${JSON.stringify(entry.name)}`);
      continue;
    }
    const projectDirectory = path.join(root, entry.name);
    const metadataPath = path.join(projectDirectory, ".subyard-meta.json");
    if (!(await regularFile(metadataPath))) continue;

    let metadata;
    try {
      metadata = JSON.parse(await readFile(metadataPath, "utf8"));
    } catch {
      warn(`ignored invalid metadata for project ${entry.name}`);
      continue;
    }
    if (
      metadata?.schema !== 1 ||
      metadata?.projectId !== entry.name ||
      !SAFE_PROJECT_ID.test(metadata.projectId)
    ) {
      warn(`ignored mismatched metadata for project ${entry.name}`);
      continue;
    }

    const checkout = path.resolve(projectDirectory, "src");
    let checkoutInfo;
    let physicalCheckout;
    try {
      checkoutInfo = await lstat(checkout);
      physicalCheckout = await realpath(checkout);
    } catch {
      warn(`ignored missing checkout for project ${entry.name}`);
      continue;
    }
    if (
      !checkoutInfo.isDirectory() ||
      checkoutInfo.isSymbolicLink() ||
      !within(physicalRoot, physicalCheckout) ||
      checkout !== path.join(root, entry.name, "src")
    ) {
      warn(`ignored unsafe checkout for project ${entry.name}`);
      continue;
    }
    inventory.push({ projectId: entry.name, path: checkout });
  }
  return inventory;
}

export function inventoryFingerprint(inventory) {
  const hash = createHash("sha256");
  for (const entry of inventory) {
    hash.update(entry.projectId);
    hash.update("\0");
    hash.update(entry.path);
    hash.update("\0");
  }
  return hash.digest("hex");
}

async function readText(file) {
  try {
    return (await readFile(file, "utf8")).trim();
  } catch {
    return "";
  }
}

export async function readSeenProjects(file, warn = diagnostic) {
  try {
    const parsed = JSON.parse(await readFile(file, "utf8"));
    if (parsed?.schemaVersion !== 1 || typeof parsed.projects !== "object" || !parsed.projects) {
      throw new Error("invalid cache schema");
    }
    const projects = new Map();
    for (const [projectId, checkout] of Object.entries(parsed.projects)) {
      if (SAFE_PROJECT_ID.test(projectId) && typeof checkout === "string" && path.isAbsolute(checkout)) {
        projects.set(projectId, checkout);
      }
    }
    return projects;
  } catch (error) {
    if (error?.code !== "ENOENT") warn("ignored missing or corrupt seen-projects cache");
    return new Map();
  }
}

async function atomicWrite(file, payload, mode = 0o600) {
  await mkdir(path.dirname(file), { recursive: true, mode: 0o700 });
  const temporary = `${file}.tmp-${process.pid}-${randomUUID()}`;
  const handle = await open(temporary, "wx", mode);
  try {
    await handle.writeFile(payload);
    await handle.sync();
  } finally {
    await handle.close();
  }
  await rename(temporary, file);
}

export async function writeSeenProjects(file, seen) {
  const projects = Object.fromEntries([...seen.entries()].sort(([left], [right]) => left.localeCompare(right)));
  await atomicWrite(file, `${JSON.stringify({ schemaVersion: 1, projects }, null, 2)}\n`);
}

export async function fetchActivePaths(client) {
  for (let attempt = 1; attempt <= MAX_PAGINATION_ATTEMPTS; attempt += 1) {
    const active = new Set();
    const cursors = new Set();
    let cursor;
    try {
      while (true) {
        const page = await client.workspaces.list({
          page: { limit: PAGE_LIMIT, ...(cursor ? { cursor } : {}) },
        });
        for (const workspace of page.entries ?? []) {
          if (typeof workspace.workspaceDirectory === "string") {
            active.add(path.resolve(workspace.workspaceDirectory));
          }
        }
        if (!cursor) {
          for (const project of page.emptyProjects ?? []) {
            if (typeof project.projectRootPath === "string") {
              active.add(path.resolve(project.projectRootPath));
            }
          }
        }
        const next = page.pageInfo?.nextCursor ?? null;
        if (!page.pageInfo?.hasMore) return active;
        if (!next || cursors.has(next)) throw new Error("unstable workspace pagination");
        cursors.add(next);
        cursor = next;
      }
    } catch (error) {
      if (attempt === MAX_PAGINATION_ATTEMPTS) throw error;
    }
  }
  throw new Error("workspace pagination did not stabilize");
}

export async function reconcileProjects({ client, inventory, seenFile }) {
  const activePaths = await fetchActivePaths(client);
  const priorSeen = await readSeenProjects(seenFile);
  const nextSeen = new Map();

  for (const project of inventory) {
    if (activePaths.has(project.path)) {
      nextSeen.set(project.projectId, project.path);
      continue;
    }
    if (priorSeen.get(project.projectId) === project.path) {
      nextSeen.set(project.projectId, project.path);
      continue;
    }
    const opened = await client.workspaces.open({ cwd: project.path });
    if (opened?.error || !opened?.workspace) {
      throw new Error(`openProject failed for ${project.projectId}`);
    }
    nextSeen.set(project.projectId, project.path);
  }
  await writeSeenProjects(seenFile, nextSeen);
}

function daemonWebSocketUrl(endpoint) {
  if (!/^(127[.]0[.]0[.]1|localhost|\[::1\]):[0-9]{1,5}$/.test(endpoint)) {
    throw new Error("daemon endpoint must be loopback host:port");
  }
  return `ws://${endpoint}/ws`;
}

async function loadClientFactory() {
  const moduleName = process.env.PASEO_SYNC_CLIENT_MODULE || "@getpaseo/client";
  const imported = await import(moduleName);
  if (typeof imported.createPaseoClient !== "function") {
    throw new Error("Paseo client module has no createPaseoClient export");
  }
  return imported.createPaseoClient;
}

export async function main(argv = process.argv.slice(2)) {
  const options = parseArguments(argv);
  const workspaceRoot = process.env.PASEO_WORKSPACE_ROOT || DEFAULT_WORKSPACE_ROOT;
  const paseoHome = process.env.PASEO_HOME || DEFAULT_PASEO_HOME;
  const endpoint = process.env.PASEO_DAEMON_ENDPOINT || DEFAULT_DAEMON_ENDPOINT;
  const fingerprintFile = path.join(paseoHome, "subyard-projects.fingerprint");
  const seenFile = path.join(paseoHome, "seen-projects.json");

  const inventory = await readInventory(workspaceRoot);
  const fingerprint = inventoryFingerprint(inventory);
  if (!options.force && (await readText(fingerprintFile)) === fingerprint) return;

  const createPaseoClient = await loadClientFactory();
  const client = createPaseoClient({
    url: daemonWebSocketUrl(endpoint),
    clientId: "subyard-project-sync",
    connectTimeoutMs: Number(process.env.PASEO_SYNC_TIMEOUT_MS || 15000),
    reconnect: { enabled: false },
  });
  try {
    await client.connect();
    await reconcileProjects({ client, inventory, seenFile });
    await atomicWrite(fingerprintFile, `${fingerprint}\n`);
  } finally {
    await client.close().catch(() => {});
  }
}

const invokedPath = process.argv[1] ? pathToFileURL(path.resolve(process.argv[1])).href : "";
if (import.meta.url === invokedPath) {
  main().catch((error) => {
    diagnostic(error instanceof Error ? error.message : String(error));
    process.exitCode = 1;
  });
}
