import { createRequire } from "node:module";
import { readFile, writeFile, mkdir } from "node:fs/promises";
import { fileURLToPath } from "node:url";
import path from "node:path";

const root = fileURLToPath(new URL("../../", import.meta.url));
const require = createRequire(path.join(root, "server/package.json"));
const ts = require("typescript");
const entries = [
  "annotation",
  "audiobook",
  "auth",
  "author",
  "book",
  "book-selection",
  "bookmark",
  "collection",
  "comic",
  "custom-metadata",
  "dashboard",
  "epub",
  "file-delivery",
  "library",
  "metadata-fetch",
  "metadata-lock",
  "permissions",
  "query",
  "reader-settings",
  "reader-themes",
  "series",
  "smart-scope",
  "table-layout",
  "tts",
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
  CreateAnnotationPayload: ["cfi", "bookFileId", "text", "color", "style", "note", "chapterTitle"],
  AnnotationItem: ["id", "bookId", "cfi", "jumpFileId", "text", "color", "style", "note", "chapterTitle", "positionStatus"],
  AnnotationListResponse: ["items", "total", "page", "pageSize"],
  AuthUser: ["id", "username", "name", "active", "isSuperuser", "isDefaultPassword", "permissions"],
  UserDashboardSettingsResponse: ["settings"],
  UserReaderSettingsResponse: ["settings", "permissions"],
  UserSettings: ["dashboardConfig", "dashboardShelfConfig", "syncReaderPreferences", "timezone"],
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
    "customMetadata",
    "seriesName",
    "seriesId",
    "seriesIndex",
    "seriesMemberships",
    "rating",
    "readStatus",
    "personalNote",
    "personalNoteUpdatedAt",
    "communityRatings",
    "providerIds",
    "hardcoverEditionId",
    "audioMetadata",
    "comicMetadata",
    "files",
    "lockedFields",
    "coverMedia",
    "covers",
    "coverVersion",
  ],
  BookDetailFile: ["id", "format", "role", "filename", "sizeBytes", "durationSeconds"],
  BookQuery: ["filter", "sort", "pagination", "q", "collapseSeries", "randomSeed"],
  SmartScope: ["id", "userId", "mediaType", "name", "icon", "filter", "defaultSort", "isPublic", "syncToKobo", "koboSyncEnabled", "isOwner"],
  Collection: ["id", "userId", "mediaType", "name", "isPublic", "isOwner", "bookCount"],
  BookIdsSelection: ["bookIds"],
  EpubBookInfo: ["containerPath", "rootPath", "spine", "manifest", "optionalFiles", "toc"],
};
const aliases = { Collection: "BookCollection", SmartScope: "BookSmartScope" };
const integerFields = new Set([
  "id",
  "bookIds",
  "userId",
  "sessionId",
  "libraryId",
  "libraryIds",
  "smartScopeId",
  "fileId",
  "bookFileId",
  "sourceFileId",
  "overlayFileId",
  "audioRevision",
  "sourceAudioRevision",
  "sourcePositionMs",
  "jumpFileId",
  "pageSize",
  "fieldId",
  "seriesId",
  "displayOrder",
  "ratingCount",
  "communityRatingCount",
  "durationSeconds",
  "startMs",
  "durationMs",
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
  "randomSeed",
  "rotation",
  "spreadGap",
  "schemaVersion",
  "sequence",
  "positionMs",
  "endMs",
  "assetOffsetMs",
  "chapterIndex",
  "sectionIndex",
  "mediaOverlaySectionIndex",
  "sectionClipIndex",
  "nextSectionIndex",
  "previousSectionIndex",
  "totalClips",
  "nextCursor",
  "index",
  "totalDurationMs",
  "baseRevision",
  "revision",
  "BookmarkResponsePageNumber",
  "CreateFixedPageBookmarkPayloadPageNumber",
  "BookmarksPageNextCursor",
]);
const declarations = new Map();
const patchRequests = new Set([
  "BookMetadataUpdatePayload",
  "AudioMetadataUpdatePayload",
  "ComicMetadataUpdatePayload",
  "BookSeriesMembershipUpdatePayload",
  "SetBookReadingStatusPayload",
  "UpdateBookPersonalNotePayload",
  "UpdateAudiobookBookmark",
]);
const requestModels = new Set([
  ...patchRequests,
  "BookMetadataAndLocksUpdatePayload",
  "SaveFileProgressPayload",
  "PutAudiobookPlaybackState",
  "CreateAnnotationPayload",
]);
const nullableResponses = new Set([
  "BookFileMetadataResponse",
  "BookFileComicMetadata",
  "EpubReaderSettingsPatch",
  "EpubReaderDefaultsResponseEpub",
  "EpubReaderPreferenceResponseSettings",
  "BookMetadataRefreshPreviewFields",
  "BookMetadataRefreshPreviewFieldsAudioMetadata",
]);

