#!/bin/bash

# ==============================================================================
# BIGQUERY FEDERATION AUDIT SCRIPT
# 
# Purpose: Identifies tables suitable for BigQuery Lakehouse Federation,
# audits Iceberg compatibility versions, and verifies Service Principal access.
#
# credentials.json has to be in the same folder - service pricipal key like
#  {
#  "client_id": "",
#  "client_secret": ""
#  }
# Usage: ./databricks_which_table.sh [databricks-instance-id] or type ID during run.
# Example: ./databricks_which_table.sh my-workspace.cloud.databricks.com
# ==============================================================================

# 1. Load Credentials
if [ ! -f "credentials.json" ]; then
    echo "[ERROR] credentials.json not found."
    exit 1
fi

CLIENT_ID=$(jq -r '.client_id' credentials.json)
CLIENT_SECRET=$(jq -r '.client_secret' credentials.json)

# Check if Instance ID was passed as a parameter
if [ -n "$1" ]; then
    INSTANCE_ID="$1"
else
    read -p "Enter your Databricks Instance ID: " INSTANCE_ID
fi

# Clean up the input just in case (removes https:// and trailing slashes)
INSTANCE_ID=$(echo "$INSTANCE_ID" | sed -e 's|https://||' -e 's|/||g')
WORKSPACE_ID=$(echo "$INSTANCE_ID" | cut -d'.' -f1)

# 2. Get OAuth Token
TOKEN_RESPONSE=$(curl -s -X POST "https://${INSTANCE_ID}/oidc/v1/token" \
    -u "${CLIENT_ID}:${CLIENT_SECRET}" \
    -d "grant_type=client_credentials&scope=all-apis")

ACCESS_TOKEN=$(echo "$TOKEN_RESPONSE" | jq -r '.access_token // empty')

if [ -z "$ACCESS_TOKEN" ]; then
    echo "[ERROR] Authentication Failed: $TOKEN_RESPONSE"
    exit 1
fi

echo "[INFO] Authenticated successfully. Workspace ID: $WORKSPACE_ID"
echo "[INFO] Auditing Service Principal: $CLIENT_ID"

# 3. Fetch Catalogues
CATALOG_DATA=$(curl -s -H "Authorization: Bearer ${ACCESS_TOKEN}" \
    "https://${INSTANCE_ID}/api/2.1/unity-catalog/catalogs" | \
    jq -r '.catalogs[]? | 
    select(.name != "system" and .name != "main" and .name != "samples") | 
    "\(.name)|\(.storage_root // "NULL")"')

# 4. Iterate through Catalogues
while IFS='|' read -r CATALOG STORAGE_ROOT; do
    
    echo ""
    echo "======================================================================================================================================"
    echo " CATALOGUE: $CATALOG"
    echo "======================================================================================================================================"
    printf "%-10s | %-50s | %-14s | %-14s | %s\n" "STATUS" "TABLE NAME" "FORMAT" "SP ACCESS" "NOTES"
    echo "--------------------------------------------------------------------------------------------------------------------------------------"

    IS_TRUE_EXTERNAL=false
    if [ "$STORAGE_ROOT" != "NULL" ] && [[ "$STORAGE_ROOT" != *"$WORKSPACE_ID"* ]]; then
        IS_TRUE_EXTERNAL=true
    fi
    
    SCHEMAS=$(curl -s -H "Authorization: Bearer ${ACCESS_TOKEN}" \
        "https://${INSTANCE_ID}/api/2.1/unity-catalog/schemas?catalog_name=${CATALOG}" | jq -r '.schemas[]?.name')

    for SCHEMA in $SCHEMAS; do
        [ "$SCHEMA" == "information_schema" ] && continue

        TABLES_JSON=$(curl -s -H "Authorization: Bearer ${ACCESS_TOKEN}" \
            "https://${INSTANCE_ID}/api/2.1/unity-catalog/tables?catalog_name=${CATALOG}&schema_name=${SCHEMA}")

        # Extract Table Details
        RESULTS=$(echo "$TABLES_JSON" | jq -r '
            .tables[]? | 
            (.data_source_format // "" | ascii_downcase) as $format |
            (.table_type // "" | ascii_downcase) as $ttype |
            (.properties["delta.universalFormat.enabledFormats"] // "" | ascii_downcase | contains("iceberg")) as $is_uniform |
            
            (.properties["delta.enableIcebergCompatV2"] // "" | ascii_downcase == "true") as $v2_old |
            (.properties["delta.feature.icebergCompatV2"] // "" | ascii_downcase == "supported") as $v2_new |
            (.properties["delta.enableIcebergCompatV3"] // "" | ascii_downcase == "true") as $v3_old |
            (.properties["delta.feature.icebergCompatV3"] // "" | ascii_downcase == "supported") as $v3_new |

            if ($format == "iceberg" or ($ttype | contains("iceberg"))) then
                "Native|\(.full_name)"
            elif ($format == "delta" and ($v3_old or $v3_new)) then
                "UniForm v3|\(.full_name)"
            elif ($format == "delta" and ($is_uniform or $v2_old or $v2_new)) then
                "UniForm v2|\(.full_name)"
            else
                empty
            end
        ')

        # Process each found table
        while IFS='|' read -r FORMAT TBL_NAME; do
            if [ -n "$TBL_NAME" ]; then
                
                STATUS="READY"
                NOTES=""
                SP_ACCESS="N/A"

                # 1. Check Storage Suitability
                if [ "$IS_TRUE_EXTERNAL" == false ]; then
                    STATUS="SKIPPED"
                    NOTES="Internal workspace storage."
                else
                    # 2. Check Version Suitability
                    if [[ "$FORMAT" == "UniForm v3" ]]; then
                        STATUS="BLOCKED"
                        NOTES="Iceberg v3 not yet supported."
                    fi
                    
                    # 3. Audit Table Permissions
                    TBL_PERMS=$(curl -s -H "Authorization: Bearer ${ACCESS_TOKEN}" \
                        "https://${INSTANCE_ID}/api/2.1/unity-catalog/effective-permissions/table/${TBL_NAME}")
                    
                    SP_PRIVS=$(echo "$TBL_PERMS" | jq -r --arg sp "$CLIENT_ID" '
                        .privilege_assignments[]? | 
                        select(.principal == $sp) | 
                        .privileges[]?' | tr '\n' ' ')
                        
                    if [[ "$SP_PRIVS" == *"ALL_PRIVILEGES"* ]] || [[ "$SP_PRIVS" == *"MODIFY"* ]]; then
                        SP_ACCESS="FULL"
                    elif [[ "$SP_PRIVS" == *"SELECT"* ]]; then
                        SP_ACCESS="READ_ONLY"
                    else
                        OWNER=$(curl -s -H "Authorization: Bearer ${ACCESS_TOKEN}" \
                            "https://${INSTANCE_ID}/api/2.1/unity-catalog/tables/${TBL_NAME}" | jq -r '.owner // ""')
                        
                        if [ "$OWNER" == "$CLIENT_ID" ]; then
                             SP_ACCESS="OWNER"
                        else
                             SP_ACCESS="MISSING"
                             STATUS="BLOCKED"
                             NOTES="${NOTES} SP lacks table access."
                        fi
                    fi
                fi
                
                # Print the aligned row
                printf "%-10s | %-50s | %-14s | %-14s | %s\n" "[$STATUS]" "$TBL_NAME" "$FORMAT" "$SP_ACCESS" "$NOTES"
            fi
        done <<< "$RESULTS"

    done
done <<< "$CATALOG_DATA"

echo ""
echo "[INFO] Audit Complete."
