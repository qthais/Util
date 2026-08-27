#!/usr/bin/env bash

set -uo pipefail

###############################################################################
# Elasticsearch 6 -> Elasticsearch 9
#
# Usage:
#   ./migrate-security-users.sh \
#     "$ES6_USER" "$ES6_PASS" "$ES6_URL" \
#     "$ES9_USER" "$ES9_PASS" "$ES9_URL"
#
# Requirements:
#   - curl
#   - jq
#
# Migration:
#   1. Read custom roles from ES6 .security-6
#   2. Create/update roles on ES9
#   3. Read users from ES6 .security-6
#   4. Skip known system/built-in users
#   5. Create/update users on ES9
#   6. Verify migrated roles/users
#
# IMPORTANT:
#   Password hashes are NEVER printed to the log.
###############################################################################

SCRIPT_NAME="$(basename "$0")"

###############################################################################
# Colors
###############################################################################

if [[ -t 1 ]]; then
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[1;33m'
    BLUE='\033[0;34m'
    CYAN='\033[0;36m'
    BOLD='\033[1m'
    NC='\033[0m'
else
    RED=''
    GREEN=''
    YELLOW=''
    BLUE=''
    CYAN=''
    BOLD=''
    NC=''
fi

###############################################################################
# Logging
###############################################################################

log_info() {
    echo -e "${BLUE}[INFO]${NC} $*"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $*"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $*"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $*" >&2
}

log_step() {
    echo
    echo -e "${BOLD}${CYAN}============================================================${NC}"
    echo -e "${BOLD}${CYAN}$*${NC}"
    echo -e "${BOLD}${CYAN}============================================================${NC}"
}

###############################################################################
# Arguments
###############################################################################

if [[ $# -ne 6 ]]; then
    cat >&2 <<EOF

Usage:
  $SCRIPT_NAME \\
    "\$ES6_USER" "\$ES6_PASS" "\$ES6_URL" \\
    "\$ES9_USER" "\$ES9_PASS" "\$ES9_URL"

Example:
  $SCRIPT_NAME \\
    "\$ES6_USER" "\$ES6_PASS" "\$ES6_URL" \\
    "\$ES9_USER" "\$ES9_PASS" "\$ES9_URL"

EOF
    exit 1
fi

ES6_USER="$1"
ES6_PASS="$2"
ES6_URL="${3%/}"

ES9_USER="$4"
ES9_PASS="$5"
ES9_URL="${6%/}"

###############################################################################
# Dependencies
###############################################################################

for cmd in curl jq; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        log_error "Required command not found: $cmd"
        exit 1
    fi
done

###############################################################################
# Temporary files
###############################################################################

TMP_DIR="$(mktemp -d)"

cleanup() {
    rm -rf "$TMP_DIR"
}

trap cleanup EXIT

chmod 700 "$TMP_DIR"

ES6_ROLES_JSON="$TMP_DIR/es6_roles.json"
ES6_USERS_JSON="$TMP_DIR/es6_users.json"

###############################################################################
# Counters
###############################################################################

ROLES_TOTAL=0
ROLES_SUCCESS=0
ROLES_FAILED=0

USERS_TOTAL=0
USERS_SUCCESS=0
USERS_FAILED=0
USERS_SKIPPED=0

###############################################################################
# Known system / built-in users
#
# These users must NOT be migrated from ES6.
###############################################################################

is_system_user() {
    local username="$1"

    case "$username" in
        elastic)
            return 0
            ;;
        kibana)
            return 0
            ;;
        kibana_system)
            return 0
            ;;
        logstash_system)
            return 0
            ;;
        beats_system)
            return 0
            ;;
        apm_system)
            return 0
            ;;
        remote_monitoring_user)
            return 0
            ;;
        _xpack)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

###############################################################################
# HTTP helper
#
# Usage:
#   http_request METHOD URL USER PASS BODY OUTPUT_FILE
#
# Returns HTTP status code.
###############################################################################

