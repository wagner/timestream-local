# Gems are compiled in a builder (nio4r and xxhash, plus sqlite3 where no
# precompiled platform gem applies) so the runtime image needs no toolchain.
FROM ruby:3.3-slim AS builder

# Frozen, against a committed lockfile: a tagged image has to install the same
# gem versions whenever it is rebuilt. Resolving at build time would make
# v1.0.0 mean something different six months from now.
ENV BUNDLE_WITHOUT="development:test" \
    BUNDLE_PATH=/usr/local/bundle \
    BUNDLE_FROZEN=true

RUN apt-get update \
    && apt-get install -y --no-install-recommends build-essential \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app
COPY Gemfile Gemfile.lock ./
RUN bundle install --retry 3 \
    && rm -rf /usr/local/bundle/cache /usr/local/bundle/ruby/*/cache

FROM ruby:3.3-slim

ENV BUNDLE_WITHOUT="development:test" \
    BUNDLE_PATH=/usr/local/bundle \
    TIMESTREAM_LOCAL_HOST=0.0.0.0 \
    TIMESTREAM_LOCAL_PORT=8080 \
    TIMESTREAM_LOCAL_DATA=/data/timestream.db

# Links the published package to its repository, which is what makes a GitHub
# Container Registry package inherit the repo's visibility rather than default
# to public.
ARG VERSION=dev
LABEL org.opencontainers.image.title="timestream-local" \
      org.opencontainers.image.description="A local stand-in for Amazon Timestream, speaking the real Write and Query APIs" \
      org.opencontainers.image.source="https://github.com/wagner/timestream-local" \
      org.opencontainers.image.licenses="MIT" \
      org.opencontainers.image.version="${VERSION}"

WORKDIR /app

COPY --from=builder /usr/local/bundle /usr/local/bundle
# Both are needed at boot: without the lockfile bundler re-resolves the whole
# Gemfile, which fails because the test-only gems are not installed here.
COPY Gemfile Gemfile.lock ./
COPY lib ./lib
COPY bin ./bin

RUN useradd --create-home --shell /usr/sbin/nologin timestream \
    && mkdir -p /data \
    && chown -R timestream:timestream /data /app

USER timestream
VOLUME ["/data"]
EXPOSE 8080

# Bash rather than Ruby: booting the interpreter and requiring net/http costs
# ~280ms a probe against ~28ms here, and at a 10s interval that is the single
# largest CPU cost of an idle container. Bash is Essential in Debian, so its
# /dev/tcp needs nothing added to the slim base -- curl and nc are absent.
HEALTHCHECK --interval=10s --timeout=3s --start-period=5s --retries=3 \
  CMD ["bash", "-c", "exec 3<>/dev/tcp/127.0.0.1/${TIMESTREAM_LOCAL_PORT:-8080} && printf 'GET /health HTTP/1.0\\r\\nHost: localhost\\r\\n\\r\\n' >&3 && read -r line <&3 && [[ $line == 'HTTP/1.'[01]' 200 '* ]]"]

CMD ["bundle", "exec", "ruby", "bin/timestream-local"]
