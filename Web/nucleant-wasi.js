// nucleant-wasi.js — the WASI (preview 1) a Swift wasm module needs to run
// in a browser page.
//
// The Swift SDK for WebAssembly targets wasm32-unknown-wasip1: the runtime
// asks the host for arguments, clocks, random bytes and stdout through WASI
// imports. A browser has none of them, so this provides them: stdio becomes
// line callbacks (console by default), clocks come from Date/performance,
// randomness from crypto. Files are whatever the page hands over (`files`):
// a read-only tree preopened at "/" — an app's resource bundles, say — and
// with none, there is no file system. Any call not listed answers ENOSYS,
// which Foundation handles as "not available".
//
//   const wasi = new NucleantWASI({ args: ['app'], files: { '/app/a.txt': bytes } });
//   const { instance } = await WebAssembly.instantiate(bytes, { ...wasi.imports, ...other });
//   wasi.attach(instance);

const ERRNO = {
  SUCCESS: 0, BADF: 8, EXIST: 20, INVAL: 28, ISDIR: 31, NOENT: 44, NOSYS: 52, NOTDIR: 54, ROFS: 69, SPIPE: 70,
};
const FILETYPE_CHARACTER_DEVICE = 2;
const FILETYPE_DIRECTORY = 3;
const FILETYPE_REGULAR_FILE = 4;
const RIGHTS_FD_SEEK = 1n << 2n;
const RIGHTS_FD_TELL = 1n << 5n;
const RIGHTS_FD_WRITE = 1n << 6n;
const RIGHTS_ALL = 0xffffffffffffffffn;
const RIGHTS_TTY = RIGHTS_ALL & ~(RIGHTS_FD_SEEK | RIGHTS_FD_TELL);
const OFLAGS_CREAT = 1, OFLAGS_DIRECTORY = 2, OFLAGS_EXCL = 4, OFLAGS_TRUNC = 8;
/** The one preopened descriptor: the root of `files`. */
const ROOT_FD = 3;

/** Thrown by proc_exit; `code` is the exit status. */
export class WASIExit extends Error {
  constructor(code) {
    super(`wasm module exited with status ${code}`);
    this.code = code;
  }
}

export class NucleantWASI {
  /**
   * @param {object}   options
   * @param {string[]} [options.args]    argv, argv[0] being the program name
   * @param {Object<string,string>} [options.env]
   * @param {(line: string) => void} [options.stdout]
   * @param {(line: string) => void} [options.stderr]
   * @param {boolean} [options.jspi]  sleep for real in poll_oneoff (the module
   *   must then be entered through WebAssembly.promising, as the WebGPU
   *   bridge's blocking waits require anyway)
   * @param {Object<string,Uint8Array>} [options.files]  read-only files by
   *   absolute path; their directories are implied
   */
  constructor({ args = ['nucleant'], env = {}, stdout = (line) => console.log(line), stderr = (line) => console.warn(line), jspi = false, files = null } = {}) {
    this.jspi = jspi;
    this.root = files && Object.keys(files).length ? makeTree(files) : null;
    this.open = new Map();  // fd -> { node, position }
    if (this.root) this.open.set(ROOT_FD, { node: this.root, position: 0 });
    this.nextFd = ROOT_FD + 1;
    this.args = args;
    this.env = Object.entries(env).map(([key, value]) => `${key}=${value}`);
    this.sinks = { 1: stdout, 2: stderr };
    this.pending = { 1: '', 2: '' };
    this.decoders = { 1: new TextDecoder(), 2: new TextDecoder() };
    this.memory = null;

    const functions = this.functions();
    // Anything the module imports that isn't implemented answers ENOSYS
    // instead of failing instantiation.
    const preview1 = new Proxy(functions, {
      get: (target, name) => target[name] ?? (() => ERRNO.NOSYS),
      has: () => true,
    });
    this.imports = { wasi_snapshot_preview1: preview1 };
  }