function generateValueUnion(type, name) {
  if (declarations.has(name)) return name;
  const cases = type.types.map((part) => {
    if (part.flags & ts.TypeFlags.StringLike) return { name: "string", type: "String" };
    if (part.flags & ts.TypeFlags.NumberLike) return { name: "number", type: "Double" };
    if (checker.isArrayType(part)) {
      const item = checker.getTypeArguments(part)[0];
      if (item.flags & ts.TypeFlags.StringLike) return { name: "strings", type: "[String]" };
      if (item.flags & ts.TypeFlags.NumberLike) return { name: "numbers", type: "[Double]" };
    }
    throw new Error(`Unsupported value union in ${name}: ${checker.typeToString(type)}`);
  });
  const caseOrder = ["string", "number", "numbers", "strings"];
  cases.sort((left, right) => caseOrder.indexOf(left.name) - caseOrder.indexOf(right.name));
  if (new Set(cases.map((value) => value.name)).size !== cases.length) throw new Error(`Ambiguous union in ${name}`);
  declarations.set(
    name,
    `enum ${name}: Codable, Sendable, Equatable {\n${cases.map((value) => `    case ${value.name}(${value.type})`).join("\n")}\n\n    init(from decoder: any Decoder) throws {\n        let container = try decoder.singleValueContainer()\n${cases.map((value) => `        if let value = try? container.decode(${value.type}.self) { self = .${value.name}(value); return }`).join("\n")}\n        throw DecodingError.typeMismatch(Self.self, .init(codingPath: decoder.codingPath, debugDescription: "Invalid filter value"))\n    }\n\n    func encode(to encoder: any Encoder) throws {\n        var container = encoder.singleValueContainer()\n        switch self {\n${cases.map((value) => `        case .${value.name}(let value): try container.encode(value)`).join("\n")}\n        }\n    }\n}`,
  );
  return name;
}

