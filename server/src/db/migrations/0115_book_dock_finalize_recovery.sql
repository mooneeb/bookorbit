CREATE TABLE "book_dock_finalizations" (
	"file_id" integer PRIMARY KEY NOT NULL,
	"user_id" integer NOT NULL,
	"library_id" integer NOT NULL,
	"state" varchar(20) DEFAULT 'placing' NOT NULL,
	"intent" jsonb NOT NULL,
	"book_ids" jsonb DEFAULT '[]'::jsonb NOT NULL,
	"result" jsonb,
	"error" text,
	"updated_at" timestamp with time zone DEFAULT now() NOT NULL,
	CONSTRAINT "book_dock_finalizations_state_chk" CHECK ("book_dock_finalizations"."state" in ('placing', 'committed', 'completed', 'failed'))
);
--> statement-breakpoint
CREATE TABLE "book_dock_finalize_job_items" (
	"id" serial PRIMARY KEY NOT NULL,
	"job_id" integer NOT NULL,
	"file_id" integer NOT NULL,
	"state" varchar(20) DEFAULT 'pending' NOT NULL,
	"result" jsonb
);
--> statement-breakpoint
CREATE TABLE "book_dock_finalize_jobs" (
	"id" serial PRIMARY KEY NOT NULL,
	"user_id" integer NOT NULL,
	"idempotency_key" uuid NOT NULL,
	"request" jsonb NOT NULL,
	"state" varchar(20) DEFAULT 'queued' NOT NULL,
	"cursor" integer DEFAULT 0 NOT NULL,
	"total" integer DEFAULT 0 NOT NULL,
	"succeeded" integer DEFAULT 0 NOT NULL,
	"failed" integer DEFAULT 0 NOT NULL,
	"error" text,
	"created_at" timestamp with time zone DEFAULT now() NOT NULL,
	"updated_at" timestamp with time zone DEFAULT now() NOT NULL,
	CONSTRAINT "book_dock_finalize_jobs_state_chk" CHECK ("book_dock_finalize_jobs"."state" in ('queued', 'running', 'completed', 'failed'))
);
--> statement-breakpoint
ALTER TABLE "book_dock_finalizations" ADD CONSTRAINT "book_dock_finalizations_user_id_users_id_fk" FOREIGN KEY ("user_id") REFERENCES "public"."users"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "book_dock_finalizations" ADD CONSTRAINT "book_dock_finalizations_library_id_libraries_id_fk" FOREIGN KEY ("library_id") REFERENCES "public"."libraries"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "book_dock_finalize_job_items" ADD CONSTRAINT "book_dock_finalize_job_items_job_id_book_dock_finalize_jobs_id_fk" FOREIGN KEY ("job_id") REFERENCES "public"."book_dock_finalize_jobs"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "book_dock_finalize_jobs" ADD CONSTRAINT "book_dock_finalize_jobs_user_id_users_id_fk" FOREIGN KEY ("user_id") REFERENCES "public"."users"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
CREATE INDEX "book_dock_finalizations_user_id_idx" ON "book_dock_finalizations" USING btree ("user_id","file_id");--> statement-breakpoint
CREATE INDEX "book_dock_finalizations_state_idx" ON "book_dock_finalizations" USING btree ("state","file_id");--> statement-breakpoint
CREATE UNIQUE INDEX "book_dock_finalize_job_items_job_file_idx" ON "book_dock_finalize_job_items" USING btree ("job_id","file_id");--> statement-breakpoint
CREATE INDEX "book_dock_finalize_job_items_pending_idx" ON "book_dock_finalize_job_items" USING btree ("job_id","state","id");--> statement-breakpoint
CREATE UNIQUE INDEX "book_dock_finalize_jobs_user_key_idx" ON "book_dock_finalize_jobs" USING btree ("user_id","idempotency_key");--> statement-breakpoint
CREATE INDEX "book_dock_finalize_jobs_state_idx" ON "book_dock_finalize_jobs" USING btree ("state","id");