http_request() {
    local method="$1"
    local url="$2"
    local user="$3"
    local pass="$4"
    local body="$5"
    local output="$6"

    local status

    if [[ -n "$body" ]]; then
        status="$(
            curl \
                -sS \
                -u "$user:$pass" \
                -X "$method" \
                -H 'Content-Type: application/json' \
                -o "$output" \
                -w '%{http_code}' \
                "$url" \
                -d "$body"
        )"
    else
        status="$(
            curl \
                -sS \
                -u "$user:$pass" \
                -X "$method" \
                -o "$output" \
                -w '%{http_code}' \
                "$url"
        )"
    fi

    echo "$status"
}

###############################################################################
# Test ES connections
###############################################################################

log_step "1. CHECK ELASTICSEARCH CONNECTIONS"

log_info "Checking Elasticsearch 6..."
ES6_TEST_FILE="$TMP_DIR/es6_test.json"

ES6_STATUS="$(
    curl \
        -sS \
        -u "$ES6_USER:$ES6_PASS" \
        -o "$ES6_TEST_FILE" \
        -w '%{http_code}' \
        "$ES6_URL/"
)"

if [[ "$ES6_STATUS" != "200" ]]; then
    log_error "Cannot connect/authenticate to ES6."
    log_error "HTTP status: $ES6_STATUS"
    cat "$ES6_TEST_FILE" >&2
    exit 1
fi

ES6_VERSION="$(jq -r '.version.number // "unknown"' "$ES6_TEST_FILE")"

log_success "ES6 connection OK - version: $ES6_VERSION"

log_info "Checking Elasticsearch 9..."
ES9_TEST_FILE="$TMP_DIR/es9_test.json"

ES9_STATUS="$(
    curl \
        -sS \
        -u "$ES9_USER:$ES9_PASS" \
        -o "$ES9_TEST_FILE" \
        -w '%{http_code}' \
        "$ES9_URL/"
)"

if [[ "$ES9_STATUS" != "200" ]]; then
    log_error "Cannot connect/authenticate to ES9."
    log_error "HTTP status: $ES9_STATUS"
    cat "$ES9_TEST_FILE" >&2
    exit 1
fi

ES9_VERSION="$(jq -r '.version.number // "unknown"' "$ES9_TEST_FILE")"

log_success "ES9 connection OK - version: $ES9_VERSION"

###############################################################################
# Fetch roles from ES6
###############################################################################

log_step "2. EXTRACT CUSTOM ROLES FROM ES6"

log_info "Reading roles from: $ES6_URL/.security-6"

ES6_ROLES_STATUS="$(
    curl \
        -sS \
        -u "$ES6_USER:$ES6_PASS" \
        -H 'Content-Type: application/json' \
        -o "$ES6_ROLES_JSON" \
        -w '%{http_code}' \
        "$ES6_URL/.security-6/_search" \
        -d '{
            "size": 10000,
            "query": {
                "term": {
                    "type": "role"
                }
            }
        }'
)"

if [[ "$ES6_ROLES_STATUS" != "200" ]]; then
    log_error "Failed to read roles from ES6."
    log_error "HTTP status: $ES6_ROLES_STATUS"
    cat "$ES6_ROLES_JSON" >&2
    exit 1
fi

ROLES_TOTAL="$(
    jq -r '.hits.hits | length' "$ES6_ROLES_JSON"
)"

log_success "Found $ROLES_TOTAL role(s) in ES6."

if [[ "$ROLES_TOTAL" -eq 0 ]]; then
    log_warn "No roles found. Continuing with user migration."
fi

###############################################################################
# Migrate roles
###############################################################################

log_step "3. MIGRATE ROLES ES6 -> ES9"

