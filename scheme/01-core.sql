CREATE EXTENSION IF NOT EXISTS pgcrypto;

CREATE EXTENSION IF NOT EXISTS hstore;

-- ---------------------------------------------------------------------------
-- Enums
-- ---------------------------------------------------------------------------
CREATE TYPE content_type AS enum(
    'live_stream',
    'live_stream_clip',
    'official_video',
    'fan_made_video',
    'lekker_spelen_related',
    'other'
);

CREATE TYPE content_platform_kind AS enum(
    'video'
);

CREATE TYPE queue_job_type AS enum(
    'fetch_platform_content',
    'fetch_channel_metadata',
    'fetch_video_metadata'
);

CREATE TYPE queue_job_status AS enum(
    'queued',
    'running',
    'completed',
    'failed',
    'canceled'
);

-- Useful for quickly querying and enforcing a contentplatform has an implementation (like an abstract class)
CREATE TYPE source_kind AS enum(
    'youtube_channel'
);

-- ---------------------------------------------------------------------------
-- Users
-- ---------------------------------------------------------------------------
-- Map athentik user to local class https://api.goauthentik.io/reference/core-users-list/
CREATE TABLE app_user(
    id           uuid PRIMARY KEY          DEFAULT gen_random_uuid(),
    username     varchar(150)     NOT NULL UNIQUE,                    -- mirrors the authentik max username lenght
    email        varchar          NOT NULL UNIQUE,
    display_name varchar          NOT NULL,
    is_verified  boolean          NOT NULL DEFAULT FALSE,
    date_joined  timestamptz      NOT NULL DEFAULT now(),
    last_updated timestamptz      NOT NULL DEFAULT now(),
    last_login   timestamptz      NOT NULL DEFAULT now()
);

-- ---------------------------------------------------------------------------
-- Content
-- ---------------------------------------------------------------------------
CREATE TABLE content(
    id                           uuid PRIMARY KEY          DEFAULT gen_random_uuid(),
    content_type                 content_type     NOT NULL,
    title                        varchar          NOT NULL,                           -- TODO Map these values to audited datatype
    description                  text,                                                -- TODO Map these values to audited datatype
    show_games_played_by_default boolean          NOT NULL DEFAULT TRUE,
    original_published_at        timestamptz,
    created_at                   timestamptz      NOT NULL DEFAULT now(),
    updated_at                   timestamptz      NOT NULL DEFAULT now()
);

CREATE TABLE content_platform(
    id                             uuid PRIMARY KEY               DEFAULT gen_random_uuid(),
    platform_kind                  content_platform_kind NOT NULL,
    display_name                   varchar               NOT NULL,
    fetch_new_content_is_automated boolean               NOT NULL DEFAULT FALSE,
    added_by_user_id               uuid                  REFERENCES app_user (id) ON DELETE SET NULL,
    created_at                     timestamptz           NOT NULL DEFAULT now(),
    CONSTRAINT content_platform_id_platform_kind_key UNIQUE (id, platform_kind)
);

CREATE TABLE content_video_platform(
    id            uuid PRIMARY KEY      REFERENCES content_platform (id) ON DELETE CASCADE,
    platform_kind content_platform_kind NOT NULL DEFAULT 'video',
    source_kind   source_kind           NOT NULL,
    CONSTRAINT content_video_platform_kind_check CHECK (platform_kind = 'video'),
    CONSTRAINT content_video_platform_id_source_kind_key UNIQUE (id, source_kind),
    CONSTRAINT content_video_platform_id_platform_kind_key UNIQUE (id, platform_kind),
    FOREIGN KEY (id, platform_kind) REFERENCES content_platform(id, platform_kind) ON DELETE CASCADE
);

