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

create type content_platform_kind as enum (
    'video'
    );

create type queue_job_type as enum (
    'fetch_platform_content',
    'sync_content_metadata',
    'refresh_thumbnail',
    'reindex_content'
    );

create type queue_job_status as enum (
    'queued',
    'running',
    'completed',
    'failed',
    'cancelled'
    );

-- Useful for quickly querying and enforcing a contentplatform has an implementation (like an abstract class)
create type source_kind as enum (
    'youtube_channel',
    'twitch_account',
    'other'
    );

-- ---------------------------------------------------------------------------
-- Users
-- ---------------------------------------------------------------------------

create table app_user
(
    id            uuid primary key     default gen_random_uuid(),
    username      varchar(50) not null unique,
    email         varchar(320) unique,
    password_hash varchar     not null,
    is_verified   boolean     not null default false,
    created_at    timestamptz not null default now(),
    updated_at    timestamptz not null default now()
);

-- ---------------------------------------------------------------------------
-- Content
-- ---------------------------------------------------------------------------

create table content
(
    id                    uuid primary key      default gen_random_uuid(),
    content_type          content_type not null,
    title                 varchar      not null, -- TODO Map these values to audited datatype
    description           text,  -- TODO Map these values to audited datatype
    show_games_played     boolean      not null default true,
    original_published_at timestamptz,
    created_at            timestamptz  not null default now(),
    updated_at            timestamptz  not null default now()
);

create table content_platform
(
    id                             uuid primary key             default gen_random_uuid(),
    kind                           content_platform_kind not null,
    display_name                   varchar               not null,
    base_url                       varchar,
    image_url                      varchar,
    fetch_new_content_is_automated boolean               not null default false,
    added_by_user_id               uuid                  references app_user (id) on delete set null,
    created_at                     timestamptz           not null default now(),
    unique (id, kind)
);

create table content_video_platform
(
    id          uuid primary key references content_platform (id) on delete cascade,
    kind        content_platform_kind not null default 'video',
    source_kind source_kind           not null,
    constraint content_video_platform_kind_check check (kind = 'video'),
    unique (id, source_kind),
    unique (id, kind),
    foreign key (id, kind) references content_platform (id, kind) on delete cascade
);

create table youtube_channel
(
    id                 uuid primary key references content_video_platform (id) on delete cascade,
    source_kind        source_kind not null default 'youtube_channel',
    youtube_channel_id varchar     not null unique,
    constraint youtube_channel_source_kind_check check (source_kind = 'youtube_channel'),
    unique (id, source_kind),
    foreign key (id, source_kind) references content_video_platform (id, source_kind) on delete cascade
);

create table hosted_content
(
    id                  uuid primary key     default gen_random_uuid(),
    content_id          uuid        not null references content (id) on delete cascade,
    content_platform_id uuid        not null references content_platform (id) on delete cascade,
    external_content_id varchar,
    url                 varchar     not null,
    unique (content_id, content_platform_id),
    unique (content_platform_id, external_content_id),
    unique (url)
);

create index idx_hosted_content_content_id on hosted_content (content_id);
create index idx_hosted_content_content_platform_id on hosted_content (content_platform_id);

-- ---------------------------------------------------------------------------
-- Optional simple tags
-- ---------------------------------------------------------------------------

create table tag
(
    id         uuid primary key      default gen_random_uuid(),
    name       varchar(100) not null unique,
    created_at timestamptz  not null default now()
);

create table content_tag
(
    content_id uuid not null references content (id) on delete cascade,
    tag_id     uuid not null references tag (id) on delete cascade,
    primary key (content_id, tag_id)
);

create index idx_content_tag_tag_id on content_tag (tag_id);

-- ---------------------------------------------------------------------------
-- Queue tracking
-- ---------------------------------------------------------------------------

create table queue_job
(
    id                   uuid primary key          default gen_random_uuid(),
    parent_job_id        uuid references queue_job (id) on delete set null,
    job_type             queue_job_type   not null,
    status               queue_job_status not null default 'queued',
    payload              jsonb            not null default '{}'::jsonb,
    priority             integer          not null default 0,
    available_at         timestamptz      not null default now(),
    requested_by_user_id uuid             references app_user (id) on delete set null,
    correlation_key      varchar,
    dedupe_key           varchar,
    error_type           varchar,
    error_message        text,
    created_at           timestamptz      not null default now(),
    updated_at           timestamptz      not null default now(),
    started_at           timestamptz,
    finished_at          timestamptz,
    constraint queue_job_running_requires_started_at
        check (status <> 'running' or started_at is not null),
    constraint queue_job_completed_requires_finished_at
        check (status <> 'completed' or finished_at is not null),
    constraint queue_job_failed_requires_finished_at
        check (status <> 'failed' or finished_at is not null),
    constraint queue_job_finished_status_requires_finished_at
        check (status not in ('completed', 'failed', 'cancelled') or finished_at is not null),
    constraint queue_job_error_only_when_failed
        check (status = 'failed' or (error_type is null and error_message is null))
);

create unique index uq_queue_job_active_dedupe_key
    on queue_job (dedupe_key)
    where dedupe_key is not null
      and status in ('queued', 'running');

create index idx_queue_job_status_available_at
    on queue_job (status, available_at);

create index idx_queue_job_requested_by_user_created_at
    on queue_job (requested_by_user_id, created_at desc);

create index idx_queue_job_parent_job_id_created_at
    on queue_job (parent_job_id, created_at);

create index idx_queue_job_correlation_key
    on queue_job (correlation_key)
    where correlation_key is not null;

create table queue_job_event
(
    id         bigserial primary key,
    job_id     uuid        not null references queue_job (id) on delete cascade,
    status     queue_job_status,
    event_type varchar(50) not null,
    message    text,
    payload    jsonb       not null default '{}'::jsonb,
    created_at timestamptz not null default now()
);

create index idx_queue_job_event_job_id_created_at
    on queue_job_event (job_id, created_at);