if [[ "$ROLES_TOTAL" -gt 0 ]]; then

    while IFS= read -r role_json; do

        ROLE_ID="$(jq -r '._id' <<< "$role_json")"

        # ES6 security documents use IDs such as:
        #   role-reader
        #   role-writer
        #   role-test_admin
        #
        # The actual role name is everything after "role-".
        ROLE_NAME="${ROLE_ID#role-}"

        ROLE_BODY="$(
            jq -c '._source |
                {
                    cluster,
                    indices,
                    applications,
                    run_as,
                    metadata
                }' <<< "$role_json"
        )"

        log_info "Migrating role: $ROLE_NAME"

        RESPONSE_FILE="$TMP_DIR/role_response.json"

        HTTP_STATUS="$(
            http_request \
                "PUT" \
                "$ES9_URL/_security/role/$ROLE_NAME" \
                "$ES9_USER" \
                "$ES9_PASS" \
                "$ROLE_BODY" \
                "$RESPONSE_FILE"
        )"

        if [[ "$HTTP_STATUS" =~ ^2[0-9][0-9]$ ]]; then
            ROLES_SUCCESS=$((ROLES_SUCCESS + 1))

            log_success \
                "Role '$ROLE_NAME' migrated successfully."

        else
            ROLES_FAILED=$((ROLES_FAILED + 1))

            log_error \
                "Failed to migrate role '$ROLE_NAME' (HTTP $HTTP_STATUS)."

            if jq empty "$RESPONSE_FILE" >/dev/null 2>&1; then
                jq '.' "$RESPONSE_FILE" >&2
            else
                cat "$RESPONSE_FILE" >&2
            fi
        fi

    done < <(
        jq -c '.hits.hits[]' "$ES6_ROLES_JSON"
    )
fi

###############################################################################
# Stop if role migration failed
#
# We don't want to create users referencing missing roles.
###############################################################################

if [[ "$ROLES_FAILED" -gt 0 ]]; then
    log_error \
        "$ROLES_FAILED role(s) failed to migrate."

    log_error \
        "User migration will NOT continue because users may reference missing roles."

    exit 1
fi

###############################################################################
# Fetch users from ES6
###############################################################################

log_step "4. EXTRACT CUSTOM USERS FROM ES6"

log_info "Reading users from: $ES6_URL/.security-6"

ES6_USERS_STATUS="$(
    curl \
        -sS \
        -u "$ES6_USER:$ES6_PASS" \
        -H 'Content-Type: application/json' \
        -o "$ES6_USERS_JSON" \
        -w '%{http_code}' \
        "$ES6_URL/.security-6/_search" \
        -d '{
            "size": 10000,
            "query": {
                "term": {
                    "type": "user"
                }
            }
        }'
)"

if [[ "$ES6_USERS_STATUS" != "200" ]]; then
    log_error "Failed to read users from ES6."
    log_error "HTTP status: $ES6_USERS_STATUS"
    cat "$ES6_USERS_JSON" >&2
    exit 1
fi

USERS_TOTAL="$(
    jq -r '.hits.hits | length' "$ES6_USERS_JSON"
)"

log_success "Found $USERS_TOTAL user document(s) in ES6."

###############################################################################
# Migrate users
###############################################################################

log_step "5. MIGRATE CUSTOM USERS ES6 -> ES9"

