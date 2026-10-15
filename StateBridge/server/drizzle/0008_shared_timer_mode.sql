ALTER TABLE `sessions` ADD `mode` text DEFAULT 'light' NOT NULL;--> statement-breakpoint
ALTER TABLE `sessions` ADD `focus_minutes` integer;--> statement-breakpoint
ALTER TABLE `sessions` ADD `experiment` integer DEFAULT false NOT NULL;