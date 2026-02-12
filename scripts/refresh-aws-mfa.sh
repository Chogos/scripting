#!/usr/bin/env bash

# AWS MFA Credential Refresher
# Description: Refreshes AWS MFA credentials for specified profile
# Usage: ./refresh-aws-mfa.sh [-p PROFILE] [-d SECONDS] [-h]

set -Eeuo pipefail

# Source shared utilities
SCRIPTDIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
readonly SCRIPTDIR
# shellcheck source=__utils.sh
. "$SCRIPTDIR/__utils.sh"

# Default values
readonly DEFAULT_DURATION=129600  # 36 hours (max allowed)
# shellcheck disable=SC2155
readonly SCRIPT_NAME="$(basename "${0}")"

# Usage information
usage() {
    cat << EOF
Usage: ${SCRIPT_NAME} [OPTIONS]

Refreshes AWS MFA credentials for the specified profile.
If no profile is specified, you'll be prompted to select from available profiles.

OPTIONS:
    -p, --profile PROFILE    AWS profile to refresh (optional - interactive selection if not provided)
    -d, --duration SECONDS   Token duration in seconds (default: ${DEFAULT_DURATION})
    -h, --help               Show this help message

EXAMPLES:
    ${SCRIPT_NAME}                                    # Interactive profile selection with default duration
    ${SCRIPT_NAME} -p intis-eu-payment -d 7200        # Specific profile with 2 hour duration
    ${SCRIPT_NAME} --profile my-profile               # Use specific profile with default duration
    ${SCRIPT_NAME} -d 3600                            # Interactive selection with 1 hour duration

NOTES:
    - If no profile is specified, you'll see a list of available profiles to choose from
    - The profile must have mfa_serial configured in ~/.aws/config
    - You will be prompted for your MFA token code
    - Temporary credentials are stored in ~/.aws/credentials
EOF
}

# Get MFA serial from AWS config
get_mfa_serial() {
    local profile="${1}"
    local mfa_serial

    mfa_serial="$(aws configure get mfa_serial --profile "$profile" 2>/dev/null || true)"

    if [[ -z "$mfa_serial" ]]; then
        error "No MFA serial found for profile '$profile'"
        die "Please configure mfa_serial in ~/.aws/config for this profile"
    fi

    echo "$mfa_serial"
}

