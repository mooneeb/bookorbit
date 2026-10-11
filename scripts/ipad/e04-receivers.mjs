import { appendFile, mkdir } from "node:fs/promises";
import { createHash } from "node:crypto";
import { createServer } from "node:http";
import { join } from "node:path";
import { startEmailReceiver } from "./e04-smtp-receiver.mjs";

const providers = ["hardcover", "readwise", "storygraph"];
const modes = ["accept", "auth", "timeout", "timeout-after-receipt", "429", "500", "malformed", "search-error", "search-empty"];
const maximumRecords = 10_000;
const maximumRequests = 500;
export const E04_STORYGRAPH_BOOK_ID = "e0400000-0000-4000-8000-000000000101";

function json(response, status, body) {
  response.writeHead(status, { "Content-Type": "application/json" });
  response.end(body === undefined ? undefined : JSON.stringify(body));
}

async function readBody(request, maximumBytes = 16 * 1024 * 1024) {
  let body = "";
  for await (const chunk of request) {
    body += chunk;
    if (Buffer.byteLength(body) > maximumBytes) throw new Error("Receiver request exceeds its bounded size");
  }
  return body;
}

function edition(id = 501) {
  return {
    id,
    title: "Orbit fixture",
    pages: 100,
    isbn_10: null,
    isbn_13: null,
    audio_seconds: null,
    edition_format: "Paperback",
    publisher: { name: "BookOrbit fixture" },
    language: { language: "English", code2: "en" },
    reading_format_id: 1,
    image: { url: null },
    release_date: "2020-01-01",
    cached_image: { url: null },
  };
}

function bookHTML(book) {
  return `<!doctype html><html><head><meta name="csrf-token" content="e04-csrf"></head><body><h1>Orbit fixture</h1><button class="read-status-label">${book.status}</button><input name="read_status[book_num_of_pages]" value="100"><input name="read_status[progress_number]" value="${book.progress}"><input name="read_status[progress_type]" value="percentage"><p>Format: Paperback</p><p>3 editions</p></body></html>`;
}

