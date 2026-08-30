-- ---------------------------------------------------------------------------
-- Review/versioning enums
-- ---------------------------------------------------------------------------
CREATE TYPE auditable_entity_type AS enum(
    'app_user',
    'creator',
    'creator_account',
    'content',
    'hosted_content',
    'tag',
    'content_tag'
);

CREATE TYPE change_set_status AS enum(
    'draft',
    'in_review',
    'approved',
    'rejected',
    'published'
);

CREATE TYPE change_operation AS enum(
    'create',
    'update',
    'delete'
);

CREATE TYPE review_decision AS enum(
    'approved',
    'rejected'
);

-- ---------------------------------------------------------------------------
-- Workspaces and proposed changes
-- ---------------------------------------------------------------------------
-- A user has one mutable workspace. Submitting it creates/finalizes a change
-- set; the workspace can subsequently be used for another draft change set.
CREATE TABLE workspace(
    id            uuid PRIMARY KEY          DEFAULT gen_random_uuid(),
    owner_user_id uuid             NOT NULL UNIQUE REFERENCES app_user (id) ON DELETE RESTRICT,
    created_at    timestamptz      NOT NULL DEFAULT now(),
    updated_at    timestamptz      NOT NULL DEFAULT now()
);

-- A change set is the non-technical equivalent of a commit/pull request unit.
-- The user builds it in draft state and then submits the complete unit for
-- review. approved/rejected are synchronized from an immutable review record.
CREATE TABLE change_set(
    id                   uuid PRIMARY KEY          DEFAULT gen_random_uuid(),
    workspace_id         uuid             NOT NULL REFERENCES workspace (id) ON DELETE RESTRICT,
    status               change_set_status NOT NULL DEFAULT 'draft',
    submitted_by_user_id uuid             REFERENCES app_user (id) ON DELETE RESTRICT,
    created_at           timestamptz      NOT NULL DEFAULT now(),
    submitted_at         timestamptz,
    published_at         timestamptz,
    CONSTRAINT change_set_state_timestamps_check CHECK (
        (status = 'draft'
            AND submitted_by_user_id IS NULL
            AND submitted_at IS NULL
            AND published_at IS NULL)
        OR
        (status IN ('in_review', 'approved', 'rejected')
            AND submitted_by_user_id IS NOT NULL
            AND submitted_at IS NOT NULL
            AND published_at IS NULL)
        OR
        (status = 'published'
            AND submitted_by_user_id IS NOT NULL
            AND submitted_at IS NOT NULL
            AND published_at IS NOT NULL)
    )
);

CREATE INDEX idx_change_set_workspace_created_at ON change_set(workspace_id, created_at DESC);

CREATE INDEX idx_change_set_status_created_at ON change_set(status, created_at DESC);

CREATE UNIQUE INDEX uq_change_set_workspace_draft ON change_set(workspace_id)
WHERE
    status = 'draft';

-- One change item targets one canonical entity. New entities receive their UUID
-- before publication so every create/update/delete uses the same identity shape.
CREATE TABLE change_item(
    id            uuid PRIMARY KEY              DEFAULT gen_random_uuid(),
    change_set_id uuid                 NOT NULL REFERENCES change_set (id) ON DELETE CASCADE,
    entity_type   auditable_entity_type NOT NULL,
    entity_id     uuid                 NOT NULL,
    operation     change_operation     NOT NULL,
    base_revision bigint,
    created_at    timestamptz          NOT NULL DEFAULT now(),
    CONSTRAINT change_item_revision_check CHECK (
        (operation = 'create' AND base_revision IS NULL)
        OR
        (operation IN ('update', 'delete') AND base_revision IS NOT NULL AND base_revision > 0)
    ),
    CONSTRAINT change_item_change_set_entity_key UNIQUE (change_set_id, entity_type, entity_id)
);

CREATE INDEX idx_change_item_entity ON change_item(entity_type, entity_id);

-- Field-level proposals keep the review representation generic while canonical
-- tables remain strongly typed. JSONB preserves numbers, booleans, strings and
-- nulls without creating a separate table for every SQL scalar type.
CREATE TABLE change_field(
    id             uuid PRIMARY KEY          DEFAULT gen_random_uuid(),
    change_item_id uuid             NOT NULL REFERENCES change_item (id) ON DELETE CASCADE,
    field_name     varchar(100)     NOT NULL,
    base_value     jsonb,
    proposed_value jsonb,
    CONSTRAINT change_field_item_field_key UNIQUE (change_item_id, field_name)
);

-- A submitted change set gets at most one immutable decision. A rejected set is
-- not reopened; follow-up work should be submitted as a new change set.
CREATE TABLE review(
    id               uuid PRIMARY KEY          DEFAULT gen_random_uuid(),
    change_set_id    uuid             NOT NULL UNIQUE REFERENCES change_set (id) ON DELETE RESTRICT,
    reviewer_user_id uuid             NOT NULL REFERENCES app_user (id) ON DELETE RESTRICT,
    decision         review_decision  NOT NULL,
    comment          text,
    reviewed_at      timestamptz      NOT NULL DEFAULT now()
);

CREATE INDEX idx_review_reviewer_reviewed_at ON review(reviewer_user_id, reviewed_at DESC);

-- ---------------------------------------------------------------------------
-- Review state synchronization
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION validate_review()
    RETURNS TRIGGER
    LANGUAGE plpgsql
    AS $$
DECLARE
    current_status change_set_status;
    submitted_by_user_id uuid;
BEGIN
    SELECT
        status,
        change_set.submitted_by_user_id
    INTO
        current_status,
        submitted_by_user_id
    FROM
        change_set
    WHERE
        id = NEW.change_set_id
    FOR UPDATE;

    IF current_status IS NULL THEN
        RAISE EXCEPTION 'review references missing change_set %', NEW.change_set_id
            USING errcode = '23503';
    END IF;

    IF current_status <> 'in_review' THEN
        RAISE EXCEPTION 'change_set % cannot be reviewed while in status %', NEW.change_set_id, current_status
            USING errcode = '23514';
    END IF;

    IF submitted_by_user_id = NEW.reviewer_user_id THEN
        RAISE EXCEPTION 'change_set % cannot be reviewed by its submitter', NEW.change_set_id
            USING errcode = '23514';
    END IF;

    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_validate_review
    BEFORE INSERT ON review
    FOR EACH ROW
    EXECUTE FUNCTION validate_review();

CREATE OR REPLACE FUNCTION sync_change_set_status_from_review()
    RETURNS TRIGGER
    LANGUAGE plpgsql
    AS $$
BEGIN
    UPDATE
        change_set
    SET
        status = CASE NEW.decision
            WHEN 'approved' THEN 'approved'::change_set_status
            WHEN 'rejected' THEN 'rejected'::change_set_status
        END
    WHERE
        id = NEW.change_set_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'failed to synchronize change_set % from review %', NEW.change_set_id, NEW.id
            USING errcode = '23503';
    END IF;

    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_sync_change_set_status_from_review
    AFTER INSERT ON review
    FOR EACH ROW
    EXECUTE FUNCTION sync_change_set_status_from_review();
