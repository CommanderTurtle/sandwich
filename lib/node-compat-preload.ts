import * as nativeNodeModule from "node:module";
import * as nativeNodeUtil from "node:util";
import { pathToFileURL } from "node:url";
import * as nodeFs from "node:fs";
import * as nodePath from "node:path";

// Bun intentionally does not implement URL imports. Node-oriented test harnesses
// commonly use base64 JavaScript data URLs to evaluate a generated ESM module,
// so the `node` compatibility entrypoint resolves that one deterministic form.
Bun.plugin({
  name: "sandwich-node-data-url",
  setup(builder) {
    builder.onResolve(
      { filter: /^data:text\/javascript;base64,/ },
      (args) => ({ path: args.path, namespace: "sandwich-data-js" }),
    );
    builder.onLoad(
      { filter: /.*/, namespace: "sandwich-data-js" },
      (args) => {
        const separator = args.path.indexOf(",");
        if (separator < 0) {
          throw new Error("invalid JavaScript data URL");
        }
        return {
          contents: Buffer.from(args.path.slice(separator + 1), "base64").toString("utf8"),
          loader: "js",
        };
      },
    );
  },
});

type AmaroFailure = {
  code?: unknown;
  message?: unknown;
  filename?: unknown;
  startLine?: unknown;
  snippet?: unknown;
};

type AmaroTransform = (
  source: string,
  options: { mode: "strip-only"; filename?: string },
) => { code: string };

type StripTypeScriptOptions = {
  mode?: "strip" | "transform";
  sourceMap?: boolean;
  sourceUrl?: string;
};

const nativeCreateRequire = nativeNodeModule.createRequire;
const requireFromPreload = nativeCreateRequire(import.meta.url);
let cachedAmaroTransform: AmaroTransform | undefined;

function amaroTransform(): AmaroTransform {
  if (cachedAmaroTransform) return cachedAmaroTransform;

  const loaded = requireFromPreload("amaro") as { transformSync?: unknown };
  if (typeof loaded.transformSync !== "function") {
    throw new Error("Sandwich could not load Amaro's transformSync export");
  }
  cachedAmaroTransform = loaded.transformSync as AmaroTransform;
  return cachedAmaroTransform;
}

function throwAmaroFailure(cause: unknown): never {
  if (cause instanceof Error) throw cause;

  const failure = (cause ?? {}) as AmaroFailure;
  const message =
    typeof failure.message === "string"
      ? failure.message
      : `TypeScript stripping failed: ${String(cause)}`;
  const error = new SyntaxError(message, { cause });
  if (failure.code === "UnsupportedSyntax") {
    error.name = "UnsupportedSyntaxError";
  }

  const location = [failure.filename, failure.startLine]
    .filter((part) => part !== undefined)
    .join(":");
  const context = [location, failure.snippet]
    .filter((part) => typeof part === "string" && part.length > 0)
    .join("\n");
  if (context) error.stack = `${context}\n${error.stack ?? `${error.name}: ${message}`}`;
  throw error;
}

function sandwichStripTypeScriptTypes(
  code: string,
  options: StripTypeScriptOptions = {},
): string {
  if (typeof code !== "string") {
    throw new TypeError("The 'code' argument must be a string");
  }
  if (options === null || typeof options !== "object") {
    throw new TypeError("The 'options' argument must be an object");
  }

  const mode = options.mode ?? "strip";
  if (mode !== "strip") {
    throw new Error(
      "Sandwich implements node:module.stripTypeScriptTypes in position-preserving strip mode only",
    );
  }
  if (options.sourceMap === true) {
    throw new Error(
      "node:module.stripTypeScriptTypes source maps require transform mode, which Sandwich does not emulate",
    );
  }
  if (options.sourceUrl !== undefined && typeof options.sourceUrl !== "string") {
    throw new TypeError("The 'sourceUrl' option must be a string");
  }

  try {
    const result = amaroTransform()(code, {
      mode: "strip-only",
      ...(options.sourceUrl ? { filename: options.sourceUrl } : {}),
    }).code;
    return options.sourceUrl
      ? `${result}\n\n//# sourceURL=${options.sourceUrl}`
      : result;
  } catch (cause) {
    throwAmaroFailure(cause);
  }
}

class SandwichLoadCache extends Map<string, unknown> {
  override has(url: string): boolean {
    if (typeof url === "string" && url.startsWith("file:")) {
      throw new Error(
        "Sandwich's Bun loader bridge supports DSH profile watching, not Node module hot reload",
      );
    }
    return super.has(url);
  }
}

