#!/bin/bash

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

SERVICE_NAME=""
ENVIRONMENTS="auto"
DELETE_BASE=true
ALLOW_PARTIAL=false
DRY_RUN=false

TARGET_ENVS=()
PRESENT_ENVS=()
ENTRY_ENVS=()
PLANNED_ENVS=()
REMOVED_PATHS=()
UPDATED_FILES=()

print_usage() {
    cat <<'EOF'
Usage:
  ./scripts/remove-service-scaffold.sh --service-name <name> [options]

Options:
  --service-name <name>
  --environments <auto|dev,staging,prod>
  --delete-base <true|false>
  --allow-partial <true|false>
  --dry-run
  --help
EOF
}

trim() {
    printf '%s' "$1" | xargs
}

bool_string() {
    case "$1" in
        true|false) ;;
        *)
            echo -e "${RED}Error: expected true or false, got '$1'${NC}" >&2
            exit 1
            ;;
    esac
}

env_overlay_dir() {
    printf 'environments/%s/%s' "$1" "$SERVICE_NAME"
}

env_kustomization_file() {
    printf 'environments/%s/kustomization.yaml' "$1"
}

contains_env() {
    local needle="$1"
    shift
    for item in "$@"; do
        [ "$item" = "$needle" ] && return 0
    done
    return 1
}

append_unique_target() {
    local value="$1"
    if ! contains_env "$value" "${TARGET_ENVS[@]:-}"; then
        TARGET_ENVS+=("$value")
    fi
}

append_unique_present() {
    local value="$1"
    if ! contains_env "$value" "${PRESENT_ENVS[@]:-}"; then
        PRESENT_ENVS+=("$value")
    fi
}

append_unique_entry() {
    local value="$1"
    if ! contains_env "$value" "${ENTRY_ENVS[@]:-}"; then
        ENTRY_ENVS+=("$value")
    fi
}

append_unique_planned() {
    local value="$1"
    if ! contains_env "$value" "${PLANNED_ENVS[@]:-}"; then
        PLANNED_ENVS+=("$value")
    fi
}

parse_args() {
    if [ $# -eq 0 ]; then
        print_usage
        exit 1
    fi

    while [ $# -gt 0 ]; do
        case "$1" in
            --service-name)
                SERVICE_NAME=$2
                shift 2
                ;;
            --environments)
                ENVIRONMENTS=$2
                shift 2
                ;;
            --delete-base)
                bool_string "$2"
                DELETE_BASE=$2
                shift 2
                ;;
            --allow-partial)
                bool_string "$2"
                ALLOW_PARTIAL=$2
                shift 2
                ;;
            --dry-run)
                DRY_RUN=true
                shift
                ;;
            --help)
                print_usage
                exit 0
                ;;
            *)
                echo -e "${RED}Error: unknown argument '$1'${NC}" >&2
                print_usage
                exit 1
                ;;
        esac
    done
}

validate_inputs() {
    if [[ ! "$SERVICE_NAME" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]]; then
        echo -e "${RED}Error: invalid service name '${SERVICE_NAME}'${NC}" >&2
        exit 1
    fi

    if [ ${#SERVICE_NAME} -gt 63 ]; then
        echo -e "${RED}Error: service name too long (max 63 characters)${NC}" >&2
        exit 1
    fi

    bool_string "$DELETE_BASE"
    bool_string "$ALLOW_PARTIAL"

    if [ "$ENVIRONMENTS" != "auto" ]; then
        IFS=',' read -ra raw_envs <<< "$ENVIRONMENTS"
        for raw_env in "${raw_envs[@]}"; do
            env=$(trim "$raw_env")
            case "$env" in
                dev|staging|prod)
                    append_unique_target "$env"
                    ;;
                *)
                    echo -e "${RED}Error: unsupported environment '${env}'${NC}" >&2
                    exit 1
                    ;;
            esac
        done
    fi
}

