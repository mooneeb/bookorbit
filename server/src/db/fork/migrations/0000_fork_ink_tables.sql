CREATE TABLE "fork_ink" (
	"id" serial PRIMARY KEY NOT NULL,
	"user_id" integer NOT NULL,
	"annotation_id" integer NOT NULL,
	"book_id" integer NOT NULL,
	"kind" varchar(10) NOT NULL,
	"book_file_id" integer,
	"page_index" integer,
	"drawing_data" "bytea" NOT NULL,
	"svg" text NOT NULL,
	"recognized_text" text,
	"version" integer DEFAULT 1 NOT NULL,
	"device_created_at" timestamp with time zone NOT NULL,
	"device_updated_at" timestamp with time zone NOT NULL,
	"deleted_at" timestamp with time zone,
	"created_at" timestamp with time zone DEFAULT now() NOT NULL,
	"updated_at" timestamp with time zone DEFAULT now() NOT NULL,
	CONSTRAINT "fork_ink_kind_chk" CHECK ("fork_ink"."kind" in ('page', 'sketch')),
	CONSTRAINT "fork_ink_kind_position_chk" CHECK (("fork_ink"."kind" = 'page' and "fork_ink"."page_index" is not null) or ("fork_ink"."kind" = 'sketch' and "fork_ink"."book_file_id" is null and "fork_ink"."page_index" is null)),
	CONSTRAINT "fork_ink_page_index_chk" CHECK ("fork_ink"."page_index" is null or "fork_ink"."page_index" >= 0),
	CONSTRAINT "fork_ink_version_chk" CHECK ("fork_ink"."version" >= 1)
);
--> statement-breakpoint
CREATE TABLE "fork_ipad_annotations" (
	"annotation_id" integer PRIMARY KEY NOT NULL,
	"user_id" integer NOT NULL,
	"created_at" timestamp with time zone DEFAULT now() NOT NULL
);
--> statement-breakpoint
ALTER TABLE "fork_ink" ADD CONSTRAINT "fork_ink_user_id_users_id_fk" FOREIGN KEY ("user_id") REFERENCES "public"."users"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "fork_ink" ADD CONSTRAINT "fork_ink_annotation_id_annotations_id_fk" FOREIGN KEY ("annotation_id") REFERENCES "public"."annotations"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "fork_ink" ADD CONSTRAINT "fork_ink_book_id_books_id_fk" FOREIGN KEY ("book_id") REFERENCES "public"."books"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "fork_ink" ADD CONSTRAINT "fork_ink_book_file_id_book_files_id_fk" FOREIGN KEY ("book_file_id") REFERENCES "public"."book_files"("id") ON DELETE set null ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "fork_ipad_annotations" ADD CONSTRAINT "fork_ipad_annotations_annotation_id_annotations_id_fk" FOREIGN KEY ("annotation_id") REFERENCES "public"."annotations"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "fork_ipad_annotations" ADD CONSTRAINT "fork_ipad_annotations_user_id_users_id_fk" FOREIGN KEY ("user_id") REFERENCES "public"."users"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
CREATE INDEX "fork_ink_user_book_updated_idx" ON "fork_ink" USING btree ("user_id","book_id","updated_at","id");--> statement-breakpoint
CREATE INDEX "fork_ink_annotation_id_idx" ON "fork_ink" USING btree ("annotation_id");--> statement-breakpoint
CREATE INDEX "fork_ink_book_id_idx" ON "fork_ink" USING btree ("book_id");--> statement-breakpoint
CREATE INDEX "fork_ink_book_file_id_idx" ON "fork_ink" USING btree ("book_file_id");--> statement-breakpoint
CREATE UNIQUE INDEX "fork_ink_annotation_kind_active_uidx" ON "fork_ink" USING btree ("annotation_id","kind") WHERE "fork_ink"."deleted_at" is null;--> statement-breakpoint
CREATE UNIQUE INDEX "fork_ink_page_active_uidx" ON "fork_ink" USING btree ("user_id","book_file_id","page_index") WHERE "fork_ink"."kind" = 'page' and "fork_ink"."deleted_at" is null;--> statement-breakpoint
CREATE INDEX "fork_ipad_annotations_user_id_idx" ON "fork_ipad_annotations" USING btree ("user_id");