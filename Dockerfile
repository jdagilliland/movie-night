# Movie Night image (SPEC §12). Builds natively for the host architecture;
# on Apple Silicon and on GitHub's ARM runners that is linux/arm64, matching
# the Graviton instance.

# --- Build ---------------------------------------------------------------
# GHC 9.10.3 matches the Stackage snapshot in stack.yaml, so Stack uses the
# image's compiler instead of downloading its own.
FROM haskell:9.10.3-slim-bookworm AS build

# Extra CA certificates (*.crt) from docker/extra-ca-certs/, for building
# behind a TLS-intercepting proxy, where Stack's downloads from Hackage
# would otherwise fail. Only this build stage trusts them; the runtime image
# below starts fresh. Without any certificates this step changes nothing.
COPY docker/extra-ca-certs/ /usr/local/share/ca-certificates/extra/
RUN update-ca-certificates

WORKDIR /src

# Dependencies first, so this layer is reused until the dependency set
# changes.
COPY stack.yaml stack.yaml.lock movie-night.cabal ./
RUN stack build --system-ghc --no-install-ghc --only-dependencies

COPY app app
COPY src src
COPY static static
COPY docs docs
RUN stack install --system-ghc --no-install-ghc --local-bin-path /out

# --- Runtime -------------------------------------------------------------
FROM debian:bookworm-slim

# libgmp is GHC's bignum backend. SQLite is compiled into the binary.
RUN apt-get update \
 && apt-get install -y --no-install-recommends libgmp10 \
 && rm -rf /var/lib/apt/lists/*

# A fixed, unprivileged UID and GID, so the host's data directory can be
# owned by them (see README, "Deployment").
RUN groupadd --system --gid 10001 movienight \
 && useradd --system --uid 10001 --gid 10001 --home-dir /data --no-create-home movienight

COPY --from=build /out/movie-night /usr/local/bin/movie-night

# All timestamps, including request logs, are UTC (SPEC §8).
ENV TZ=UTC \
    PORT=8080 \
    DB_PATH=/data/db/pastes.db \
    AUTH_USERS_FILE=/data/users \
    TAKEDOWN_LOG=/data/logs/takedowns.log

USER movienight
VOLUME /data
EXPOSE 8080

ENTRYPOINT ["movie-night"]
CMD ["serve"]
