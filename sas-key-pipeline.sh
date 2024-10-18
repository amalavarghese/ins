#!/bin/bash

#
# This script is for automatically updating Storage Account tokens in Key Vaults.
#
# Tokens currently supported and format expected:
# Note: a key vault secret name is max 127 char and can only contain alphanumeric characters and hyphens. (a-z A-Z 0-9 "-")
#
# - Storage Account SAS token (access level defined below, has expiration date)
#   - [storage account name]-sasToken
#   - ex. sacscdnausedlhdevlz-sasToken
#
# - Storage Account SAS URI (SAS token, also contains connection info)
#   - [storage account name]-sasUri
#   - ex. sacscdnausedlhdevlz-sasUri
#
# - Storage Container SAS token (scoped to individual container in Storage Account, access level defined below, has expiration date)
#   - [storage account name]-[storage container name]-sasToken
#   - ex. sacscdnausedlhdevlz-data-service-sasToken
#
# - Storage Container SAS URI (SAS token, also contains connection info, scoped to individual container)
#   - [storage account name]-[storage container name]-sasUri
#   - ex. sacscdnausedlhdevlz-data-service-sasUri
#
# - Storage Account Access Key (No expiration, full control)
#   - [storage account name]-accountKey
#   - ex. sacscdnausedlhdevlz-accountKey
#
# - Storage Account Connection String (uses Access Key, also contains connection info)
#   - [storage account name]-accountConnStr
#   - ex. sacscdnausedlhdevlz-accountConnStr
#

# Defining functions
pprint() {
    local myArr=("$@")
    echo "${myArr[@]}" | sed 's/ /, /g'
}

acct_key() {
    local resource_group=$1
    local storage_acct=$2

    az storage account keys list \
        --resource-group "$resource_group" \
        --account-name "$storage_acct" \
        --query "[0].value" -o tsv
}

sas_token() {
    local storage_acct=$1
    local account_key=$2
    local container=${3:""}

    if [[ -z "$container" ]]; then
        az storage account generate-sas \
            --account-name "$storage_acct" \
            --account-key "$account_key" \
            --expiry "$(date -d '+3 days' '+%Y-%m-%dT%H:%M:%SZ')" \
            --permissions "cdlruwap" \
            --resource-types "sco" \
            --services "bfqt" \
            -o tsv
    else
        az storage container generate-sas \
            --name "$container" \
            --account-name "$storage_acct" \
            --account-key "$account_key" \
            --expiry "$(date -d '+3 days' '+%Y-%m-%dT%H:%M:%SZ')" \
            --permissions "cdlruwap" \
            -o tsv
    fi
}

# checking for environment variable, setting value if it does not exist for testing purposes
[[ -z "$resource_groups" ]] &&
    resource_groups="rg-csc-dataanalytics-dev-datalh rg-csc-dataanalytics-qa-datalh rg-csc-dataanalytics-prod-datalh"

IFS=" " read -r -a rgs <<<"$resource_groups"

