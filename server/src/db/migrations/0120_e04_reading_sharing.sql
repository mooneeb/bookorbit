CREATE TABLE "hardcover_sync_runs" (
	"id" serial PRIMARY KEY NOT NULL,
	"user_id" integer NOT NULL,
	"status" varchar(20) DEFAULT 'running' NOT NULL,
	"total_books" integer DEFAULT 0 NOT NULL,
	"processed_books" integer DEFAULT 0 NOT NULL,
	"synced_books" integer DEFAULT 0 NOT NULL,
	"failed_books" integer DEFAULT 0 NOT NULL,
	"skipped_books" integer DEFAULT 0 NOT NULL,
	"error" text,
	"started_at" timestamp with time zone DEFAULT now() NOT NULL,
	"finished_at" timestamp with time zone
);
--> statement-breakpoint
CREATE TABLE "reading_session_deletions" (
	"user_id" integer NOT NULL,
	"session_id" varchar(64) NOT NULL,
	"book_id" integer NOT NULL,
	"deleted_at" timestamp with time zone DEFAULT now() NOT NULL,
	CONSTRAINT "reading_session_deletions_user_id_session_id_pk" PRIMARY KEY("user_id","session_id")
);
--> statement-breakpoint
ALTER TABLE "kobo_device_library_snapshots" ADD COLUMN "pending_page" jsonb;--> statement-breakpoint
ALTER TABLE "readwise_user_settings" ADD COLUMN "sync_state" text DEFAULT 'idle' NOT NULL;--> statement-breakpoint
ALTER TABLE "readwise_user_settings" ADD COLUMN "sync_exported_highlights" integer DEFAULT 0 NOT NULL;--> statement-breakpoint
ALTER TABLE "readwise_user_settings" ADD COLUMN "sync_started_at" timestamp with time zone;--> statement-breakpoint
ALTER TABLE "readwise_user_settings" ADD COLUMN "sync_finished_at" timestamp with time zone;--> statement-breakpoint
ALTER TABLE "readwise_user_settings" ADD COLUMN "sync_lease_until" timestamp with time zone;--> statement-breakpoint
ALTER TABLE "readwise_user_settings" ADD COLUMN "sync_error" text;--> statement-breakpoint
ALTER TABLE "readwise_user_settings" ADD COLUMN "sync_received_book_ids" jsonb DEFAULT '[]'::jsonb NOT NULL;--> statement-breakpoint
ALTER TABLE "storygraph_user_settings" ADD COLUMN "last_sync_status" jsonb;--> statement-breakpoint
ALTER TABLE "hardcover_sync_runs" ADD CONSTRAINT "hardcover_sync_runs_user_id_users_id_fk" FOREIGN KEY ("user_id") REFERENCES "public"."users"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "reading_session_deletions" ADD CONSTRAINT "reading_session_deletions_user_id_users_id_fk" FOREIGN KEY ("user_id") REFERENCES "public"."users"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "reading_session_deletions" ADD CONSTRAINT "reading_session_deletions_book_id_books_id_fk" FOREIGN KEY ("book_id") REFERENCES "public"."books"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
CREATE INDEX "hardcover_sync_runs_user_id_idx" ON "hardcover_sync_runs" USING btree ("user_id","id");--> statement-breakpoint
CREATE INDEX "reading_session_deletions_book_idx" ON "reading_session_deletions" USING btree ("book_id");