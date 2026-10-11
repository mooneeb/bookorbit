import { copyFile, mkdir, stat, writeFile } from "node:fs/promises";
import { dirname, join, relative } from "node:path";
import { createRequire } from "node:module";
import { randomUUID, randomBytes } from "node:crypto";

const require = createRequire(new URL("../../server/package.json", import.meta.url));
const { PDFDocument } = require("pdf-lib");

export async function seedDuplicateMergeFixture(client, directory, libraryFolderId, options = {}) {
  const {
    rows: [folder],
  } = await client.query("select id, library_id, path from library_folders where ($1::integer is null or id=$1) order by id limit 1", [
    libraryFolderId ?? null,
  ]);
  if (!folder) throw new Error("Duplicate merge fixture requires an existing library folder");
  const result = { libraryId: folder.library_id, libraryFolderId: folder.id, appDataPath: options.appDataPath ?? join(dirname(directory), "data") };
  const isbnBody = `978${String(randomBytes(4).readUInt32BE() % 1000000000).padStart(9, "0")}`;
  const isbnChecksum = (10 - ([...isbnBody].reduce((sum, digit, index) => sum + Number(digit) * (index % 2 === 0 ? 1 : 3), 0) % 10)) % 10;
  result.isbn13 = `${isbnBody}${isbnChecksum}`;
  for (const kind of ["source", "target"]) {
    const path = join(directory, `duplicate-merge-${kind}`);
    await mkdir(path, { recursive: true });
    const pdf = await PDFDocument.create();
    pdf.addPage([600, 800]).drawText("Duplicate merge preserves source PDF bytes", { x: 40, y: 700, size: 18 });
    const absolutePath = join(path, `${kind}.pdf`);
    await writeFile(absolutePath, await pdf.save());
    const fileStat = await stat(absolutePath);
    const {
      rows: [book],
    } = await client.query("insert into books (library_id, library_folder_id, folder_path) values ($1,$2,$3) returning id", [
      folder.library_id,
      folder.id,
      path,
    ]);
    const {
      rows: [file],
    } = await client.query(
      "insert into book_files (book_id,library_folder_id,absolute_path,rel_path,ino,size_bytes,mtime,format) values ($1,$2,$3,$4,$5,$6,$7,'pdf') returning id",
      [book.id, folder.id, absolutePath, relative(folder.path, absolutePath), fileStat.ino, fileStat.size, fileStat.mtime],
    );
    await client.query("update books set primary_file_id=$1 where id=$2", [file.id, book.id]);
    await client.query("insert into book_metadata (book_id,title,isbn13) values ($1,'Merge preservation fixture',$2)", [book.id, result.isbn13]);
    result[`${kind}BookId`] = book.id;
    result[`${kind}FileId`] = file.id;
  }
  if (options.includePreservation !== false) {
    result.preservation = await seedDuplicateMergeFixture(client, join(directory, "preservation"), folder.id, {
      includePreservation: false,
      appDataPath: result.appDataPath,
    });
    const {
      rows: [owner],
    } = await client.query("select id from users where username='ipad-owner'");
    const token = randomBytes(32).toString("hex");
    const entitlementId = randomUUID();
    const coverImageId = randomUUID();
    const {
      rows: [device],
    } = await client.query("insert into kobo_devices (user_id,name,token) values ($1,'E03 duplicate preservation',$2) returning id", [
      owner.id,
      token,
    ]);
    const {
      rows: [snapshot],
    } = await client.query("insert into kobo_device_library_snapshots (user_id,device_id) values ($1,$2) returning id", [owner.id, device.id]);
    await client.query(
      "insert into kobo_device_snapshot_books (snapshot_id,book_id,synced,is_new,file_hash) values ($1,$2,true,false,'preserved-delivery-hash')",
      [snapshot.id, result.preservation.sourceBookId],
    );
    await client.query(
      "insert into kobo_book_entitlements (user_id,book_id,entitlement_id,cover_image_id,needs_legacy_numeric_removal) values ($1,$2,$3,$4,false)",
      [owner.id, result.preservation.sourceBookId, entitlementId, coverImageId],
    );
    await client.query(
      "insert into kobo_reading_states (user_id,book_id,entitlement_id,current_bookmark,statistics,status_info) values ($1,$2,$3,$4,$5,$6)",
      [
        owner.id,
        result.preservation.sourceBookId,
        entitlementId,
        { ProgressPercent: 42, ContentSourceProgressPercent: 42 },
        { MinutesRead: 81 },
        { Status: "Reading" },
      ],
    );
    Object.assign(result.preservation, { koboToken: token, entitlementId, coverImageId });
    result.audioConflict = await seedDuplicateMergeFixture(client, join(directory, "audio-conflict"), folder.id, {
      includePreservation: false,
      appDataPath: result.appDataPath,
    });
    const {
      rows: [audio],
    } = await client.query(
      "select absolute_path,format,duration_seconds from book_files where format in ('mp3','m4b','m4a','opus','ogg','flac') and role='content' order by id limit 1",
    );
    if (!audio) throw new Error("Duplicate audio fixture requires the real harness narration recording");
    for (const kind of ["source", "target"]) {
      const absolutePath = join(directory, "audio-conflict", `duplicate-merge-${kind}`, `${kind}.${audio.format}`);
      await copyFile(audio.absolute_path, absolutePath);
      const info = await stat(absolutePath);
      const {
        rows: [file],
      } = await client.query(
        "insert into book_files (book_id,library_folder_id,absolute_path,rel_path,ino,size_bytes,mtime,format,duration_seconds,sort_order) values ($1,$2,$3,$4,$5,$6,$7,$8,$9,0) returning id",
        [
          result.audioConflict[`${kind}BookId`],
          folder.id,
          absolutePath,
          relative(folder.path, absolutePath),
          info.ino,
          info.size,
          info.mtime,
          audio.format,
          audio.duration_seconds,
        ],
      );
      result.audioConflict[`${kind}AudioFileId`] = file.id;
    }
  }
  return result;
}
