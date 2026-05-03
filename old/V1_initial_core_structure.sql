-- Optional, if you want gen_random_uuid()
create extension if not exists pgcrypto;

-- ---------------------------------------------------------------------------
-- Enums
-- ---------------------------------------------------------------------------

create type content_type as enum (
  'live_stream',
  'live_stream_clip',
  'official_video',
  'fan_made_video',
  'lekker_spelen_related',
  'other'
);

create type platform_owner_type as enum (
  'official_lekker_spelen_managed',
  'fan_account',
  'other'
);

create type issue_status as enum (
  'open',
  'closed',
  're_opened'
);

create type content_user_report_reason as enum (
  'illegal_value',
  'other'
);

create type content_user_report_review_verdict as enum (
  'dismiss',
  'warn_content_user_that_made_report',
  'warn_content_user_reported',
  'ban_content_user_reported'
);

create type request_review_decision as enum (
  'approved',
  'denied'
);

create type entity_lifecycle_change_type as enum (
  'enable',
  'disable'
);

create type community_managed_content_visibility as enum (
  'visible',
  'disabled'
);

create type community_managed_entity_kind as enum (
  'content',
  'label',
  'content_label',
  'content_game',
  'people',
  'people_content'
);

create type mutable_field_kind as enum (
  'string',
  'integer',
  'timestamp'
);

create type content_platform_kind as enum (
  'video'
);

create type content_video_platform_kind as enum (
  'youtube_channel',
  'twitch_account'
);

create type change_request_kind as enum (
  'entity_lifecycle',
  'string',
  'timestamp',
  'integer'
);

create type content_user_issue_referenceable_kind as enum (
  'issue',
  'report_review'
);

create type content_user_issue_kind as enum (
  'generic',
  'report'
);

-- ---------------------------------------------------------------------------
-- Core identity / auth
-- ---------------------------------------------------------------------------

create table content_user (
  id uuid primary key,
  user_changeable_string_content_username uuid not null,
  password_hash varchar not null,
  is_verified boolean not null default false
);

create table content_moderator (
  content_user_id uuid primary key,
  promoted_by_administrator uuid not null
);

create table system_administrator (
  id uuid primary key,
  assigned_by_administrator uuid not null
);

create table user_changeable_string_content (
  id uuid primary key,
  previous_value uuid not null,
  owner uuid not null,
  created_at timestamp not null
);

create table user_changeable_string_non_nullable_content (
  id uuid primary key,
  value varchar not null
);

-- ---------------------------------------------------------------------------
-- Managed entities / mutable fields
-- ---------------------------------------------------------------------------

create table community_managed_entity (
  id uuid primary key,
  kind community_managed_entity_kind not null,
  state community_managed_content_visibility not null default 'disabled',
  unique (id, kind)
);

create table mutable_field (
  id uuid primary key,
  kind mutable_field_kind not null,
  updated_on timestamp not null,
  unique (id, kind)
);

create table community_managed_mutable_string_field (
  id uuid primary key,
  kind mutable_field_kind not null default 'string',
  value varchar not null,
  constraint cmmsf_kind_check check (kind = 'string'),
  unique (id, kind)
);

create table community_managed_mutable_integer_field (
  id uuid primary key,
  kind mutable_field_kind not null default 'integer',
  value integer not null,
  constraint cmmif_kind_check check (kind = 'integer'),
  unique (id, kind)
);

create table community_managed_mutable_timestamp_field (
  id uuid primary key,
  kind mutable_field_kind not null default 'timestamp',
  value timestamp not null,
  constraint cmmtf_kind_check check (kind = 'timestamp'),
  unique (id, kind)
);

-- ---------------------------------------------------------------------------
-- Content / platform
-- ---------------------------------------------------------------------------

create table content (
  id uuid primary key,
  kind community_managed_entity_kind not null default 'content',
  type content_type not null,
  show_games_played boolean not null default true,
  constraint content_kind_check check (kind = 'content'),
  unique (id, kind)
);

