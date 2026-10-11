CREATE TABLE "entity_file_write_books" (
	"operation_id" uuid NOT NULL,
	"attempted_at" timestamp with time zone,
	"book_id" integer NOT NULL,
	CONSTRAINT "entity_file_write_books_operation_id_book_id_pk" PRIMARY KEY("operation_id","book_id")
);
--> statement-breakpoint
CREATE TABLE "entity_file_writes" (
	"id" uuid PRIMARY KEY NOT NULL,
	"user_id" integer NOT NULL,
	"entity_type" varchar(30) NOT NULL,
	"created_at" timestamp with time zone DEFAULT now() NOT NULL
);
--> statement-breakpoint
ALTER TABLE "entity_file_write_books" ADD CONSTRAINT "entity_file_write_books_operation_id_entity_file_writes_id_fk" FOREIGN KEY ("operation_id") REFERENCES "public"."entity_file_writes"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "entity_file_write_books" ADD CONSTRAINT "entity_file_write_books_book_id_books_id_fk" FOREIGN KEY ("book_id") REFERENCES "public"."books"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "entity_file_writes" ADD CONSTRAINT "entity_file_writes_user_id_users_id_fk" FOREIGN KEY ("user_id") REFERENCES "public"."users"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
CREATE INDEX "entity_file_write_books_pending_idx" ON "entity_file_write_books" USING btree ("operation_id","attempted_at","book_id");--> statement-breakpoint
CREATE INDEX "entity_file_writes_user_type_idx" ON "entity_file_writes" USING btree ("user_id","entity_type","created_at");