# Get available AWS profiles with MFA configured
get_available_profiles() {
    local profiles
    local mfa_profiles=()
    local profile

    if ! profiles="$(aws configure list-profiles 2>/dev/null)"; then
        die "Could not retrieve AWS profiles. Make sure AWS CLI is configured."
    fi

    if [[ -z "$profiles" ]]; then
        die "No AWS profiles found. Please configure at least one profile."
    fi

    # Filter profiles that have mfa_serial configured
    while IFS= read -r profile; do
        if [[ -n "$profile" ]]; then
            if aws configure get mfa_serial --profile "$profile" >/dev/null 2>&1; then
                mfa_profiles+=("$profile")
            fi
        fi
    done <<< "$profiles"

    if [[ ${#mfa_profiles[@]} -eq 0 ]]; then
        error "No AWS profiles found with MFA serial configured."
        die "Please add 'mfa_serial = arn:aws:iam::ACCOUNT:mfa/USERNAME' to your profiles in ~/.aws/config"
    fi

    printf '%s\n' "${mfa_profiles[@]}"
}

# Interactive profile selection
select_profile_interactively() {
    local profiles
    local profiles_array=()
    local profile_count
    local selection
    local selected_profile

    profiles="$(get_available_profiles)"

    # Convert profiles to array using a more reliable method
    while IFS= read -r profile; do
        if [[ -n "$profile" ]]; then
            profile="$(printf '%s' "$profile" | tr -d '\n\r' | xargs)"
            if [[ -n "$profile" ]]; then
                profiles_array+=("$profile")
            fi
        fi
    done < <(printf '%s\n' "$profiles")

    profile_count="${#profiles_array[@]}"

    if [[ "$profile_count" -eq 0 ]]; then
        die "No profiles found in array"
    fi

    info "Available AWS profiles with MFA configured:"
    for i in "${!profiles_array[@]}"; do
        printf "  %d) %s\n" "$((i + 1))" "${profiles_array[i]}" >&2
    done
    printf '\n' >&2

    if ! [[ -t 0 ]]; then
        die "This script requires interactive input for profile selection. Please run in a terminal."
    fi

    while true; do
        read -r -p "Select a profile (1-${profile_count}): " selection

        if [[ ! "$selection" =~ ^[0-9]+$ ]]; then
            warn "Please enter a valid number (1-${profile_count})"
            continue
        fi

        if [[ "$selection" -lt 1 ]] || [[ "$selection" -gt "$profile_count" ]]; then
            warn "Please enter a number between 1 and ${profile_count}"
            continue
        fi

        selected_profile="${profiles_array[$((selection - 1))]}"
        selected_profile="$(printf '%s' "$selected_profile" | tr -d '\n\r' | xargs)"
        break
    done

    printf '\n'
    info "Selected profile: $selected_profile"
    printf '%s' "$selected_profile"
}

# Validate profile exists
validate_profile() {
    local profile="${1}"

    if ! aws configure list-profiles 2>/dev/null | grep -q "^${profile}$"; then
        error "Profile '$profile' not found in AWS configuration"
        error "Available profiles:"
        aws configure list-profiles 2>/dev/null | sed 's/^/  /' || true
        exit 1
    fi
}

# Get MFA token from user
get_mfa_token() {
    local mfa_token

    if ! [[ -t 0 ]]; then
        die "This script requires interactive input for MFA token. Please run in a terminal."
    fi

    read -r -p "Enter MFA token code: " mfa_token

    if [[ ! "$mfa_token" =~ ^[0-9]{6}$ ]]; then
        die "Invalid MFA token format. Expected 6 digits."
    fi

    echo "$mfa_token"
}

# Get temporary credentials using STS
get_temporary_credentials() {
    local profile="${1}"
    local mfa_serial="${2}"
    local mfa_token="${3}"
    local duration="${4}"
    local temp_file

    temp_file="$(mktemp_file)"

    info "Requesting temporary credentials..."

    if ! aws sts get-session-token \
        --profile "$profile" \
        --serial-number "$mfa_serial" \
        --token-code "$mfa_token" \
        --duration-seconds "$duration" \
        --output json > "$temp_file" 2>/dev/null; then
        die "Failed to get session token. Please check your MFA code and try again."
    fi

    echo "$temp_file"
}

# Update AWS credentials file
update_credentials() {
    local profile="${1}"
    local credentials_file="${2}"
    local mfa_profile="${profile}-mfa"
    local aws_access_key_id
    local aws_secret_access_key
    local aws_session_token
    local expiration

    # Extract credentials from JSON response
    aws_access_key_id="$(jq -r '.Credentials.AccessKeyId' "$credentials_file")"
    aws_secret_access_key="$(jq -r '.Credentials.SecretAccessKey' "$credentials_file")"
    aws_session_token="$(jq -r '.Credentials.SessionToken' "$credentials_file")"
    expiration="$(jq -r '.Credentials.Expiration' "$credentials_file")"

    # Validate we got valid credentials
    if [[ "$aws_access_key_id" == "null" ]] || [[ "$aws_secret_access_key" == "null" ]] || [[ "$aws_session_token" == "null" ]]; then
        die "Failed to parse credentials from AWS response"
    fi

    # Update credentials file
    info "Updating credentials for profile '$mfa_profile'..."

    aws configure set aws_access_key_id "$aws_access_key_id" --profile "$mfa_profile"
    aws configure set aws_secret_access_key "$aws_secret_access_key" --profile "$mfa_profile"
    aws configure set aws_session_token "$aws_session_token" --profile "$mfa_profile"

    # Copy region and output settings from original profile
    local region output
    region="$(aws configure get region --profile "$profile" 2>/dev/null || echo "eu-west-1")"
    output="$(aws configure get output --profile "$profile" 2>/dev/null || echo "json")"

    aws configure set region "$region" --profile "$mfa_profile"
    aws configure set output "$output" --profile "$mfa_profile"

    info "Credentials updated successfully!"
    info "Profile: $mfa_profile"
    info "Expires: $expiration"
    warn "To use these credentials, set: export AWS_PROFILE=$mfa_profile"
}

# Main function
main() {
    local profile=""
    local duration="$DEFAULT_DURATION"
    local use_interactive_selection=true

    # Parse command line arguments
    while [[ $# -gt 0 ]]; do
        case $1 in
            -p|--profile)
                profile="${2:-}"
                [[ -n "$profile" ]] || { error "Profile name required"; usage; exit 1; }
                use_interactive_selection=false
                shift 2
                ;;
            -d|--duration)
                duration="${2:-}"
                [[ "$duration" =~ ^[0-9]+$ ]] || die "Duration must be a number"
                [[ "$duration" -ge 900 ]] || die "Duration must be at least 900 seconds (15 minutes)"
                [[ "$duration" -le 129600 ]] || die "Duration cannot exceed 129600 seconds (36 hours)"
                shift 2
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            *)
                error "Unknown option: $1"
                usage
                exit 1
                ;;
        esac
    done

    # Check dependencies first
    ensure_commands aws jq

    # If no profile specified, use interactive selection
    if [[ "$use_interactive_selection" == true ]]; then
        profile="$(select_profile_interactively)"
        profile="$(printf '%s' "$profile" | tr -d '\n\r')"
    else
        info "Using specified profile: $profile"
        validate_profile "$profile"
    fi

    info "Refreshing MFA credentials for profile: $profile"

    # Get MFA serial for the profile
    local mfa_serial
    mfa_serial="$(get_mfa_serial "$profile")"
    info "Using MFA device: $mfa_serial"

    # Get MFA token from user
    local mfa_token
    mfa_token="$(get_mfa_token)"

    # Get temporary credentials
    local credentials_file
    credentials_file="$(get_temporary_credentials "$profile" "$mfa_serial" "$mfa_token" "$duration")"

    # Update credentials file
    update_credentials "$profile" "$credentials_file"

    info "MFA credentials refresh completed successfully!"
}

# Run main function with all arguments
main "$@"
