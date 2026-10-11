CREATE TABLE "migration_plan_preview_counts" (
	"id" serial PRIMARY KEY NOT NULL,
	"artifact_id" integer NOT NULL,
	"user_id" integer NOT NULL,
	"source_book_id" text NOT NULL,
	"source_user_id" text NOT NULL,
	"statuses" integer DEFAULT 0 NOT NULL,
	"file_progress" integer DEFAULT 0 NOT NULL,
	"reading_sessions" integer DEFAULT 0 NOT NULL,
	"bookmarks" integer DEFAULT 0 NOT NULL,
	"annotations" integer DEFAULT 0 NOT NULL,
	"shelves" integer DEFAULT 0 NOT NULL
);
--> statement-breakpoint
CREATE TABLE "migration_plan_source_books" (
	"id" serial PRIMARY KEY NOT NULL,
	"artifact_id" integer NOT NULL,
	"user_id" integer NOT NULL,
	"source_book_id" text NOT NULL,
	"title" text,
	"author" text,
	"file_path" text,
	"target_book_id" integer,
	"strategy" varchar(32),
	"unresolved_reason" text
);
--> statement-breakpoint
ALTER TABLE "migration_plan_preview_counts" ADD CONSTRAINT "migration_plan_preview_counts_user_id_users_id_fk" FOREIGN KEY ("user_id") REFERENCES "public"."users"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "migration_plan_preview_counts" ADD CONSTRAINT "migration_plan_preview_counts_artifact_owner_fk" FOREIGN KEY ("artifact_id","user_id") REFERENCES "public"."migration_plan_artifacts"("id","created_by_user_id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "migration_plan_source_books" ADD CONSTRAINT "migration_plan_source_books_user_id_users_id_fk" FOREIGN KEY ("user_id") REFERENCES "public"."users"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "migration_plan_source_books" ADD CONSTRAINT "migration_plan_source_books_artifact_owner_fk" FOREIGN KEY ("artifact_id","user_id") REFERENCES "public"."migration_plan_artifacts"("id","created_by_user_id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
CREATE UNIQUE INDEX "migration_plan_preview_counts_source_uidx" ON "migration_plan_preview_counts" USING btree ("artifact_id","user_id","source_book_id","source_user_id");--> statement-breakpoint
CREATE UNIQUE INDEX "migration_plan_source_books_source_uidx" ON "migration_plan_source_books" USING btree ("artifact_id","user_id","source_book_id");--> statement-breakpoint
CREATE INDEX "migration_plan_source_books_target_idx" ON "migration_plan_source_books" USING btree ("artifact_id","user_id","target_book_id");