export async function startE04Receivers({ httpPort = 0, smtpPort = 0, smtpHttpPort = 0, artifactDirectory } = {}) {
  const email = await startEmailReceiver({ smtpPort, httpPort: smtpHttpPort });
  const faults = new Map();
  const requests = [];
  const userBooks = new Map();
  const reads = new Map();
  const highlights = new Map();
  const storygraphBooks = new Map();
  const sockets = new Set();
  const nativeHandoffs = {};
  const nativeSubmissions = [];
  let requestCount = 0;
  let receiptCount = 0;
  let nextHighlightId = 1001;
  let nextUserBookId = 801;
  let nextReadId = 901;
  if (artifactDirectory) await mkdir(artifactDirectory, { recursive: true });

  async function record(provider, request, operation, accepted, payload) {
    const receipt = { id: ++requestCount, provider, method: request.method, path: request.url, operation, accepted, payload };
    if (accepted) receiptCount++;
    requests.push(receipt);
    if (requests.length > maximumRequests) requests.shift();
    if (artifactDirectory) await appendFile(join(artifactDirectory, "e04-provider-receipts.ndjson"), `${JSON.stringify(receipt)}\n`);
  }

  function getStorygraphBook(id, namespace) {
    const key = `${namespace}:${id}`;
    if (!storygraphBooks.has(key)) {
      if (storygraphBooks.size >= maximumRecords) throw new Error("Controlled provider record limit reached");
      storygraphBooks.set(key, { id, namespace, status: "to-read", progress: 0 });
    }
    return storygraphBooks.get(key);
  }

  function hardcover(body, namespace) {
    const operation = /(?:query|mutation)\s+(\w+)/.exec(body.query ?? "")?.[1] ?? "Me";
    const variables = body.variables ?? {};
    let data;
    if (operation === "Me" || /\bme\s*\{\s*username/.test(body.query ?? "")) {
      data = { me: [{ username: "fixture-hardcover" }] };
    } else if (/FindBook(?:ById|EditionsById|EditionMetricsById|EditionsForDisplay|EditionById)/.test(operation)) {
      data = {
        books: [{ id: variables.id, title: "Orbit fixture", editions: variables.editionId && variables.editionId !== 501 ? [] : [edition()] }],
      };
    } else if (operation === "SearchBooks") {
      data = { search: { error: null, ids: [102] } };
    } else if (operation === "FindBooksByIds") {
      data = { books: variables.ids.slice(0, 5).map((id) => ({ id, editions: [edition()] })) };
    } else if (operation === "InsertUserBook") {
      const object = variables.object;
      if (userBooks.size >= maximumRecords) throw new Error("Controlled provider record limit reached");
      const book = { id: nextUserBookId++, namespace, ...object };
      userBooks.set(book.id, book);
      data = { insert_user_book: { user_book: { id: book.id }, error: null } };
    } else if (operation === "FindUserBook") {
      data = {
        me: {
          user_books: [...userBooks.values()]
            .filter((book) => book.namespace === namespace && book.book_id === variables.bookId)
            .map(({ id }) => ({ id })),
        },
      };
    } else if (operation === "UpdateUserBook") {
      const book = userBooks.get(variables.id);
      if (!book || book.namespace !== namespace) return { operation, body: { errors: [{ message: "Unknown fixture user book" }] } };
      Object.assign(book, variables.object);
      data = { update_user_book: { user_book: { id: book.id }, error: null } };
    } else if (operation === "FindUserBookReads") {
      data = { user_book_reads: [...reads.values()].filter((read) => read.namespace === namespace && read.user_book_id === variables.userBookId) };
    } else if (operation === "InsertUserBookRead") {
      if (reads.size >= maximumRecords) throw new Error("Controlled provider record limit reached");
      if (userBooks.get(variables.userBookId)?.namespace !== namespace)
        return { operation, body: { errors: [{ message: "Unknown fixture user book" }] } };
      const read = { id: nextReadId++, namespace, user_book_id: variables.userBookId, ...variables.object };
      reads.set(read.id, read);
      data = { insert_user_book_read: { user_book_read: { id: read.id }, error: null } };
    } else if (operation === "UpdateUserBookRead") {
      const read = reads.get(variables.id);
      if (!read || read.namespace !== namespace) return { operation, body: { errors: [{ message: "Unknown fixture read" }] } };
      Object.assign(read, variables.object);
      data = { update_user_book_read: { user_book_read: { id: read.id }, error: null } };
    } else if (operation === "PullReadStatus") {
      const books = [...userBooks.values()]
        .filter((book) => book.namespace === namespace && book.id > (variables.afterId ?? 0))
        .sort((left, right) => left.id - right.id)
        .slice(variables.offset ?? 0, (variables.offset ?? 0) + Math.min(101, variables.limit ?? 100));
      data = {
        me: [
          {
            user_books: books.map((book) => ({
              ...book,
              first_started_reading_date: book.first_started_reading_date ?? "2026-10-10",
              last_read_date: book.last_read_date ?? null,
              user_book_status: book.user_book_status ?? { status: book.status_id === 3 ? "Read" : "Currently Reading" },
              book: book.book ?? { id: book.book_id, title: "Orbit fixture", slug: null, cached_contributors: [] },
              edition: book.edition ?? edition(book.edition_id ?? 501),
              user_book_reads:
                book.user_book_reads ?? [...reads.values()].filter((read) => read.namespace === namespace && read.user_book_id === book.id),
            })),
          },
        ],
      };
    } else {
      return { operation, body: { errors: [{ message: `Unsupported fixture operation: ${operation}` }] } };
    }
    return { operation, body: { data } };
  }

  const server = createServer(async (request, response) => {
    try {
      const url = new URL(request.url, "http://127.0.0.1");
      if (url.pathname === "/health") return json(response, 200, { ready: true });
      if (url.pathname === "/native-handoffs" && request.method === "GET") {
        return json(response, 200, { ...nativeHandoffs, submissions: nativeSubmissions });
      }
      if (url.pathname === "/native-handoff" && request.method === "POST") {
        const handoff = JSON.parse(await readBody(request, 256 * 1024));
        if (!/^A0[1-5]$/.test(handoff.case ?? "") || typeof handoff.testId !== "string" || typeof handoff.username !== "string") {
          return json(response, 400, { error: "Invalid native handoff" });
        }
        if (nativeSubmissions.length >= 100) return json(response, 413, { error: "Native handoff limit reached" });
        const merged = { ...nativeHandoffs[handoff.case], ...handoff };
        for (const [key, value] of Object.entries(handoff)) {
          if (value && typeof value === "object" && !Array.isArray(value)) merged[key] = { ...nativeHandoffs[handoff.case]?.[key], ...value };
        }
        nativeHandoffs[handoff.case] = merged;
        nativeSubmissions.push(handoff);
        if (artifactDirectory) await appendFile(join(artifactDirectory, "e04-native-handoffs.ndjson"), `${JSON.stringify(handoff)}\n`);
        return json(response, 204);
      }
      if (url.pathname === "/receipts" && request.method === "GET") {
        const limit = Math.min(100, Math.max(1, Number(url.searchParams.get("limit")) || 100));
        const offset = Math.max(0, Number(url.searchParams.get("offset")) || 0);
        const provider = url.searchParams.get("provider");
        const selected = requests.filter((receipt) => !provider || receipt.provider === provider);
        return json(response, 200, {
          requestCount,
          receiptCount,
          requests: selected.slice(offset, offset + limit),
          hardcover: {
            userBooks: [...userBooks.values()].slice(offset, offset + limit),
            reads: [...reads.values()].slice(offset, offset + limit),
            totalUserBooks: userBooks.size,
            totalReads: reads.size,
          },
          readwise: { highlights: [...highlights.values()].slice(offset, offset + limit), totalHighlights: highlights.size },
          storygraph: { books: [...storygraphBooks.values()].slice(offset, offset + limit), totalBooks: storygraphBooks.size },
        });
      }
      if (url.pathname === "/control" && request.method === "POST") {
        const control = JSON.parse(await readBody(request, 1024));
        if (
          !providers.includes(control.provider) ||
          !modes.includes(control.mode) ||
          (["search-error", "search-empty"].includes(control.mode) && (control.provider !== "hardcover" || control.operation !== "SearchBooks")) ||
          (control.operation !== undefined && !/^[A-Za-z][A-Za-z0-9_]{0,63}$/.test(control.operation)) ||
          (control.count !== undefined && (!Number.isInteger(control.count) || control.count < 1 || control.count > 100))
        ) {
          return json(response, 400, { error: "Invalid provider, mode, or count" });
        }
        faults.set(control.provider, { mode: control.mode, operation: control.operation, remaining: control.count ?? Infinity });
        return json(response, 204);
      }
      if (url.pathname === "/fixtures" && request.method === "POST") {
        const fixture = JSON.parse(await readBody(request));
        if (
          fixture.provider !== "hardcover" ||
          typeof fixture.token !== "string" ||
          !Array.isArray(fixture.userBooks) ||
          fixture.userBooks.length > 1000 ||
          (fixture.reads !== undefined && (!Array.isArray(fixture.reads) || fixture.reads.length > 1000))
        ) {
          return json(response, 400, { error: "Invalid controlled provider fixture" });
        }
        const namespace = createHash("sha256").update(`Bearer ${fixture.token}`).digest("hex").slice(0, 12);
        if (userBooks.size + fixture.userBooks.length > maximumRecords || reads.size + (fixture.reads?.length ?? 0) > maximumRecords) {
          return json(response, 413, { error: "Controlled provider record limit reached" });
        }
        for (const value of fixture.userBooks) {
          const id = value.id ?? nextUserBookId++;
          userBooks.set(id, { ...value, id, namespace });
          nextUserBookId = Math.max(nextUserBookId, id + 1);
        }
        for (const value of fixture.reads ?? []) {
          const id = value.id ?? nextReadId++;
          reads.set(id, { ...value, id, namespace });
          nextReadId = Math.max(nextReadId, id + 1);
        }
        return json(response, 200, { namespace, userBooks: fixture.userBooks.length, reads: fixture.reads?.length ?? 0 });
      }
      if (url.pathname === "/reset" && request.method === "POST") {
        faults.clear();
        requests.length = 0;
        userBooks.clear();
        reads.clear();
        highlights.clear();
        storygraphBooks.clear();
        requestCount = 0;
        receiptCount = 0;
        nextHighlightId = 1001;
        nextUserBookId = 801;
        nextReadId = 901;
        return json(response, 204);
      }
      const provider = providers.find((value) => url.pathname.startsWith(`/${value}/`));
      if (!provider) return json(response, 404, { error: "Unknown receiver path" });
      const path = url.pathname.slice(provider.length + 1);
      const graphBody = provider === "hardcover" && request.method === "POST" ? JSON.parse(await readBody(request, 128 * 1024)) : undefined;
      const graphOperation = graphBody ? (/(?:query|mutation)\s+(\w+)/.exec(graphBody.query ?? "")?.[1] ?? "Me") : undefined;
      const configuredFault = faults.get(provider);
      const fault = !configuredFault?.operation || configuredFault.operation === graphOperation ? configuredFault : undefined;
      const mode = fault?.mode ?? "accept";
      if (fault && --fault.remaining === 0) faults.delete(provider);
      const credentials = provider === "storygraph" ? request.headers.cookie : request.headers.authorization;
      if (mode === "auth" || !credentials || /invalid|expired|unauthorized/i.test(credentials)) {
        await record(provider, request, "authentication", false, {});
        return json(response, 401, { error: "Controlled authentication rejection" });
      }
      const namespace = createHash("sha256").update(credentials).digest("hex").slice(0, 12);
      if (["timeout", "429", "500"].includes(mode)) {
        await record(provider, request, mode, false, {});
        if (mode === "timeout") return;
        return json(response, Number(mode), { error: "Controlled provider failure" });
      }
      if (provider === "hardcover" && path === "/v1/graphql" && request.method === "POST") {
        const body = graphBody;
        if (mode === "search-empty" && graphOperation === "SearchBooks") {
          await record(provider, request, graphOperation, true, body.variables ?? {});
          return json(response, 200, { data: { search: { error: null, ids: [] } } });
        }
        if (mode === "search-error" && graphOperation === "SearchBooks") {
          await record(provider, request, graphOperation, false, body.variables ?? {});
          return json(response, 200, { data: { search: { error: "Controlled search failure", ids: null } } });
        }
        const result = hardcover(body, namespace);
        await record(provider, request, result.operation, !result.body.errors, body.variables ?? {});
        if (mode === "timeout-after-receipt") return;
        return json(response, 200, mode === "malformed" ? { unexpected: true } : result.body);
      }
      if (provider === "readwise" && path === "/api/v2/auth/" && request.method === "GET") {
        await record(provider, request, "validateToken", false, {});
        return json(response, 204);
      }
      if (provider === "readwise" && path === "/api/v2/highlights/" && request.method === "POST") {
        const body = JSON.parse(await readBody(request));
        if (
          !Array.isArray(body.highlights) ||
          body.highlights.length < 1 ||
          body.highlights.length > 100 ||
          body.highlights.some((value) => typeof value.text !== "string" || typeof value.highlight_url !== "string")
        ) {
          return json(response, 400, { error: "Invalid fixture highlight batch" });
        }
        if (mode === "malformed") {
          await record(provider, request, "createHighlights", false, { count: body.highlights.length });
          return json(response, 200, { unexpected: true });
        }
        const accepted = body.highlights.map((value) => {
          const key = `${namespace}:${value.highlight_url}`;
          if (!highlights.has(key) && highlights.size >= maximumRecords) throw new Error("Controlled provider record limit reached");
          const id = highlights.get(key)?.id ?? nextHighlightId++;
          const highlight = { ...value, id, namespace };
          highlights.set(key, highlight);
          return highlight;
        });
        if (artifactDirectory) {
          await appendFile(join(artifactDirectory, "e04-readwise-highlights.ndjson"), accepted.map((value) => `${JSON.stringify(value)}\n`).join(""));
        }
        await record(provider, request, "createHighlights", true, { ids: accepted.map(({ id }) => id), count: accepted.length });
        if (mode === "timeout-after-receipt") return;
        return json(
          response,
          200,
          accepted.map((value) => ({
            id: value.id,
            title: value.title ?? "",
            author: value.author ?? "",
            num_highlights: 1,
            modified_highlights: [value.id],
          })),
        );
      }
      if (provider === "storygraph") {
        const form = new URLSearchParams(await readBody(request));
        let book;
        if (request.method === "POST") {
          if (request.headers["x-csrf-token"] !== "e04-csrf" || form.get("authenticity_token") !== "e04-csrf") {
            return json(response, 422, { error: "Invalid fixture CSRF token" });
          }
          const id = url.searchParams.get("book_id") ?? form.get("book_id") ?? form.get("to_book_id");
          if (!id) return json(response, 400, { error: "Missing fixture book ID" });
          book = getStorygraphBook(id, namespace);
          if (path === "/update-status.js") book.status = url.searchParams.get("status");
          else if (path === "/update-progress") book.progress = Number(form.get("read_status[progress_number]"));
          else if (path !== "/switch-editions") return json(response, 404, { error: "Unsupported fixture action" });
          await record(provider, request, path.slice(1), true, {
            ...Object.fromEntries(form),
            bookId: id,
            status: book.status,
            progress: book.progress,
          });
          if (mode === "timeout-after-receipt") return;
        } else {
          await record(provider, request, path, false, {});
        }
        let html;
        if (path === "/journal") html = '<html><body><a href="/users/sign_out">Sign out</a><h1>Reading journal</h1></body></html>';
        else if (path === "/browse")
          html = `<div class="book-title-author-and-series"><a href="/books/${E04_STORYGRAPH_BOOK_ID}">Orbit fixture</a></div>`;
        else if (/^\/books\/[^/]+\/editions$/.test(path))
          html = `<meta name="csrf-token" content="e04-csrf"><div class="book-pane" data-book-id="${E04_STORYGRAPH_BOOK_ID}"><a href="/books/${E04_STORYGRAPH_BOOK_ID}">Orbit fixture</a><div class="edition-info"><p>Format: Paperback</p><p>Language: English</p><p>Publisher: BookOrbit fixture</p></div><p class="text-xs font-light">100 pages</p></div>`;
        else if (/^\/books\/[^/]+$/.test(path)) html = bookHTML(getStorygraphBook(decodeURIComponent(path.split("/")[2]), namespace));
        else if (book) html = bookHTML(book);
        else return json(response, 404, { error: "Unsupported StoryGraph fixture path" });
        response.writeHead(200, { "Content-Type": "text/html" });
        return response.end(mode === "malformed" ? "<html></html>" : html);
      }
      return json(response, 404, { error: "Unsupported provider request" });
    } catch (error) {
      json(response, 400, { error: error.message });
    }
  });
  server.on("connection", (socket) => {
    sockets.add(socket);
    socket.once("close", () => sockets.delete(socket));
  });
  try {
    await new Promise((resolve, reject) => {
      server.once("error", reject);
      server.listen(httpPort, "127.0.0.1", resolve);
    });
  } catch (error) {
    await email.close();
    throw error;
  }
  const httpURL = `http://127.0.0.1:${server.address().port}`;
  return {
    httpURL,
    smtpPort: email.smtpPort,
    smtpHTTPURL: email.httpURL,
    env: {
      IPAD_TEST_HARDCOVER_GRAPHQL_URL: `${httpURL}/hardcover/v1/graphql`,
      IPAD_TEST_HARDCOVER_TIMEOUT_MS: "500",
      IPAD_TEST_READWISE_BASE_URL: `${httpURL}/readwise/api/v2`,
      IPAD_TEST_READWISE_TIMEOUT_MS: "500",
      IPAD_TEST_STORYGRAPH_BASE_URL: `${httpURL}/storygraph`,
      IPAD_TEST_STORYGRAPH_TIMEOUT_MS: "500",
      IPAD_E04_RECEIVER_URL: httpURL,
      IPAD_E04_SMTP_PORT: String(email.smtpPort),
      IPAD_E04_SMTP_HTTP_URL: email.httpURL,
    },
    close: async () => {
      for (const socket of sockets) socket.destroy();
      await Promise.all([email.close(), new Promise((resolve) => server.close(resolve))]);
    },
  };
}