create table content_platform (
  id uuid primary key,
  kind content_platform_kind not null,
  name varchar not null,
  image_1x1_url varchar not null,
  owner_type platform_owner_type not null,
  platform_base_url varchar not null,
  added_at timestamp not null,
  added_by uuid not null,
  fetch_new_content_is_automated boolean not null default false,
  unique (id, kind)
);

create table content_video_platform (
  id uuid primary key,
  kind content_platform_kind not null default 'video',
  video_kind content_video_platform_kind not null,
  constraint cvp_kind_check check (kind = 'video'),
  unique (id, kind),
  unique (id, video_kind)
);

create table youtube_channel (
  id uuid primary key,
  video_kind content_video_platform_kind not null default 'youtube_channel',
  youtube_channel_id varchar not null,
  constraint youtube_channel_kind_check check (video_kind = 'youtube_channel'),
  unique (id, video_kind),
  unique (youtube_channel_id)
);

create table twitch_account (
  id uuid primary key,
  video_kind content_video_platform_kind not null default 'twitch_account',
  twitch_account_id varchar not null,
  constraint twitch_account_kind_check check (video_kind = 'twitch_account'),
  unique (id, video_kind),
  unique (twitch_account_id)
);

create table hosted_content (
  content_id uuid not null,
  content_platform_id uuid not null,
  posted_at uuid not null,
  created_at timestamp not null,
  primary key (content_id, content_platform_id)
);

create table label (
  id uuid primary key,
  kind community_managed_entity_kind not null default 'label',
  name uuid not null unique,
  constraint label_kind_check check (kind = 'label'),
  unique (id, kind)
);

create table content_label (
  content_id uuid not null,
  label_id uuid not null,
  community_managed_entity_id uuid not null unique,
  kind community_managed_entity_kind not null default 'content_label',
  constraint content_label_kind_check check (kind = 'content_label'),
  primary key (content_id, label_id),
  unique (community_managed_entity_id, kind)
);

create table game (
  id uuid primary key,
  title varchar not null,
  date_released timestamp not null
);

create table content_game (
  content_id uuid not null,
  game_id uuid not null,
  community_managed_entity_id uuid not null unique,
  kind community_managed_entity_kind not null default 'content_game',
  constraint content_game_kind_check check (kind = 'content_game'),
  primary key (content_id, game_id),
  unique (community_managed_entity_id, kind)
);

-- ---------------------------------------------------------------------------
-- Change requests
-- ---------------------------------------------------------------------------

create table change_request (
  id uuid primary key,
  kind change_request_kind not null,
  request_created_at timestamp not null,
  description varchar,
  requested_by_content_user_id uuid not null,
  unique (id, kind)
);

create table change_request_review (
  change_request_id uuid not null,
  decided_by_moderator_id uuid not null,
  decision request_review_decision not null,
  reason varchar,
  decided_at timestamp not null,
  primary key (change_request_id, decided_by_moderator_id)
);

create table change_entity_lifecycle_request (
  id uuid primary key,
  kind change_request_kind not null default 'entity_lifecycle',
  target_community_managed_entity_id uuid not null,
  lifecycle_change_type entity_lifecycle_change_type not null,
  constraint celr_kind_check check (kind = 'entity_lifecycle'),
  unique (id, kind)
);

create table change_string_request (
  id uuid primary key,
  kind change_request_kind not null default 'string',
  new_value varchar not null,
  mutable_string_field uuid not null,
  constraint csr_kind_check check (kind = 'string'),
  unique (id, kind)
);

create table change_timestamp_request (
  id uuid primary key,
  kind change_request_kind not null default 'timestamp',
  new_value timestamp not null,
  mutable_timestamp_field uuid not null,
  constraint ctr_kind_check check (kind = 'timestamp'),
  unique (id, kind)
);

create table change_integer_request (
  id uuid primary key,
  kind change_request_kind not null default 'integer',
  mutable_integer_field uuid not null,
  new_value integer not null,
  constraint cir_kind_check check (kind = 'integer'),
  unique (id, kind)
);

-- ---------------------------------------------------------------------------
-- Issues / reports
-- ---------------------------------------------------------------------------

create table content_user_issue_referenceable (
  id uuid primary key,
  kind content_user_issue_referenceable_kind not null,
  unique (id, kind)
);

