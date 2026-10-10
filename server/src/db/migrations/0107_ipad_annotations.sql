CREATE TABLE "native_annotation_acks" (
	"user_id" integer NOT NULL,
	"device_id" varchar(100) NOT NULL,
	"book_id" integer NOT NULL,
	"cursor" bigint DEFAULT 0 NOT NULL,
	"updated_at" timestamp with time zone DEFAULT now() NOT NULL,
	CONSTRAINT "native_annotation_acks_user_id_device_id_book_id_pk" PRIMARY KEY("user_id","device_id","book_id")
);
--> statement-breakpoint
CREATE TABLE "native_annotation_drafts" (
	"id" serial PRIMARY KEY NOT NULL,
	"user_id" integer NOT NULL,
	"book_id" integer NOT NULL,
	"annotation_id" integer,
	"operation_id" uuid NOT NULL,
	"reason" varchar(100) NOT NULL,
	"payload" jsonb NOT NULL,
	"created_at" timestamp with time zone DEFAULT now() NOT NULL
);
--> statement-breakpoint
CREATE TABLE "native_annotation_operations" (
	"user_id" integer NOT NULL,
	"operation_id" uuid NOT NULL,
	"device_id" varchar(100) NOT NULL,
	"request" jsonb NOT NULL,
	"result" jsonb NOT NULL,
	"created_at" timestamp with time zone DEFAULT now() NOT NULL,
	CONSTRAINT "native_annotation_operations_user_id_operation_id_pk" PRIMARY KEY("user_id","operation_id")
);
--> statement-breakpoint
ALTER TABLE "users" ADD COLUMN "manage_own_annotations" boolean DEFAULT true NOT NULL;--> statement-breakpoint
ALTER TABLE "annotations" ADD COLUMN "client_id" uuid;--> statement-breakpoint
ALTER TABLE "annotations" ADD COLUMN "kind" varchar(20) DEFAULT 'highlight' NOT NULL;--> statement-breakpoint
ALTER TABLE "annotations" ADD COLUMN "drawing" jsonb;--> statement-breakpoint
ALTER TABLE "annotations" ADD COLUMN "source_revision" varchar(128);--> statement-breakpoint
ALTER TABLE "annotations" ADD COLUMN "page_fingerprint" varchar(128);--> statement-breakpoint
ALTER TABLE "annotations" ADD COLUMN "change_sequence" bigserial NOT NULL;--> statement-breakpoint
ALTER TABLE "native_annotation_acks" ADD CONSTRAINT "native_annotation_acks_user_id_users_id_fk" FOREIGN KEY ("user_id") REFERENCES "public"."users"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "native_annotation_acks" ADD CONSTRAINT "native_annotation_acks_book_id_books_id_fk" FOREIGN KEY ("book_id") REFERENCES "public"."books"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "native_annotation_drafts" ADD CONSTRAINT "native_annotation_drafts_user_id_users_id_fk" FOREIGN KEY ("user_id") REFERENCES "public"."users"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "native_annotation_drafts" ADD CONSTRAINT "native_annotation_drafts_book_id_books_id_fk" FOREIGN KEY ("book_id") REFERENCES "public"."books"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "native_annotation_drafts" ADD CONSTRAINT "native_annotation_drafts_annotation_id_annotations_id_fk" FOREIGN KEY ("annotation_id") REFERENCES "public"."annotations"("id") ON DELETE set null ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "native_annotation_operations" ADD CONSTRAINT "native_annotation_operations_user_id_users_id_fk" FOREIGN KEY ("user_id") REFERENCES "public"."users"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
CREATE UNIQUE INDEX "native_annotation_drafts_user_operation_uidx" ON "native_annotation_drafts" USING btree ("user_id","operation_id");--> statement-breakpoint
CREATE INDEX "native_annotation_drafts_user_book_id_idx" ON "native_annotation_drafts" USING btree ("user_id","book_id","id");--> statement-breakpoint
CREATE INDEX "native_annotation_drafts_user_id_idx" ON "native_annotation_drafts" USING btree ("user_id","id");--> statement-breakpoint
CREATE INDEX "native_annotation_operations_user_device_idx" ON "native_annotation_operations" USING btree ("user_id","device_id");--> statement-breakpoint
CREATE UNIQUE INDEX "annotations_user_client_uidx" ON "annotations" USING btree ("user_id","client_id");--> statement-breakpoint
CREATE INDEX "annotations_user_change_idx" ON "annotations" USING btree ("user_id","change_sequence");--> statement-breakpoint
CREATE INDEX "annotations_user_book_change_idx" ON "annotations" USING btree ("user_id","book_id","change_sequence");--> statement-breakpoint
CREATE INDEX "annotations_user_book_id_idx" ON "annotations" USING btree ("user_id","book_id","id" DESC NULLS LAST);--> statement-breakpoint
CREATE INDEX "annotations_user_kind_id_idx" ON "annotations" USING btree ("user_id","kind","id" DESC NULLS LAST);--> statement-breakpoint
CREATE INDEX "annotations_user_origin_id_idx" ON "annotations" USING btree ("user_id","origin","id" DESC NULLS LAST);--> statement-breakpoint
ALTER TABLE "annotations" ADD CONSTRAINT "annotations_kind_chk" CHECK ("annotations"."kind" in ('highlight', 'text_note', 'handwriting', 'pdf_ink'));