if [[ "$USERS_TOTAL" -gt 0 ]]; then

    while IFS= read -r user_json; do

        USERNAME="$(jq -r '._source.username // empty' <<< "$user_json")"

        if [[ -z "$USERNAME" ]]; then
            log_warn "Skipping user document without username."
            USERS_SKIPPED=$((USERS_SKIPPED + 1))
            continue
        fi

        #######################################################################
        # Skip system users
        #######################################################################

        if is_system_user "$USERNAME"; then
            log_warn \
                "Skipping system/built-in user: $USERNAME"

            USERS_SKIPPED=$((USERS_SKIPPED + 1))
            continue
        fi

        #######################################################################
        # Extract user fields
        #######################################################################

        PASSWORD_HASH="$(jq -r '._source.password // empty' <<< "$user_json")"

        ROLES_JSON="$(
            jq -c '._source.roles // []' <<< "$user_json"
        )"

        FULL_NAME_JSON="$(
            jq -c '._source.full_name // null' <<< "$user_json"
        )"

        EMAIL_JSON="$(
            jq -c '._source.email // null' <<< "$user_json"
        )"

        METADATA_JSON="$(
            jq -c '._source.metadata // {}' <<< "$user_json"
        )"

        ENABLED="$(
            jq -r '._source.enabled // true' <<< "$user_json"
        )"

        #######################################################################
        # Validate password hash
        #######################################################################

        if [[ -z "$PASSWORD_HASH" ]]; then
            log_error \
                "User '$USERNAME' has no password hash. Skipping."

            USERS_FAILED=$((USERS_FAILED + 1))
            continue
        fi

        #######################################################################
        # Show roles but NEVER show password hash
        #######################################################################

        ROLE_LIST="$(
            jq -r 'join(", ")' <<< "$ROLES_JSON"
        )"

        log_info \
            "Migrating user: $USERNAME"

        log_info \
            "  roles: [$ROLE_LIST]"

        log_info \
            "  enabled: $ENABLED"

        #######################################################################
        # Build ES9 user API body
        #
        # password_hash is intentionally used instead of password.
        #
        # This allows the existing ES6 password hash to be migrated without
        # knowing the plaintext password.
        #######################################################################

        USER_BODY="$(
            jq -cn \
                --arg password_hash "$PASSWORD_HASH" \
                --argjson roles "$ROLES_JSON" \
                --argjson full_name "$FULL_NAME_JSON" \
                --argjson email "$EMAIL_JSON" \
                --argjson metadata "$METADATA_JSON" \
                --argjson enabled "$ENABLED" \
                '{
                    password_hash: $password_hash,
                    roles: $roles,
                    full_name: $full_name,
                    email: $email,
                    metadata: $metadata,
                    enabled: $enabled
                }'
        )"

        #######################################################################
        # Create/update user on ES9
        #######################################################################

        RESPONSE_FILE="$TMP_DIR/user_response.json"

        HTTP_STATUS="$(
            http_request \
                "PUT" \
                "$ES9_URL/_security/user/$USERNAME" \
                "$ES9_USER" \
                "$ES9_PASS" \
                "$USER_BODY" \
                "$RESPONSE_FILE"
        )"

        if [[ "$HTTP_STATUS" =~ ^2[0-9][0-9]$ ]]; then

            USERS_SUCCESS=$((USERS_SUCCESS + 1))

            CREATED="$(
                jq -r '.created // "unknown"' "$RESPONSE_FILE" 2>/dev/null
            )"

            if [[ "$CREATED" == "true" ]]; then
                log_success \
                    "User '$USERNAME' CREATED successfully."
            elif [[ "$CREATED" == "false" ]]; then
                log_success \
                    "User '$USERNAME' UPDATED successfully."
            else
                log_success \
                    "User '$USERNAME' migrated successfully."
            fi

        else

            USERS_FAILED=$((USERS_FAILED + 1))

            log_error \
                "Failed to migrate user '$USERNAME' (HTTP $HTTP_STATUS)."

            if jq empty "$RESPONSE_FILE" >/dev/null 2>&1; then
                jq '.' "$RESPONSE_FILE" >&2
            else
                cat "$RESPONSE_FILE" >&2
            fi

        fi

    done < <(
        jq -c '.hits.hits[]' "$ES6_USERS_JSON"
    )
fi

###############################################################################
# Verification
###############################################################################

log_step "6. VERIFY MIGRATED ROLES"

VERIFY_ROLE_SUCCESS=0
VERIFY_ROLE_FAILED=0

