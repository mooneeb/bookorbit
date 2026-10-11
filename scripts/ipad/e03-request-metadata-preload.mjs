const originalFetch = globalThis.fetch;
const fixtureTitle = /^Native discovered fixture ([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})$/i;

if (process.env.IPAD_E03_PROOF === "1") {
  globalThis.fetch = async (input, init) => {
    const url = new URL(input instanceof Request ? input.url : input);
    const title = url.searchParams.get("title") ?? "";
    const match = fixtureTitle.exec(title);
    if (url.origin === "https://openlibrary.org" && url.pathname === "/search.json" && match) {
      const signal = init?.signal ?? (input instanceof Request ? input.signal : undefined);
      signal?.throwIfAborted();
      return new Response(
        JSON.stringify({
          numFound: 1,
          docs: [
            {
              key: `/works/E03${match[1].replaceAll("-", "").toUpperCase()}W`,
              title,
              author_name: ["Native discovery author"],
              first_publish_year: 2026,
              language: ["eng"],
            },
          ],
        }),
        { headers: { "content-type": "application/json" } },
      );
    }
    return originalFetch(input, init);
  };
}
