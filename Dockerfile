#
# Licensed to the Apache Software Foundation (ASF) under one or more
# contributor license agreements.  See the NOTICE file distributed with
# this work for additional information regarding copyright ownership.
# The ASF licenses this file to You under the Apache License, Version 2.0
# (the "License"); you may not use this file except in compliance with
# the License.  You may obtain a copy of the License at
#
#    http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#

######################################################################
# Node stage to deal with static asset construction
######################################################################
ARG PY_VER=3.9-slim-bookworm

# if BUILDPLATFORM is null, set it to 'amd64' (or leave as is otherwise).
ARG BUILDPLATFORM=${BUILDPLATFORM:-amd64}
FROM --platform=${BUILDPLATFORM} node:16-slim AS superset-node

ARG NPM_BUILD_CMD="build"
ENV BUILD_CMD=${NPM_BUILD_CMD}
ENV PUPPETEER_SKIP_CHROMIUM_DOWNLOAD=true

# NPM ci first, as to NOT invalidate previous steps except for when package.json changes
WORKDIR /app/superset-frontend

COPY ./docker/frontend-mem-nag.sh /

RUN /frontend-mem-nag.sh

COPY superset-frontend/package*.json ./

RUN npm ci

COPY ./superset-frontend ./

# This seems to be the most expensive step
RUN npm run ${BUILD_CMD}

######################################################################
# Final lean image...
######################################################################
FROM python:${PY_VER} AS lean

WORKDIR /app
ENV LANG=C.UTF-8 \
    LC_ALL=C.UTF-8 \
    FLASK_ENV=production \
    FLASK_APP="superset.app:create_app()" \
    PYTHONPATH="/app/pythonpath" \
    SUPERSET_HOME="/app/superset_home" \
    SUPERSET_PORT=8088

RUN mkdir -p ${PYTHONPATH} \
    && useradd --user-group -d ${SUPERSET_HOME} -m --no-log-init --shell /bin/bash superset \
    && apt-get update -q \
    && apt-get install -yq --no-install-recommends \
        build-essential \
        curl \
        default-libmysqlclient-dev \
        libsasl2-dev \
        libsasl2-modules-gssapi-mit \
        libpq-dev \
        libecpg-dev \
        libldap2-dev \
    && rm -rf /var/lib/apt/lists/*

COPY --chown=superset:superset ./requirements/*.txt  requirements/
COPY --chown=superset:superset setup.py MANIFEST.in README.md ./
# setup.py uses the version information in package.json
COPY --chown=superset:superset superset-frontend/package.json superset-frontend/

RUN mkdir -p superset/static \
    && touch superset/static/version_info.json \
    && pip install --no-cache-dir -r requirements/local.txt

COPY --chown=superset:superset --from=superset-node /app/superset/static/assets superset/static/assets
## Lastly, let's install superset itself
COPY --chown=superset:superset superset superset

RUN chown -R superset:superset ./* \
    && pip install --no-cache-dir -e . \
    && flask fab babel-compile --target superset/translations

COPY --chmod=755 ./docker/run-server.sh /usr/bin/
USER superset

HEALTHCHECK CMD curl -f "http://localhost:$SUPERSET_PORT/health"

EXPOSE ${SUPERSET_PORT}

CMD ["/usr/bin/run-server.sh"]

######################################################################
# Dev image...
######################################################################
FROM lean AS dev
ARG GECKODRIVER_VERSION=v0.32.0
ARG FIREFOX_VERSION=106.0.3

USER root

RUN apt-get update -q \
    && apt-get install -yq --no-install-recommends \
        libnss3 \
        libdbus-glib-1-2 \
        libgtk-3-0 \
        libx11-xcb1 \
        libasound2 \
        libxtst6 \
        wget \
    # Install GeckoDriver WebDriver
    && wget https://github.com/mozilla/geckodriver/releases/download/${GECKODRIVER_VERSION}/geckodriver-${GECKODRIVER_VERSION}-linux64.tar.gz -O - | tar xfz - -C /usr/local/bin \
    # Install Firefox
    && wget https://download-installer.cdn.mozilla.net/pub/firefox/releases/${FIREFOX_VERSION}/linux-x86_64/en-US/firefox-${FIREFOX_VERSION}.tar.bz2 -O - | tar xfj - -C /opt \
    && ln -s /opt/firefox/firefox /usr/local/bin/firefox \
    && apt-get autoremove -yqq --purge wget && rm -rf /var/lib/apt/lists/* && apt-get clean

COPY ./requirements/*.txt ./docker/requirements-*.txt/ /app/requirements/
# Cache everything for dev purposes...
RUN pip install --no-cache-dir -r /app/requirements/docker.txt \
    && pip install --no-cache-dir -r /app/requirements/requirements-local.txt || true

USER superset
######################################################################
# CI image...
######################################################################
FROM lean AS ci

COPY --chown=superset --chmod=755 ./docker/*.sh /app/docker/

CMD ["/app/docker/docker-ci.sh"]
