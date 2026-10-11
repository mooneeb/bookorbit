CREATE TABLE "migration_plan_source_batches" (
	"id" serial PRIMARY KEY NOT NULL,
	"artifact_id" integer NOT NULL,
	"batch_index" integer NOT NULL,
	"book_overlays" integer DEFAULT 1 NOT NULL,
	"source_data" jsonb NOT NULL
);
--> statement-breakpoint
CREATE TABLE "migration_run_batch_checkpoints" (
	"id" serial PRIMARY KEY NOT NULL,
	"run_id" integer NOT NULL,
	"stage" varchar(64) NOT NULL,
	"batch_index" integer NOT NULL,
	"metrics" jsonb NOT NULL,
	"updated_at" timestamp with time zone DEFAULT now() NOT NULL
);
--> statement-breakpoint
DROP INDEX "migration_plan_artifacts_plan_hash_uidx";--> statement-breakpoint
ALTER TABLE "migration_plan_source_batches" ADD CONSTRAINT "migration_plan_source_batches_artifact_id_migration_plan_artifacts_id_fk" FOREIGN KEY ("artifact_id") REFERENCES "public"."migration_plan_artifacts"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "migration_run_batch_checkpoints" ADD CONSTRAINT "migration_run_batch_checkpoints_run_id_migration_runs_id_fk" FOREIGN KEY ("run_id") REFERENCES "public"."migration_runs"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
CREATE UNIQUE INDEX "migration_plan_source_batches_artifact_index_uidx" ON "migration_plan_source_batches" USING btree ("artifact_id","batch_index");--> statement-breakpoint
CREATE UNIQUE INDEX "migration_run_batch_checkpoints_run_stage_uidx" ON "migration_run_batch_checkpoints" USING btree ("run_id","stage");--> statement-breakpoint
CREATE INDEX "migration_plan_artifacts_plan_hash_idx" ON "migration_plan_artifacts" USING btree ("plan_hash");--> statement-breakpoint
CREATE INDEX "upload_sessions_user_dock_idx" ON "upload_sessions" USING btree ("user_id","result_book_dock_file_id");