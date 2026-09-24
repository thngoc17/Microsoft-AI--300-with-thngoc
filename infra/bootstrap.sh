#!/usr/bin/env bash
# =============================================================================
# AI-300 / Microsoft Foundry RAG BOOTSTRAP
#
# One-time environment bootstrap. Run manually with an identity that can:
#   * create resources in the subscription / resource group
#   * create Azure RBAC role assignments (Owner or User Access Administrator)
#
# Architecture created by this script:
#   1) Resource Group
#   2) Microsoft Foundry resource + project + model deployments
#      - GPT-5.6 Luna for the Agent
#      - text-embedding-3-small for Azure AI Search vectorization
#   3) Azure AI Search + Blob source + vector/semantic index + indexer
#      + initial RAG corpus upload
#   4) Foundry project -> Azure AI Search AAD connection
#      + Prompt Agent with system prompt, RAI guardrail, and required tool use
#   5) Outputs configuration consumed by CI/eval; evaluation itself remains in
#      eval.yml so it uses the Microsoft Foundry evaluation service/UI.
#
# The script is intentionally idempotent for the long-lived resources. If the
# Agent already exists, it keeps the current latest version unless
# FOUNDRY_FORCE_AGENT_VERSION=true.
#
# Useful overrides:
#   RESOURCE_GROUP=ai300-rag-rg
#   RESOURCE_GROUP_LOCATION=eastasia
#   FOUNDRY_LOCATION=japaneast
#   SEARCH_LOCATION=eastasia
#   FOUNDRY_RESOURCE_NAME=thngoc-test-resource-1
#   FOUNDRY_PROJECT_NAME=thngoc-test
#   FOUNDRY_MODEL=gpt-5.6-luna
#   FOUNDRY_MODEL_VERSION=2026-07-09
#   FOUNDRY_MODEL_DEPLOYMENT=gpt-5.6-luna
#   FOUNDRY_MODEL_SKU=GlobalStandard
#   FOUNDRY_MODEL_CAPACITY=10
#   EMBEDDING_MODEL=text-embedding-3-small
#   EMBEDDING_VERSION=1
#   EMBEDDING_DEPLOYMENT=text-embedding-3-small
#   EMBEDDING_DIMENSIONS=1536
#   SEARCH_SKU=basic
#   FOUNDRY_AGENT_NAME=ai300-rag-agent
#   FOUNDRY_AGENT_REASONING_EFFORT=high
#   FOUNDRY_AGENT_INSTRUCTIONS_FILE=./config/agent_system_prompt.txt
#   FOUNDRY_RAI_POLICY_NAME=ai300-defaultv2
#   FOUNDRY_FORCE_AGENT_VERSION=false
# =============================================================================
set -euo pipefail

# ----------------------------- Naming / locations -----------------------------
RESOURCE_GROUP="${RESOURCE_GROUP:-ai-300-foundry-rg}"
RESOURCE_GROUP_LOCATION="${RESOURCE_GROUP_LOCATION:-eastasia}"
FOUNDRY_LOCATION="${FOUNDRY_LOCATION:-japaneast}"
SEARCH_LOCATION="${SEARCH_LOCATION:-eastasia}"
SP_NAME="${SP_NAME:-sp-digital-twin-cicd}"

FOUNDRY_RESOURCE_NAME="${FOUNDRY_RESOURCE_NAME:-ai-300-resource-1}"
FOUNDRY_PROJECT_NAME="${FOUNDRY_PROJECT_NAME:-ai-300-project}"
FOUNDRY_PROJECT_DISPLAY_NAME="${FOUNDRY_PROJECT_DISPLAY_NAME:-ai-300-project}"
FOUNDRY_RESOURCE_SKU="${FOUNDRY_RESOURCE_SKU:-S0}"

# GPT-5.6 Luna is a Foundry model. The current Microsoft-documented version is
# 2026-07-09; deployments are accessed by deployment name, not model name.
FOUNDRY_MODEL="${FOUNDRY_MODEL:-gpt-5.6-luna}"
FOUNDRY_MODEL_VERSION="${FOUNDRY_MODEL_VERSION:-2026-07-09}"
FOUNDRY_MODEL_DEPLOYMENT="${FOUNDRY_MODEL_DEPLOYMENT:-gpt-5.6-luna}"
FOUNDRY_MODEL_SKU="${FOUNDRY_MODEL_SKU:-GlobalStandard}"
FOUNDRY_MODEL_CAPACITY="${FOUNDRY_MODEL_CAPACITY:-10}"

EMBEDDING_MODEL="${EMBEDDING_MODEL:-text-embedding-3-small}"
EMBEDDING_VERSION="${EMBEDDING_VERSION:-1}"
EMBEDDING_DEPLOYMENT="${EMBEDDING_DEPLOYMENT:-text-embedding-3-small}"
EMBEDDING_DIMENSIONS="${EMBEDDING_DIMENSIONS:-1536}"
EMBEDDING_SKU="${EMBEDDING_SKU:-Standard}"
EMBEDDING_CAPACITY="${EMBEDDING_CAPACITY:-10}"

# ----------------------------- Search / RAG names -----------------------------
RAG_CONTAINER="${RAG_CONTAINER:-rag}"
RAG_INDEX="${RAG_INDEX:-ai300-rag-index}"
RAG_DATASOURCE="${RAG_DATASOURCE:-ai300-rag-datasource}"
RAG_SKILLSET="${RAG_SKILLSET:-ai300-rag-skillset}"
RAG_INDEXER="${RAG_INDEXER:-ai300-rag-indexer}"
SEARCH_SKU="${SEARCH_SKU:-basic}"
RAG_SEARCH_SERVICE="${RAG_SEARCH_SERVICE:-ai-300-rag-service}"
RAG_STORAGE_ACCOUNT="${RAG_STORAGE_ACCOUNT:-}"