  attach(instance) {
    this.memory = instance.exports.memory;
  }

  /** Writes out any partial line still buffered on stdout/stderr. */
  flush() {
    for (const fd of [1, 2]) {
      if (this.pending[fd]) this.sinks[fd](this.pending[fd]);
      this.pending[fd] = '';
    }
  }

  view() { return new DataView(this.memory.buffer); }

  writeStrings(strings, pointersPtr, bufferPtr) {
    const view = this.view();
    const bytes = new Uint8Array(this.memory.buffer);
    let offset = bufferPtr;
    strings.forEach((string, i) => {
      const encoded = new TextEncoder().encode(string);
      view.setUint32(pointersPtr + i * 4, offset, true);
      bytes.set(encoded, offset);
      bytes[offset + encoded.length] = 0;
      offset += encoded.length + 1;
    });
    return ERRNO.SUCCESS;
  }

  sizes(strings, countPtr, sizePtr) {
    const view = this.view();
    view.setUint32(countPtr, strings.length, true);
    view.setUint32(sizePtr, strings.reduce((sum, s) => sum + new TextEncoder().encode(s).length + 1, 0), true);
    return ERRNO.SUCCESS;
  }

  functions() {
    return {
      args_sizes_get: (countPtr, sizePtr) => this.sizes(this.args, countPtr, sizePtr),
      args_get: (argvPtr, bufferPtr) => this.writeStrings(this.args, argvPtr, bufferPtr),
      environ_sizes_get: (countPtr, sizePtr) => this.sizes(this.env, countPtr, sizePtr),
      environ_get: (environPtr, bufferPtr) => this.writeStrings(this.env, environPtr, bufferPtr),

      clock_res_get: (id, resultPtr) => {
        this.view().setBigUint64(resultPtr, 1000n, true);
        return ERRNO.SUCCESS;
      },
      clock_time_get: (id, precision, resultPtr) => {
        const nanoseconds = id === 0
          ? BigInt(Date.now()) * 1_000_000n
          : BigInt(Math.round((performance.timeOrigin + performance.now()) * 1e6));
        this.view().setBigUint64(resultPtr, nanoseconds, true);
        return ERRNO.SUCCESS;
      },

      fd_write: (fd, iovs, iovsLength, writtenPtr) => {
        const view = this.view();
        let written = 0;
        for (let i = 0; i < iovsLength; i++) {
          const base = view.getUint32(iovs + i * 8, true);
          const length = view.getUint32(iovs + i * 8 + 4, true);
          if (fd === 1 || fd === 2) {
            this.pending[fd] += this.decoders[fd].decode(new Uint8Array(this.memory.buffer, base, length), { stream: true });
          }
          written += length;
        }
        if (fd !== 1 && fd !== 2) return ERRNO.BADF;
        const lines = this.pending[fd].split('\n');
        this.pending[fd] = lines.pop();
        for (const line of lines) this.sinks[fd](line);
        view.setUint32(writtenPtr, written, true);
        return ERRNO.SUCCESS;
      },
      fd_read: (fd, iovs, iovsLength, readPtr) => {
        const file = this.open.get(fd);
        if (file) {
          if (file.node.children) return ERRNO.ISDIR;
          const read = this.readInto(file.node.data, file.position, iovs, iovsLength);
          file.position += read;
          this.view().setUint32(readPtr, read, true);
          return ERRNO.SUCCESS;
        }
        this.view().setUint32(readPtr, 0, true);
        return fd === 0 ? ERRNO.SUCCESS : ERRNO.BADF;
      },
      fd_pread: (fd, iovs, iovsLength, offset, readPtr) => {
        const file = this.open.get(fd);
        if (!file) return ERRNO.BADF;
        if (file.node.children) return ERRNO.ISDIR;
        this.view().setUint32(readPtr, this.readInto(file.node.data, Number(offset), iovs, iovsLength), true);
        return ERRNO.SUCCESS;
      },
      fd_close: (fd) => {
        this.open.delete(fd);
        return ERRNO.SUCCESS;
      },
      fd_seek: (fd, offset, whence, newOffsetPtr) => {
        const file = this.open.get(fd);
        if (!file) return fd <= 2 ? ERRNO.SPIPE : ERRNO.BADF;
        if (file.node.children) return ERRNO.ISDIR;
        const base = whence === 0 ? 0 : whence === 1 ? file.position : file.node.data.length;
        const position = base + Number(offset);
        if (position < 0) return ERRNO.INVAL;
        file.position = position;
        this.view().setBigUint64(newOffsetPtr, BigInt(position), true);
        return ERRNO.SUCCESS;
      },
      fd_tell: (fd, offsetPtr) => {
        const file = this.open.get(fd);
        if (!file) return fd <= 2 ? ERRNO.SPIPE : ERRNO.BADF;
        this.view().setBigUint64(offsetPtr, BigInt(file.position), true);
        return ERRNO.SUCCESS;
      },
      fd_sync: () => ERRNO.SUCCESS,
      fd_fdstat_get: (fd, statPtr) => {
        const file = this.open.get(fd);
        if (file) {
          const view = this.view();
          for (let i = 0; i < 24; i++) view.setUint8(statPtr + i, 0);
          view.setUint8(statPtr, file.node.children ? FILETYPE_DIRECTORY : FILETYPE_REGULAR_FILE);
          // Read-only in fact (path_open refuses writing), but every right
          // granted, so wasi-libc's access() checks on a directory pass.
          view.setBigUint64(statPtr + 8, RIGHTS_ALL, true);
          view.setBigUint64(statPtr + 16, RIGHTS_ALL, true);
          return ERRNO.SUCCESS;
        }
        if (fd > 2) return ERRNO.BADF;
        const view = this.view();
        for (let i = 0; i < 24; i++) view.setUint8(statPtr + i, 0);
        view.setUint8(statPtr, FILETYPE_CHARACTER_DEVICE);
        // A character device without seek/tell rights is what wasi-libc's
        // isatty() looks for — and a terminal gets line-buffered stdio, so a
        // print() shows up when it happens rather than when a buffer fills.
        view.setBigUint64(statPtr + 8, RIGHTS_TTY, true);
        view.setBigUint64(statPtr + 16, RIGHTS_TTY, true);
        return ERRNO.SUCCESS;
      },
      fd_fdstat_set_flags: () => ERRNO.SUCCESS,
      fd_filestat_get: (fd, statPtr) => {
        const file = this.open.get(fd);
        if (file) {
          this.writeFilestat(file.node, statPtr);
          return ERRNO.SUCCESS;
        }
        if (fd > 2) return ERRNO.BADF;
        const view = this.view();
        for (let i = 0; i < 64; i++) view.setUint8(statPtr + i, 0);
        view.setUint8(statPtr + 16, FILETYPE_CHARACTER_DEVICE);
        return ERRNO.SUCCESS;
      },
      // One preopened directory, "/", when there are files; the next query
      // ends the enumeration.
      fd_prestat_get: (fd, prestatPtr) => {
        if (!this.root || fd !== ROOT_FD) return ERRNO.BADF;
        const view = this.view();
        view.setUint32(prestatPtr, 0, true);      // a directory
        view.setUint32(prestatPtr + 4, 1, true);  // "/"
        return ERRNO.SUCCESS;
      },
      fd_prestat_dir_name: (fd, pathPtr, length) => {
        if (!this.root || fd !== ROOT_FD) return ERRNO.BADF;
        if (length >= 1) this.view().setUint8(pathPtr, 0x2f);
        return ERRNO.SUCCESS;
      },
      path_open: (dirFd, lookupFlags, pathPtr, pathLength, oflags, rightsBase, rightsInheriting, fdflags, fdPtr) => {
        const node = this.lookup(dirFd, pathPtr, pathLength);
        if (typeof node === 'number') {
          return node === ERRNO.NOENT && (oflags & OFLAGS_CREAT) ? ERRNO.ROFS : node;
        }
        if ((oflags & OFLAGS_CREAT) && (oflags & OFLAGS_EXCL)) return ERRNO.EXIST;
        if ((oflags & OFLAGS_DIRECTORY) && !node.children) return ERRNO.NOTDIR;
        if ((oflags & OFLAGS_TRUNC) || (BigInt(rightsBase) & RIGHTS_FD_WRITE)) {
          return node.children ? ERRNO.ISDIR : ERRNO.ROFS;
        }
        const fd = this.nextFd++;
        this.open.set(fd, { node, position: 0 });
        this.view().setUint32(fdPtr, fd, true);
        return ERRNO.SUCCESS;
      },
      path_filestat_get: (dirFd, lookupFlags, pathPtr, pathLength, statPtr) => {
        const node = this.lookup(dirFd, pathPtr, pathLength);
        if (typeof node === 'number') return node;
        this.writeFilestat(node, statPtr);
        return ERRNO.SUCCESS;
      },
      fd_readdir: (fd, bufferPtr, bufferLength, cookie, usedPtr) => {
        const file = this.open.get(fd);
        if (!file) return ERRNO.BADF;
        if (!file.node.children) return ERRNO.NOTDIR;
        const bytes = new Uint8Array(this.memory.buffer, bufferPtr, bufferLength);
        const view = this.view();
        const entries = [...file.node.children.entries()];
        let used = 0;
        // Each entry: a 24-byte dirent, then its name; the last may be cut
        // short, and the caller then asks again from its cookie.
        for (let index = Number(cookie); index < entries.length && used < bufferLength; index++) {
          const [name, child] = entries[index];
          const encoded = new TextEncoder().encode(name);
          const record = new Uint8Array(24 + encoded.length);
          const header = new DataView(record.buffer);
          header.setBigUint64(0, BigInt(index + 1), true);
          header.setBigUint64(8, BigInt(child.ino), true);
          header.setUint32(16, encoded.length, true);
          header.setUint8(20, child.children ? FILETYPE_DIRECTORY : FILETYPE_REGULAR_FILE);
          record.set(encoded, 24);
          const take = Math.min(record.length, bufferLength - used);
          bytes.set(record.subarray(0, take), used);
          used += take;
        }
        view.setUint32(usedPtr, used, true);
        return ERRNO.SUCCESS;
      },

      // A sleep (Task.sleep, usleep, a timed wait) is a clock subscription.
      // Under JSPI the module's stack suspends until the earliest one is due,
      // and the page keeps running meanwhile; without it nothing may block
      // the page's thread, and every subscription is reported ready at once.
      poll_oneoff: this.jspi
        ? new WebAssembly.Suspending(async (inPtr, outPtr, count, eventsPtr) => {
          const delay = this.earliestTimeout(inPtr, count);
          if (delay > 0) await new Promise((resolve) => setTimeout(resolve, delay));
          return this.reportReady(inPtr, outPtr, count, eventsPtr);
        })
        : (inPtr, outPtr, count, eventsPtr) => this.reportReady(inPtr, outPtr, count, eventsPtr),
      proc_exit: (code) => {
        this.flush();
        throw new WASIExit(code);
      },
      random_get: (ptr, length) => {
        for (let offset = 0; offset < length; offset += 65536) {
          crypto.getRandomValues(new Uint8Array(this.memory.buffer, ptr + offset, Math.min(65536, length - offset)));
        }
        return ERRNO.SUCCESS;
      },
      sched_yield: () => ERRNO.SUCCESS,
    };
  }

