import { createRequire } from "node:module";
import { readFile, writeFile, mkdir } from "node:fs/promises";
import { fileURLToPath } from "node:url";
import path from "node:path";

const root = fileURLToPath(new URL("../../", import.meta.url));
const require = createRequire(path.join(root, "server/package.json"));
const ts = require("typescript");
const entries = ["auth", "book", "library", "permissions", "query"].map((name) => path.join(root, `packages/types/src/${name}.ts`));
const program = ts.createProgram(entries, {
  strict: true,
  target: ts.ScriptTarget.ES2022,
  module: ts.ModuleKind.Node16,
  moduleResolution: ts.ModuleResolutionKind.Node16,
  skipLibCheck: true,
});
const diagnostics = ts.getPreEmitDiagnostics(program);
if (diagnostics.length) {
  throw new Error(
    ts.formatDiagnosticsWithColorAndContext(diagnostics, {
      getCurrentDirectory: () => root,
      getCanonicalFileName: (name) => name,
      getNewLine: () => "\n",
    }),
  );
}
const checker = program.getTypeChecker();
const symbols = new Map(
  entries.flatMap((entry) =>
    checker.getExportsOfModule(checker.getSymbolAtLocation(program.getSourceFile(entry))).map((symbol) => [symbol.name, symbol]),
  ),
);

// These audited projections decode existing responses without generating unused server data.
const projections = {
  AuthUser: ["id", "username", "name", "active", "isSuperuser", "isDefaultPassword", "permissions"],
  Library: ["id", "type", "accessLevel", "name", "bookCount"],
  BookCard: ["id", "title", "authors", "files", "hasCover", "coverVersion", "readingProgress", "seriesName"],
  BookDetail: ["id", "libraryId", "libraryName", "title", "description", "authors", "files", "lockedFields", "coverVersion"],
  BookDetailFile: ["id", "format", "role", "filename", "sizeBytes", "durationSeconds"],
  BookQuery: ["sort", "pagination", "q", "collapseSeries"],
};
const integerFields = new Set(["id", "sessionId", "libraryId", "fileId", "page", "size", "total", "bookCount"]);
const declarations = new Map();

function swiftType(type, name, field) {
  if (type.isUnion()) {
    const values = type.types.filter((part) => !(part.flags & (ts.TypeFlags.Null | ts.TypeFlags.Undefined)));
    const optional = values.length !== type.types.length;
    let value;
    if (values.every((part) => part.flags & ts.TypeFlags.StringLike)) value = "String";
    else if (values.every((part) => part.flags & ts.TypeFlags.BooleanLike)) value = "Bool";
    else if (values.length === 1) value = swiftType(values[0], name, field);
    else throw new Error(`Unsupported union in ${name}: ${checker.typeToString(type)}`);
    return value + (optional ? "?" : "");
  }
  if (type.flags & ts.TypeFlags.StringLike) return "String";
  if (type.flags & ts.TypeFlags.NumberLike) return integerFields.has(field) ? "Int" : "Double";
  if (type.flags & ts.TypeFlags.BooleanLike) return "Bool";
  if (checker.isArrayType(type)) return `[${swiftType(checker.getTypeArguments(type)[0], `${name}Item`, field)}]`;
  if (type.flags & ts.TypeFlags.Object || type.isIntersection()) {
    const symbolName = type.aliasSymbol?.name ?? type.symbol?.name;
    const modelName = symbols.has(symbolName) ? symbolName : name;
    generateModel(modelName, type);
    return modelName;
  }
  throw new Error(`Unsupported type in ${name}: ${checker.typeToString(type)}`);
}

function generateModel(name, type) {
  if (declarations.has(name)) return;
  declarations.set(name, "");
  const properties = checker.getPropertiesOfType(type);
  const selected = projections[name] ?? properties.map((property) => property.name);
  const fields = selected.map((field) => {
    const property = properties.find((candidate) => candidate.name === field);
    if (!property) throw new Error(`${name}.${field} no longer exists in the shared contract`);
    const propertyType = checker.getTypeOfSymbolAtLocation(property, property.valueDeclaration ?? property.declarations[0]);
    let target = swiftType(propertyType, `${name}${field[0].toUpperCase()}${field.slice(1)}`, field);
    if (property.flags & ts.SymbolFlags.Optional && !target.endsWith("?")) target += "?";
    return `    var \`${field}\`: ${target}`;
  });
  const identifiable = selected.includes("id") ? ", Identifiable" : "";
  declarations.set(name, `struct ${name}: Codable, Sendable, Equatable${identifiable} {\n${fields.join("\n")}\n}`);
}

for (const name of [
  "NativeAuthResponse",
  "NativeCredentials",
  "LoginRequest",
  "RefreshRequest",
  "ChangePasswordRequest",
  "OidcStateResponse",
  "OidcCallbackRequest",
  "LoginOptionsResponse",
  "Library",
  "BooksPage",
  "BookDetail",
  "BookQuery",
]) {
  const symbol = symbols.get(name);
  if (!symbol) throw new Error(`Missing shared contract: ${name}`);
  generateModel(name, checker.getDeclaredTypeOfSymbol(symbol));
}

const permission = symbols.get("Permission");
const permissionType = checker.getDeclaredTypeOfSymbol(permission);
const cases = permissionType.types.map((type) => {
  if (typeof type.value !== "string") throw new Error("Permission must remain a string enum");
  const name = type.symbol.name;
  return `    case \`${name[0].toLowerCase()}${name.slice(1)}\` = ${JSON.stringify(type.value)}`;
});
const output = `// Generated by scripts/ipad/generate-contracts.mjs from @bookorbit/types.\n// Regenerate after shared contract changes.\nimport Foundation\n\n${[...declarations.values()].join("\n\n")}\n\nenum Permission: String, Sendable {\n${cases.join("\n")}\n}\n`;
const destination = path.join(root, "ipad/Sources/Contracts/GeneratedContracts.swift");
if (process.argv.includes("--check")) {
  if ((await readFile(destination, "utf8")) !== output) throw new Error("Swift contracts are stale. Run pnpm ipad:contracts.");
} else {
  await mkdir(path.dirname(destination), { recursive: true });
  await writeFile(destination, output);
}