# ----------------------------- Agent configuration ---------------------------
FOUNDRY_AGENT_NAME="${FOUNDRY_AGENT_NAME:-ai300-rag-agent}"
FOUNDRY_AGENT_REASONING_EFFORT="${FOUNDRY_AGENT_REASONING_EFFORT:-high}"
FOUNDRY_FORCE_AGENT_VERSION="${FOUNDRY_FORCE_AGENT_VERSION:-false}"
FOUNDRY_RAI_POLICY_NAME="${FOUNDRY_RAI_POLICY_NAME:-ai300-defaultv2}"
FOUNDRY_RAI_POLICY_ID="${FOUNDRY_RAI_POLICY_ID:-}"
FOUNDRY_SEARCH_CONNECTION_NAME="${FOUNDRY_SEARCH_CONNECTION_NAME:-azure-ai-search-rag}"
FOUNDRY_SEARCH_TOP_K="${FOUNDRY_SEARCH_TOP_K:-5}"
FOUNDRY_SEARCH_QUERY_TYPE="${FOUNDRY_SEARCH_QUERY_TYPE:-vector_semantic_hybrid}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
RAG_DIR="${RAG_DIR:-$REPO_ROOT/rag}"
AGENT_INSTRUCTIONS_FILE="${FOUNDRY_AGENT_INSTRUCTIONS_FILE:-$REPO_ROOT/config/agent_system_prompt.txt}"
OUTPUT_FILE="${OUTPUT_FILE:-$SCRIPT_DIR/bootstrap-output.env}"
CREDENTIAL_FILE="${CREDENTIAL_FILE:-$SCRIPT_DIR/sp-credentials.json}"

SEARCH_API_VERSION="2026-04-01"
SEARCH_MANAGEMENT_API_VERSION="2025-05-01"
FOUNDRY_CONNECTION_API_VERSION="2025-06-01"
FOUNDRY_AGENT_API_VERSION="v1"
FOUNDRY_RAI_API_VERSION="2026-05-15-preview"

# ------------------------------- Requirements --------------------------------
require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "[ERROR] Required command not found: $1" >&2
    exit 1
  }
}

require_cmd az
require_cmd curl
require_cmd python3
require_cmd sha256sum

az account show >/dev/null
SUBSCRIPTION_ID="$(az account show --query id -o tsv)"
az account set --subscription "$SUBSCRIPTION_ID"

RG_ID="/subscriptions/${SUBSCRIPTION_ID}/resourceGroups/${RESOURCE_GROUP}"

az provider register --namespace Microsoft.Storage --wait >/dev/null
az provider register --namespace Microsoft.Search --wait >/dev/null
az provider register --namespace Microsoft.CognitiveServices --wait >/dev/null

mkdir -p "$SCRIPT_DIR"

# ------------------------------- Resource Group --------------------------------
echo "==> [1/5] Creating Resource Group: $RESOURCE_GROUP"
az group create \
  --name "$RESOURCE_GROUP" \
  --location "$RESOURCE_GROUP_LOCATION" \
  --tags Project=AI300 Component=RAG Environment=dev \
  --output none
RG_ID="$(az group show -n "$RESOURCE_GROUP" --query id -o tsv)"

# -------------------------- GitHub Actions identity ---------------------------
EXISTING_SP_APP_ID="$(az ad sp list --display-name "$SP_NAME" --query '[0].appId' -o tsv 2>/dev/null || true)"
if [[ -n "$EXISTING_SP_APP_ID" ]]; then
  SP_APP_ID="$EXISTING_SP_APP_ID"
  SP_OBJECT_ID="$(az ad sp show --id "$SP_APP_ID" --query id -o tsv)"
  echo "==> Reusing GitHub Actions Service Principal: $SP_NAME"

  # Azure does not let us retrieve an existing client secret after creation.
  # If the local credential file is missing, append one new password credential
  # and materialize a GitHub Actions-compatible AZURE_CREDENTIALS JSON file.
  # --append is intentional: it preserves any existing secret currently used by CI.
  if [[ ! -s "$CREDENTIAL_FILE" ]]; then
    echo "    Credential file missing; creating a new client secret (existing secrets preserved)..."
    SP_CRED_RESULT="$(az ad sp credential reset \
      --id "$SP_APP_ID" \
      --append \
      --years "${SP_CREDENTIAL_YEARS:-2}" \
      -o json)"
    SP_CLIENT_SECRET="$(python3 -c 'import json,sys; print(json.load(sys.stdin)["password"])' <<<"$SP_CRED_RESULT")"
    SP_TENANT_ID="$(az account show --query tenantId -o tsv)"
    python3 - "$CREDENTIAL_FILE" "$SP_APP_ID" "$SP_CLIENT_SECRET" "$SUBSCRIPTION_ID" "$SP_TENANT_ID" <<'PY2'
import json, pathlib, sys
out = pathlib.Path(sys.argv[1])
payload = {
    "clientId": sys.argv[2],
    "clientSecret": sys.argv[3],
    "subscriptionId": sys.argv[4],
    "tenantId": sys.argv[5],
}
out.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")
out.chmod(0o600)
PY2
    unset SP_CLIENT_SECRET SP_CRED_RESULT
    echo "    Credential file: $CREDENTIAL_FILE"
  fi
else
  echo "==> Creating GitHub Actions Service Principal (RG-scoped Contributor)..."
  SP_RESULT="$(az ad sp create-for-rbac \
    --name "$SP_NAME" \
    --role Contributor \
    --scopes "$RG_ID" \
    --sdk-auth)"
  SP_APP_ID="$(python3 -c 'import json,sys; print(json.load(sys.stdin)["clientId"])' <<<"$SP_RESULT")"
  SP_OBJECT_ID="$(az ad sp show --id "$SP_APP_ID" --query id -o tsv)"
  printf '%s\n' "$SP_RESULT" > "$CREDENTIAL_FILE"
  chmod 600 "$CREDENTIAL_FILE"
  echo "    Credential file: $CREDENTIAL_FILE"
fi

ensure_role() {
  local assignee_object_id="$1"
  local role_name="$2"
  local scope="$3"
  local count
  count="$(az role assignment list \
    --assignee-object-id "$assignee_object_id" \
    --scope "$scope" \
    --query "[?roleDefinitionName=='${role_name}'] | length(@)" \
    -o tsv 2>/dev/null || echo 0)"
  if [[ "$count" == "0" ]]; then
    az role assignment create \
      --assignee-object-id "$assignee_object_id" \
      --assignee-principal-type ServicePrincipal \
      --role "$role_name" \
      --scope "$scope" \
      --output none
    echo "    RBAC added: $role_name -> $scope"
  else
    echo "    RBAC exists: $role_name -> $scope"
  fi
}