  // MARK: - Files

  /** The node `path` names, relative to directory `dirFd`; an errno if none. */
  lookup(dirFd, pathPtr, pathLength) {
    const directory = this.open.get(dirFd);
    if (!directory) return ERRNO.BADF;
    const path = new TextDecoder().decode(new Uint8Array(this.memory.buffer, pathPtr, pathLength));
    const trail = [directory.node];
    for (const part of path.split('/')) {
      if (part === '' || part === '.') continue;
      const current = trail[trail.length - 1];
      if (!current.children) return ERRNO.NOTDIR;
      if (part === '..') {
        if (trail.length > 1) trail.pop();
        continue;
      }
      const next = current.children.get(part);
      if (!next) return ERRNO.NOENT;
      trail.push(next);
    }
    return trail[trail.length - 1];
  }

  /** Copies `data` from `position` into the iovecs; returns the byte count. */
  readInto(data, position, iovs, iovsLength) {
    const view = this.view();
    let read = 0;
    for (let i = 0; i < iovsLength && position + read < data.length; i++) {
      const base = view.getUint32(iovs + i * 8, true);
      const length = view.getUint32(iovs + i * 8 + 4, true);
      const chunk = data.subarray(position + read, Math.min(data.length, position + read + length));
      new Uint8Array(this.memory.buffer, base, chunk.length).set(chunk);
      read += chunk.length;
    }
    return read;
  }

