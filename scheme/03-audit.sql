-- ---------------------------------------------------------------------------
-- Audit enums
-- ---------------------------------------------------------------------------
CREATE TYPE audit_operation AS enum(
    'create',
    'update',
    'delete'
);

CREATE TYPE audit_source AS enum(
    'user',
    'review_publish',
    'worker',
    'authentik',
    'system',
    'migration'
);

-- ---------------------------------------------------------------------------
-- Append-only audit history
-- ---------------------------------------------------------------------------
-- audit_event describes one actual canonical mutation. It is intentionally
-- separate from proposed changes: an Authentik username sync has an audit event
-- but no review, while an approved content edit links back to its review.
CREATE TABLE audit_event(
    id            uuid PRIMARY KEY              DEFAULT gen_random_uuid(),
    entity_type   auditable_entity_type NOT NULL,
    entity_id     uuid                 NOT NULL,
    operation     audit_operation      NOT NULL,
    source        audit_source         NOT NULL,
    actor_user_id uuid                 REFERENCES app_user (id) ON DELETE SET NULL,
    review_id     uuid                 REFERENCES review (id) ON DELETE RESTRICT,
    queue_job_id  uuid                 REFERENCES queue_job (id) ON DELETE SET NULL,
    before_data   jsonb,
    after_data    jsonb,
    created_at    timestamptz          NOT NULL DEFAULT now(),
    CONSTRAINT audit_event_snapshot_shape_check CHECK (
        (operation = 'create' AND before_data IS NULL AND after_data IS NOT NULL)
        OR
        (operation = 'update' AND before_data IS NOT NULL AND after_data IS NOT NULL)
        OR
        (operation = 'delete' AND before_data IS NOT NULL AND after_data IS NULL)
    ),
    CONSTRAINT audit_event_review_source_check CHECK (
        (source = 'review_publish' AND review_id IS NOT NULL)
        OR
        (source <> 'review_publish' AND review_id IS NULL)
    )
);

CREATE INDEX idx_audit_event_entity_created_at ON audit_event(entity_type, entity_id, created_at DESC);

CREATE INDEX idx_audit_event_review_id ON audit_event(review_id)
WHERE
    review_id IS NOT NULL;

CREATE INDEX idx_audit_event_queue_job_id ON audit_event(queue_job_id)
WHERE
    queue_job_id IS NOT NULL;

-- Derived field changes make review/history UIs and field-specific searches
-- cheap while audit_event retains complete meaningful before/after snapshots.
CREATE TABLE audit_field_change(
    id             uuid PRIMARY KEY          DEFAULT gen_random_uuid(),
    audit_event_id uuid             NOT NULL REFERENCES audit_event (id) ON DELETE CASCADE,
    field_name     varchar(100)     NOT NULL,
    old_value      jsonb,
    new_value      jsonb,
    CONSTRAINT audit_field_change_event_field_key UNIQUE (audit_event_id, field_name)
);

CREATE INDEX idx_audit_field_change_field_name ON audit_field_change(field_name);

-- ---------------------------------------------------------------------------
-- Transaction-local audit context
-- ---------------------------------------------------------------------------
-- Application code only declares WHY a transaction is mutating canonical data.
-- The database remains responsible for producing the audit records themselves.
CREATE OR REPLACE FUNCTION set_audit_context(
    source audit_source,
    actor_user_id uuid DEFAULT NULL,
    review_id uuid DEFAULT NULL,
    queue_job_id uuid DEFAULT NULL)
    RETURNS void
    LANGUAGE plpgsql
    AS $$
BEGIN
    PERFORM set_config('app.audit.source', source::text, true);
    PERFORM set_config('app.audit.actor_user_id', COALESCE(actor_user_id::text, ''), true);
    PERFORM set_config('app.audit.review_id', COALESCE(review_id::text, ''), true);
    PERFORM set_config('app.audit.queue_job_id', COALESCE(queue_job_id::text, ''), true);
END;
$$;

CREATE OR REPLACE FUNCTION clear_audit_context()
    RETURNS void
    LANGUAGE plpgsql
    AS $$
BEGIN
    PERFORM set_config('app.audit.source', '', true);
    PERFORM set_config('app.audit.actor_user_id', '', true);
    PERFORM set_config('app.audit.review_id', '', true);
    PERFORM set_config('app.audit.queue_job_id', '', true);
END;
$$;

-- ---------------------------------------------------------------------------
-- Generic audit trigger
-- ---------------------------------------------------------------------------
-- Usage:
--   EXECUTE FUNCTION audit_row_change(
--       'content', 'id', 'revision', 'created_at', 'updated_at');
--
-- TG_ARGV[0] is the auditable entity type. Remaining arguments are technical
-- fields that should not appear in snapshots or field-level history.
CREATE OR REPLACE FUNCTION audit_row_change()
    RETURNS TRIGGER
    LANGUAGE plpgsql
    AS $$
DECLARE
    entity_type_value auditable_entity_type;
    source_setting text;
    source_value audit_source;
    actor_user_id_value uuid;
    review_id_value uuid;
    queue_job_id_value uuid;
    ignored_fields text[] := ARRAY[]::text[];
    old_data jsonb;
    new_data jsonb;
    audit_event_id uuid;
    argument_index integer;
BEGIN
    IF TG_NARGS < 1 THEN
        RAISE EXCEPTION 'audit_row_change requires an auditable entity type argument';
    END IF;

    entity_type_value := TG_ARGV[0]::auditable_entity_type;

    source_setting := NULLIF(current_setting('app.audit.source', true), '');
    IF source_setting IS NULL THEN
        RAISE EXCEPTION 'audited mutation on %.% requires transaction-local audit context', TG_TABLE_SCHEMA, TG_TABLE_NAME
            USING hint = 'Call set_audit_context(...) in the same transaction before mutating canonical data.';
    END IF;

    source_value := source_setting::audit_source;
    actor_user_id_value := NULLIF(current_setting('app.audit.actor_user_id', true), '')::uuid;
    review_id_value := NULLIF(current_setting('app.audit.review_id', true), '')::uuid;
    queue_job_id_value := NULLIF(current_setting('app.audit.queue_job_id', true), '')::uuid;

    IF source_value = 'user' AND actor_user_id_value IS NULL THEN
        RAISE EXCEPTION 'user-originated audited mutation requires actor_user_id';
    END IF;

    IF source_value = 'review_publish' THEN
        IF review_id_value IS NULL THEN
            RAISE EXCEPTION 'review_publish audited mutation requires review_id';
        END IF;

        PERFORM 1
        FROM review
        INNER JOIN change_set ON change_set.id = review.change_set_id
        WHERE
            review.id = review_id_value
            AND review.decision = 'approved'
            AND change_set.status IN ('approved', 'published');

        IF NOT FOUND THEN
            RAISE EXCEPTION 'review % is not an approved publishable review', review_id_value
                USING errcode = '23514';
        END IF;
    END IF;

    IF TG_NARGS > 1 THEN
        FOR argument_index IN 1..TG_NARGS - 1 LOOP
            ignored_fields := array_append(ignored_fields, TG_ARGV[argument_index]);
        END LOOP;
    END IF;

    IF TG_OP IN ('UPDATE', 'DELETE') THEN
        old_data := to_jsonb(OLD) - ignored_fields;
    END IF;

    IF TG_OP IN ('INSERT', 'UPDATE') THEN
        new_data := to_jsonb(NEW) - ignored_fields;
    END IF;

    -- Do not create an audit entry when only ignored/technical fields changed.
    IF TG_OP = 'UPDATE' AND old_data = new_data THEN
        RETURN NEW;
    END IF;

    INSERT INTO audit_event(
        entity_type,
        entity_id,
        operation,
        source,
        actor_user_id,
        review_id,
        queue_job_id,
        before_data,
        after_data)
    VALUES(
        entity_type_value,
        CASE WHEN TG_OP = 'DELETE' THEN OLD.id ELSE NEW.id END,
        CASE TG_OP
            WHEN 'INSERT' THEN 'create'::audit_operation
            WHEN 'UPDATE' THEN 'update'::audit_operation
            WHEN 'DELETE' THEN 'delete'::audit_operation
        END,
        source_value,
        actor_user_id_value,
        review_id_value,
        queue_job_id_value,
        old_data,
        new_data)
    RETURNING id INTO audit_event_id;

    INSERT INTO audit_field_change(
        audit_event_id,
        field_name,
        old_value,
        new_value)
    SELECT
        audit_event_id,
        changed_keys.key,
        old_data -> changed_keys.key,
        new_data -> changed_keys.key
    FROM (
        SELECT key
        FROM jsonb_object_keys(COALESCE(old_data, '{}'::jsonb)) AS old_keys(key)
        UNION
        SELECT key
        FROM jsonb_object_keys(COALESCE(new_data, '{}'::jsonb)) AS new_keys(key)
    ) AS changed_keys
    WHERE
        (old_data -> changed_keys.key) IS DISTINCT FROM (new_data -> changed_keys.key);

    RETURN CASE WHEN TG_OP = 'DELETE' THEN OLD ELSE NEW END;
END;
$$;

-- ---------------------------------------------------------------------------
-- Immutable history protection
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION prevent_history_mutation()
    RETURNS TRIGGER
    LANGUAGE plpgsql
    AS $$
BEGIN
    RAISE EXCEPTION '% is append-only and cannot be changed with %', TG_TABLE_NAME, lower(TG_OP);
END;
$$;

CREATE TRIGGER trg_prevent_audit_event_mutation
    BEFORE UPDATE OR DELETE ON audit_event
    FOR EACH ROW
    EXECUTE FUNCTION prevent_history_mutation();

CREATE TRIGGER trg_prevent_audit_field_change_mutation
    BEFORE UPDATE OR DELETE ON audit_field_change
    FOR EACH ROW
    EXECUTE FUNCTION prevent_history_mutation();

CREATE TRIGGER trg_prevent_review_mutation
    BEFORE UPDATE OR DELETE ON review
    FOR EACH ROW
    EXECUTE FUNCTION prevent_history_mutation();

-- ---------------------------------------------------------------------------
-- Canonical audit triggers
-- ---------------------------------------------------------------------------
-- id and technical timestamp/revision fields are excluded from user-facing
-- diffs. All meaningful domain values are captured automatically.
CREATE TRIGGER trg_audit_app_user
    AFTER INSERT OR UPDATE OR DELETE ON app_user
    FOR EACH ROW
    EXECUTE FUNCTION audit_row_change(
        'app_user',
        'id',
        'date_joined',
        'last_updated',
        'last_login');

CREATE TRIGGER trg_audit_creator
    AFTER INSERT OR UPDATE OR DELETE ON creator
    FOR EACH ROW
    EXECUTE FUNCTION audit_row_change(
        'creator',
        'id',
        'revision',
        'created_at',
        'updated_at');

CREATE TRIGGER trg_audit_creator_account
    AFTER INSERT OR UPDATE OR DELETE ON creator_account
    FOR EACH ROW
    EXECUTE FUNCTION audit_row_change(
        'creator_account',
        'id',
        'revision',
        'created_at',
        'updated_at');

CREATE TRIGGER trg_audit_content
    AFTER INSERT OR UPDATE OR DELETE ON content
    FOR EACH ROW
    EXECUTE FUNCTION audit_row_change(
        'content',
        'id',
        'revision',
        'created_at',
        'updated_at');

CREATE TRIGGER trg_audit_hosted_content
    AFTER INSERT OR UPDATE OR DELETE ON hosted_content
    FOR EACH ROW
    EXECUTE FUNCTION audit_row_change(
        'hosted_content',
        'id',
        'revision',
        'created_at',
        'updated_at');

CREATE TRIGGER trg_audit_tag
    AFTER INSERT OR UPDATE OR DELETE ON tag
    FOR EACH ROW
    EXECUTE FUNCTION audit_row_change(
        'tag',
        'id',
        'revision',
        'created_at',
        'updated_at');

CREATE TRIGGER trg_audit_content_tag
    AFTER INSERT OR UPDATE OR DELETE ON content_tag
    FOR EACH ROW
    EXECUTE FUNCTION audit_row_change(
        'content_tag',
        'id',
        'created_at');