const sandwichLoadCache = new SandwichLoadCache();

function resolveFromParent(specifier: string, parentURL: string): string {
  if (nativeNodeModule.isBuiltin(specifier)) {
    return specifier.startsWith("node:") ? specifier : `node:${specifier}`;
  }
  if (
    specifier.startsWith("./") ||
    specifier.startsWith("../") ||
    specifier.startsWith("/") ||
    /^[A-Za-z][A-Za-z0-9+.-]*:/.test(specifier)
  ) {
    return new URL(specifier, parentURL).href;
  }
  return pathToFileURL(nativeCreateRequire(parentURL).resolve(specifier)).href;
}

const sandwichInternalLoader = {
  loadCache: sandwichLoadCache,
  async import(
    specifier: string,
    parentURL: string,
    _importAttributes: ImportAttributes,
  ): Promise<unknown> {
    // Real Node's cascaded loader resolves import() through its own
    // resolveSync, so consumers that patch resolveSync (dsh's runtime
    // interception) stay in the resolution path here too.
    return import(this.resolveSync(parentURL, { specifier }).url);
  },
  register(): never {
    throw new Error(
      "Sandwich's Bun loader bridge cannot register Node ESM loader hooks",
    );
  },
  getOrCreateModuleJob(): never {
    throw new Error(
      "Sandwich's Bun loader bridge cannot expose Node module jobs",
    );
  },
  resolveSync(
    parentURL: string,
    request: { specifier: string },
  ): { format: "builtin" | "module"; url: string } {
    const url = resolveFromParent(request.specifier, parentURL);
    return {
      format: url.startsWith("node:") ? "builtin" : "module",
      url,
    };
  },
  load(): never {
    throw new Error(
      "Sandwich's Bun loader bridge cannot expose Node loader source records",
    );
  },
};

const sandwichInternalModule = Object.freeze({
  getOrInitializeCascadedLoader: () => sandwichInternalLoader,
});

// dsh's runtime interception reads Node's private module internals through the
// node-addon-require-builtin addon. Bun has no Node internals to expose, so the
// bridge serves the five surfaces dsh validates over Bun primitives. The
// interception stays inert under Bun — nothing routes Bun's own import machinery
// through these objects — so dsh only needs them to exist with the shapes its
// Node 22/24/26 matrix validates.
class SandwichCjsModule {
  id: string;
  path: string;
  exports: Record<string, unknown> = {};
  filename: string;
  loaded = false;
  children: unknown[] = [];

  constructor(id: string) {
    this.id = id;
    this.path = nodePath.dirname(id);
    this.filename = id;
  }

  static _nodeModulePaths(from: string): string[] {
    const paths: string[] = [];
    let current = nodePath.resolve(from);
    for (;;) {
      paths.push(nodePath.join(current, "node_modules"));
      const parent = nodePath.dirname(current);
      if (parent === current) return paths;
      current = parent;
    }
  }

  static _resolveFilename(
    request: string,
    parent?: { filename?: string; paths?: readonly string[] },
  ): string {
    if (nativeNodeModule.isBuiltin(request)) {
      return request.startsWith("node:") ? request : `node:${request}`;
    }
    const anchor = parent?.filename ?? `${process.cwd()}/`;
    if (request.startsWith("./") || request.startsWith("../")) {
      return nodePath.resolve(nodePath.dirname(anchor), request);
    }
    if (request.startsWith("/")) return request;
    for (const root of parent?.paths ?? []) {
      const probed = SandwichCjsModule.probe(nodePath.join(root, request));
      if (probed) return probed;
    }
    const error = new Error(
      `Cannot find module '${request}' from '${anchor}'`,
    ) as NodeJS.ErrnoException & { requireStack: string[] };
    error.code = "MODULE_NOT_FOUND";
    error.requireStack = [anchor];
    throw error;
  }

  private static probe(base: string): string | undefined {
    for (const candidate of [
      base,
      `${base}.js`,
      `${base}.json`,
      `${base}.node`,
      `${base}${nodePath.sep}index.js`,
      `${base}${nodePath.sep}index.json`,
    ]) {
      if (nodeFs.existsSync(candidate) && nodeFs.statSync(candidate).isFile()) {
        return candidate;
      }
    }
    return undefined;
  }
}

