FROM sqldef/psqldef:3.11 AS psqldef

FROM postgres:16-alpine

COPY --from=psqldef /usr/local/bin/sqldef /usr/local/bin/psqldef

COPY ./scheme /docker-entrypoint-initdb.d/
COPY ./scripts/schema-sync /usr/local/bin/schema-sync

RUN chmod +x /usr/local/bin/schema-sync
