CREATE TABLE `native_approval_notifications` (
	`command_id` text PRIMARY KEY NOT NULL,
	`request_hash` text NOT NULL,
	`device_id` text NOT NULL,
	`policy_revision` integer NOT NULL,
	`claim_id` text NOT NULL,
	`state` text NOT NULL,
	`system_submitted_at` text,
	`clicked_at` text,
	`updated_at` text NOT NULL
);
--> statement-breakpoint
CREATE TABLE `native_approval_policy` (
	`id` text PRIMARY KEY NOT NULL,
	`revision` integer NOT NULL,
	`body` text NOT NULL,
	`last_request_hash` text,
	`updated_at` text NOT NULL
);