# Deterministic names, unless explicitly overridden.
NAME_HASH="$(printf '%s' "${SUBSCRIPTION_ID}:${RESOURCE_GROUP}" | sha256sum | cut -c1-8)"
if [[ -z "$RAG_STORAGE_ACCOUNT" ]]; then
  RAG_STORAGE_ACCOUNT="ai300rag${NAME_HASH}"
fi
if [[ -z "$RAG_SEARCH_SERVICE" ]]; then
  RAG_SEARCH_SERVICE="ai300-rag-${NAME_HASH}"
fi

# -------------------------- Foundry resource + project ------------------------
echo "==> [2/5] Creating Microsoft Foundry resource: $FOUNDRY_RESOURCE_NAME"
CUSTOM_DOMAIN="$(az cognitiveservices account show \
  --name "$FOUNDRY_RESOURCE_NAME" \
  --resource-group "$RESOURCE_GROUP" \
  --query 'properties.customSubDomainName' -o tsv 2>/dev/null || true)"

if [[ -z "$CUSTOM_DOMAIN" ]]; then
  CUSTOM_DOMAIN="$FOUNDRY_RESOURCE_NAME"
  az cognitiveservices account create \
    --name "$FOUNDRY_RESOURCE_NAME" \
    --resource-group "$RESOURCE_GROUP" \
    --kind AIServices \
    --sku "$FOUNDRY_RESOURCE_SKU" \
    --location "$FOUNDRY_LOCATION" \
    --custom-domain "$CUSTOM_DOMAIN" \
    --assign-identity \
    --allow-project-management true \
    --tags Project=AI300 Component=Foundry Environment=dev \
    --output none
else
  echo "    Foundry resource already exists."
fi

FOUNDRY_RESOURCE_ID="$(az cognitiveservices account show -n "$FOUNDRY_RESOURCE_NAME" -g "$RESOURCE_GROUP" --query id -o tsv)"
FOUNDRY_RESOURCE_PRINCIPAL_ID="$(az cognitiveservices account show -n "$FOUNDRY_RESOURCE_NAME" -g "$RESOURCE_GROUP" --query identity.principalId -o tsv)"
FOUNDRY_MODEL_ENDPOINT="https://${CUSTOM_DOMAIN}.openai.azure.com"
FOUNDRY_PROJECT_ENDPOINT="https://${CUSTOM_DOMAIN}.services.ai.azure.com/api/projects/${FOUNDRY_PROJECT_NAME}"

# Foundry project is a stateful container for agents/evaluations/files and gets
# a system-managed identity so the agent can query Search without a stored key.
PROJECT_EXISTS="$(az cognitiveservices account project show \
  --name "$FOUNDRY_RESOURCE_NAME" \
  --resource-group "$RESOURCE_GROUP" \
  --project-name "$FOUNDRY_PROJECT_NAME" \
  --query 'name' -o tsv 2>/dev/null || true)"
if [[ -z "$PROJECT_EXISTS" ]]; then
  echo "==> Creating Foundry project: $FOUNDRY_PROJECT_NAME"
  az cognitiveservices account project create \
    --name "$FOUNDRY_RESOURCE_NAME" \
    --resource-group "$RESOURCE_GROUP" \
    --project-name "$FOUNDRY_PROJECT_NAME" \
    --location "$FOUNDRY_LOCATION" \
    --display-name "$FOUNDRY_PROJECT_DISPLAY_NAME" \
    --description "AI-300 RAG Agent project" \
    --assign-identity --include-system-identity \
    --output none
else
  echo "    Foundry project already exists."
fi

FOUNDRY_PROJECT_ID="$(az cognitiveservices account project show \
  -n "$FOUNDRY_RESOURCE_NAME" \
  -g "$RESOURCE_GROUP" \
  --project-name "$FOUNDRY_PROJECT_NAME" \
  --query id -o tsv)"
FOUNDRY_PROJECT_PRINCIPAL_ID="$(az cognitiveservices account project show \
  -n "$FOUNDRY_RESOURCE_NAME" \
  -g "$RESOURCE_GROUP" \
  --project-name "$FOUNDRY_PROJECT_NAME" \
  --query identity.principalId -o tsv)"

[[ -n "$FOUNDRY_PROJECT_PRINCIPAL_ID" && "$FOUNDRY_PROJECT_PRINCIPAL_ID" != "null" ]] || {
  echo "[ERROR] Foundry project does not have a system-assigned managed identity." >&2
  exit 1
}

# ---------------------------- Model deployments -------------------------------
echo "==> Deploying Agent model: $FOUNDRY_MODEL ($FOUNDRY_MODEL_VERSION)"
MODEL_DEPLOYMENT_EXISTS="$(az cognitiveservices account deployment show \
  --name "$FOUNDRY_RESOURCE_NAME" \
  --resource-group "$RESOURCE_GROUP" \
  --deployment-name "$FOUNDRY_MODEL_DEPLOYMENT" \
  --query 'properties.provisioningState' -o tsv 2>/dev/null || true)"
if [[ "$MODEL_DEPLOYMENT_EXISTS" != "Succeeded" ]]; then
  az cognitiveservices account deployment create \
    --name "$FOUNDRY_RESOURCE_NAME" \
    --resource-group "$RESOURCE_GROUP" \
    --deployment-name "$FOUNDRY_MODEL_DEPLOYMENT" \
    --model-name "$FOUNDRY_MODEL" \
    --model-version "$FOUNDRY_MODEL_VERSION" \
    --model-format OpenAI \
    --sku-capacity "$FOUNDRY_MODEL_CAPACITY" \
    --sku-name "$FOUNDRY_MODEL_SKU" \
    --output none
else
  echo "    Agent model deployment already exists."
fi

# Validate model availability in the configured region before proceeding.
MODEL_REGION_MATCH="$(az cognitiveservices model list \
  --location "$FOUNDRY_LOCATION" \
  --query "[?model.name=='${FOUNDRY_MODEL}' && model.version=='${FOUNDRY_MODEL_VERSION}'] | length(@)" \
  -o tsv 2>/dev/null || echo 0)"
