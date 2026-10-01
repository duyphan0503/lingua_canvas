# syntax=docker/dockerfile:1
# ==============================================================================
# Lingua Canvas - Multi-stage Production Dockerfile for Rust Axum Server
# ==============================================================================

# ------------------------------------------------------------------------------
# Stage 1: Build stage
# ------------------------------------------------------------------------------
FROM rust:1.92-bookworm AS builder

WORKDIR /usr/src/server

# Copy dependency manifests for layer caching
COPY Cargo.toml Cargo.lock ./

# Copy migrations and source code
COPY migrations ./migrations
COPY src ./src

# Build release binary
RUN cargo build --release --bin server

# ------------------------------------------------------------------------------
# Stage 2: Minimal Runtime stage
# ------------------------------------------------------------------------------
FROM debian:bookworm-slim AS runtime

# Install CA certificates and curl for health checks
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        ca-certificates \
        curl && \
    rm -rf /var/lib/apt/lists/*

# Run as dedicated unprivileged user for security
RUN groupadd -r lingua && useradd -r -g lingua lingua

WORKDIR /app

# Copy binary and migrations from builder stage
COPY --from=builder /usr/src/server/target/release/server /app/server
COPY --from=builder /usr/src/server/migrations /app/migrations

# Secure permissions
RUN chown -R lingua:lingua /app

USER lingua

# Expose default Axum server port
EXPOSE 8080

# Environment defaults
ENV PORT=8080 \
    HOST=0.0.0.0 \
    RUST_LOG=info

# Container healthcheck against Axum health endpoint
HEALTHCHECK --interval=15s --timeout=5s --start-period=5s --retries=3 \
    CMD curl -f http://localhost:8080/api/v1/health || exit 1

ENTRYPOINT ["/app/server"]