discover_service_footprint() {
    BASE_EXISTS=false
    if [ -d "bases/${SERVICE_NAME}" ]; then
        BASE_EXISTS=true
    fi

    for env in dev staging prod; do
        if [ -d "$(env_overlay_dir "$env")" ]; then
            append_unique_present "$env"
            append_unique_planned "$env"
        fi

        if [ -f "$(env_kustomization_file "$env")" ] && grep -Fqx "  - ${SERVICE_NAME}" "$(env_kustomization_file "$env")"; then
            append_unique_entry "$env"
            append_unique_planned "$env"
        fi
    done

    if [ "$BASE_EXISTS" = false ] && [ ${#PLANNED_ENVS[@]} -eq 0 ]; then
        echo -e "${RED}Error: service '${SERVICE_NAME}' does not exist in bases/ or environments/${NC}" >&2
        exit 1
    fi

    if [ "$ENVIRONMENTS" = "auto" ]; then
        TARGET_ENVS=("${PLANNED_ENVS[@]}")
    fi

    if [ ${#TARGET_ENVS[@]} -eq 0 ] && [ "$DELETE_BASE" != true ]; then
        echo -e "${RED}Error: no target environments selected and base deletion disabled${NC}" >&2
        exit 1
    fi

    if [ "$DELETE_BASE" = true ] && [ "$ALLOW_PARTIAL" != true ]; then
        for env in "${PRESENT_ENVS[@]}"; do
            if ! contains_env "$env" "${TARGET_ENVS[@]}"; then
                echo -e "${RED}Error: overlay exists in '${env}' outside requested removal set; re-run with --allow-partial true or use --environments auto${NC}" >&2
                exit 1
            fi
        done
    fi
}

remove_top_level_kustomization_entry() {
    local env="$1"
    local file
    local tmp
    file=$(env_kustomization_file "$env")

    [ -f "$file" ] || return 0
    grep -Fqx "  - ${SERVICE_NAME}" "$file" || return 0

    if [ "$DRY_RUN" = true ]; then
        echo -e "${YELLOW}DRY RUN${NC} would update ${file}"
        return 0
    fi

    tmp=$(mktemp)
    grep -Fvx "  - ${SERVICE_NAME}" "$file" > "$tmp"
    mv "$tmp" "$file"
    UPDATED_FILES+=("$file")
}

remove_env_overlay() {
    local env="$1"
    local dir
    dir=$(env_overlay_dir "$env")

    if [ -d "$dir" ]; then
        if [ "$DRY_RUN" = true ]; then
            echo -e "${YELLOW}DRY RUN${NC} would remove ${dir}"
        else
            rm -rf "$dir"
            REMOVED_PATHS+=("$dir")
        fi
    fi

    remove_top_level_kustomization_entry "$env"
}

remove_base_dir() {
    local dir="bases/${SERVICE_NAME}"
    if [ "$DELETE_BASE" != true ] || [ ! -d "$dir" ]; then
        return 0
    fi

    if [ "$DRY_RUN" = true ]; then
        echo -e "${YELLOW}DRY RUN${NC} would remove ${dir}"
    else
        rm -rf "$dir"
        REMOVED_PATHS+=("$dir")
    fi
}

print_summary() {
    echo ""
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${GREEN}🧹 Service cleanup complete${NC}"
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    echo -e "${YELLOW}📋 Summary:${NC}"
    echo "  Service: ${SERVICE_NAME}"
    echo "  Target environments: ${ENVIRONMENTS}"
    echo "  Delete base: ${DELETE_BASE}"
    echo "  Allow partial: ${ALLOW_PARTIAL}"
    echo "  Dry run: ${DRY_RUN}"
    echo ""
    echo -e "${YELLOW}🔎 Discovered footprint:${NC}"
    echo "  Base directory: ${BASE_EXISTS}"
    echo "  Overlay directories: ${PRESENT_ENVS[*]:-(none)}"
    echo "  Top-level kustomization entries: ${ENTRY_ENVS[*]:-(none)}"
    echo ""
    echo -e "${YELLOW}🗑️ Changes:${NC}"
    if [ ${#REMOVED_PATHS[@]} -eq 0 ]; then
        echo "  Removed paths: (none)"
    else
        for path in "${REMOVED_PATHS[@]}"; do
            echo "  Removed: ${path}"
        done
    fi

    if [ ${#UPDATED_FILES[@]} -eq 0 ]; then
        echo "  Updated files: (none)"
    else
        for file in "${UPDATED_FILES[@]}"; do
            echo "  Updated: ${file}"
        done
    fi
}

main() {
    parse_args "$@"
    validate_inputs
    discover_service_footprint

    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${GREEN}🧹 Removing service scaffold: ${SERVICE_NAME}${NC}"
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    echo -e "${YELLOW}📋 Configuration:${NC}"
    echo "  Service Name: ${SERVICE_NAME}"
    echo "  Target Environments: ${ENVIRONMENTS}"
    echo "  Delete Base: ${DELETE_BASE}"
    echo "  Allow Partial: ${ALLOW_PARTIAL}"
    echo "  Dry Run: ${DRY_RUN}"
    echo ""

    for env in "${TARGET_ENVS[@]}"; do
        remove_env_overlay "$env"
    done

    remove_base_dir
    print_summary
}

main "$@"