[[ "$MODEL_REGION_MATCH" != "0" ]] || {
  echo "[ERROR] ${FOUNDRY_MODEL} ${FOUNDRY_MODEL_VERSION} is not reported by Azure for region ${FOUNDRY_LOCATION}." >&2
  exit 1
}

echo "==> Deploying embedding model: $EMBEDDING_MODEL ($EMBEDDING_VERSION)"
EMBEDDING_DEPLOYMENT_EXISTS="$(az cognitiveservices account deployment show \
  --name "$FOUNDRY_RESOURCE_NAME" \
  --resource-group "$RESOURCE_GROUP" \
  --deployment-name "$EMBEDDING_DEPLOYMENT" \
  --query 'properties.provisioningState' -o tsv 2>/dev/null || true)"
if [[ "$EMBEDDING_DEPLOYMENT_EXISTS" != "Succeeded" ]]; then
  az cognitiveservices account deployment create \
    --name "$FOUNDRY_RESOURCE_NAME" \
    --resource-group "$RESOURCE_GROUP" \
    --deployment-name "$EMBEDDING_DEPLOYMENT" \
    --model-name "$EMBEDDING_MODEL" \
    --model-version "$EMBEDDING_VERSION" \
    --model-format OpenAI \
    --sku-capacity "$EMBEDDING_CAPACITY" \
    --sku-name "$EMBEDDING_SKU" \
    --output none
else
  echo "    Embedding deployment already exists."
fi

# ------------------------------- Azure AI Search -------------------------------
echo "==> [3/5] Creating Azure AI Search service: $RAG_SEARCH_SERVICE"
SEARCH_BODY="$(python3 - "$SEARCH_LOCATION" "$SEARCH_SKU" <<'PY'
import json
import sys
location, sku = sys.argv[1:]
print(json.dumps({
    "location": location,
    "sku": {"name": sku},
    "identity": {"type": "SystemAssigned"},
    "tags": {"Project": "AI300", "Component": "RAG", "RagRole": "search"},
    "properties": {
        "authOptions": {
            "aadOrApiKey": {
                "aadAuthFailureMode": "http401WithBearerChallenge"
            }
        },
        "disableLocalAuth": False,
        "hostingMode": "default",
        "partitionCount": 1,
        "replicaCount": 1,
        "publicNetworkAccess": "enabled"
    }
}))
PY
)"
az rest --method put \
  --url "https://management.azure.com/subscriptions/${SUBSCRIPTION_ID}/resourceGroups/${RESOURCE_GROUP}/providers/Microsoft.Search/searchServices/${RAG_SEARCH_SERVICE}?api-version=${SEARCH_MANAGEMENT_API_VERSION}" \
  --body "$SEARCH_BODY" >/dev/null

SEARCH_RESOURCE_ID="/subscriptions/${SUBSCRIPTION_ID}/resourceGroups/${RESOURCE_GROUP}/providers/Microsoft.Search/searchServices/${RAG_SEARCH_SERVICE}"
SEARCH_PRINCIPAL_ID="$(az rest --method get \
  --url "https://management.azure.com${SEARCH_RESOURCE_ID}?api-version=${SEARCH_MANAGEMENT_API_VERSION}" \
  --query 'identity.principalId' -o tsv)"
SEARCH_ENDPOINT="https://${RAG_SEARCH_SERVICE}.search.windows.net"

# Storage source account and container.
echo "==> Creating RAG source Storage Account: $RAG_STORAGE_ACCOUNT"
az storage account create \
  --name "$RAG_STORAGE_ACCOUNT" \
  --resource-group "$RESOURCE_GROUP" \
  --location "$SEARCH_LOCATION" \
  --sku Standard_LRS \
  --kind StorageV2 \
  --min-tls-version TLS1_2 \
  --https-only true \
  --tags Project=AI300 Component=RAG RagRole=source \
  --output none
STORAGE_ID="$(az storage account show -g "$RESOURCE_GROUP" -n "$RAG_STORAGE_ACCOUNT" --query id -o tsv)"
STORAGE_KEY="$(az storage account keys list -g "$RESOURCE_GROUP" -n "$RAG_STORAGE_ACCOUNT" --query '[0].value' -o tsv)"
az storage container create \
  --name "$RAG_CONTAINER" \
  --account-name "$RAG_STORAGE_ACCOUNT" \
  --auth-mode key \
  --account-key "$STORAGE_KEY" \
  --output none

# RBAC: CI sync + Search indexer + Search/Foundry agent.
ensure_role "$SEARCH_PRINCIPAL_ID" 'Storage Blob Data Reader' "$STORAGE_ID"
ensure_role "$SEARCH_PRINCIPAL_ID" 'Cognitive Services OpenAI User' "$FOUNDRY_RESOURCE_ID"
ensure_role "$FOUNDRY_PROJECT_PRINCIPAL_ID" 'Search Index Data Contributor' "$SEARCH_RESOURCE_ID"
ensure_role "$FOUNDRY_PROJECT_PRINCIPAL_ID" 'Search Service Contributor' "$SEARCH_RESOURCE_ID"
ensure_role "$SP_OBJECT_ID" 'Storage Blob Data Contributor' "$STORAGE_ID"
ensure_role "$SP_OBJECT_ID" 'Search Service Contributor' "$SEARCH_RESOURCE_ID"
ensure_role "$SP_OBJECT_ID" 'Search Index Data Contributor' "$SEARCH_RESOURCE_ID"

# The project managed identity needs access to the model resource for agent use.
# This is scoped to the Foundry resource itself.
ensure_role "$FOUNDRY_PROJECT_PRINCIPAL_ID" 'Cognitive Services OpenAI User' "$FOUNDRY_RESOURCE_ID"

sleep 20
SEARCH_ADMIN_KEY="$(az rest --method post \
  --url "https://management.azure.com${SEARCH_RESOURCE_ID}/listAdminKeys?api-version=${SEARCH_MANAGEMENT_API_VERSION}" \
  --query primaryKey -o tsv)"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