function generateRule() {
  if (declarations.has("Rule")) return;
  declarations.set("Rule", "");
  const variants = checker.getDeclaredTypeOfSymbol(symbols.get("Rule")).types;
  const fields = new Map();
  for (const variant of variants) {
    const discriminator = checker.getTypeOfPropertyOfType(variant, "type");
    if (!(discriminator?.flags & ts.TypeFlags.StringLiteral) || discriminator.value !== "rule") throw new Error("Rule discriminator changed");
    for (const property of checker.getPropertiesOfType(variant)) {
      const declaration = property.valueDeclaration ?? property.declarations[0];
      const type = checker.getTypeOfSymbolAtLocation(property, declaration);
      const target = swiftType(type, `Rule${property.name[0].toUpperCase()}${property.name.slice(1)}`, property.name);
      const existing = fields.get(property.name);
      if (existing && existing.target !== target) throw new Error(`Rule variant changed: ${property.name}`);
      fields.set(property.name, { target, count: (existing?.count ?? 0) + 1 });
    }
  }
  declarations.set(
    "Rule",
    `struct Rule: Codable, Sendable, Equatable {\n${[...fields].map(([field, value]) => `    var \`${field}\`: ${value.target}${value.count !== variants.length && !value.target.endsWith("?") ? "?" : ""}`).join("\n")}\n}`,
  );
}

function generateRuleNode() {
  if (declarations.has("FilterNode")) return "FilterNode";
  declarations.set("FilterNode", "");
  generateRule();
  const group = checker.getDeclaredTypeOfSymbol(symbols.get("GroupRule"));
  const discriminator = checker.getTypeOfPropertyOfType(group, "type");
  const join = checker.getTypeOfPropertyOfType(group, "join");
  if (discriminator?.value !== "group" || !join?.isUnion() || join.types.some((part) => !["AND", "OR"].includes(part.value)))
    throw new Error("Group rule vocabulary changed");
  generateModel("GroupRule", group);
  declarations.set(
    "FilterNode",
    `indirect enum FilterNode: Codable, Sendable, Equatable {\n    case rule(Rule)\n    case group(GroupRule)\n\n    private enum CodingKeys: String, CodingKey { case type }\n\n    init(from decoder: any Decoder) throws {\n        let container = try decoder.container(keyedBy: CodingKeys.self)\n        switch try container.decode(String.self, forKey: .type) {\n        case "rule": self = .rule(try Rule(from: decoder))\n        case "group": self = .group(try GroupRule(from: decoder))\n        default: throw DecodingError.dataCorruptedError(forKey: .type, in: container, debugDescription: "Invalid filter node")\n        }\n    }\n\n    func encode(to encoder: any Encoder) throws {\n        switch self {\n        case .rule(let value): try value.encode(to: encoder)\n        case .group(let value): try value.encode(to: encoder)\n        }\n    }\n}`,
  );
  return "FilterNode";
}

function swiftType(type, name, field) {
  if (type.aliasSymbol?.name === "CustomMetadataPrimitiveValue") {
    const expected = ts.TypeFlags.String | ts.TypeFlags.Number | ts.TypeFlags.BooleanLiteral | ts.TypeFlags.Null;
    if (!type.isUnion() || type.types.some((part) => !(part.flags & expected))) throw new Error("Custom metadata primitive contract changed");
    declarations.set(
      "CustomMetadataPrimitiveValue",
      `enum CustomMetadataPrimitiveValue: Codable, Sendable, Equatable {
    case string(String), number(Double), boolean(Bool), null

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .boolean(value) }
        else if let value = try? container.decode(Double.self) { self = .number(value) }
        else { self = .string(try container.decode(String.self)) }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .boolean(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }
}`,
    );
    return "CustomMetadataPrimitiveValue";
  }
  if (type.aliasSymbol?.name === "CoverMedium") return "CoverMedium";
  if (field === "coverMedia" && checker.isArrayType(type)) return "[CoverMedium]";
  if (type.isUnion()) {
    const values = type.types.filter((part) => !(part.flags & (ts.TypeFlags.Null | ts.TypeFlags.Undefined)));
    const optional = values.length !== type.types.length;
    let value;
    if (values.every((part) => part.flags & ts.TypeFlags.StringLike)) value = "String";
    else if (values.every((part) => part.flags & ts.TypeFlags.NumberLike))
      value =
        name.startsWith("EpubMediaOverlay") && field === "durationSeconds"
          ? "Double"
          : integerFields.has(field) || integerFields.has(name)
            ? "Int"
            : "Double";
    else if (values.every((part) => part.flags & ts.TypeFlags.BooleanLike)) value = "Bool";
    else if (values.length === 1) value = swiftType(values[0], name, field);
    else if (name === "GroupRuleRulesItem") value = generateRuleNode();
    else if (type.aliasSymbol?.name === "RuleValue" || name === "RuleValue" || name === "RuleValueTo" || name === "CoverSearchResultUrl") {
      value = generateValueUnion({ types: values }, name);
    } else throw new Error(`Unsupported union in ${name}: ${checker.typeToString(type)}`);
    return value + (optional ? "?" : "");
  }
  if (type.flags & ts.TypeFlags.StringLike) return "String";
  if (type.flags & ts.TypeFlags.NumberLike) return integerFields.has(field) || integerFields.has(name) ? "Int" : "Double";
  if (type.flags & ts.TypeFlags.BooleanLike) return "Bool";
  if (checker.isArrayType(type)) return `[${swiftType(checker.getTypeArguments(type)[0], `${name}Item`, field)}]`;
  const indexed = checker.getIndexTypeOfType(type, ts.IndexKind.String);
  if (indexed) return `[String: ${swiftType(indexed, `${name}Value`, field)}]`;
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
    if (field === "filter" && ["SmartScope", "CreateSmartScopePayload", "UpdateSmartScopePayload"].includes(name)) {
      const filter = checker.getDeclaredTypeOfSymbol(symbols.get("SmartScopeFilter"));
      if (!filter.isUnion() || !filter.types.some((part) => part.aliasSymbol?.name === "GroupRule"))
        throw new Error("Book scope filter contract changed");
      generateModel("GroupRule", checker.getDeclaredTypeOfSymbol(symbols.get("GroupRule")));
      target = "GroupRule?";
    } else if (canonical && requestModels.has(canonical.name)) {
      generateModel(canonical.name, checker.getDeclaredTypeOfSymbol(canonical));
      target = canonical.name;
    } else {
      target = swiftType(propertyType, `${name}${field[0].toUpperCase()}${field.slice(1)}`, field);
    }
    if (
      (patchRequests.has(name) || nullableResponses.has(name)) &&
      propertyType.isUnion() &&
      propertyType.types.some((part) => part.flags & ts.TypeFlags.Null)
    ) {
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
  "CreateAnnotationPayload",
  "AnnotationListResponse",
  "AudiobookManifest",
  "AudiobookPlaybackState",
  "AudiobookBookmark",
  "AudiobookBookmarksPage",
  "CreateAudiobookBookmark",
  "UpdateAudiobookBookmark",
  "PutAudiobookPlaybackState",
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
  "BookContinuationQuery",
  "BookContinuationResponse",
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
  "EpubMediaOverlayClipsPage",
  "ComicPageCountResponse",
  "AuthorsPage",
  "AuthorDetail",
  "AuthorBooksPage",
  "SeriesPage",
  "SeriesBooksPage",
  "SeriesNextBookResponse",
  "DashboardScrollerBatchRequest",
  "DashboardScrollerBatchResponse",
  "DashboardShelfConfig",
  "SmartScopesPage",
  "SmartScopePageQuery",
  "CreateSmartScopePayload",
  "UpdateSmartScopePayload",
  "SetSmartScopeKoboSyncPayload",
  "SavedView",
  "MetadataCandidate",
  "BookFileMetadataResponse",
  "BookMetadataRefreshPreviewResponse",
  "MetadataProviderInfo",
  "MetadataProviderSearchStatus",
  "UploadCoverFromUrlPayload",
  "CoverSearchResult",
  "PdfReaderSettings",
  "CbxReaderSettings",
  "PdfReaderSettingsPatch",
  "CbxReaderSettingsPatch",
  "PdfReaderPreferenceResponse",
  "CbxReaderPreferenceResponse",
  "FixedReaderDefaultsResponse",
  "EpubReaderSettings",
  "EpubReaderSettingsPatch",
  "EpubReaderDefaultsResponse",
  "EpubReaderDefaultsPatchBody",
  "EpubReaderPreferenceResponse",
  "EpubReaderSettingsBody",
  "EpubReaderPreferencePatchBody",
  "AudioReaderSettings",
  "AudioReaderDefaultsResponse",
  "AudioReaderDefaultsPatchBody",
  "PdfReaderPreferencePatchBody",
  "CbxReaderPreferencePatchBody",
  "PdfReaderDefaultsPatchBody",
  "CbxReaderDefaultsPatchBody",
  "BookmarkResponse",
  "BookmarksPage",
  "CreateFixedPageBookmarkPayload",
  "CreateEpubBookmarkPayload",
  "SetBookReadingStatusPayload",
  "UpdateBookPersonalNotePayload",
  "TtsPosition",
  "TtsUserPreferences",
  "TtsEffectivePreferences",
  "TtsSpeedPreferencesPatch",
  "TtsPreferencesPatch",
  "TtsVoicePreviewRequest",
  "TtsProviderInfo",
  "TtsVoice",
  "TtsSynthesisRequest",
  "TtsCaptionedSpeech",
  "NativeTtsVoiceSettings",
]) {
  const symbol = symbols.get(name);
  if (!symbol) throw new Error(`Missing shared contract: ${name}`);
  generateModel(name, checker.getDeclaredTypeOfSymbol(symbol));
}

generateModel("UserDashboardSettingsResponse", checker.getDeclaredTypeOfSymbol(symbols.get("AuthUser")));
generateModel("UserReaderSettingsResponse", checker.getDeclaredTypeOfSymbol(symbols.get("AuthUser")));

for (const [model, constant] of [
  ["EpubReaderSettings", "EPUB_READER_DEFAULTS"],
  ["AudioReaderSettings", "AUDIO_READER_DEFAULTS"],
  ["PdfReaderSettings", "PDF_READER_DEFAULTS"],
  ["CbxReaderSettings", "CBX_READER_DEFAULTS"],
]) {
  const initializer = symbols.get(constant).valueDeclaration.initializer;
  if (!ts.isObjectLiteralExpression(initializer)) throw new Error(`${constant} must remain a literal object`);
  const values = initializer.properties.map((property) => {
    if (!ts.isPropertyAssignment(property)) throw new Error(`${constant} property changed`);
    const expression = property.initializer;
    let value;
    if (ts.isStringLiteral(expression)) value = JSON.stringify(expression.text);
    else if (ts.isNumericLiteral(expression)) value = expression.text;
    else if (expression.kind === ts.SyntaxKind.TrueKeyword) value = "true";
    else if (expression.kind === ts.SyntaxKind.FalseKeyword) value = "false";
    else if (expression.kind === ts.SyntaxKind.NullKeyword) value = "nil";
    else {
      const literal = checker.getTypeAtLocation(expression).value;
      if (typeof literal !== "number" || !Number.isFinite(literal)) throw new Error(`${constant} value is not a literal`);
      value = String(literal);
    }
    return `${property.name.getText()}: ${value}`;
  });
  declarations.set(`${model}Defaults`, `extension ${model} {\n    static var readerDefault: Self { Self(${values.join(", ")}) }\n}`);
}

const themeSource = symbols.get("EPUB_READER_THEMES").valueDeclaration.initializer;
const literalJSON = (node) => {
  if (ts.isStringLiteral(node)) return node.text;
  if (ts.isArrayLiteralExpression(node)) return node.elements.map(literalJSON);
  if (ts.isObjectLiteralExpression(node))
    return Object.fromEntries(
      node.properties.map((property) => {
        if (!ts.isPropertyAssignment(property)) throw new Error("Reader themes must remain literal objects");
        return [property.name.getText(), literalJSON(property.initializer)];
      }),
    );
  throw new Error("Reader themes must remain literal strings");
};
const readerThemes = literalJSON(themeSource);
const bookMimeTypes = literalJSON(symbols.get("BOOK_FILE_MIME_TYPES").valueDeclaration.initializer);
const readerFormats = symbols.get("READER_OPENABLE_FORMATS").valueDeclaration.initializer.arguments[0].elements.map((item) => item.text);
const formatGroups = literalJSON(symbols.get("FORMAT_TO_GROUP").valueDeclaration.initializer);
const ebookFormats = readerFormats.filter((format) => formatGroups[format] === "epub");
declarations.set(
  "NativeEbookVocabulary",
  `enum NativeEbookVocabulary {\n  static let mimeTypes: [String: String] = [\n${ebookFormats.map((format) => `    ${JSON.stringify(format)}: ${JSON.stringify(bookMimeTypes[format])},`).join("\n")}\n  ]\n}`,
);
declarations.set(
  "EPUBThemeVocabulary",
  `enum EPUBThemeVocabulary {\n    static let names: [String] = [${readerThemes.map((theme) => JSON.stringify(theme.name)).join(", ")}]\n}`,
);
const themeDestination = path.join(root, "ipad/EPUBReader/themes.js");
const prettier = require("prettier");
const themeOutput = await prettier.format(`// Generated from @bookorbit/types.\nexport const themes = ${JSON.stringify(readerThemes, null, 2)};\n`, {
  ...(await prettier.resolveConfig(themeDestination)),
  filepath: themeDestination,
});
if (process.argv.includes("--check")) {
  if ((await readFile(themeDestination, "utf8")) !== themeOutput) throw new Error("Native reader themes are stale");
} else {
  await mkdir(path.dirname(themeDestination), { recursive: true });
  await writeFile(themeDestination, themeOutput);
}