  writeFilestat(node, statPtr) {
    const view = this.view();
    for (let i = 0; i < 64; i++) view.setUint8(statPtr + i, 0);
    view.setBigUint64(statPtr + 8, BigInt(node.ino), true);
    view.setUint8(statPtr + 16, node.children ? FILETYPE_DIRECTORY : FILETYPE_REGULAR_FILE);
    view.setBigUint64(statPtr + 24, 1n, true);
    view.setBigUint64(statPtr + 32, BigInt(node.children ? 0 : node.data.length), true);
  }

  /** Milliseconds until the soonest clock subscription is due (0 for none). */
  earliestTimeout(inPtr, count) {
    const view = this.view();
    let earliest = Infinity;
    for (let i = 0; i < count; i++) {
      const subscription = inPtr + i * 48;
      if (view.getUint8(subscription + 8) !== 0) continue;  // not a clock
      const clock = view.getUint32(subscription + 16, true);
      const timeout = Number(view.getBigUint64(subscription + 24, true)) / 1e6;
      const absolute = (view.getUint16(subscription + 40, true) & 1) !== 0;
      const now = clock === 0 ? Date.now() : performance.timeOrigin + performance.now();
      earliest = Math.min(earliest, absolute ? timeout - now : timeout);
    }
    return Number.isFinite(earliest) ? Math.max(0, earliest) : 0;
  }

