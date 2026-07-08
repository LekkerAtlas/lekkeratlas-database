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
├── 02-indexes.sql
└── 03-views.sql
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