const readerLayoutLimits = ["CBX_SPREAD_GAP_MIN", "CBX_SPREAD_GAP_MAX"].map((name) => {
  const value = checker.getTypeAtLocation(symbols.get(name).valueDeclaration.initializer).value;
  if (!Number.isInteger(value)) throw new Error(`${name} must remain an integer literal`);
  return value;
});
const widePageRatio = checker.getTypeAtLocation(symbols.get("CBX_WIDE_PAGE_RATIO_THRESHOLD").valueDeclaration.initializer).value;
if (typeof widePageRatio !== "number" || !Number.isFinite(widePageRatio) || widePageRatio <= 1)
  throw new Error("Wide page threshold must remain a finite literal greater than one");

const readingStatuses = checker.getDeclaredTypeOfSymbol(symbols.get("ReadStatus"));
const audioSchema = checker.getTypeAtLocation(symbols.get("AUDIOBOOK_MANIFEST_SCHEMA").valueDeclaration.initializer).value;
const audioVersion = checker.getTypeAtLocation(symbols.get("AUDIOBOOK_MANIFEST_VERSION").valueDeclaration.initializer).value;
if (typeof audioSchema !== "string" || !Number.isInteger(audioVersion)) throw new Error("Audiobook manifest vocabulary changed");
declarations.set(
  "AudiobookVocabulary",
  `enum AudiobookVocabulary {\n    static let schema = ${JSON.stringify(audioSchema)}\n    static let version = ${audioVersion}\n}`,
);
if (!readingStatuses.isUnion() || !readingStatuses.types.every((part) => part.flags & ts.TypeFlags.StringLiteral))
  throw new Error("Reading status vocabulary changed");