  reportReady(inPtr, outPtr, count, eventsPtr) {
    const view = this.view();
    for (let i = 0; i < count; i++) {
      const subscription = inPtr + i * 48;
      const event = outPtr + i * 32;
      view.setBigUint64(event, view.getBigUint64(subscription, true), true);
      view.setUint16(event + 8, ERRNO.SUCCESS, true);
      view.setUint8(event + 10, view.getUint8(subscription + 8));
      for (let b = 11; b < 32; b++) view.setUint8(event + b, 0);
    }
    view.setUint32(eventsPtr, count, true);
    return ERRNO.SUCCESS;
  }
}

/** A directory tree of `files` (absolute path -> bytes): nodes are
 * `{ ino, children: Map }` for directories, `{ ino, data }` for files. */
function makeTree(files) {
  let ino = 1;
  const root = { ino: ino++, children: new Map() };
  for (const [path, data] of Object.entries(files)) {
    const parts = path.split('/').filter((part) => part && part !== '.');
    let directory = root;
    for (const part of parts.slice(0, -1)) {
      let next = directory.children.get(part);
      if (!next) {
        next = { ino: ino++, children: new Map() };
        directory.children.set(part, next);
      }
      directory = next;
    }
    if (parts.length) directory.children.set(parts[parts.length - 1], { ino: ino++, data });
  }
  return root;
}