create table content_user_issue (
  id uuid primary key,
  referenceable_kind content_user_issue_referenceable_kind not null default 'issue',
  issue_kind content_user_issue_kind not null default 'generic',
  created_by uuid not null,
  created_at timestamp not null,
  title varchar not null,
  description varchar,
  status issue_status not null default 'open',
  explicit_reviewer uuid,
  constraint cui_referenceable_kind_check check (referenceable_kind = 'issue'),
  unique (id, referenceable_kind),
  unique (id, issue_kind)
);

create table content_user_issue_with_reference (
  id uuid primary key,
  content_user_issue_referenceable_id uuid not null
);

create table content_user_report (
  id uuid primary key,
  issue_kind content_user_issue_kind not null default 'report',
  content_user_reported uuid not null,
  reported_by uuid not null,
  reported_at timestamp not null,
  reason content_user_report_reason not null,
  user_changeable_string_content_id uuid not null,
  title varchar not null,
  description varchar,
  constraint cur_kind_check check (issue_kind = 'report'),
  unique (id, issue_kind)
);

create table content_user_report_review (
  id uuid primary key,
  kind content_user_issue_referenceable_kind not null default 'report_review',
  content_user_report_id uuid not null,
  reviewed_by_content_moderator_id uuid not null,
  reviewed_at timestamp not null,
  verdict content_user_report_review_verdict not null,
  reason varchar not null,
  constraint curr_kind_check check (kind = 'report_review'),
  unique (id, kind)
);

-- ---------------------------------------------------------------------------
-- Optional MVP+
-- ---------------------------------------------------------------------------

create table people (
  id uuid primary key,
  kind community_managed_entity_kind not null default 'people',
  name uuid not null,
  constraint people_kind_check check (kind = 'people'),
  unique (id, kind)
);

create table people_content (
  id uuid primary key,
  kind community_managed_entity_kind not null default 'people_content',
  people_id uuid not null,
  content_id uuid not null,
  constraint people_content_kind_check check (kind = 'people_content'),
  unique (id, kind),
  unique (people_id, content_id)
);

-- ---------------------------------------------------------------------------
-- Base inheritance FKs
-- ---------------------------------------------------------------------------

alter table community_managed_mutable_string_field
  add constraint cmmsf_mutable_field_fk
  foreign key (id, kind)
  references mutable_field (id, kind)
  on delete cascade;

alter table community_managed_mutable_integer_field
  add constraint cmmif_mutable_field_fk
  foreign key (id, kind)
  references mutable_field (id, kind)
  on delete cascade;

alter table community_managed_mutable_timestamp_field
  add constraint cmmtf_mutable_field_fk
  foreign key (id, kind)
  references mutable_field (id, kind)
  on delete cascade;

alter table content
  add constraint content_managed_entity_fk
  foreign key (id, kind)
  references community_managed_entity (id, kind)
  on delete cascade;

alter table label
  add constraint label_managed_entity_fk
  foreign key (id, kind)
  references community_managed_entity (id, kind)
  on delete cascade;

alter table content_video_platform
  add constraint cvp_platform_fk
  foreign key (id, kind)
  references content_platform (id, kind)
  on delete cascade;

alter table youtube_channel
  add constraint youtube_channel_video_platform_fk
  foreign key (id, video_kind)
  references content_video_platform (id, video_kind)
  on delete cascade;

alter table twitch_account
  add constraint twitch_account_video_platform_fk
  foreign key (id, video_kind)
  references content_video_platform (id, video_kind)
  on delete cascade;

alter table change_entity_lifecycle_request
  add constraint celr_change_request_fk
  foreign key (id, kind)
  references change_request (id, kind)
  on delete cascade;

alter table change_string_request
  add constraint csr_change_request_fk
  foreign key (id, kind)
  references change_request (id, kind)
  on delete cascade;

alter table change_timestamp_request
  add constraint ctr_change_request_fk
  foreign key (id, kind)
  references change_request (id, kind)
  on delete cascade;

alter table change_integer_request
  add constraint cir_change_request_fk
  foreign key (id, kind)
  references change_request (id, kind)
  on delete cascade;

