# Production deployment review bundle

This Compose stack is a deployment template for review. It has not been deployed
or load-tested. Build the web assets with the pinned Flutter SDK before building
the images:

```sh
cd app
../tools/flutter --no-version-check build web --no-pub --release --no-web-resources-cdn --pwa-strategy=none
cd ..
```

Create protected secret files through the host's secret manager, outside this
repository. `LINGUA_DATABASE_URL_FILE` must contain a PostgreSQL URL whose
password matches `LINGUA_POSTGRES_PASSWORD_FILE`. The TLS files must contain a
certificate chain and matching private key. Set the four `LINGUA_*_FILE`
variables in the deployment environment, then validate without starting
services:

```sh
docker compose -f deploy/production/compose.yaml config --quiet
```

The server reads the URL from `DATABASE_URL_FILE`; a configured file that cannot
be read causes startup to fail instead of silently using the in-memory store.
The database and Redis have no published host ports. Only the TLS proxy is
public. PostgreSQL and Redis volumes require tested backup and restore
procedures. Keep the secret files out of the Git checkout and rotate them with
the corresponding application configuration.

The proxy terminates TLS 1.2/1.3, redirects HTTP to HTTPS, applies response
security headers and a bounded auth-route request limit, and disables response
buffering for API streaming. Its IP limit assumes direct client connections;
if another proxy sits in front, configure trusted real-client IPs explicitly
before exposing this stack. The application also enforces its own credential
limits and does not trust forwarding headers for identity.

Replace mutable container tags with reviewed image digests for a release, pin
the Rust builder and Nginx base images, configure the real AI provider endpoint,
and complete TLS renewal, database restore, monitoring, resource limits, and
incident procedures before production use. No command in this guide deploys the
stack.
