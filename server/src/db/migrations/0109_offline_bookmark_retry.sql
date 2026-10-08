DROP INDEX "bookmarks_user_book_file_page_uidx";--> statement-breakpoint
DROP INDEX "bookmarks_user_book_cfi_uidx";--> statement-breakpoint
ALTER TABLE "bookmarks" ADD COLUMN "retry_protected" boolean DEFAULT false NOT NULL;--> statement-breakpoint
CREATE UNIQUE INDEX "bookmarks_user_book_file_page_uidx" ON "bookmarks" USING btree ("user_id","book_id","file_id","page_number") WHERE "bookmarks"."file_id" is not null and "bookmarks"."page_number" is not null and "bookmarks"."deleted_at" is null;--> statement-breakpoint
CREATE UNIQUE INDEX "bookmarks_user_book_cfi_uidx" ON "bookmarks" USING btree ("user_id","book_id","cfi") WHERE "bookmarks"."cfi" is not null and "bookmarks"."deleted_at" is null;