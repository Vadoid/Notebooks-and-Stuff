#!/bin/bash

# ==============================================================================
# BIGQUERY FEDERATION
# 
# The intersection of 'True External Storage' and 'Iceberg Format' 
# is the golden ticket for BigQuery Lakehouse Federation via Lakehouse runtime catalog. 
#
# This script will now:
# 1. Flag suitable tables with 🌐 [BQ Federation Ready]
# 2. Audit the Service Principal's permissions on the Catalogue and Table
#    to ensure it has full access (OWNER, ALL_PRIVILEGES, or MODIFY).
# ==============================================================================

# 1. Load Credentials
if [ ! -f "credentials.json" ]; then
    echo "Error: credentials.json not found."
    exit 1
fi

CLIENT_ID=$(jq -r '.client_id' credentials.json)
CLIENT_SECRET=$(jq -r '.client_secret' credentials.json)

read -p "Enter your Databricks Instance ID: " INSTANCE_ID
INSTANCE_ID=$(echo "$INSTANCE_ID" | sed -e 's|https://||' -e 's|/||g')

WORKSPACE_ID=$(echo "$INSTANCE_ID" | cut -d'.' -f1)

# 2. Get OAuth Token
TOKEN_RESPONSE=$(curl -s -X POST "https://${INSTANCE_ID}/oidc/v1/token" \
    -u "${CLIENT_ID}:${CLIENT_SECRET}" \
    -d "grant_type=client_credentials&scope=all-apis")

ACCESS_TOKEN=$(echo "$TOKEN_RESPONSE" | jq -r '.access_token // empty')

if [ -z "$ACCESS_TOKEN" ]; then
    echo "Authentication Failed: $TOKEN_RESPONSE"
    exit 1
fi

echo "--- Authenticated (Workspace ID: $WORKSPACE_ID) ---"
echo "Auditing Service Principal: $CLIENT_ID"
echo ""

# 3. Fetch Catalogs (Extracting both Name and Storage Root)
CATALOG_DATA=$(curl -s -H "Authorization: Bearer ${ACCESS_TOKEN}" \
    "https://${INSTANCE_ID}/api/2.1/unity-catalog/catalogs" | \
    jq -r '.catalogs[]? | 
    select(.name != "system" and .name != "main" and .name != "samples") | 
    "\(.name)|\(.storage_root // "NULL")"')

# 4. Iterate through ALL selected catalogs
while IFS='|' read -r CATALOG STORAGE_ROOT; do
    echo "====================================================="
    echo "Scanning Catalog: $CATALOG"
    
    IS_TRUE_EXTERNAL=false
    
    # Check if storage is Default or True External
    if [ "$STORAGE_ROOT" == "NULL" ] || [[ "$STORAGE_ROOT" == *"$WORKSPACE_ID"* ]]; then
        echo "Storage:          [Default Workspace] ($STORAGE_ROOT)"
    else
        echo "Storage:          [Custom External Root] -> $STORAGE_ROOT"
        IS_TRUE_EXTERNAL=true
        
        # --- AUDIT CATALOGUE ACCESS ---
        CAT_PERMS=$(curl -s -H "Authorization: Bearer ${ACCESS_TOKEN}" \
            "https://${INSTANCE_ID}/api/2.1/unity-catalog/effective-permissions/catalog/${CATALOG}")
        
        CAT_PRIVS=$(echo "$CAT_PERMS" | jq -r --arg sp "$CLIENT_ID" '.privilege_assignments[]? | select(.principal == $sp) | .privileges[]?' | tr '\n' ' ')
        
        if [[ "$CAT_PRIVS" == *"ALL_PRIVILEGES"* ]] || [[ "$CAT_PRIVS" == *"OWNER"* ]] || [[ "$CAT_PRIVS" == *"USE_CATALOG"* ]]; then
            echo "Access (Cat):     🔑 SP has explicit access to this catalogue."
        else
            echo "Access (Cat):     ⚠️ Warning: SP lacks explicit full access to catalogue."
        fi
    fi
    echo "====================================================="
    
    SCHEMAS=$(curl -s -H "Authorization: Bearer ${ACCESS_TOKEN}" \
        "https://${INSTANCE_ID}/api/2.1/unity-catalog/schemas?catalog_name=${CATALOG}" | jq -r '.schemas[]?.name')

    for SCHEMA in $SCHEMAS; do
        [ "$SCHEMA" == "information_schema" ] && continue

        TABLES_JSON=$(curl -s -H "Authorization: Bearer ${ACCESS_TOKEN}" \
            "https://${INSTANCE_ID}/api/2.1/unity-catalog/tables?catalog_name=${CATALOG}&schema_name=${SCHEMA}")

        # Extract Table Name and Type tag
        RESULTS=$(echo "$TABLES_JSON" | jq -r '
            .tables[]? | 
            (.data_source_format // "" | ascii_downcase) as $format |
            (.table_type // "" | ascii_downcase) as $ttype |
            (.properties["delta.universalFormat.enabledFormats"] // "" | ascii_downcase | contains("iceberg")) as $is_uniform |
            (.properties["delta.enableIcebergCompatV2"] // "" | ascii_downcase == "true") as $is_compat |

            if ($format == "iceberg" or ($ttype | contains("iceberg"))) then
                "[Native]|\(.full_name)"
            elif ($format == "delta" and ($is_uniform or $is_compat)) then
                "[UniForm]|\(.full_name)"
            else
                empty
            end
        ')

        # Process each found table
        while IFS='|' read -r TAG TBL_NAME; do
            if [ -n "$TBL_NAME" ]; then
                FED_NOTE=""
                PERM_CHECK=""
                
                # If it's True External, it's suitable for BigQuery Federation
                if [ "$IS_TRUE_EXTERNAL" == true ]; then
                    FED_NOTE=" 🌐 [BQ Federation Ready]"
                    
                    # --- AUDIT TABLE ACCESS ---
                    TBL_PERMS=$(curl -s -H "Authorization: Bearer ${ACCESS_TOKEN}" \
                        "https://${INSTANCE_ID}/api/2.1/unity-catalog/effective-permissions/table/${TBL_NAME}")
                    
                    SP_PRIVS=$(echo "$TBL_PERMS" | jq -r --arg sp "$CLIENT_ID" '
                        .privilege_assignments[]? | 
                        select(.principal == $sp) | 
                        .privileges[]?' | tr '\n' ' ')
                        
                    if [[ "$SP_PRIVS" == *"ALL_PRIVILEGES"* ]] || [[ "$SP_PRIVS" == *"MODIFY"* ]]; then
                        PERM_CHECK=" 🔑 [SP: Full Access]"
                    elif [[ "$SP_PRIVS" == *"SELECT"* ]]; then
                        PERM_CHECK=" 👁️ [SP: Read-Only]"
                    else
                        # Fallback to check literal owner
                        OWNER=$(curl -s -H "Authorization: Bearer ${ACCESS_TOKEN}" \
                            "https://${INSTANCE_ID}/api/2.1/unity-catalog/tables/${TBL_NAME}" | jq -r '.owner // ""')
                        
                        if [ "$OWNER" == "$CLIENT_ID" ]; then
                             PERM_CHECK=" 🔑 [SP: Owner]"
                        else
                             PERM_CHECK=" ⚠️ [SP: Missing explicit full access]"
                        fi
                    fi
                fi
                
                echo " >> [FOUND] $TAG $TBL_NAME$FED_NOTE$PERM_CHECK"
            fi
        done <<< "$RESULTS"

    done
done <<< "$CATALOG_DATA"

echo "--- Search Complete ---"
