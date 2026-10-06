import { createRequire } from "node:module";
import { readFile, writeFile, mkdir } from "node:fs/promises";
import { fileURLToPath } from "node:url";
import path from "node:path";

const root = fileURLToPath(new URL("../../", import.meta.url));
const require = createRequire(path.join(root, "server/package.json"));
const ts = require("typescript");
const entries = [
  "auth",
  "author",
  "book",
  "book-selection",
  "collection",
  "comic",
  "dashboard",
  "epub",
  "library",
  "permissions",
  "query",
  "series",
].map((name) => path.join(root, `packages/types/src/${name}.ts`));
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
  UserDashboardSettingsResponse: ["settings"],
  UserSettings: ["dashboardConfig", "dashboardShelfConfig"],
  Library: ["id", "type", "accessLevel", "name", "bookCount"],
  BookCard: ["id", "title", "authors", "files", "hasCover", "coverVersion", "readingProgress", "seriesName"],
  BookDetail: [
    "id",
    "libraryId",
    "libraryName",
    "title",
    "subtitle",
    "description",
    "publisher",
    "publishedDate",
    "publishedYear",
    "language",
    "pageCount",
    "isbn10",
    "isbn13",
    "authors",
    "genres",
    "tags",
    "files",
    "lockedFields",
    "coverMedia",
    "covers",
    "coverVersion",
  ],
  BookDetailFile: ["id", "format", "role", "filename", "sizeBytes", "durationSeconds"],
  BookQuery: ["sort", "pagination", "q", "collapseSeries"],
  Collection: ["id", "userId", "mediaType", "name", "isPublic", "isOwner", "bookCount"],
  BookIdsSelection: ["bookIds"],
  EpubBookInfo: ["containerPath", "rootPath", "spine", "manifest", "optionalFiles"],
};
const aliases = { Collection: "BookCollection" };
const integerFields = new Set([
  "id",
  "bookIds",
  "userId",
  "sessionId",
  "libraryId",
  "libraryIds",
  "smartScopeId",
  "fileId",
  "page",
  "size",
  "total",
  "bookCount",
  "bookTotal",
  "bookId",
  "coverBookId",
  "coverBookIds",
  "nextBookId",
  "publishedYear",
  "pageCount",
  "readCount",
  "readingCount",
  "expectedBookCount",
  "gapCount",
  "gaps",
  "possibleGaps",
  "all",
  "notStarted",
  "inProgress",
  "complete",
  "hasGaps",
  "birthYear",
  "deathYear",
  "width",
  "height",
]);
const declarations = new Map();
const patchRequests = new Set(["BookMetadataUpdatePayload"]);
const requestModels = new Set([...patchRequests, "BookMetadataAndLocksUpdatePayload", "SaveFileProgressPayload"]);

function swiftType(type, name, field) {
  if (type.aliasSymbol?.name === "CoverMedium") return "CoverMedium";
  if (field === "coverMedia" && checker.isArrayType(type)) return "[CoverMedium]";
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
    return aliases[modelName] ?? modelName;
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
    const declaration = property.valueDeclaration ?? property.declarations?.[0] ?? program.getSourceFile(entries[0]);
    const propertyType = checker.getTypeOfSymbolAtLocation(property, declaration);
    const reference =
      declaration.type && ts.isTypeReferenceNode(declaration.type) ? checker.getSymbolAtLocation(declaration.type.typeName) : undefined;
    const canonical = reference && reference.flags & ts.SymbolFlags.Alias ? checker.getAliasedSymbol(reference) : reference;
    let target;
    if (canonical && requestModels.has(canonical.name)) {
      generateModel(canonical.name, checker.getDeclaredTypeOfSymbol(canonical));
      target = canonical.name;
    } else {
      target = swiftType(propertyType, `${name}${field[0].toUpperCase()}${field.slice(1)}`, field);
    }
    if (patchRequests.has(name) && propertyType.isUnion() && propertyType.types.some((part) => part.flags & ts.TypeFlags.Null)) {
      target = `FieldUpdate<${target.replace(/\?$/, "")}>?`;
    }
    if (property.flags & ts.SymbolFlags.Optional && !target.endsWith("?")) target += "?";
    return `    var \`${field}\`: ${target}`;
  });
  const identifiable = selected.includes("id") ? ", Identifiable" : "";
  declarations.set(
    name,
    `struct ${aliases[name] ?? name}: ${requestModels.has(name) ? "Encodable" : "Codable"}, Sendable, Equatable${identifiable} {\n${fields.join("\n")}\n}`,
  );
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
  "CollectionsPage",
  "CollectionPageQuery",
  "CreateCollectionPayload",
  "BookIdsSelection",
  "BookMetadataUpdatePayload",
  "BookMetadataAndLocksUpdatePayload",
  "FileReadingProgress",
  "SaveFileProgressPayload",
  "EpubBookInfo",
  "ComicPageCountResponse",
  "AuthorsPage",
  "AuthorDetail",
  "AuthorBooksPage",
  "SeriesPage",
  "SeriesBooksPage",
  "DashboardScrollerBatchRequest",
  "DashboardScrollerBatchResponse",
  "DashboardShelfConfig",
]) {
  const symbol = symbols.get(name);
  if (!symbol) throw new Error(`Missing shared contract: ${name}`);
  generateModel(name, checker.getDeclaredTypeOfSymbol(symbol));
}

generateModel("UserDashboardSettingsResponse", checker.getDeclaredTypeOfSymbol(symbols.get("AuthUser")));

const permission = symbols.get("Permission");
const coverMedium = checker.getDeclaredTypeOfSymbol(symbols.get("CoverMedium"));
declarations.set(
  "CoverMedium",
  `enum CoverMedium: String, Codable, Sendable, CaseIterable, Identifiable {\n${coverMedium.types.map((type) => `    case ${type.value}`).join("\n")}\n    var id: String { rawValue }\n}`,
);
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
