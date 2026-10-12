CREATE TABLE `research_log` (
	`id` integer PRIMARY KEY AUTOINCREMENT NOT NULL,
	`call_id` text NOT NULL,
	`kind` text NOT NULL,
	`batch_id` text,
	`actor` text,
	`created_at` text NOT NULL,
	`body` text NOT NULL
);
--> statement-breakpoint
CREATE UNIQUE INDEX `research_log_call_id_unique` ON `research_log` (`call_id`);--> statement-breakpoint
CREATE INDEX `idx_research_batch` ON `research_log` (`batch_id`,`id`);