const personalNoteLimit = checker.getTypeAtLocation(symbols.get("PERSONAL_NOTE_MAX_LENGTH").valueDeclaration.initializer).value;
if (!Number.isInteger(personalNoteLimit)) throw new Error("Personal note limit must remain an integer literal");
declarations.set(
  "BookReadingVocabulary",
  `enum BookReadingVocabulary {\n    static let statuses: [String] = [${readingStatuses.types.map((part) => JSON.stringify(part.value)).join(", ")}]\n    static let noteMaximum = ${personalNoteLimit}\n}`,
);
const annotationCFILimit = checker.getTypeAtLocation(symbols.get("ANNOTATION_CFI_MAX_LENGTH").valueDeclaration.initializer).value;
if (!Number.isInteger(annotationCFILimit)) throw new Error("Annotation CFI limit must remain an integer literal");
declarations.set("AnnotationVocabulary", `enum AnnotationVocabulary {\n    static let cfiMaximum = ${annotationCFILimit}\n}`);
declarations.set(
  "ReaderLayoutBounds",
  `enum ReaderLayoutBounds {\n    static let spreadGapMinimum = ${readerLayoutLimits[0]}\n    static let spreadGapMaximum = ${readerLayoutLimits[1]}\n    static let widePageRatio = ${widePageRatio}\n}`,
);