alter table content_user_issue
  add constraint cui_referenceable_fk
  foreign key (id, referenceable_kind)
  references content_user_issue_referenceable (id, kind)
  on delete cascade;

alter table content_user_report
  add constraint cur_issue_fk
  foreign key (id, issue_kind)
  references content_user_issue (id, issue_kind)
  on delete cascade;

alter table content_user_report_review
  add constraint curr_referenceable_fk
  foreign key (id, kind)
  references content_user_issue_referenceable (id, kind)
  on delete cascade;

alter table people
  add constraint people_managed_entity_fk
  foreign key (id, kind)
  references community_managed_entity (id, kind)
  on delete cascade;

alter table people_content
  add constraint people_content_managed_entity_fk
  foreign key (id, kind)
  references community_managed_entity (id, kind)
  on delete cascade;

alter table content_label
  add constraint content_label_managed_entity_fk
  foreign key (community_managed_entity_id, kind)
  references community_managed_entity (id, kind)
  on delete cascade;

alter table content_game
  add constraint content_game_managed_entity_fk
  foreign key (community_managed_entity_id, kind)
  references community_managed_entity (id, kind)
  on delete cascade;

-- ---------------------------------------------------------------------------
-- Regular FKs
-- ---------------------------------------------------------------------------

alter table content_moderator
  add constraint content_moderator_user_fk
  foreign key (content_user_id)
  references content_user (id)
  on delete cascade;

alter table system_administrator
  add constraint system_administrator_moderator_fk
  foreign key (id)
  references content_moderator (content_user_id)
  on delete cascade;

alter table user_changeable_string_content
  add constraint user_changeable_string_content_previous_fk
  foreign key (previous_value)
  references user_changeable_string_content (id)
  deferrable initially deferred;

alter table user_changeable_string_content
  add constraint user_changeable_string_content_owner_fk
  foreign key (owner)
  references content_user (id)
  deferrable initially deferred;

alter table user_changeable_string_non_nullable_content
  add constraint user_changeable_string_non_nullable_content_base_fk
  foreign key (id)
  references user_changeable_string_content (id)
  on delete cascade;

alter table content_user
  add constraint content_user_username_fk
  foreign key (user_changeable_string_content_username)
  references user_changeable_string_non_nullable_content (id)
  deferrable initially deferred;

alter table content_moderator
  add constraint content_moderator_promoted_by_fk
  foreign key (promoted_by_administrator)
  references system_administrator (id)
  deferrable initially deferred;

alter table system_administrator
  add constraint system_administrator_assigned_by_fk
  foreign key (assigned_by_administrator)
  references system_administrator (id)
  deferrable initially deferred;

alter table content_platform
  add constraint content_platform_added_by_fk
  foreign key (added_by)
  references system_administrator (id);

alter table hosted_content
  add constraint hosted_content_content_fk
  foreign key (content_id)
  references content (id)
  on delete cascade;

alter table hosted_content
  add constraint hosted_content_platform_fk
  foreign key (content_platform_id)
  references content_platform (id)
  on delete cascade;

alter table hosted_content
  add constraint hosted_content_posted_at_fk
  foreign key (posted_at)
  references community_managed_mutable_timestamp_field (id);

alter table label
  add constraint label_name_fk
  foreign key (name)
  references community_managed_mutable_string_field (id);

alter table content_label
  add constraint content_label_content_fk
  foreign key (content_id)
  references content (id)
  on delete cascade;

alter table content_label
  add constraint content_label_label_fk
  foreign key (label_id)
  references label (id)
  on delete cascade;

alter table content_game
  add constraint content_game_content_fk
  foreign key (content_id)
  references content (id)
  on delete cascade;

alter table content_game
  add constraint content_game_game_fk
  foreign key (game_id)
  references game (id)
  on delete cascade;

alter table change_request
  add constraint change_request_requested_by_fk
  foreign key (requested_by_content_user_id)
  references content_user (id);

alter table change_request_review
  add constraint change_request_review_change_request_fk
  foreign key (change_request_id)
  references change_request (id)
  on delete cascade;

alter table change_request_review
  add constraint change_request_review_moderator_fk
  foreign key (decided_by_moderator_id)
  references content_moderator (content_user_id);

