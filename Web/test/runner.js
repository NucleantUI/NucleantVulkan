// Runs a SwiftPM test product built for wasm32-wasip1 (the .xctest file
// `swift build --build-tests --swift-sdk …_wasm` produces) inside this page,
// with the WebGPU bridge as its Vulkan and nucleant-wasi.js as its WASI.
//
// Driven by scripts/run_wasm_tests.py: the page reports every output line to
// POST /log and the exit status to POST /done. Any WebGPU validation error
// (or failed shader translation) fails the run, since on a Vulkan driver
// the same call would have been a validation-layer error.
//
// Query: ?wasm=<url of the test product>&args=<JSON array of test arguments>
//        [&files=<url of a manifest of files to mount read-only>]
//
// The manifest is { "root": "/where/they/appear", "base": "<url they are
// fetched from>", "files": ["relative/path", …] } — how a package's tests
// reach their resource bundles, which SwiftPM's Bundle.module names by the
// path they were built at.

import { createNucleantWebGPU } from '../nucleant-webgpu.js';
import { NucleantWASI, WASIExit } from '../nucleant-wasi.js';

const params = new URLSearchParams(location.search);
const output = document.getElementById('output');
let posting = Promise.resolve();

function report(path, body) {
  posting = posting.then(() => fetch(path, { method: 'POST', body }).catch(() => {}));
  return posting;
}

function line(text) {
  output.textContent += text + '\n';
  report('/log', text);
}

/** The manifest's files, by the absolute path the module sees. */
async function loadFiles(manifestURL) {
  const manifestBase = new URL(manifestURL, location.href);
  const manifest = await (await fetch(manifestBase)).json();
  const base = new URL(manifest.base ?? '', manifestBase);
  const root = manifest.root.replace(/\/$/, '');
  const entries = await Promise.all(manifest.files.map(async (path) => {
    const file = await fetch(new URL(path.split('/').map(encodeURIComponent).join('/'), base));
    if (!file.ok) throw new Error(`cannot load ${path} (${file.status})`);
    return [`${root}/${path}`, new Uint8Array(await file.arrayBuffer())];
  }));
  return Object.fromEntries(entries);
}

async function run() {
  const errors = [];
  const gpu = await createNucleantWebGPU({
    nagaURL: new URL('../naga_webgpu.wasm', import.meta.url),
    onError: (message) => errors.push(message),
  });
  line(`[runner] WebGPU device ready; blocking waits (JSPI): ${gpu.blockingWaits}`);
  const args = JSON.parse(params.get('args') ?? '[]');
  const files = params.get('files') ? await loadFiles(params.get('files')) : null;
  const wasi = new NucleantWASI({ args: ['NucleantVulkanPackageTests', ...args], stdout: line, stderr: line, files });
  const bytes = await (await fetch(params.get('wasm'))).arrayBuffer();
  const { instance } = await WebAssembly.instantiate(bytes, { ...wasi.imports, ...gpu.imports });
  gpu.attach(instance);
  wasi.attach(instance);

  let status = 0;
  try {
    const start = gpu.blockingWaits ? WebAssembly.promising(instance.exports._start) : instance.exports._start;
    await start();
  } catch (error) {
    if (error instanceof WASIExit) status = error.code;
    else {
      line(`[runner] trapped: ${error?.stack ?? error}`);
      status = 1;
    }
  }
  wasi.flush();
  // Let in-flight GPU work report its errors before deciding.
  await gpu.device.queue.onSubmittedWorkDone();
  for (const message of errors) line(`[runner] WebGPU error: ${message}`);
  if (errors.length && status === 0) status = 1;
  return status;
}

run()
  .catch((error) => {
    line(`[runner] failed to start: ${error?.stack ?? error}`);
    return 1;
  })
  .then((status) => report('/done', String(status)));
