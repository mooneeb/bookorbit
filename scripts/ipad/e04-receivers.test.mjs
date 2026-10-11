import assert from "node:assert/strict";
import { mkdtemp, readFile, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import { E04_STORYGRAPH_BOOK_ID, startE04Receivers } from "./e04-receivers.mjs";

test("E04 providers expose accepted artifacts, scoped identities, and controlled failures over real protocols", async () => {
  const artifactDirectory = await mkdtemp(join(tmpdir(), "bookorbit-e04-receivers-"));
  const receiver = await startE04Receivers({ artifactDirectory });
  try {
    const control = async (body) => {
      const response = await fetch(`${receiver.httpURL}/control`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify(body),
      });
      assert.equal(response.status, 204);
    };
    const graph = async (operation, variables, token = "fixture-token", signal) => {
      const response = await fetch(receiver.env.IPAD_TEST_HARDCOVER_GRAPHQL_URL, {
        method: "POST",
        headers: { Authorization: `Bearer ${token}`, "Content-Type": "application/json" },
        body: JSON.stringify({ query: `mutation ${operation} { fixture }`, variables }),
        signal,
      });
      return response.json();
    };
    assert.equal((await graph("Me", {})).data.me[0].username, "fixture-hardcover");
    await control({ provider: "hardcover", mode: "search-error", operation: "SearchBooks", count: 1 });
    assert.deepEqual((await graph("SearchBooks", { query: "Orbit Author" })).data.search, { error: "Controlled search failure", ids: null });
    assert.deepEqual((await graph("SearchBooks", { query: "Orbit Author" })).data.search, { error: null, ids: [102] });
    assert.equal((await graph("FindBooksByIds", { ids: [102] })).data.books[0].id, 102);
    await control({ provider: "hardcover", mode: "search-empty", operation: "SearchBooks", count: 1 });
    assert.equal((await graph("Me", {})).data.me[0].username, "fixture-hardcover");
    assert.deepEqual((await graph("SearchBooks", { query: "No matching provider book" })).data.search, { error: null, ids: [] });
    const searchReceipts = await (await fetch(`${receiver.httpURL}/receipts?provider=hardcover`)).json();
    assert.equal(searchReceipts.requests.at(-1).operation, "SearchBooks");
    assert.equal(searchReceipts.requests.at(-1).accepted, true);
    assert.deepEqual((await graph("SearchBooks", { query: "Orbit Author" })).data.search, { error: null, ids: [102] });

    await control({ provider: "hardcover", mode: "timeout-after-receipt", operation: "InsertUserBook", count: 1 });
    assert.equal((await graph("FindUserBook", { bookId: 101 })).data.me.user_books.length, 0);
    await assert.rejects(
      graph("InsertUserBook", { object: { book_id: 101, status_id: 2, edition_id: 501 } }, "fixture-token", AbortSignal.timeout(75)),
    );
    const books = (await graph("FindUserBook", { bookId: 101 })).data.me.user_books;
    assert.equal(books.length, 1);
    assert.equal((await graph("FindUserBook", { bookId: 101 }, "other-token")).data.me.user_books.length, 0);
    for (let index = 0; index < 2; index++) await graph("InsertUserBookRead", { userBookId: books[0].id, object: { progress_pages: 20 } });
    assert.equal((await graph("FindUserBookReads", { userBookId: books[0].id })).data.user_book_reads.length, 2);
    const seeded = await fetch(`${receiver.httpURL}/fixtures`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ provider: "hardcover", token: "fixture-token", userBooks: [{ id: 1000, book_id: 102, status_id: 3, edition_id: 501 }] }),
    });
    assert.equal(seeded.status, 200);
    assert.equal((await graph("PullReadStatus", { afterId: books[0].id, limit: 101 })).data.me[0].user_books[0].id, 1000);

    const highlight = {
      text: "E04 eligible passage",
      title: "Orbit fixture",
      highlight_url: "http://bookorbit.test/book/1?annotationId=1",
      source_type: "bookorbit",
      category: "books",
    };
    const sendHighlights = (token = "readwise-token", signal) =>
      fetch(`${receiver.env.IPAD_TEST_READWISE_BASE_URL}/highlights/`, {
        method: "POST",
        headers: { Authorization: `Token ${token}`, "Content-Type": "application/json" },
        body: JSON.stringify({ highlights: [highlight] }),
        signal,
      });
    await control({ provider: "readwise", mode: "timeout-after-receipt", count: 1 });
    await assert.rejects(sendHighlights("readwise-token", AbortSignal.timeout(75)));
    const accepted = await (await sendHighlights()).json();
    assert.equal(accepted[0].num_highlights, 1);
    await sendHighlights("another-readwise-token");
    await control({ provider: "readwise", mode: "auth", count: 1 });
    assert.equal((await sendHighlights()).status, 401);
    await control({ provider: "readwise", mode: "malformed", count: 1 });
    assert.deepEqual(await (await sendHighlights()).json(), { unexpected: true });

    const storyHeaders = {
      Cookie: "_storygraph_session=fixture; remember_user_token=fixture",
      "X-CSRF-Token": "e04-csrf",
      "Content-Type": "application/x-www-form-urlencoded",
    };
    assert.equal((await fetch(`${receiver.env.IPAD_TEST_STORYGRAPH_BASE_URL}/journal`, { headers: storyHeaders })).status, 200);
    assert.equal(
      (
        await fetch(`${receiver.env.IPAD_TEST_STORYGRAPH_BASE_URL}/update-progress`, {
          method: "POST",
          headers: storyHeaders,
          body: new URLSearchParams({ book_id: E04_STORYGRAPH_BOOK_ID, "read_status[progress_number]": "42", authenticity_token: "e04-csrf" }),
        })
      ).status,
      200,
    );
    const page = await (
      await fetch(`${receiver.env.IPAD_TEST_STORYGRAPH_BASE_URL}/books/${E04_STORYGRAPH_BOOK_ID}`, { headers: storyHeaders })
    ).text();
    assert.match(page, /name="read_status\[progress_number\]" value="42"/);
    assert.equal(
      (await fetch(`${receiver.env.IPAD_TEST_STORYGRAPH_BASE_URL}/update-progress`, { method: "POST", headers: storyHeaders, body: "book_id=other" }))
        .status,
      422,
    );

    for (const handoff of [
      { case: "A01", testId: "IPAD-E04-A01-record", username: "ipad-e04-record", readingRecord: { rating: 4 } },
      { case: "A01", testId: "IPAD-E04-A01-statistics", username: "ipad-e04-statistics", statistics: { totalSeconds: 900 } },
    ]) {
      assert.equal(
        (
          await fetch(`${receiver.httpURL}/native-handoff`, {
            method: "POST",
            headers: { "Content-Type": "application/json" },
            body: JSON.stringify(handoff),
          })
        ).status,
        204,
      );
    }
    const handoffs = await (await fetch(`${receiver.httpURL}/native-handoffs`)).json();
    assert.equal(handoffs.A01.readingRecord.rating, 4);
    assert.equal(handoffs.A01.statistics.totalSeconds, 900);
    assert.equal(handoffs.submissions.length, 2);
    const receipts = await (await fetch(`${receiver.httpURL}/receipts`)).json();
    assert.equal(receipts.hardcover.totalReads, 2);
    assert.equal(receipts.readwise.totalHighlights, 2);
    assert.equal(receipts.storygraph.books[0].progress, 42);
    assert.equal(new Set(receipts.readwise.highlights.map(({ namespace }) => namespace)).size, 2);
    const artifacts = await readFile(join(artifactDirectory, "e04-provider-receipts.ndjson"), "utf8");
    assert.doesNotMatch(artifacts, /fixture-token|readwise-token|Authorization|remember_user_token/);
    assert.match(artifacts, /InsertUserBookRead/);
    const receivedHighlights = await readFile(join(artifactDirectory, "e04-readwise-highlights.ndjson"), "utf8");
    assert.match(receivedHighlights, /E04 eligible passage/);
    assert.doesNotMatch(receivedHighlights, /readwise-token/);
  } finally {
    await receiver.close();
    await rm(artifactDirectory, { recursive: true, force: true });
  }
});