alter table change_entity_lifecycle_request
  add constraint celr_target_entity_fk
  foreign key (target_community_managed_entity_id)
  references community_managed_entity (id);

alter table change_string_request
  add constraint csr_mutable_string_fk
  foreign key (mutable_string_field)
  references community_managed_mutable_string_field (id);

alter table change_timestamp_request
  add constraint ctr_mutable_timestamp_fk
  foreign key (mutable_timestamp_field)
  references community_managed_mutable_timestamp_field (id);

alter table change_integer_request
  add constraint cir_mutable_integer_fk
  foreign key (mutable_integer_field)
  references community_managed_mutable_integer_field (id);

alter table content_user_issue
  add constraint cui_created_by_fk
  foreign key (created_by)
  references content_user (id);

alter table content_user_issue
  add constraint cui_explicit_reviewer_fk
  foreign key (explicit_reviewer)
  references content_moderator (content_user_id);

alter table content_user_issue_with_reference
  add constraint cuiwr_issue_fk
  foreign key (id)
  references content_user_issue (id)
  on delete cascade;

alter table content_user_issue_with_reference
  add constraint cuiwr_referenceable_fk
  foreign key (content_user_issue_referenceable_id)
  references content_user_issue_referenceable (id);

alter table content_user_report
  add constraint cur_reported_fk
  foreign key (content_user_reported)
  references content_user (id);

alter table content_user_report
  add constraint cur_reported_by_fk
  foreign key (reported_by)
  references content_user (id);

alter table content_user_report
  add constraint cur_user_changeable_string_content_fk
  foreign key (user_changeable_string_content_id)
  references user_changeable_string_content (id);

alter table content_user_report_review
  add constraint curr_content_user_report_fk
  foreign key (content_user_report_id)
  references content_user_report (id);

alter table content_user_report_review
  add constraint curr_reviewed_by_fk
  foreign key (reviewed_by_content_moderator_id)
  references content_moderator (content_user_id);

alter table people
  add constraint people_name_fk
  foreign key (name)
  references community_managed_mutable_string_field (id);

alter table people_content
  add constraint people_content_people_fk
  foreign key (people_id)
  references people (id)
  on delete cascade;

alter table people_content
  add constraint people_content_content_fk
  foreign key (content_id)
  references content (id)
  on delete cascade;

-- ---------------------------------------------------------------------------
-- Helpful indexes
-- ---------------------------------------------------------------------------

create index idx_hosted_content_platform on hosted_content (content_platform_id);
create index idx_content_label_label on content_label (label_id);
create index idx_content_game_game on content_game (game_id);
create index idx_change_request_requested_by on change_request (requested_by_content_user_id);
create index idx_issue_created_by on content_user_issue (created_by);
create index idx_report_reported_user on content_user_report (content_user_reported);
create index idx_people_content_people on people_content (people_id);
create index idx_people_content_content on people_content (content_id);

-- ---------------------------------------------------------------------------
-- Business-rule trigger:
-- every content row must have at least one hosted_content by commit time
-- ---------------------------------------------------------------------------

create or replace function trg_check_content_has_hosting()
returns trigger
language plpgsql
as $$
declare
  v_content_id uuid;
begin
  v_content_id := case
    when tg_table_name = 'content' then new.id
    when tg_op = 'DELETE' then old.content_id
    else new.content_id
  end;

  if not exists (
    select 1
    from hosted_content hc
    where hc.content_id = v_content_id
  ) then
    raise exception 'content % must have at least one hosted_content row', v_content_id;
  end if;

  return null;
end;
$$;

create constraint trigger check_content_has_hosting_after_content
after insert or update on content
deferrable initially deferred
for each row
execute function trg_check_content_has_hosting();

create constraint trigger check_content_has_hosting_after_hosted_content_delete
after delete on hosted_content
deferrable initially deferred
for each row
execute function trg_check_content_has_hosting();

create constraint trigger check_content_has_hosting_after_hosted_content_update
after update of content_id on hosted_content
deferrable initially deferred
for each row
execute function trg_check_content_has_hosting();