# -------------------------------- Search schema --------------------------------
cat > "$TMP_DIR/index.json" <<INDEXJSON
{
  "name": "$RAG_INDEX",
  "fields": [
    {"name":"id","type":"Edm.String","key":true,"filterable":true,"retrievable":true},
    {"name":"title","type":"Edm.String","searchable":true,"retrievable":true},
    {"name":"content","type":"Edm.String","searchable":true,"retrievable":true},
    {"name":"sourcePath","type":"Edm.String","filterable":true,"retrievable":true},
    {"name":"contentVector","type":"Collection(Edm.Single)","searchable":true,"retrievable":true,"dimensions":$EMBEDDING_DIMENSIONS,"vectorSearchProfile":"rag-vector-profile"}
  ],
  "semantic": {
    "defaultConfiguration": "rag-semantic-config",
    "configurations": [
      {
        "name": "rag-semantic-config",
        "prioritizedFields": {
          "titleField": {"fieldName":"title"},
          "prioritizedContentFields": [{"fieldName":"content"}]
        }
      }
    ]
  },
  "vectorSearch": {
    "algorithms": [
      {"name":"rag-hnsw","kind":"hnsw","hnswParameters":{"metric":"cosine","m":4,"efConstruction":400,"efSearch":500}}
    ],
    "profiles": [
      {"name":"rag-vector-profile","algorithm":"rag-hnsw","vectorizer":"rag-openai-vectorizer"}
    ],
    "vectorizers": [
      {
        "name":"rag-openai-vectorizer",
        "kind":"azureOpenAI",
        "azureOpenAIParameters": {
          "resourceUri":"https://${CUSTOM_DOMAIN}.services.ai.azure.com",
          "deploymentId":"$EMBEDDING_DEPLOYMENT",
          "modelName":"$EMBEDDING_MODEL"
        }
      }
    ]
  }
}
INDEXJSON

cat > "$TMP_DIR/datasource.json" <<DSJSON
{
  "name":"$RAG_DATASOURCE",
  "type":"azureblob",
  "credentials":{"connectionString":"ResourceId=$STORAGE_ID"},
  "container":{"name":"$RAG_CONTAINER"}
}
DSJSON

cat > "$TMP_DIR/skillset.json" <<SKILLSETJSON
{
  "name":"$RAG_SKILLSET",
  "description":"AI-300 Markdown RAG embedding skillset using the Foundry embedding deployment",
  "skills":[
    {
      "@odata.type":"#Microsoft.Skills.Text.AzureOpenAIEmbeddingSkill",
      "name":"rag-embedding",
      "description":"Embeds parsed Markdown sections before indexing",
      "context":"/document",
      "resourceUri":"https://${CUSTOM_DOMAIN}.services.ai.azure.com",
      "deploymentId":"$EMBEDDING_DEPLOYMENT",
      "modelName":"$EMBEDDING_MODEL",
      "dimensions":$EMBEDDING_DIMENSIONS,
      "inputs":[{"name":"text","source":"/document/content"}],
      "outputs":[{"name":"embedding","targetName":"embedding"}]
    }
  ]
}
SKILLSETJSON

cat > "$TMP_DIR/indexer.json" <<INDEXERJSON
{
  "name":"$RAG_INDEXER",
  "dataSourceName":"$RAG_DATASOURCE",
  "targetIndexName":"$RAG_INDEX",
  "skillsetName":"$RAG_SKILLSET",
  "disabled": true,
  "parameters":{
    "batchSize":16,
    "maxFailedItems":0,
    "maxFailedItemsPerBatch":0,
    "configuration":{
      "parsingMode":"markdown",
      "markdownParsingSubmode":"oneToMany",
      "markdownHeaderDepth":"h3",
      "dataToExtract":"contentAndMetadata"
    }
  },
  "fieldMappings":[
    {"sourceFieldName":"metadata_storage_name","targetFieldName":"title"},
    {"sourceFieldName":"metadata_storage_path","targetFieldName":"sourcePath"}
  ],
  "outputFieldMappings":[
    {"sourceFieldName":"/document/embedding","targetFieldName":"contentVector"}
  ]
}
INDEXERJSON

search_put() {
  local resource_path="$1"
  local body_file="$2"
  local label="$3"
  echo "    Creating/updating Search ${label}..."
  curl --fail-with-body --silent --show-error --request PUT \
    "${SEARCH_ENDPOINT}/${resource_path}?api-version=${SEARCH_API_VERSION}" \
    --header 'Content-Type: application/json' \
    --header "api-key: ${SEARCH_ADMIN_KEY}" \
    --data-binary "@${body_file}" >/dev/null || {
      echo "[ERROR] Azure AI Search rejected ${label}. Request body:" >&2
      cat "$body_file" >&2
      exit 1
    }
}

search_put "indexes('$RAG_INDEX')" "$TMP_DIR/index.json" "index"
search_put "datasources('$RAG_DATASOURCE')" "$TMP_DIR/datasource.json" "datasource"
search_put "skillsets('$RAG_SKILLSET')" "$TMP_DIR/skillset.json" "skillset"
search_put "indexers('$RAG_INDEXER')" "$TMP_DIR/indexer.json" "indexer"

# -------------------------------- Initial RAG load -----------------------------
[[ -d "$RAG_DIR" ]] || {
  echo "[ERROR] RAG directory not found: $RAG_DIR" >&2
  exit 1
}
find "$RAG_DIR" -type f -name '*.md' -print -quit | grep -q . || {
  echo "[ERROR] No .md files found under $RAG_DIR" >&2
  exit 1
}

BLOB_COUNT="$(find "$RAG_DIR" -type f -name '*.md' | wc -l | tr -d ' ')"
echo "    Uploading $BLOB_COUNT Markdown files into Blob Storage..."
az storage blob sync \
  --account-name "$RAG_STORAGE_ACCOUNT" \
  --container "$RAG_CONTAINER" \
  --source "$RAG_DIR" \
  --auth-mode key \
  --account-key "$STORAGE_KEY" \
  --delete-destination true

echo "    Enabling Search indexer for initial load..."
# CreateOrUpdate with disabled=true prevents Azure AI Search from automatically
# starting an execution before the blob upload is complete. The indexer is kept
# on-demand (no schedule); rag-sync.yml explicitly invokes it after each corpus
# synchronization.
python3 - "$TMP_DIR/indexer.json" "$TMP_DIR/indexer-enabled.json" <<'PY'
import json, sys
src, dst = sys.argv[1:]
obj = json.load(open(src))
obj["disabled"] = False
json.dump(obj, open(dst, "w"), indent=2)
PY
search_put "indexers('$RAG_INDEXER')" "$TMP_DIR/indexer-enabled.json" "indexer (enabled)"

