// Prints the server's OpenAPI document, merged with overlay.json, without a database or a running
// server. Nest's preview mode registers every controller but never instantiates providers, so no
// connection is opened. Requires a prior `nest build` so dist/metadata.js carries the DTO schemas.
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');

const serverDir = path.resolve(process.argv[2] ?? path.join(__dirname, '../../../server'));
const overlayPath = path.join(__dirname, 'overlay.json');

process.env.JWT_SECRET ??= 'openapi-export-placeholder-secret';
process.env.APP_DATA_PATH ??= os.tmpdir();

const serverRequire = (id) => require(require.resolve(id, { paths: [serverDir] }));

async function exportDocument() {
  const { NestFactory } = serverRequire('@nestjs/core');
  const { FastifyAdapter } = serverRequire('@nestjs/platform-fastify');
  const { DocumentBuilder, SwaggerModule } = serverRequire('@nestjs/swagger');
  const { AppModule } = require(path.join(serverDir, 'dist/app.module.js'));
  const { normalizeSwaggerDocument } = require(path.join(serverDir, 'dist/swagger.js'));
  const metadata = require(path.join(serverDir, 'dist/metadata.js'));

  await SwaggerModule.loadPluginMetadata(metadata.default);
  const app = await NestFactory.create(AppModule, new FastifyAdapter(), { preview: true, logger: false, abortOnError: false });
  // Mirrors the prefix in server/src/main.ts.
  app.setGlobalPrefix('api/v1', { exclude: ['api/kobo/:deviceToken/(.*)', 'api/v3/(.*)', 'api/UserStorage/(.*)'] });
  const config = new DocumentBuilder()
    .setTitle('BookOrbit API')
    .setDescription('BookOrbit server API')
    .setVersion('exported')
    .addBearerAuth({ type: 'http', scheme: 'bearer', bearerFormat: 'JWT' }, 'bearer')
    .build();
  const document = normalizeSwaggerDocument(SwaggerModule.createDocument(app, config));
  await app.close();
  return document;
}

// Nest documents @All() routes with a `search` method, which OpenAPI 3.0 does not allow.
const OPENAPI_METHODS = new Set(['get', 'put', 'post', 'delete', 'options', 'head', 'patch', 'trace']);
const PATH_ITEM_FIELDS = new Set(['$ref', 'summary', 'description', 'servers', 'parameters']);

function dropNonStandardMethods(document) {
  for (const pathItem of Object.values(document.paths)) {
    for (const key of Object.keys(pathItem)) {
      if (!OPENAPI_METHODS.has(key) && !PATH_ITEM_FIELDS.has(key) && !key.startsWith('x-')) delete pathItem[key];
    }
  }
  return document;
}

// The server does not declare response schemas (its services return plain TypeScript types), so
// the overlay supplies the shapes the iPad App decodes. Operations are matched by operationId.
function applyOverlay(document, overlay) {
  document.components ??= {};
  document.components.schemas ??= {};
  for (const [name, schema] of Object.entries(overlay.schemas ?? {})) {
    if (document.components.schemas[name]) {
      throw new Error(`overlay schema ${name} now exists on the server; remove it from overlay.json`);
    }
    document.components.schemas[name] = schema;
  }

  const operations = new Map();
  for (const pathItem of Object.values(document.paths)) {
    for (const operation of Object.values(pathItem)) {
      if (operation && typeof operation === 'object' && operation.operationId) operations.set(operation.operationId, operation);
    }
  }

  for (const [operationId, patch] of Object.entries(overlay.operations ?? {})) {
    const operation = operations.get(operationId);
    if (!operation) throw new Error(`overlay operation ${operationId} does not exist on the server`);
    if (patch.requestBody) operation.requestBody = patch.requestBody;
    for (const [status, response] of Object.entries(patch.responses ?? {})) {
      operation.responses[status] = response;
    }
  }
  return document;
}

exportDocument()
  .then((document) => {
    const overlay = JSON.parse(fs.readFileSync(overlayPath, 'utf8'));
    process.stdout.write(`${JSON.stringify(applyOverlay(dropNonStandardMethods(document), overlay), null, 2)}\n`);
    process.exit(0);
  })
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });
