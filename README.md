# PostgreSQL Database

This image contains the PostgreSQL database schema and a command for
synchronizing an existing database.

## File structure

```text
.
├── Dockerfile
├── scripts
│   └── schema-sync
└── scheme
    └── 01-core.sql
```

All `.sql` files under `scheme/` describe the desired database structure.

Additional files can be added:

```text
scheme/
├── 01-core.sql
├── 02-review.sql
└── 03-audit.sql
```

Files are processed in filename order.

## Schema synchronization

After changing a file under `scheme/`, rebuild and restart the container:

```bash
docker compose up --build -d postgres
```

### Preview changes

Show the SQL required to update the current database:

```bash
docker compose exec postgres schema-sync diff
```

### Apply changes

Apply the generated schema changes:

```bash
docker compose exec postgres schema-sync apply
```

### Check for differences

Check whether the current database matches the schema files:

```bash
docker compose exec postgres schema-sync check
```

### Allow destructive changes

Dropping tables, columns, or other objects is disabled by default.

Preview destructive changes:

```bash
docker compose exec postgres schema-sync diff --enable-drop
```

Apply them:

```bash
docker compose exec postgres schema-sync apply --enable-drop
```

Use `--enable-drop` carefully because it can permanently remove data.

## Review and audit model

The canonical domain tables remain strongly typed. Proposed changes and audit
history use generic entity/field records so the same workflow can be reused for
content, creators, accounts, users, tags, and their relationships.

- `02-review.sql` defines workspaces, change sets, field-level proposals, and
  immutable maintainer reviews.
- `03-audit.sql` defines append-only audit events and generic audit triggers.
- Mutable canonical entities use database-owned `revision` values for optimistic
  concurrency checks.

Every mutation of an audited canonical table requires transaction-local audit
context. Set it in the same transaction before writing canonical data:

```sql
BEGIN;

SELECT set_audit_context(
    'authentik',
    NULL,
    NULL,
    NULL
);

UPDATE app_user
SET username = 'new-name'
WHERE id = '00000000-0000-0000-0000-000000000000';

COMMIT;
```

Publishing an approved review uses the same mechanism and links resulting audit
events to the review:

```sql
BEGIN;

SELECT set_audit_context(
    'review_publish',
    '11111111-1111-1111-1111-111111111111',
    '22222222-2222-2222-2222-222222222222',
    NULL
);

UPDATE content
SET title = 'Reviewed title'
WHERE id = '33333333-3333-3333-3333-333333333333'
  AND revision = 4;

COMMIT;
```

The application supplies the reason for a mutation; PostgreSQL creates the audit
records. This prevents individual update implementations from having to remember
to write audit history themselves.
