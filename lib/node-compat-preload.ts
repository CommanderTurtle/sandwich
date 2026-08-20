import * as nativeNodeModule from "node:module";
import { pathToFileURL } from "node:url";

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
    return import(resolveFromParent(specifier, parentURL));
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