wait_for_indexer() {
  local status_json overall execution error_message
  for attempt in $(seq 1 60); do
    status_json="$(curl --fail-with-body --silent --show-error \
      "${SEARCH_ENDPOINT}/indexers('${RAG_INDEXER}')/search.status?api-version=${SEARCH_API_VERSION}" \
      --header "api-key: ${SEARCH_ADMIN_KEY}")"

    IFS='|' read -r overall execution error_message < <(python3 - "$status_json" <<'PY'
import json, sys
payload = json.loads(sys.argv[1])
last = payload.get("lastResult") or {}
overall = payload.get("status") or "unknown"
execution = last.get("status") or ""
error = last.get("errorMessage") or ""
print(f"{overall}|{execution}|{error}")
PY
)

    if [[ -n "$execution" ]]; then
      echo "    Indexer status=$execution (overall=$overall, attempt $attempt/60)"
    else
      echo "    Indexer status=$overall; execution result not available yet (attempt $attempt/60)"
    fi

    case "$overall:$execution" in
      error:*)
        echo "$status_json"
        echo "[ERROR] Search indexer is in error state.${error_message:+ $error_message}" >&2
        return 1
        ;;
      *:success)
        return 0
        ;;
      *:transientFailure|*:persistentFailure|*:failure|*:reset)
        echo "$status_json"
        echo "[ERROR] Search indexer failed.${error_message:+ $error_message}" >&2
        return 1
        ;;
      *)
        if [[ "$attempt" == "60" ]]; then
          echo "$status_json"
          echo "[ERROR] Timed out waiting for Search indexer." >&2
          return 1
        fi
        sleep 10
        ;;
    esac
  done
}

# Enabling the indexer can race with an automatic invocation on an existing
# resource, so inspect status before issuing an on-demand run. If Azure rejects
# the run with HTTP 409 because another invocation is already active, adopt that
# execution and monitor it instead of failing.
STATUS_JSON="$(curl --fail-with-body --silent --show-error \
  "${SEARCH_ENDPOINT}/indexers('${RAG_INDEXER}')/search.status?api-version=${SEARCH_API_VERSION}" \
  --header "api-key: ${SEARCH_ADMIN_KEY}")"
EXECUTION_STATUS="$(python3 - "$STATUS_JSON" <<'PY'
import json, sys
payload=json.loads(sys.argv[1])
last=payload.get('lastResult') or {}
print(last.get('status') or '')
PY
)"

if [[ "$EXECUTION_STATUS" == "running" ]]; then
  echo "    Search indexer is already running; adopting the active execution."
else
  echo "    Starting initial Search indexer on demand..."
  set +e
  RUN_OUTPUT="$(curl --fail-with-body --silent --show-error --request POST \
    "${SEARCH_ENDPOINT}/indexers('${RAG_INDEXER}')/search.run?api-version=${SEARCH_API_VERSION}" \
    --header "api-key: ${SEARCH_ADMIN_KEY}" \
    --header 'Content-Length: 0' 2>&1)"
  RUN_RC=$?
  set -e
  if [[ "$RUN_RC" -ne 0 ]]; then
    if grep -qi '409' <<<"$RUN_OUTPUT"; then
      echo "    Indexer run returned 409 (already running); adopting the active execution."
    else
      echo "$RUN_OUTPUT" >&2
      echo "[ERROR] Failed to start Search indexer." >&2
      exit 1
    fi
  fi
fi

wait_for_indexer

INDEX_COUNT_JSON="$(curl --fail --silent --show-error --request POST \
  "${SEARCH_ENDPOINT}/indexes('${RAG_INDEX}')/docs/search?api-version=${SEARCH_API_VERSION}" \
  --header "api-key: ${SEARCH_ADMIN_KEY}" \
  --header 'Content-Type: application/json' \
  --data '{"search":"*","count":true,"top":0}')"
INDEX_COUNT="$(python3 - "$INDEX_COUNT_JSON" <<'PY'
import json
import sys
print(json.loads(sys.argv[1]).get("@odata.count", 0))
PY
)"
[[ "$INDEX_COUNT" -gt 0 ]] || {
  echo "[ERROR] Search index is empty after bootstrap." >&2
  exit 1
}
echo "    Search index contains $INDEX_COUNT documents."

# ------------------------- Foundry Search project connection -------------------
echo "==> Creating/validating Foundry -> Azure AI Search connection"
CONNECTION_ID="/subscriptions/${SUBSCRIPTION_ID}/resourceGroups/${RESOURCE_GROUP}/providers/Microsoft.CognitiveServices/accounts/${FOUNDRY_RESOURCE_NAME}/projects/${FOUNDRY_PROJECT_NAME}/connections/${FOUNDRY_SEARCH_CONNECTION_NAME}"
CONNECTION_BODY="$(python3 - "$SEARCH_ENDPOINT" <<'PY'
import json, sys
print(json.dumps({
    "properties": {
        "category": "CognitiveSearch",
        "target": sys.argv[1],
        "authType": "AAD"
    }
}))
PY
)"
az rest --method put \
  --url "https://management.azure.com${CONNECTION_ID}?api-version=${FOUNDRY_CONNECTION_API_VERSION}" \
  --body "$CONNECTION_BODY" >/dev/null

# ----------------------------- RAI guardrail policy ----------------------------
echo "==> Creating/validating RAI guardrail: $FOUNDRY_RAI_POLICY_NAME"
if [[ -n "$FOUNDRY_RAI_POLICY_ID" ]]; then
  RAI_POLICY_ID="$FOUNDRY_RAI_POLICY_ID"
else
  RAI_POLICY_ID="${FOUNDRY_RESOURCE_ID}/raiPolicies/${FOUNDRY_RAI_POLICY_NAME}"

  # A custom RAI policy must include a non-null contentFilters array.
  # Microsoft.DefaultV2 is the base policy; these controls explicitly preserve
  # the standard harmful-content protections for both prompts and completions,
  # plus prompt attack / protected-material controls supported by the policy API.
  RAI_BODY="$(python3 - <<'PY'
