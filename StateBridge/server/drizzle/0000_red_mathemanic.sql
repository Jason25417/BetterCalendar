CREATE TABLE `batches` (
	`id` text PRIMARY KEY NOT NULL,
	`minute` integer NOT NULL,
	`through_id` integer NOT NULL,
	`created_at` text NOT NULL,
	`body` text NOT NULL
);
--> statement-breakpoint
CREATE UNIQUE INDEX `batches_minute_unique` ON `batches` (`minute`);--> statement-breakpoint
CREATE TABLE `changes` (
	`id` integer PRIMARY KEY AUTOINCREMENT NOT NULL,
	`event_id` text NOT NULL,
	`source_key` text NOT NULL,
	`occurred_at` text NOT NULL,
	`body` text NOT NULL
);
--> statement-breakpoint
CREATE UNIQUE INDEX `changes_event_id_unique` ON `changes` (`event_id`);--> statement-breakpoint
CREATE TABLE `commands` (
	`id` text PRIMARY KEY NOT NULL,
	`request_hash` text NOT NULL,
	`session_id` text NOT NULL,
	`result` text NOT NULL,
	`created_at` text NOT NULL
);
--> statement-breakpoint
CREATE TABLE `deliveries` (
	`id` text PRIMARY KEY NOT NULL,
	`subscription_id` text NOT NULL,
	`batch_id` text NOT NULL,
	`status` text NOT NULL,
	`attempts` integer DEFAULT 0 NOT NULL,
	`next_attempt_at` text NOT NULL,
	`received_at` text,
	`last_error` text
);
--> statement-breakpoint
CREATE INDEX `idx_deliveries_pending` ON `deliveries` (`status`,`next_attempt_at`);--> statement-breakpoint
CREATE TABLE `devices` (
	`id` text PRIMARY KEY NOT NULL,
	`label` text NOT NULL,
	`token_hash` text NOT NULL,
	`scopes` text NOT NULL,
	`created_at` text NOT NULL,
	`revoked_at` text
);
--> statement-breakpoint
CREATE TABLE `notes` (
	`id` text PRIMARY KEY NOT NULL,
	`kind` text NOT NULL,
	`body` text NOT NULL,
	`assertion` text NOT NULL,
	`confidence` text NOT NULL,
	`basis` text NOT NULL,
	`created_at` text NOT NULL,
	`expires_at` text,
	`supersedes` text
);
--> statement-breakpoint
CREATE TABLE `observations` (
	`id` text PRIMARY KEY NOT NULL,
	`source_key` text NOT NULL,
	`device_id` text NOT NULL,
	`seq` integer NOT NULL,
	`observed_at` text NOT NULL,
	`received_at` text NOT NULL,
	`body` text NOT NULL
);
--> statement-breakpoint
CREATE TABLE `sessions` (
	`id` text PRIMARY KEY NOT NULL,
	`title` text NOT NULL,
	`status` text NOT NULL,
	`started_at` text NOT NULL,
	`active_since` text,
	`elapsed_ms` integer DEFAULT 0 NOT NULL,
	`updated_at` text NOT NULL,
	`revision` integer DEFAULT 1 NOT NULL,
	`last_command_id` text NOT NULL,
	`provenance` text NOT NULL
);
--> statement-breakpoint
CREATE TABLE `states` (
	`source_key` text PRIMARY KEY NOT NULL,
	`device_id` text NOT NULL,
	`seq` integer NOT NULL,
	`observed_at` text NOT NULL,
	`received_at` text NOT NULL,
	`expires_at` text,
	`value_hash` text NOT NULL,
	`body` text NOT NULL
);
--> statement-breakpoint
CREATE TABLE `subscriptions` (
	`id` text PRIMARY KEY NOT NULL,
	`owner_id` text NOT NULL,
	`callback` text NOT NULL,
	`secret` text NOT NULL,
	`expires_at` text,
	`created_at` text NOT NULL
);
