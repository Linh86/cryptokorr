/**
 * Snake / camel case converters for the SDK ↔ wire boundary.
 *
 * The wire is snake_case (matches `priv/openapi/openapi.json`); the
 * SDK exposes camelCase per `docs/api/sdk-surface.md`. Object keys
 * are converted recursively; values pass through unchanged.
 *
 * Arrays are walked element-wise. Plain objects (`Object.prototype`
 * or null prototype) get their keys converted; anything class-shaped
 * (`Date`, `Map`, `Set`, custom classes) passes through verbatim.
 */

const CAMEL_RE = /([a-z0-9])([A-Z])/g;
const SNAKE_RE = /_([a-z0-9])/g;

function camelKey(key: string): string {
  return key.replace(SNAKE_RE, (_match, ch: string) => ch.toUpperCase());
}

function snakeKey(key: string): string {
  return key.replace(CAMEL_RE, "$1_$2").toLowerCase();
}

function isPlainObject(value: unknown): value is Record<string, unknown> {
  if (value === null || typeof value !== "object") return false;
  const proto = Object.getPrototypeOf(value);
  return proto === null || proto === Object.prototype;
}

export function toCamelDeep(value: unknown): unknown {
  if (Array.isArray(value)) return value.map(toCamelDeep);
  if (!isPlainObject(value)) return value;

  const out: Record<string, unknown> = {};
  for (const [key, raw] of Object.entries(value)) {
    out[camelKey(key)] = toCamelDeep(raw);
  }
  return out;
}

export function toSnakeDeep(value: unknown): unknown {
  if (Array.isArray(value)) return value.map(toSnakeDeep);
  if (!isPlainObject(value)) return value;

  const out: Record<string, unknown> = {};
  for (const [key, raw] of Object.entries(value)) {
    out[snakeKey(key)] = toSnakeDeep(raw);
  }
  return out;
}