const metadataLocks = symbols.get("BOOK_METADATA_LOCK_FIELDS").valueDeclaration.initializer;
const coverProviders = symbols.get("COVER_SEARCH_PROVIDERS").valueDeclaration.initializer;
if (!ts.isAsExpression(coverProviders) || !ts.isArrayLiteralExpression(coverProviders.expression)) throw new Error("Cover providers changed");
if (!ts.isAsExpression(metadataLocks) || !ts.isArrayLiteralExpression(metadataLocks.expression)) throw new Error("Metadata lock vocabulary changed");
const metadataProviders = checker.getDeclaredTypeOfSymbol(symbols.get("MetadataProviderKey"));
if (!metadataProviders.isUnion() || !metadataProviders.types.every((part) => part.flags & ts.TypeFlags.StringLiteral))
  throw new Error("Metadata provider vocabulary changed");
const statusEvent = symbols.get("METADATA_PROVIDER_STATUS_EVENT").valueDeclaration.initializer;
if (!ts.isStringLiteral(statusEvent)) throw new Error("Metadata status event changed");
declarations.set(
  "MetadataVocabulary",
  `enum MetadataVocabulary {
    static let coverProviders: [String] = [${coverProviders.expression.elements.map((element) => JSON.stringify(element.text)).join(", ")}]
    static let lockFields: [String] = [${metadataLocks.expression.elements.map((element) => JSON.stringify(element.text)).join(", ")}]
    static let providers: [String] = [${metadataProviders.types.map((part) => JSON.stringify(part.value)).join(", ")}]
    static let statusEvent = ${JSON.stringify(statusEvent.text)}
}`,
);

const idFieldType = checker.getTypeOfSymbolAtLocation(
  symbols.get("METADATA_PROVIDER_ID_FIELDS"),
  symbols.get("METADATA_PROVIDER_ID_FIELDS").valueDeclaration,
);
const idFields = checker
  .getPropertiesOfType(idFieldType)
  .map((property) => [property.name, checker.getTypeOfSymbolAtLocation(property, property.valueDeclaration).value]);
