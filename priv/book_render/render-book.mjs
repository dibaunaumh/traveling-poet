// Renders one printed journal to PDF on the poet's sprite and uploads it.
//
// Written by the app before every run (never trusted from a previous run)
// and started detached; the app polls status.json. No agent, no model: this
// script and its job file are all that runs.
//
//   node render-book.mjs <job.json>
//
// job.json: {url, cookie: {name, value, domain} | null, upload_url, work_dir,
//            timeout_ms, chrome_version}
// status.json (in work_dir): {state: "installing"|"rendering"|"uploading"|
//            "done"|"failed", pages, bytes, error, at}
import { spawn, execFileSync } from "node:child_process";
import { readFileSync, writeFileSync, existsSync, mkdirSync, rmSync, statSync } from "node:fs";
import { join } from "node:path";
import { homedir } from "node:os";

const job = JSON.parse(readFileSync(process.argv[2], "utf8"));
// relative to the sprite user's home, so the app need not know it
const work = job.work_dir.startsWith("/") ? job.work_dir : join(homedir(), job.work_dir);
mkdirSync(work, { recursive: true });
const statusFile = join(work, "status.json");
const say = (state, extra = {}) =>
  writeFileSync(statusFile, JSON.stringify({ state, at: new Date().toISOString(), ...extra }));
const log = (...args) => console.log(new Date().toISOString(), ...args);
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

let chrome;
const fail = (error) => {
  log("FAILED", error);
  say("failed", { error: String(error).slice(0, 500) });
  try { chrome && chrome.kill("SIGKILL"); } catch {}
  process.exit(1);
};
setTimeout(() => fail(`timed out after ${job.timeout_ms} ms`), job.timeout_ms).unref();

// Libraries headless Chrome links against, by their Ubuntu 24.04+ names.
const LIBS = [
  "libnss3", "libnspr4", "libatk1.0-0t64", "libatk-bridge2.0-0t64", "libcups2t64",
  "libdrm2", "libxkbcommon0", "libxcomposite1", "libxdamage1", "libxfixes3",
  "libxrandr2", "libgbm1", "libasound2t64", "libpango-1.0-0", "libcairo2",
  "libdbus-1-3", "libexpat1", "fonts-liberation", "fonts-noto-cjk",
  // not Chrome's: recompresses the printed drawings (see shrink below)
  "ghostscript",
];

const hasGhostscript = () => {
  try { execFileSync("gs", ["--version"], { stdio: "ignore" }); return true; } catch { return false; }
};

function chromePath() {
  const root = join(homedir(), ".tpoet", "chrome");
  if (existsSync(join(root, "path.txt")) && hasGhostscript()) {
    const p = readFileSync(join(root, "path.txt"), "utf8").trim();
    if (p && existsSync(p)) return p;
  }
  say("installing");
  log("installing headless chrome and its libraries");
  execFileSync("sudo", ["-n", "apt-get", "update", "-qq"], { stdio: "inherit" });
  execFileSync("sudo", ["-n", "env", "DEBIAN_FRONTEND=noninteractive", "apt-get", "install", "-y", "-qq", "--no-install-recommends", ...LIBS], { stdio: "inherit" });
  mkdirSync(root, { recursive: true });
  const out = execFileSync("npx", ["-y", "@puppeteer/browsers@2", "install", `chrome-headless-shell@${job.chrome_version || "stable"}`, "--path", root], { encoding: "utf8" });
  log(out.trim());
  const p = out.trim().split("\n").pop().split(" ").slice(1).join(" ").trim();
  if (!p || !existsSync(p)) throw new Error(`chrome not found after install: ${out}`);
  const missing = execFileSync("bash", ["-c", `ldd '${p}' | grep 'not found' || true`], { encoding: "utf8" }).trim();
  if (missing) throw new Error(`chrome is missing libraries: ${missing}`);
  writeFileSync(join(root, "path.txt"), p);
  return p;
}