function sandwichDefaultResolve(
  specifier: string,
  context: { parentURL?: string } = {},
): { format?: string; url: string } {
  const parentURL = context.parentURL ?? pathToFileURL(`${process.cwd()}/`).href;
  const url = resolveFromParent(specifier, parentURL);
  if (url.startsWith("node:")) return { url };
  return { format: url.endsWith(".json") ? "json" : "module", url };
}

const sandwichCjsLoaderModule = Object.freeze({ Module: SandwichCjsModule });
const sandwichCjsHelpers = Object.freeze({
  getCjsConditions: () =>
    new Set(["require", "node", "node-addons", "module-sync"]),
});
const sandwichEsmUtils = Object.freeze({
  getDefaultConditions: () =>
    Object.freeze(["node", "import", "module-sync", "node-addons"]),
});
const sandwichEsmResolve = Object.freeze({
  defaultResolve: sandwichDefaultResolve,
});

function copyRequireProperties(
  target: NodeJS.Require,
  source: NodeJS.Require,
): NodeJS.Require {
  for (const key of Reflect.ownKeys(source)) {
    if (["length", "name", "arguments", "caller", "prototype"].includes(String(key))) {
      continue;
    }
    const descriptor = Object.getOwnPropertyDescriptor(source, key);
    if (descriptor) Object.defineProperty(target, key, descriptor);
  }
  return target;
}

function sandwichCreateRequire(filename: string | URL): NodeJS.Require {
  const nativeRequire = nativeCreateRequire(filename);
  const wrappedRequire = function (specifier: string): unknown {
    if (specifier !== "node-addon-require-builtin") {
      return nativeRequire(specifier);
    }
    return Object.freeze({
      requireBuiltin(id: string): unknown {
        if (id === "internal/modules/esm/loader") return sandwichInternalModule;
        if (id === "internal/modules/cjs/loader") return sandwichCjsLoaderModule;
        if (id === "internal/modules/helpers") return sandwichCjsHelpers;
        if (id === "internal/modules/esm/utils") return sandwichEsmUtils;
        if (id === "internal/modules/esm/resolve") return sandwichEsmResolve;
        if (id.startsWith("internal/")) {
          throw new Error(`Sandwich does not expose Node private module ${JSON.stringify(id)}`);
        }
        return nativeRequire(id);
      },
    });
  } as NodeJS.Require;
  return copyRequireProperties(wrappedRequire, nativeRequire);
}

const nativeExports = nativeNodeModule as typeof nativeNodeModule &
  Record<string, unknown>;
const stripTypeScriptTypes =
  typeof nativeExports.stripTypeScriptTypes === "function"
    ? nativeExports.stripTypeScriptTypes
    : sandwichStripTypeScriptTypes;

// Keep CommonJS/default-import behavior native while adding the missing method.
// The synthetic ESM namespace below is necessary because adding a property alone
// cannot add a new named export to Bun's built-in module namespace.
const nativeDefault = nativeNodeModule.default as typeof nativeNodeModule.default &
  Record<string, unknown>;
Object.defineProperty(nativeDefault, "createRequire", {
  configurable: true,
  enumerable: true,
  value: sandwichCreateRequire,
  writable: false,
});
if (typeof nativeDefault.stripTypeScriptTypes !== "function") {
  Object.defineProperty(nativeDefault, "stripTypeScriptTypes", {
    configurable: true,
    enumerable: true,
    value: stripTypeScriptTypes,
    writable: false,
  });
}

const nodeModuleBridge = Object.freeze({
  ...nativeNodeModule,
  createRequire: sandwichCreateRequire,
  default: nativeDefault,
  stripTypeScriptTypes,
});
const nodeModuleBridgeSymbol = Symbol.for("sandwich.node-module.bridge");
Object.defineProperty(globalThis, nodeModuleBridgeSymbol, {
  configurable: true,
  value: nodeModuleBridge,
});

const identifier = /^[A-Za-z_$][A-Za-z0-9_$]*$/;
const nodeModuleBridgeSource = [
  'const bridge = globalThis[Symbol.for("sandwich.node-module.bridge")];',
  ...Object.keys(nodeModuleBridge)
    .filter((name) => name !== "default" && identifier.test(name))
    .map((name) => `export const ${name} = bridge[${JSON.stringify(name)}];`),
  "export default bridge.default;",
].join("\n");