CREATE TABLE youtube_channel(
    id                 uuid PRIMARY KEY REFERENCES content_video_platform (id) ON DELETE CASCADE,
    source_kind        source_kind      NOT NULL DEFAULT 'youtube_channel',
    youtube_channel_id varchar          NOT NULL UNIQUE,
    CONSTRAINT youtube_channel_source_kind_check CHECK (source_kind = 'youtube_channel'),
    CONSTRAINT youtube_channel_id_source_kind_key UNIQUE (id, source_kind),
    FOREIGN KEY (id, source_kind) REFERENCES content_video_platform(id, source_kind) ON DELETE CASCADE
);

CREATE TABLE hosted_content(
    id                  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    content_id          uuid             NOT NULL REFERENCES content (id) ON DELETE CASCADE,
    content_platform_id uuid             NOT NULL REFERENCES content_platform (id) ON DELETE CASCADE,
    external_content_id varchar          NOT NULL,
    --     url                 varchar     not null,
    CONSTRAINT hosted_content_content_id_content_platform_id_key UNIQUE (content_id, content_platform_id),
    CONSTRAINT hosted_content_content_platform_id_external_content_id_key UNIQUE (content_platform_id, external_content_id)
    --     unique (url)
);

CREATE INDEX idx_hosted_content_content_id ON hosted_content(content_id);

CREATE INDEX idx_hosted_content_content_platform_id ON hosted_content(content_platform_id);

-- ---------------------------------------------------------------------------
-- Optional simple tags
-- ---------------------------------------------------------------------------
CREATE TABLE tag(
    id         uuid PRIMARY KEY          DEFAULT gen_random_uuid(),
    name       varchar(100)     NOT NULL UNIQUE,
    created_at timestamptz      NOT NULL DEFAULT now()
);

CREATE TABLE content_tag(
    content_id uuid NOT NULL REFERENCES content (id) ON DELETE CASCADE,
    tag_id     uuid NOT NULL REFERENCES tag (id) ON DELETE CASCADE,
    PRIMARY KEY (content_id, tag_id)
);

CREATE INDEX idx_content_tag_tag_id ON content_tag(tag_id);

-- ---------------------------------------------------------------------------
-- Queue tracking
-- ---------------------------------------------------------------------------
CREATE TABLE queue_job(
    id                   uuid PRIMARY KEY          DEFAULT gen_random_uuid(),
    parent_job_id        uuid             REFERENCES queue_job (id) ON DELETE SET NULL,
    type                 queue_job_type   NOT NULL,
    status               queue_job_status NOT NULL DEFAULT 'queued',
    payload              jsonb            NOT NULL DEFAULT '{}'::jsonb,
    requested_by_user_id uuid             REFERENCES app_user (id) ON DELETE SET NULL,
    correlation_key      varchar,
    dedupe_key           varchar,
    created_at           timestamptz      NOT NULL DEFAULT now(),
    started_at           timestamptz,
    finished_at          timestamptz
);

CREATE TABLE queue_job_cancellation_request(
    job_id               uuid PRIMARY KEY REFERENCES queue_job (id) ON DELETE CASCADE,
    requested_by_user_id uuid             REFERENCES app_user (id) ON DELETE SET NULL,
    requested_at         timestamptz      NOT NULL DEFAULT now()
);

CREATE UNIQUE INDEX uq_queue_job_active_dedupe_key ON queue_job(dedupe_key)
WHERE
    dedupe_key IS NOT NULL AND status IN ('queued', 'running');

CREATE INDEX idx_queue_job_requested_by_user_created_at ON queue_job(requested_by_user_id, created_at DESC);

CREATE INDEX idx_queue_job_parent_job_id_created_at ON queue_job(parent_job_id, created_at);

CREATE INDEX idx_queue_job_correlation_key ON queue_job(correlation_key)
WHERE
    correlation_key IS NOT NULL;

CREATE TABLE queue_job_event(
    id         uuid PRIMARY KEY          DEFAULT gen_random_uuid(),
    job_id     uuid             NOT NULL REFERENCES queue_job (id) ON DELETE CASCADE,
    status     queue_job_status,
    message    text,
    created_at timestamptz      NOT NULL DEFAULT now()
);