for rg in "${rgs[@]}"; do
    echo "##[section]Working in Resource Group: $rg"
    echo "##[group]Details"

    # Skip any resource groups that aren't currently deployed
    [[ $(az group list --query "[?name == '$rg'].name" -o tsv) ]] || {
        echo "##[info]Resource Group not found"
        printf "##[endgroup]\n\n"
        continue
    }

    # Get Key Vault name in the resource group
    kv="$(
        az resource list \
            --resource-group "$rg" \
            --resource-type "Microsoft.KeyVault/vaults" \
            --query "[].name" \
            -o tsv
    )"

    [[ -z "$kv" ]] && {
        echo "##[warning]No Key Vaults found in $rg"
        printf "##[endgroup]\n\n"
        continue
    }

    echo "##[info]Found Key Vault: $kv"

    secret_pattern="sacsc"
    echo "##[info]Retrieving secret names in KV that contain $secret_pattern"

    IFS=" " read -r -a \
        secrets <<<"$(
            az keyvault secret list \
                --vault-name "$kv" \
                --query "[?starts_with(name, '$secret_pattern')].name" \
                -o tsv |
                tr '\n' ' '
        )"

    [[ -z "${secrets[0]}" ]] && {
        echo "##[warning]No Secrets found in Key Vault that contain $secret_pattern"
        printf "##[endgroup]\n\n"
        continue
    }

    secretTypes=(
        "accountConnStr"
        "accountKey"
        "sasToken"
        "sasUri"
    )

    for secret in "${secrets[@]}"; do
        echo "##[info]Found Secret: $secret"

        echo "##[info]Deconstructing secret $secret"
        IFS=- read -ra contents <<<"$secret"

        # combine any values in the middle, in case a container uses a hyphen in its name
        if [[ "${#contents[@]}" -gt "3" ]]; then
            echo "##[info]Assuming secret includes a container name which uses a hyphen. Rebuilding container name"
            echo "##[info]Starting secret name identifiers: $(pprint "${contents[@]}")"

            middle_length=$((${#contents[@]} - 2))
            middle_value=$(
                IFS=-
                echo "${contents[*]:1:$middle_length}"
            )
            contents=("${contents[0]}" "$middle_value" "${contents[*]: -1}")

            echo "##[info]Modified secret name identifiers: $(pprint "${contents[@]}")"
        fi

        # run some secret name validation checks
        # --------------------------------------
        # check if secretTypes array contains the last token in the secret name
        # (if the secret name contains one of the expected secret type identifiers)
        if [[ ! "${secretTypes[*]}" =~ ${contents[*]: -1} ]]; then
            echo "##[warning]Secret does not end with one of: [$(pprint "${secretTypes[@]}")] (found: ${contents[*]: -1}). Skipping"
            continue
        fi

        # confirm that there is no container in secret name if it is supposed to be an account-level secret
        if [[ "${contents[*]: -1}" == *"account"* ]] && [[ "${#contents[@]}" -gt "2" ]]; then
            echo "##[warning]Secret type is account-scoped but secret name contains extra value(s): $(pprint "${contents[@]:1:${#contents[@]}-2}"). Skipping"
            continue
        fi
        # --------------------------------------

        # move values into separate variables for clarity:
        secret_value=""
        secret_type="${contents[*]: -1}"
        sa_name="${contents[0]}"
        container_name="$(
            [[ "${#contents[@]}" -gt "2" ]] && echo "${contents[1]}" || echo ""
        )"

        account_key="$(acct_key "$rg" "$sa_name")"

        case $secret_type in

        "accountKey")
            echo "##[info]Generating $secret_type"
            secret_value="$account_key"
            ;;
        "accountConnStr")
            echo "##[info]Generating $secret_type"
            secret_value="DefaultEndpointsProtocol=https;AccountName=${sa_name};AccountKey=${account_key};EndpointSuffix=core.windows.net"
            ;;
        "sasToken")
            if [[ -z $container_name ]]; then
                echo "##[info]Generating $secret_type"
                secret_value="$(sas_token "$sa_name" "$account_key")"
            else
                echo "##[info]Generating $secret_type for container"
                secret_value="$(sas_token "$sa_name" "$account_key" "$container_name")"
            fi
            ;;
        "sasUri")
            if [[ -z $container_name ]]; then
                echo "##[info]Generating $secret_type"
                secret_value="https://${sa_name}.blob.core.windows.net/?$(sas_token "$sa_name" "$account_key")"
            else
                echo "##[info]Generating $secret_type for container"
                secret_value="https://${sa_name}.blob.core.windows.net/${container_name}?$(sas_token "$sa_name" "$account_key" "$container_name")"
            fi
            ;;

        esac

        az keyvault secret set \
            --name "$secret" \
            --vault-name "$kv" \
            --value "$secret_value" \
            >/dev/null &&
            echo "##[info]Uploaded $secret_type to $secret successfully" ||
            echo "##[warning]Could not upload $secret_type to $secret"
    done

    printf "##[endgroup]\n\n"
done
