FROM postgres:16-alpine

COPY ./scheme /docker-entrypoint-initdb.d/