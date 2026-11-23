ARG BASE_IMAGE=docker/sandbox-templates:shell@sha256:7a248c96459694d181d9d51ffc9e530c0b9a4cb3d1887cc070425336b1fb5115

FROM ${BASE_IMAGE} AS sqlite-builder

ARG SQLITE_URL=https://sqlite.org/2026/sqlite-autoconf-3540100.tar.gz
ARG SQLITE_SHA256=926ef8d3eab93fbf6e06011901273eec076b25594a4e1cdadd50c987f4f6d64e

WORKDIR /tmp/sqlite-src

RUN curl -fsSL -o sqlite.tar.gz "${SQLITE_URL}"

RUN printf '%s  %s\n' "${SQLITE_SHA256}" sqlite.tar.gz > sqlite.sha256 && sha256sum -c sqlite.sha256

RUN tar -xzf sqlite.tar.gz --strip-components=1

USER root

RUN apt-get update \
    && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        build-essential \
    && rm -rf /var/lib/apt/lists/*

# Enable the SQLite features Hermes uses. A bare configure omits FTS5.

RUN CFLAGS="-O2 -DSQLITE_ENABLE_FTS3 -DSQLITE_ENABLE_FTS3_PARENTHESIS -DSQLITE_ENABLE_FTS4 -DSQLITE_ENABLE_FTS5 -DSQLITE_ENABLE_RTREE -DSQLITE_ENABLE_GEOPOLY -DSQLITE_ENABLE_COLUMN_METADATA -DSQLITE_ENABLE_UNLOCK_NOTIFY -DSQLITE_ENABLE_DBSTAT_VTAB -DSQLITE_ENABLE_DBPAGE_VTAB -DSQLITE_ENABLE_MATH_FUNCTIONS -DSQLITE_ENABLE_PREUPDATE_HOOK -DSQLITE_ENABLE_SESSION -DSQLITE_SECURE_DELETE -DSQLITE_THREADSAFE=1 -DSQLITE_MAX_VARIABLE_NUMBER=250000" ./configure --prefix=/usr/local --disable-static >/dev/null

RUN make -j"$(nproc)" >/dev/null && make install >/dev/null

FROM ${BASE_IMAGE}

ARG HERMES_REF=main
ARG CODEX_VERSION=0.171.0

COPY --chmod=0755 docker-entrypoint.sh /usr/local/bin/hermes-entrypoint

USER root

# The base sets npm's global prefix to /usr/local/share/npm-global, but the
# image lacks its lib dir. npx then aborts and the browser install fails.

RUN mkdir -p /usr/local/share/npm-global/lib

RUN apt-get update \
    && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        build-essential \
        ffmpeg \
        tmux \
    && rm -rf /var/lib/apt/lists/*

# The pinned base is Ubuntu 26.04.1. That base still ships SQLite 3.46.1, and
# that build has the WAL-reset bug. Fixes land in 3.51.3+. Python resolves
# libsqlite3.so.0 at run time, so this newer build ahead of the multiarch
# path wins.

COPY --from=sqlite-builder /usr/local/lib/ /usr/local/lib/
COPY --from=sqlite-builder /usr/local/bin/sqlite3 /usr/local/bin/sqlite3

# libc.conf lists /usr/local/lib after the multiarch path. The 00- prefix
# makes this file sort first, so the copied SQLite loads instead.

RUN echo /usr/local/lib > /etc/ld.so.conf.d/00-local-lib.conf && ldconfig

# The version assert catches a stale library. The query catches a missing FTS5.

RUN python3 -c "exec('import sqlite3\nassert sqlite3.sqlite_version_info >= (3, 51, 3)')"
RUN sqlite3 :memory: "CREATE VIRTUAL TABLE docs USING fts5(c, tokenize='trigram')" "INSERT INTO docs VALUES ('hermes')" "SELECT count(*) FROM docs WHERE docs MATCH 'erm'"

# Log lines reach the container log without buffering delays.

ENV PYTHONUNBUFFERED=1

RUN mkdir -p /home/agent/.hermes /home/agent/.local/bin \
    && chown -R agent:agent /home/agent/.hermes /home/agent/.local

USER agent
ENV HOME=/home/agent
ENV PATH="/home/agent/.local/bin:${PATH}"
WORKDIR /home/agent

RUN curl -fsSL "https://raw.githubusercontent.com/NousResearch/hermes-agent/${HERMES_REF}/scripts/install.sh" \
    | bash -s -- --skip-setup --branch "${HERMES_REF}" --dir /home/agent/hermes-agent \
    && rm -rf /home/agent/.npm /home/agent/.cache/uv

# Set CODEX_VERSION empty to skip the Codex CLI and its 442MB layer.

RUN [ -z "${CODEX_VERSION}" ] || npm install -g --prefix /home/agent/.local @openai/codex@${CODEX_VERSION} \
    && rm -rf /home/agent/.npm

RUN HERMES_HOME=/home/agent/.hermes HOME=/home/agent hermes skills list >/dev/null

# Hermes runs the venv interpreter, which bundles its own SQLite.
# The floor must hold there too, or the guard above means nothing.

RUN /home/agent/hermes-agent/venv/bin/python -c "exec('import sqlite3\nassert sqlite3.sqlite_version_info >= (3, 51, 3)')"

# Fail the build when the Chromium download did not land in the agent cache.

RUN test -n "$(find /home/agent/.cache/ms-playwright -name chrome -type f -print -quit)"

USER root

RUN mkdir -p /usr/local/share/hermes-home \
    && cp -a /home/agent/.hermes/. /usr/local/share/hermes-home/ \
    && chown -R agent:agent /usr/local/share/hermes-home

USER agent
WORKDIR /home/agent/workspace
VOLUME ["/home/agent/.hermes"]
ENTRYPOINT ["/usr/local/bin/hermes-entrypoint"]
