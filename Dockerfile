# syntax=docker/dockerfile:1.7
#
# CodeLift reproduction environment for Laravel runtime errors.
#
# Each scenario is reproduced from a clean app inside this container, so a
# result can never be an artifact of somebody's local setup. curl runs in the
# same container as the server: no host networking, no port collisions.
#
FROM php:8.4-cli-bookworm

ENV DEBIAN_FRONTEND=noninteractive \
    TZ=UTC \
    COMPOSER_ALLOW_SUPERUSER=1 \
    COMPOSER_NO_INTERACTION=1

RUN apt-get update && apt-get install -y --no-install-recommends \
        git unzip zip curl ca-certificates procps \
        libzip-dev libicu-dev \
        sqlite3 libsqlite3-dev \
    && docker-php-ext-install -j"$(nproc)" bcmath intl pdo_sqlite zip \
    && rm -rf /var/lib/apt/lists/*

COPY --from=composer:2 /usr/bin/composer /usr/bin/composer

WORKDIR /lab

CMD ["bash"]