Bun.plugin({
  name: "sandwich-node-module",
  setup(builder) {
    builder.onResolve(
      { filter: /^module$/, namespace: "node" },
      () => ({ path: "module", namespace: "sandwich-node-module" }),
    );
    builder.onLoad(
      { filter: /^module$/, namespace: "sandwich-node-module" },
      () => ({ contents: nodeModuleBridgeSource, loader: "js" }),
    );
  },
});

// Bun's node:util predates Node 26's util.getSystemErrorMessage, which dsh's
// subprocess runner uses to format libuv failures. Serve the native util
// namespace plus that one method through the same synthetic-namespace bridge
// used for node:module above. Node accepts only negative libuv codes and
// answers unknown ones with its own "Unknown system error" text; the table
// holds Node 26.7.0's exact uv_strerror strings for Linux.
const UV_ERROR_MESSAGES: Record<number, string> = {
  1: "operation not permitted",
  2: "no such file or directory",
  3: "no such process",
  4: "interrupted system call",
  5: "i/o error",
  6: "no such device or address",
  7: "argument list too long",
  8: "exec format error",
  9: "bad file descriptor",
  11: "resource temporarily unavailable",
  12: "not enough memory",
  13: "permission denied",
  14: "bad address in system call argument",
  16: "resource busy or locked",
  17: "file already exists",
  18: "cross-device link not permitted",
  19: "no such device",
  20: "not a directory",
  21: "illegal operation on a directory",
  22: "invalid argument",
  23: "file table overflow",
  24: "too many open files",
  25: "inappropriate ioctl for device",
  26: "text file is busy",
  27: "file too large",
  28: "no space left on device",
  29: "invalid seek",
  30: "read-only file system",
  31: "too many links",
  32: "broken pipe",
  34: "result too large",
  36: "name too long",
  38: "function not implemented",
  39: "directory not empty",
  40: "too many symbolic links encountered",
  49: "protocol driver not attached",
  61: "no data available",
  64: "machine is not on the network",
  71: "protocol error",
  75: "value too large for defined data type",
  84: "illegal byte sequence",
  88: "socket operation on non-socket",
  89: "destination address required",
  90: "message too long",
  91: "protocol wrong type for socket",
  92: "protocol not available",
  93: "protocol not supported",
  94: "socket type not supported",
  95: "operation not supported on socket",
  97: "address family not supported",
  98: "address already in use",
  99: "address not available",
  100: "network is down",
  101: "network is unreachable",
  103: "software caused connection abort",
  104: "connection reset by peer",
  105: "no buffer space available",
  106: "socket is already connected",
  107: "socket is not connected",
  108: "cannot send after transport endpoint shutdown",
  110: "connection timed out",
  111: "connection refused",
  112: "host is down",
  113: "host is unreachable",
  114: "connection already in progress",
  121: "remote I/O error",
  125: "operation canceled",
};

function sandwichGetSystemErrorMessage(err: number): string {
  if (typeof err !== "number" || !Number.isInteger(err) || err >= 0) {
    const error = new RangeError(
      `The value of "err" is out of range. It must be a negative integer. Received ${err}`,
    ) as NodeJS.ErrnoException;
    error.code = "ERR_OUT_OF_RANGE";
    throw error;
  }
  return UV_ERROR_MESSAGES[-err] ?? `Unknown system error ${err}`;
}

const nodeUtilBridge = Object.freeze({
  ...nativeNodeUtil,
  default: nativeNodeUtil.default,
  getSystemErrorMessage: sandwichGetSystemErrorMessage,
});
const nodeUtilBridgeSymbol = Symbol.for("sandwich.node-util.bridge");
Object.defineProperty(globalThis, nodeUtilBridgeSymbol, {
  configurable: true,
  value: nodeUtilBridge,
});

const nodeUtilBridgeSource = [
  'const bridge = globalThis[Symbol.for("sandwich.node-util.bridge")];',
  ...Object.keys(nodeUtilBridge)
    .filter((name) => name !== "default" && identifier.test(name))
    .map((name) => `export const ${name} = bridge[${JSON.stringify(name)}];`),
  "export default bridge;",
].join("\n");

Bun.plugin({
  name: "sandwich-node-util",
  setup(builder) {
    builder.onResolve(
      { filter: /^util$/, namespace: "node" },
      () => ({ path: "util", namespace: "sandwich-node-util" }),
    );
    builder.onLoad(
      { filter: /^util$/, namespace: "sandwich-node-util" },
      () => ({ contents: nodeUtilBridgeSource, loader: "js" }),
    );
  },
});

