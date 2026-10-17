CREATE TABLE `native_approval_notification_deliveries` (
	`command_id` text NOT NULL,
	`request_hash` text NOT NULL,
	`device_id` text NOT NULL,
	`policy_revision` integer NOT NULL,
	`claim_id` text NOT NULL,
	`state` text NOT NULL,
	`system_submitted_at` text,
	`clicked_at` text,
	`updated_at` text NOT NULL,
	PRIMARY KEY(`command_id`, `device_id`)
);
--> statement-breakpoint
CREATE TABLE `native_approval_notification_routes` (
	`command_id` text PRIMARY KEY NOT NULL,
	`request_hash` text NOT NULL,
	`policy_revision` integer NOT NULL,
	`device_ids` text NOT NULL,
	`created_at` text NOT NULL
);
