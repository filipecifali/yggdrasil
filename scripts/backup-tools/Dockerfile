FROM alpine:3.21

# Install runtime utilities for backups:
# - curl: S3 / HTTP REST uploads
# - postgresql16-client: pg_dump and psql
# - age: modern asymmetric streaming encryption
# - ca-certificates: TLS root anchors
RUN apk add --no-cache \
    curl \
    postgresql16-client \
    age \
    ca-certificates

# Create unprivileged backup user (UID 10001) for strict Pod Security Standards
RUN addgroup -g 10001 backupgroup && \
    adduser -u 10001 -G backupgroup -s /bin/sh -D backupuser

USER 10001:10001

ENTRYPOINT ["/bin/sh"]