const limitType = checker.getTypeOfSymbolAtLocation(symbols.get("PROVIDER_ID_MAX_LENGTHS"), symbols.get("PROVIDER_ID_MAX_LENGTHS").valueDeclaration);
const limitFields = checker
  .getPropertiesOfType(limitType)
  .map((property) => [property.name, checker.getTypeOfSymbolAtLocation(property, property.valueDeclaration).value]);
if (idFields.some(([, value]) => typeof value !== "string") || limitFields.some(([, value]) => !Number.isInteger(value)))
  throw new Error("Provider ID mapping changed");
declarations.set(
  "MetadataProviderField",
  `@MainActor struct MetadataProviderField: Identifiable {
    let id: String
    let provider: String
    let maximum: Int
    let read: KeyPath<BookDetail, String?>
    let write: WritableKeyPath<BookMetadataUpdatePayload, FieldUpdate<String>?>
    let preview: KeyPath<BookMetadataRefreshPreviewFields, FieldUpdate<String>?>
    let file: KeyPath<BookFileMetadataResponse, FieldUpdate<String>?>

    static let byProvider: [String: String] = [${idFields.map(([provider, field]) => `${JSON.stringify(provider)}: ${JSON.stringify(field)}`).join(", ")}]

    static let fields: [MetadataProviderField] = [
${limitFields
  .map(([field, limit]) => {
    const provider = idFields.find(([, value]) => value === field)?.[0];
    if (!provider && field !== "hardcoverEditionId") throw new Error(`Unmapped provider field ${field}`);
    return `        .init(id: ${JSON.stringify(field)}, provider: ${JSON.stringify(provider ?? "hardcover")}, maximum: ${limit}, read: \\BookDetail.${field === "hardcoverEditionId" ? field : `providerIds.${provider}`}, write: \\BookMetadataUpdatePayload.${field}, preview: \\BookMetadataRefreshPreviewFields.${field}, file: \\BookFileMetadataResponse.${field}),`;
  })
  .join("\n")}
    ]
}`,
);

const operatorsDeclaration = symbols.get("FIELD_OPERATORS").valueDeclaration.initializer;
if (!ts.isObjectLiteralExpression(operatorsDeclaration)) throw new Error("Filter vocabulary must remain a literal map");
const operatorMap = operatorsDeclaration.properties.map((property) => {
  if (!ts.isPropertyAssignment(property) || !ts.isArrayLiteralExpression(property.initializer)) throw new Error("Filter vocabulary changed");
  return `        ${JSON.stringify(property.name.getText())}: [${property.initializer.elements
    .map((value) => {
      if (!ts.isStringLiteral(value)) throw new Error("Filter operators must remain literal strings");
      return JSON.stringify(value.text);
    })
    .join(", ")}],`;
});
const filterChoices = ["CommunityRatingProvider", "ReadStatus", "BookFormat"].map((name) => {
  const type = checker.getDeclaredTypeOfSymbol(symbols.get(name));
  if (!type.isUnion() || !type.types.every((part) => part.flags & ts.TypeFlags.StringLiteral)) throw new Error(`${name} vocabulary changed`);
  return `    static let ${name === "CommunityRatingProvider" ? "ratingProviders" : name === "ReadStatus" ? "readStatuses" : "formats"}: [String] = [${type.types.map((part) => JSON.stringify(part.value)).join(", ")}]`;
});
declarations.set(
  "FilterVocabulary",
  `enum FilterVocabulary {\n    static let operators: [String: [String]] = [\n${operatorMap.join("\n")}\n    ]\n${filterChoices.join("\n")}\n}`,
);

const sortDeclaration = symbols.get("SORT_FIELDS").valueDeclaration.initializer;
if (!ts.isArrayLiteralExpression(sortDeclaration) || !sortDeclaration.elements.every(ts.isStringLiteral)) throw new Error("Sort vocabulary changed");
declarations.set(
  "SortVocabulary",
  `enum SortVocabulary {\n    static let fields: [String] = [${sortDeclaration.elements.map((value) => JSON.stringify(value.text)).join(", ")}]\n}`,
);

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
