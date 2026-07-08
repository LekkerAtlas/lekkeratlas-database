create extension if not exists pgcrypto;
create extension if not exists hstore;

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
    'fetch_channel_metadata',
    'fetch_video_metadata'
    );

create type queue_job_status as enum (
    'queued',
    'running',
    'completed',
    'failed',
    'canceled'
    );

-- Useful for quickly querying and enforcing a contentplatform has an implementation (like an abstract class)
create type source_kind as enum (
    'youtube_channel'
    );

-- ---------------------------------------------------------------------------
-- Users
-- ---------------------------------------------------------------------------

-- Map athentik user to local class https://api.goauthentik.io/reference/core-users-list/
create table app_user
(
    id           uuid primary key      default gen_random_uuid(),
    username     varchar(150) not null unique, -- mirrors the authentik max username lenght
    email        varchar      not null unique,
    display_name varchar      not null,
    is_verified  boolean      not null default false,
    date_joined  timestamptz  not null default now(),
    last_updated timestamptz  not null default now(),
    last_login   timestamptz  not null default now()
);

-- ---------------------------------------------------------------------------
-- Content
-- ---------------------------------------------------------------------------

create table content
(
    id                           uuid primary key      default gen_random_uuid(),
    content_type                 content_type not null,
    title                        varchar      not null, -- TODO Map these values to audited datatype
    description                  text,                  -- TODO Map these values to audited datatype
    show_games_played_by_default boolean      not null default true,
    original_published_at        timestamptz,
    created_at                   timestamptz  not null default now(),
    updated_at                   timestamptz  not null default now()
);

create table content_platform
(
    id                             uuid primary key               default gen_random_uuid(),
    platform_kind                  content_platform_kind not null,
    display_name                   varchar               not null,
    fetch_new_content_is_automated boolean               not null default false,
    added_by_user_id               uuid                  references app_user (id) on delete set null,
    created_at                     timestamptz           not null default now(),
    unique (id, platform_kind)
);

create table content_video_platform
(
    id            uuid primary key references content_platform (id) on delete cascade,
    platform_kind content_platform_kind not null default 'video',
    source_kind   source_kind           not null,
    constraint content_video_platform_kind_check check (platform_kind = 'video'),
    unique (id, source_kind),
    unique (id, platform_kind),
    foreign key (id, platform_kind) references content_platform (id, platform_kind) on delete cascade
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
    id                  uuid primary key default gen_random_uuid(),
    content_id          uuid    not null references content (id) on delete cascade,
    content_platform_id uuid    not null references content_platform (id) on delete cascade,
    external_content_id varchar not null,
--     url                 varchar     not null,
    unique (content_id, content_platform_id),
    unique (content_platform_id, external_content_id)
--     unique (url)
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
    parent_job_id        uuid             references queue_job (id) on delete set null,
    type                 queue_job_type   not null,
    status               queue_job_status not null default 'queued',
    payload              jsonb            not null default '{}'::jsonb,
    requested_by_user_id uuid             references app_user (id) on delete set null,
    correlation_key      varchar,
    dedupe_key           varchar,
    error_type           varchar,
    error_message        text,
    created_at           timestamptz      not null default now(),
    started_at           timestamptz,
    finished_at          timestamptz
);

create unique index uq_queue_job_active_dedupe_key
    on queue_job (dedupe_key)
    where dedupe_key is not null
        and status in ('queued', 'running');

create index idx_queue_job_requested_by_user_created_at
    on queue_job (requested_by_user_id, created_at desc);

create index idx_queue_job_parent_job_id_created_at
    on queue_job (parent_job_id, created_at);

create index idx_queue_job_correlation_key
    on queue_job (correlation_key)
    where correlation_key is not null;

create table queue_job_event
(
    id         uuid primary key     default gen_random_uuid(),
    job_id     uuid        not null references queue_job (id) on delete cascade,
    status     queue_job_status,
    message    text,
    created_at timestamptz not null default now()
);

create index idx_queue_job_event_job_id_created_at
    on queue_job_event (job_id, created_at);


-- ---------------------------------------------------------------------------
-- Queue job creation event
-- ---------------------------------------------------------------------------
-- Every queue_job gets an initial timeline event when it is created.
-- The event status is intentionally null so it does not trigger a redundant
-- status synchronization update through trg_sync_queue_job_status_from_event.

create or replace function create_queue_job_created_event()
    returns trigger
    language plpgsql
as
$$
begin
    insert into queue_job_event (job_id,
                                 status,
                                 message,
                                 created_at)
    values (new.id,
            'queued',
            'Job created',
            new.created_at);

    return new;
end;
$$;

create trigger trg_create_queue_job_created_event
    after insert
    on queue_job
    for each row
execute function create_queue_job_created_event();

-- ---------------------------------------------------------------------------
-- Queue job status synchronization
-- ---------------------------------------------------------------------------
-- queue_job_event can act as the append-only timeline, while queue_job keeps
-- the latest/current status for fast user-facing status checks.
-- When a new event with a non-null status is inserted, queue_job is updated.
-- Events without a status are treated as timeline/debug entries only.

create or replace function sync_queue_job_status_from_event()
    returns trigger
    language plpgsql
as
$$
declare
    current_status     queue_job_status;
    next_started_at    timestamptz;
    next_finished_at   timestamptz;
    next_error_type    varchar;
    next_error_message text;
begin
    if new.status is null then
        return new;
    end if;

    select status,
           started_at,
           finished_at,
           error_type,
           error_message
    into current_status,
        next_started_at,
        next_finished_at,
        next_error_type,
        next_error_message
    from queue_job
    where id = new.job_id
        for update;

    if current_status is null then
        raise exception 'queue_job_event references missing queue_job %', new.job_id
            using errcode = '23503';
    end if;

    if current_status in ('completed', 'failed', 'canceled')
        and new.status <> current_status then
        raise exception 'cannot change terminal queue_job % from % to %',
            new.job_id,
            current_status,
            new.status
            using errcode = '23514';
    end if;

    next_started_at = case
                          when new.status = 'running' and next_started_at is null then new.created_at
                          when new.status in ('completed', 'failed', 'canceled') and next_started_at is null
                              then new.created_at
                          else next_started_at
        end;

    next_finished_at = case
                           when new.status in ('completed', 'failed', 'canceled') and next_finished_at is null
                               then new.created_at
                           else next_finished_at
        end;

    next_error_type = case

                          when new.status = 'failed' then next_error_type

                          else null
        end;

    next_error_message = case

                             when new.status = 'failed' then coalesce(new.message, next_error_message)

                             else null
        end;

    if new.status = 'running' and next_started_at is null then
        raise exception 'queue_job % cannot be running without started_at', new.job_id
            using errcode = '23514';
    end if;

    if new.status in ('completed', 'failed', 'canceled') and next_finished_at is null then
        raise exception 'queue_job % cannot be % without finished_at', new.job_id, new.status
            using errcode = '23514';
    end if;

    if new.status <> 'failed' and (next_error_type is not null or next_error_message is not null) then
        raise exception 'queue_job % cannot have error fields while status is %', new.job_id, new.status
            using errcode = '23514';
    end if;

    update queue_job
    set status        = new.status,
        started_at    = next_started_at,
        finished_at   = next_finished_at,
        error_type    = next_error_type,
        error_message = next_error_message
    where id = new.job_id;

    if not found then
        raise exception 'failed to synchronize queue_job % from event %', new.job_id, new.id
            using errcode = '23503';
    end if;

    return new;
end;
$$;

create trigger trg_sync_queue_job_status_from_event
    after insert
    on queue_job_event
    for each row
execute function sync_queue_job_status_from_event();