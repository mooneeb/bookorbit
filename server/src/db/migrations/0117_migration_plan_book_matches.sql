CREATE TABLE "migration_plan_book_matches" (
	"id" serial PRIMARY KEY NOT NULL,
	"artifact_id" integer NOT NULL,
	"user_id" integer NOT NULL,
	"position" integer NOT NULL,
	"source_book_id" text NOT NULL,
	"target_book_id" integer NOT NULL,
	"strategy" varchar(32) NOT NULL,
	CONSTRAINT "migration_plan_book_matches_position_chk" CHECK ("migration_plan_book_matches"."position" >= 0),
	CONSTRAINT "migration_plan_book_matches_strategy_chk" CHECK ("migration_plan_book_matches"."strategy" IN ('isbn', 'asin', 'file_hash', 'path_mapping', 'title_author'))
);
--> statement-breakpoint
ALTER TABLE "migration_plan_book_matches" ADD CONSTRAINT "migration_plan_book_matches_user_id_users_id_fk" FOREIGN KEY ("user_id") REFERENCES "public"."users"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "migration_plan_book_matches" ADD CONSTRAINT "migration_plan_book_matches_artifact_owner_fk" FOREIGN KEY ("artifact_id","user_id") REFERENCES "public"."migration_plan_artifacts"("id","created_by_user_id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
CREATE UNIQUE INDEX "migration_plan_book_matches_source_uidx" ON "migration_plan_book_matches" USING btree ("artifact_id","user_id","source_book_id");--> statement-breakpoint
CREATE UNIQUE INDEX "migration_plan_book_matches_position_uidx" ON "migration_plan_book_matches" USING btree ("artifact_id","user_id","position");--> statement-breakpoint
CREATE INDEX "migration_plan_book_matches_user_idx" ON "migration_plan_book_matches" USING btree ("user_id");