CREATE INDEX idx_queue_job_event_job_id_created_at ON queue_job_event(job_id, created_at);

-- ---------------------------------------------------------------------------
-- Queue job creation event
-- ---------------------------------------------------------------------------
-- Every queue_job gets an initial timeline event when it is created.
-- The event status is intentionally null so it does not trigger a redundant
-- status synchronization update through trg_sync_queue_job_status_from_event.
CREATE OR REPLACE FUNCTION create_queue_job_created_event()
    RETURNS TRIGGER
    LANGUAGE plpgsql
    AS $$
BEGIN
    INSERT INTO queue_job_event(job_id, status, message, created_at)
        VALUES(NEW.id, 'queued', 'Job created', NEW.created_at);
    RETURN new;
END;
$$;

CREATE TRIGGER trg_create_queue_job_created_event
    AFTER INSERT ON queue_job
    FOR EACH ROW
    EXECUTE FUNCTION create_queue_job_created_event();

-- ---------------------------------------------------------------------------
-- Queue job status synchronization
-- ---------------------------------------------------------------------------
-- queue_job_event can act as the append-only timeline, while queue_job keeps
-- the latest/current status for fast user-facing status checks.
-- When a new event with a non-null status is inserted, queue_job is updated.
-- Events without a status are treated as timeline/debug entries only.
CREATE OR REPLACE FUNCTION sync_queue_job_status_from_event()
    RETURNS TRIGGER
    LANGUAGE plpgsql
    AS $$
DECLARE
    current_status queue_job_status;
    next_started_at timestamptz;
    next_finished_at timestamptz;
BEGIN
    IF NEW.status IS NULL THEN
        RETURN NEW;
    END IF;
    SELECT
        status,
        started_at,
        finished_at
    INTO
        current_status,
        next_started_at,
        next_finished_at
    FROM
        queue_job
    WHERE
        id = NEW.job_id
    FOR UPDATE;
    IF current_status IS NULL THEN
        RAISE EXCEPTION 'queue_job_event references missing queue_job %', NEW.job_id
            USING errcode = '23503';
    END IF;
    IF current_status IN ('completed', 'failed', 'canceled') AND NEW.status <> current_status THEN
        RAISE EXCEPTION 'cannot change terminal queue_job % from % to %', NEW.job_id, current_status, NEW.status
            USING errcode = '23514';
    END IF;
    next_started_at := CASE WHEN NEW.status = 'running'
        AND next_started_at IS NULL THEN
        NEW.created_at
    WHEN NEW.status IN ('completed', 'failed', 'canceled')
        AND next_started_at IS NULL THEN
        NEW.created_at
    ELSE
        next_started_at
    END;
    next_finished_at := CASE WHEN NEW.status IN ('completed', 'failed', 'canceled')
        AND next_finished_at IS NULL THEN
        NEW.created_at
    ELSE
        next_finished_at
    END;
    IF NEW.status = 'running' AND next_started_at IS NULL THEN
        RAISE EXCEPTION 'queue_job % cannot be running without started_at', NEW.job_id
            USING errcode = '23514';
    END IF;
    IF NEW.status IN ('completed', 'failed', 'canceled') AND next_finished_at IS NULL THEN
        RAISE EXCEPTION 'queue_job % cannot be % without finished_at', NEW.job_id, NEW.status
            USING errcode = '23514';
    END IF;
    UPDATE
        queue_job
    SET
        status = NEW.status,
        started_at = next_started_at,
        finished_at = next_finished_at
    WHERE
        id = NEW.job_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'failed to synchronize queue_job % from event %', NEW.job_id, NEW.id
            USING errcode = '23503';
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_sync_queue_job_status_from_event
    AFTER INSERT ON queue_job_event
    FOR EACH ROW
    EXECUTE FUNCTION sync_queue_job_status_from_event();

