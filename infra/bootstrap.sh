#!/usr/bin/env bash
# =============================================================================
# BOOTSTRAP — CHẠY THỦ CÔNG MỘT LẦN DUY NHẤT, KHÔNG CHẠY TRONG GITHUB ACTIONS.
#
# Tạo Resource Group và Service Principal phục vụ CI/CD.
# Service Principal chỉ có quyền trong phạm vi đúng 1 Resource Group này.
# =============================================================================
set -euo pipefail

SUBSCRIPTION_ID="<SUBSCRIPTION_ID_CUA_BAN>"
RESOURCE_GROUP="foundry-agent-rg"         # Khớp với GitHub repo Variable "RESOURCE_GROUP"
LOCATION="eastasia"
SP_NAME="sp-foundry-agent-cicd"

echo "==> Đăng nhập và chọn đúng subscription..."
az account set --subscription "$SUBSCRIPTION_ID"

echo "==> Tạo Resource Group (idempotent, không lỗi nếu đã tồn tại)..."
az group create --name "$RESOURCE_GROUP" --location "$LOCATION" --output none

RG_ID=$(az group show --name "$RESOURCE_GROUP" --query id -o tsv)
echo "    Resource Group ID: $RG_ID"

echo "==> Tạo Service Principal với quyền Contributor trên Resource Group..."
# Tạo SP với quyền Contributor
SP_JSON=$(az ad sp create-for-rbac \
  --name "$SP_NAME" \
  --role "Contributor" \
  --scopes "$RG_ID" \
  --sdk-auth)

SP_APP_ID=$(echo "$SP_JSON" | jq -r .clientId)

echo "==> Bổ sung quyền 'Role Based Access Control Administrator' trên Resource Group..."
echo "    (Bắt buộc để Bicep có thể tự gán quyền RBAC giữa Hub/Project tới Search và OpenAI)"
az role assignment create \
  --assignee "$SP_APP_ID" \
  --role "Role Based Access Control Administrator" \
  --scope "$RG_ID" \
  --output none

echo "$SP_JSON" > sp-credentials.json

echo ""
echo "=================================================================="
echo "XONG. Các bước tiếp theo (thủ công):"
echo "1. Mở file sp-credentials.json vừa tạo, copy toàn bộ nội dung JSON."
echo "2. Vào GitHub repo > Settings > Secrets and variables > Actions"
echo "   > New repository secret > tên 'AZURE_CREDENTIALS' > dán JSON vào."
echo "3. Thêm repository Variable (hoặc để mặc định):"
echo "   - 'RESOURCE_GROUP' = '$RESOURCE_GROUP'"
echo "   - 'FOUNDRY_PROJECT_NAME' = 'foundry-agent-project'"
echo "4. XOÁ NGAY file sp-credentials.json khỏi máy cá nhân:"
echo "     rm sp-credentials.json"
echo "=================================================================="