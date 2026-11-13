#!/usr/bin/env bash

set -euo pipefail

readonly ENV_FILE="/var/www/html/.env"
readonly TEMP_ENV_FILE="$(mktemp "${ENV_FILE}.XXXXXX")"

cleanup() {
    rm -f "${TEMP_ENV_FILE}"
}

trap cleanup EXIT

: "${INFISICAL_TOKEN:?INFISICAL_TOKEN must be set}"
: "${INFISICAL_PROJECT_ID:?INFISICAL_PROJECT_ID must be set}"
: "${INFISICAL_ENVIRONMENT:?INFISICAL_ENVIRONMENT must be set}"


infisical_args=(
    export
    "--token=${INFISICAL_TOKEN}"
    "--projectId=${INFISICAL_PROJECT_ID}"
    "--env=${INFISICAL_ENVIRONMENT}"
    "--format=dotenv"
)

if [[ -n "${INFISICAL_DOMAIN:-}" ]]; then
    infisical_args+=("--domain=${INFISICAL_DOMAIN}")
fi

echo "Fetching application secrets from Infisical..."
if ! infisical "${infisical_args[@]}" > "${TEMP_ENV_FILE}"; then
    echo "Unable to fetch application secrets from Infisical." >&2
    exit 1
fi

install -o www-data -g www-data -m 0640 "${TEMP_ENV_FILE}" "${ENV_FILE}"
echo "Application secrets written to ${ENV_FILE}."

unset INFISICAL_TOKEN

exec "$@"
