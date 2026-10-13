CREATE TABLE `native_grants` (
	`device_id` text PRIMARY KEY NOT NULL,
	`revision` integer NOT NULL,
	`body` text NOT NULL,
	`updated_at` text NOT NULL,
	`expires_at` text NOT NULL
);
--> statement-breakpoint
CREATE TABLE `native_requests` (
	`command_id` text PRIMARY KEY NOT NULL,
	`device_id` text NOT NULL,
	`owner_id` text NOT NULL,
	`request_hash` text NOT NULL,
	`body` text NOT NULL,
	`permission` text NOT NULL,
	`grant_revision` integer NOT NULL,
	`state` text NOT NULL,
	`accepted_at` text NOT NULL,
	`expires_at` text NOT NULL,
	`approval_hash` text,
	`approved_at` text,
	`attempt_id` text,
	`claimed_at` text,
	`result_hash` text,
	`result` text,
	`result_at` text
);
--> statement-breakpoint
CREATE INDEX `idx_native_target_state` ON `native_requests` (`device_id`,`state`,`accepted_at`,`command_id`);