import json

filters = []
def add(name, source, *, severity=None, blocking=True, enabled=True):
    item = {
        "name": name,
        "blocking": blocking,
        "enabled": enabled,
        "source": source,
    }
    if severity is not None:
        item["severityThreshold"] = severity
    filters.append(item)

for source in ("Prompt", "Completion"):
    for category in ("Violence", "Hate", "Sexual", "Selfharm"):
        add(category, source, severity="Medium")

add("Jailbreak", "Prompt")
add("Indirect Attack", "Prompt")
add("Profanity", "Prompt")
add("Protected Material Text", "Completion")
add("Protected Material Code", "Completion", blocking=False)
add("Profanity", "Completion")

print(json.dumps({
    "properties": {
        "basePolicyName": "Microsoft.DefaultV2",
        "mode": "Blocking",
        "contentFilters": filters,
    },
    "tags": {
        "Project": "AI300",
        "Component": "RAG",
        "Purpose": "AgentGuardrail",
    },
}))
PY
)"
  az rest --method put \
    --url "https://management.azure.com${RAI_POLICY_ID}?api-version=${FOUNDRY_RAI_API_VERSION}" \
    --body "$RAI_BODY" >/dev/null
fi

# ----------------------------- Agent configuration ----------------------------
echo "==> [4/5] Creating/validating Prompt Agent: $FOUNDRY_AGENT_NAME"
if [[ -f "$AGENT_INSTRUCTIONS_FILE" ]]; then
  AGENT_INSTRUCTIONS="$(cat "$AGENT_INSTRUCTIONS_FILE")"
else
  AGENT_INSTRUCTIONS='You are the AI-300 RAG Assistant. Always use the Azure AI Search tool before answering project-knowledge questions. Treat retrieved project documents as the authoritative source. Do not invent facts that are not supported by retrieved content. When the search results do not contain enough information, say so clearly. Cite the retrieved sources in your answer using the citations supplied by the tool.'
  echo "    No instructions file found; using the built-in RAG safety prompt."
fi

python3 - "$TMP_DIR/agent.json" \
  "$FOUNDRY_AGENT_NAME" \
  "$FOUNDRY_MODEL_DEPLOYMENT" \
  "$FOUNDRY_SEARCH_CONNECTION_NAME" \
  "$RAG_INDEX" \
  "$FOUNDRY_SEARCH_QUERY_TYPE" \
  "$FOUNDRY_SEARCH_TOP_K" \
  "$FOUNDRY_AGENT_REASONING_EFFORT" \
  "$RAI_POLICY_ID" \
  "$AGENT_INSTRUCTIONS" <<'PY'
import json
import pathlib
import sys
(
    out,
    agent_name,
    model,
    connection_name,
    index_name,
    query_type,
    top_k,
    reasoning_effort,
    rai_policy_id,
    instructions,
) = sys.argv[1:]

project_connection_id = "__PROJECT_CONNECTION_ID__"  # replaced by shell before REST call
body = {
    "name": agent_name,
    "description": "AI-300 RAG Prompt Agent backed by Azure AI Search",
    "state": "enabled",
    "definition": {
        "kind": "prompt",
        "model": model,
        "instructions": instructions,
        "reasoning": {"effort": reasoning_effort},
        # Permanent / deterministic tool use: the agent must invoke at least one tool.
        "tool_choice": "required",
        "tools": [
            {
                "type": "azure_ai_search",
                "azure_ai_search": {
                    "indexes": [
                        {
                            "project_connection_id": connection_name,
                            "index_name": index_name,
                            "query_type": query_type,
                            "top_k": int(top_k)
                        }
                    ]
                }
            }
        ],
        "rai_config": {"rai_policy_name": rai_policy_id}
    },
    "metadata": {
        "project": "AI300",
        "architecture": "foundry-project-search-agent",
        "search_connection": connection_name,
        "search_index": index_name
    }
}
pathlib.Path(out).write_text(json.dumps(body, ensure_ascii=False, indent=2))
PY

# Replace the symbolic connection-name placeholder with the concrete project
# connection resource ID required by the current Agent REST schema.
python3 - "$TMP_DIR/agent.json" "$CONNECTION_ID" <<'PY'
import json
import pathlib
import sys
p = pathlib.Path(sys.argv[1])
connection_id = sys.argv[2]
data = json.loads(p.read_text())
idx = data["definition"]["tools"][0]["azure_ai_search"]["indexes"][0]
idx["project_connection_id"] = connection_id
p.write_text(json.dumps(data, ensure_ascii=False, indent=2))
PY

# Determine whether the named Prompt Agent already exists.
AGENT_EXISTS_JSON="$(curl --fail --silent --show-error \
  --request GET \
  --url "${FOUNDRY_PROJECT_ENDPOINT}/agents/${FOUNDRY_AGENT_NAME}?api-version=${FOUNDRY_AGENT_API_VERSION}" \
  --header "Authorization: Bearer $(az account get-access-token --scope https://ai.azure.com/.default --query accessToken -o tsv)" \
  --header 'Content-Type: application/json' 2>/dev/null || true)"

if [[ -z "$AGENT_EXISTS_JSON" || "$AGENT_EXISTS_JSON" == *'"error"'* ]]; then
  echo "    Creating first Agent version..."
  AGENT_TOKEN="$(az account get-access-token --scope https://ai.azure.com/.default --query accessToken -o tsv)"
  AGENT_RESPONSE="$(curl --fail --silent --show-error \
    --request POST \
    --url "${FOUNDRY_PROJECT_ENDPOINT}/agents?api-version=${FOUNDRY_AGENT_API_VERSION}" \
    --header "Authorization: Bearer ${AGENT_TOKEN}" \
    --header 'Content-Type: application/json' \
    --data-binary "@${TMP_DIR}/agent.json")"
else
  if [[ "$FOUNDRY_FORCE_AGENT_VERSION" == "true" ]]; then
    echo "    Agent exists; creating a new version because FOUNDRY_FORCE_AGENT_VERSION=true..."
    AGENT_TOKEN="$(az account get-access-token --scope https://ai.azure.com/.default --query accessToken -o tsv)"
    VERSION_BODY="$(python3 - "$TMP_DIR/agent.json" <<'PY'