async function main() {
  const bin = chromePath();
  say("rendering");
  const port = 9300 + Math.floor(Math.random() * 500);
  const profile = join(work, "profile");
  rmSync(profile, { recursive: true, force: true });
  chrome = spawn(bin, [
    "--no-sandbox", "--disable-gpu", "--disable-dev-shm-usage", "--no-first-run",
    "--hide-scrollbars", `--user-data-dir=${profile}`, `--remote-debugging-port=${port}`,
    "--window-size=1200,1600", "about:blank",
  ], { stdio: ["ignore", "ignore", "pipe"] });

  let target;
  for (let i = 0; i < 100 && !target; i++) {
    await sleep(200);
    try { target = await (await fetch(`http://127.0.0.1:${port}/json/new?about:blank`, { method: "PUT" })).json(); } catch {}
  }
  if (!target) throw new Error("chrome did not start");

  const ws = new WebSocket(target.webSocketDebuggerUrl);
  await new Promise((resolve, reject) => { ws.onopen = resolve; ws.onerror = reject; });
  let id = 0;
  const pending = new Map();
  ws.onmessage = (m) => {
    const d = JSON.parse(m.data);
    if (d.id && pending.has(d.id)) { pending.get(d.id)(d); pending.delete(d.id); }
  };
  const send = (method, params = {}) => new Promise((resolve, reject) => {
    const i = ++id;
    pending.set(i, (d) => (d.error ? reject(new Error(`${method}: ${d.error.message}`)) : resolve(d.result)));
    ws.send(JSON.stringify({ id: i, method, params }));
  });
  const evalJs = async (expression) =>
    (await send("Runtime.evaluate", { expression, awaitPromise: true, returnByValue: true })).result?.value;

  await send("Network.enable");
  if (job.cookie) {
    await send("Network.setCookie", { ...job.cookie, path: "/", secure: job.url.startsWith("https"), httpOnly: true });
  }
  await send("Page.enable");
  await send("Page.navigate", { url: job.url });

  let rendered;
  const started = Date.now();
  while (!rendered) {
    await sleep(1000);
    rendered = await evalJs("document.body && document.body.dataset.bookRendered").catch(() => undefined);
    if (Date.now() - started > job.timeout_ms) throw new Error("the book never finished laying out");
  }
  if (rendered !== "true") throw new Error(`the book did not paginate (${rendered})`);
  const pages = Number(await evalJs("document.body.dataset.bookPages"));
  log("laid out", pages, "pages in", Date.now() - started, "ms");

  const { stream } = await send("Page.printToPDF", {
    printBackground: true, preferCSSPageSize: true, transferMode: "ReturnAsStream",
    marginTop: 0, marginBottom: 0, marginLeft: 0, marginRight: 0,
  });
  const chunks = [];
  for (;;) {
    const r = await send("IO.read", { handle: stream, size: 1 << 20 });
    chunks.push(Buffer.from(r.data, r.base64Encoded ? "base64" : "utf8"));
    if (r.eof) break;
  }
  await send("IO.close", { handle: stream });
  const printed = Buffer.concat(chunks);
  const raw = join(work, "printed.pdf");
  writeFileSync(raw, printed);
  log("printed", printed.length, "bytes");
  try { chrome.kill("SIGKILL"); } catch {}

  // Chrome embeds every drawing at full resolution (a 220-page journal came
  // out at 80 MB). Ghostscript recompresses images to print resolution and
  // keeps the pages, text and link annotations. Kept only if it is smaller.
  say("compressing", { pages });
  const out = join(work, "book.pdf");
  let pdf = printed;
  try {
    execFileSync("gs", [
      "-sDEVICE=pdfwrite", "-dCompatibilityLevel=1.7", "-dPDFSETTINGS=/printer",
      "-dDownsampleColorImages=true", "-dColorImageResolution=200", "-dColorImageDownsampleType=/Bicubic",
      "-dAutoFilterColorImages=false", "-dColorImageFilter=/DCTEncode", "-dJPEGQ=85",
      "-dNOPAUSE", "-dQUIET", "-dBATCH", `-sOutputFile=${out}`, raw,
    ], { stdio: "inherit", timeout: 600000 });
    const smaller = readFileSync(out);
    if (smaller.length > 0 && smaller.length < printed.length) pdf = smaller;
    log("compressed to", smaller.length, "bytes");
  } catch (e) {
    log("compression skipped:", String(e).slice(0, 200));
  }
  writeFileSync(out, pdf);
  rmSync(raw, { force: true });

  say("uploading", { pages, bytes: pdf.length });
  const res = await fetch(job.upload_url, { method: "PUT", body: pdf, headers: { "content-type": "application/pdf" } });
  if (!res.ok) throw new Error(`upload answered ${res.status}: ${(await res.text()).slice(0, 200)}`);
  if (!job.keep) rmSync(out, { force: true });
  say("done", { pages, bytes: pdf.length });
  log("uploaded");
  process.exit(0);
}

main().catch(fail);