if [[ "$ROLES_TOTAL" -gt 0 ]]; then

    while IFS= read -r role_json; do

        ROLE_ID="$(jq -r '._id' <<< "$role_json")"
        ROLE_NAME="${ROLE_ID#role-}"

        RESPONSE_FILE="$TMP_DIR/verify_role.json"

        HTTP_STATUS="$(
            curl \
                -sS \
                -u "$ES9_USER:$ES9_PASS" \
                -o "$RESPONSE_FILE" \
                -w '%{http_code}' \
                "$ES9_URL/_security/role/$ROLE_NAME"
        )"

        if [[ "$HTTP_STATUS" == "200" ]]; then

            if jq -e --arg role "$ROLE_NAME" \
                'has($role)' "$RESPONSE_FILE" >/dev/null 2>&1; then

                VERIFY_ROLE_SUCCESS=$((VERIFY_ROLE_SUCCESS + 1))

                log_success \
                    "Verified role: $ROLE_NAME"

            else

                VERIFY_ROLE_FAILED=$((VERIFY_ROLE_FAILED + 1))

                log_error \
                    "Role '$ROLE_NAME' returned HTTP 200 but was not found in response."
            fi

        else

            VERIFY_ROLE_FAILED=$((VERIFY_ROLE_FAILED + 1))

            log_error \
                "Cannot verify role '$ROLE_NAME' (HTTP $HTTP_STATUS)."

        fi

    done < <(
        jq -c '.hits.hits[]' "$ES6_ROLES_JSON"
    )
fi

###############################################################################
# Verify users
###############################################################################

log_step "7. VERIFY MIGRATED USERS"

VERIFY_USER_SUCCESS=0
VERIFY_USER_FAILED=0

if [[ "$USERS_TOTAL" -gt 0 ]]; then

    while IFS= read -r user_json; do

        USERNAME="$(jq -r '._source.username // empty' <<< "$user_json")"

        if [[ -z "$USERNAME" ]]; then
            continue
        fi

        if is_system_user "$USERNAME"; then
            continue
        fi

        RESPONSE_FILE="$TMP_DIR/verify_user.json"

        HTTP_STATUS="$(
            curl \
                -sS \
                -u "$ES9_USER:$ES9_PASS" \
                -o "$RESPONSE_FILE" \
                -w '%{http_code}' \
                "$ES9_URL/_security/user/$USERNAME"
        )"

        if [[ "$HTTP_STATUS" == "200" ]]; then

            ES9_USERNAME="$(
                jq -r --arg u "$USERNAME" '.[$u].username // empty' \
                    "$RESPONSE_FILE"
            )"

            if [[ "$ES9_USERNAME" == "$USERNAME" ]]; then

                VERIFY_USER_SUCCESS=$((VERIFY_USER_SUCCESS + 1))

                log_success \
                    "Verified user: $USERNAME"

            else

                VERIFY_USER_FAILED=$((VERIFY_USER_FAILED + 1))

                log_error \
                    "User '$USERNAME' verification failed."

            fi

        else

            VERIFY_USER_FAILED=$((VERIFY_USER_FAILED + 1))

            log_error \
                "Cannot verify user '$USERNAME' (HTTP $HTTP_STATUS)."

        fi

    done < <(
        jq -c '.hits.hits[]' "$ES6_USERS_JSON"
    )
fi

###############################################################################
# Final summary
###############################################################################

log_step "8. MIGRATION SUMMARY"

echo
echo -e "${BOLD}Roles${NC}"
echo "  Found:       $ROLES_TOTAL"
echo "  Migrated:    $ROLES_SUCCESS"
echo "  Failed:      $ROLES_FAILED"
echo "  Verified:    $VERIFY_ROLE_SUCCESS"
echo "  Verify fail: $VERIFY_ROLE_FAILED"

echo
echo -e "${BOLD}Users${NC}"
echo "  Found:       $USERS_TOTAL"
echo "  Migrated:    $USERS_SUCCESS"
echo "  Failed:      $USERS_FAILED"
echo "  Skipped:     $USERS_SKIPPED"
echo "  Verified:    $VERIFY_USER_SUCCESS"
echo "  Verify fail: $VERIFY_USER_FAILED"

echo

###############################################################################
# Final status
###############################################################################

if [[ "$ROLES_FAILED" -gt 0 ||
      "$USERS_FAILED" -gt 0 ||
      "$VERIFY_ROLE_FAILED" -gt 0 ||
      "$VERIFY_USER_FAILED" -gt 0 ]]; then

    log_error "Migration completed with errors."
    exit 1
fi

log_success "Migration completed successfully."
exit 0