import json, pathlib, sys
p = pathlib.Path(sys.argv[1])
data = json.loads(p.read_text())
data.pop("name", None)
data.pop("state", None)
print(json.dumps(data, ensure_ascii=False))
PY
)"
    AGENT_RESPONSE="$(curl --fail --silent --show-error \
      --request POST \
      --url "${FOUNDRY_PROJECT_ENDPOINT}/agents/${FOUNDRY_AGENT_NAME}/versions?api-version=${FOUNDRY_AGENT_API_VERSION}" \
      --header "Authorization: Bearer ${AGENT_TOKEN}" \
      --header 'Content-Type: application/json' \
      --data "$VERSION_BODY")"
  else
    echo "    Agent already exists; preserving its latest version."
    AGENT_RESPONSE="$AGENT_EXISTS_JSON"
  fi
fi

AGENT_VERSION="$(python3 - "$AGENT_RESPONSE" <<'PY'
import json, sys
x=json.loads(sys.argv[1])
print(x.get("version") or x.get("versions", {}).get("latest", {}).get("version") or "")
PY
)"
AGENT_ID="$(python3 - "$AGENT_RESPONSE" <<'PY'
import json, sys
x=json.loads(sys.argv[1])
print(x.get("id", ""))
PY
)"
AGENT_STATUS="$(python3 - "$AGENT_RESPONSE" <<'PY'
import json, sys
x=json.loads(sys.argv[1])
print(x.get("status") or x.get("versions", {}).get("latest", {}).get("status") or "")
PY
)"

[[ -n "$AGENT_VERSION" ]] || {
  echo "[ERROR] Agent was created/found but no version was returned." >&2
  echo "$AGENT_RESPONSE" >&2
  exit 1
}

# ------------------------------ Final outputs ---------------------------------
echo "==> [5/5] Writing bootstrap outputs"
cat > "$OUTPUT_FILE" <<ENV
RESOURCE_GROUP=$RESOURCE_GROUP
RESOURCE_GROUP_LOCATION=$RESOURCE_GROUP_LOCATION
FOUNDRY_LOCATION=$FOUNDRY_LOCATION
SEARCH_LOCATION=$SEARCH_LOCATION
FOUNDRY_RESOURCE_NAME=$FOUNDRY_RESOURCE_NAME
FOUNDRY_RESOURCE_ID=$FOUNDRY_RESOURCE_ID
FOUNDRY_PROJECT_NAME=$FOUNDRY_PROJECT_NAME
FOUNDRY_PROJECT_ID=$FOUNDRY_PROJECT_ID
FOUNDRY_PROJECT_ENDPOINT=$FOUNDRY_PROJECT_ENDPOINT
FOUNDRY_MODEL=$FOUNDRY_MODEL
FOUNDRY_MODEL_VERSION=$FOUNDRY_MODEL_VERSION
FOUNDRY_MODEL_DEPLOYMENT=$FOUNDRY_MODEL_DEPLOYMENT
EMBEDDING_MODEL=$EMBEDDING_MODEL
EMBEDDING_VERSION=$EMBEDDING_VERSION
EMBEDDING_DEPLOYMENT=$EMBEDDING_DEPLOYMENT
EMBEDDING_DIMENSIONS=$EMBEDDING_DIMENSIONS
RAG_STORAGE_ACCOUNT=$RAG_STORAGE_ACCOUNT
RAG_CONTAINER=$RAG_CONTAINER
RAG_SEARCH_SERVICE=$RAG_SEARCH_SERVICE
RAG_INDEX=$RAG_INDEX
RAG_DATASOURCE=$RAG_DATASOURCE
RAG_SKILLSET=$RAG_SKILLSET
RAG_INDEXER=$RAG_INDEXER
FOUNDRY_SEARCH_CONNECTION_NAME=$FOUNDRY_SEARCH_CONNECTION_NAME
FOUNDRY_SEARCH_CONNECTION_ID=$CONNECTION_ID
FOUNDRY_AGENT_NAME=$FOUNDRY_AGENT_NAME
FOUNDRY_AGENT_VERSION=$AGENT_VERSION
FOUNDRY_AGENT_ID=$AGENT_ID
FOUNDRY_AGENT_STATUS=$AGENT_STATUS
FOUNDRY_RAI_POLICY_ID=$RAI_POLICY_ID
ENV
chmod 600 "$OUTPUT_FILE"

cat <<EOF

====================================================================
AI-300 MICROSOFT FOUNDRY RAG BOOTSTRAP COMPLETE
====================================================================
Resource Group     : $RESOURCE_GROUP
Foundry Resource   : $FOUNDRY_RESOURCE_NAME ($FOUNDRY_LOCATION)
Foundry Project    : $FOUNDRY_PROJECT_NAME
Agent model        : $FOUNDRY_MODEL_DEPLOYMENT
Embedding model    : $EMBEDDING_DEPLOYMENT
Search Service     : $RAG_SEARCH_SERVICE ($SEARCH_LOCATION)
Search Index       : $RAG_INDEX
Indexed documents  : $INDEX_COUNT
Search connection  : $FOUNDRY_SEARCH_CONNECTION_NAME (AAD)
Agent              : $FOUNDRY_AGENT_NAME v$AGENT_VERSION
Agent status       : $AGENT_STATUS
RAI guardrail      : $RAI_POLICY_ID
Tool choice        : required (Azure AI Search)

CI credential file : $CREDENTIAL_FILE
Config output      : $OUTPUT_FILE

Next actions:
  1. Store $CREDENTIAL_FILE as GitHub secret AZURE_CREDENTIALS.
  2. Set GitHub variables from $OUTPUT_FILE, especially:
       FOUNDRY_PROJECT_ENDPOINT
       FOUNDRY_AGENT_NAME
       FOUNDRY_AGENT_VERSION
  3. Keep evaluation in .github/workflows/eval.yml; it uses the
     Microsoft Foundry evaluation service and the configured metrics.
  4. Delete $CREDENTIAL_FILE after securely storing the GitHub secret.
====================================================================
EOF