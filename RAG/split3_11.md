---
source_url: https://gemini.google.com/app/c351bb7263c09763
conversation_date: 2026-09-01
context_week: N/A
conversation_types: [FIX_HA_TANG, TRANH_LUAN_QUYET_DINH, LY_THUYET]
ai300_domains: [Design and implement MLOps infrastructure, Model lifecycle, Optimize generative AI systems and model performance]
technologies: [Azure ML, Azure Container Registry (ACR), Docker, GitHub Actions, Azure CLI, YAML, RBAC]
key_decision: "Phải tái cấu trúc workflow từ một script deploy rời rạc thành pipeline MLOps tích hợp CI/CD đầy đủ, với cơ chế kiểm tra trạng thái (idempotent) và xử lý version cho artifact, nhưng cần bổ sung chính sách Retention và Checksum để tránh phình to bộ nhớ."
status: resolved
---

## Bối cảnh & Vấn đề

Luồng workflow CI/CD hiện tại của dự án (AI-core) gặp 7 vấn đề nghiêm trọng khiến quá trình deploy không thể hoạt động ổn định:

1.  **Điều kiện Trigger sai:** Workflow chỉ được kích hoạt khi thay đổi trên nhánh `main` và đúng thư mục `ai-core/**`.
2.  **Secret không hợp lệ:** Yêu cầu `AZURE_CREDENTIALS` phải là Service Principal hợp lệ và có quyền Contributor/AzureML Data Scientist. Nếu không, bước `Azure Login` sẽ thất bại.
3.  **Placeholder không thay đổi:** Biến `workspace` và `resource-group` bị hard-code literal (`YOUR_WORKSPACE`), dẫn đến lỗi `workspace not found`.
4.  **Endpoint tồn tại:** Workflow giả định endpoint (`yolo-endpoint-ver1`) đã được tạo thủ công, không có bước `az ml online-endpoint create`.
5.  **Model chưa đăng ký:** Model (`football-tracking-ensemble:1`) bị tham chiếu mà chưa được đăng ký (thiếu bước `az ml model create`).
6.  **Docker Image thiếu:** Workflow trỏ đến image trên ACR (`acrthngoc17cv.azurecr.io/football-tracking-api:v1`) nhưng không có bước build/push image.
7.  **Lệnh Create Deployment không idempotent:** `az ml online-deployment create` sẽ báo lỗi nếu deployment cùng tên đã tồn tại. Điều này khiến workflow chỉ chạy thành công lần đầu tiên.

## Quyết định cuối cùng & Lý do

**Quyết định:** Sử dụng một pipeline MLOps duy nhất (CI/CD) trong file `.github/workflows/azure-ml-deploy.yml` để tự động hóa toàn bộ quy trình từ Build Image đến Deploy.

**Lý do:** Luồng cũ quá rời rạc, phụ thuộc vào thao tác thủ công và thiếu cơ chế "idempotent". Pipeline mới tích hợp cả CI (build/push image) và CD (register model, endpoint, deployment) để giảm thiểu rủi ro do con người.

**Các phương án bị loại bỏ:**
*   **KHÔNG dùng `az ml online-deployment create` để cập nhật deployment:** Lệnh này không idempotent. Phải dùng logic `show` + `update/create`.
*   **KHÔNG dùng tag image `v1` cố định để deploy nhiều lần:** Nếu build cùng tag, ACR sẽ ghi đè và Azure ML có thể không pull image mới. Do đó cần tag động (ví dụ: `v1.${{ github.run_number }}` hoặc `${{ github.sha }}`).
*   **KHÔNG dùng `GITHUB_SHA` cho Model Version để chạy mỗi commit:** Mặc dù đảm bảo tính bất biến, nhưng gây lãng phí tài nguyên lưu trữ và chi phí.

## Lệnh và Cấu hình cụ thể đã dùng

**File: `.github/workflows/azure-ml-deploy.yml` (Pipeline Toàn diện)**

```yaml
name: MLOps Pipeline - YOLO Football Tracking
on:
  push:
    branches:
      - main
    paths:
      - 'ai-core/**'
      - '.github/workflows/azure-ml-deploy.yml'
env:
  # Cần thay đổi WORKSPACE và RESOURCE_GROUP thành tên thực tế trên Azure của bạn
  WORKSPACE: "your-workspace-name"
  RESOURCE_GROUP: "your-resource-group"
  ACR_NAME: "acrthngoc17cv"
  ENDPOINT_NAME: "yolo-endpoint-ver1"
  DEPLOYMENT_NAME: "yolo-deployment-ver1"
  IMAGE_TAG: "v1.${{ github.run_number }}" # Tag image linh hoạt theo từng lần chạy
jobs:
  build-register-deploy:
    runs-on: ubuntu-latest
    steps:
      - name: Checkout Source Code
        uses: actions/checkout@v3
      - name: Azure Login
        uses: azure/login@v1
        with:
          creds: ${{ secrets.AZURE_CREDENTIALS }}
      - name: Install Azure ML Extension
        run: |
          az extension add -n ml -y
      - name: Set Default Azure ML Workspace
        run: |
          az configure --defaults workspace=${{ env.WORKSPACE }} group=${{ env.RESOURCE_GROUP }}
      - name: Login to Azure Container Registry (ACR)
        run: |
          az acr login --name ${{ env.ACR_NAME }}
      - name: Docker Build & Push Image
        run: |
          IMAGE_URI="${ env.ACR_NAME }}.azurecr.io/football-tracking-api:${ env.IMAGE_TAG }}"
          echo "Building Docker image: ${IMAGE_URI}"
          # Cập nhật file deployment.yml để sử dụng image tag mới nhất trước khi deploy
          sed -i "s|image: .*|image: ${IMAGE_URI}|g" ai-core/config/deployment.yml
          docker build -t ${IMAGE_URI ./ai-core
          docker push ${IMAGE_URI
      - name: Register Ensemble Model
        run: |
          echo "Registering model football-tracking-ensemble..."
          az ml model create -f ai-core/config/ensemble_model.yml
      - name: Create or Update Online Endpoint
        run: |
          echo "Configuring online endpoint: ${ env.ENDPOINT_NAME }}"
          # Lệnh 'create' của Endpoint trong Azure CLI v2 tự động cập nhật nếu đã tồn tại
          az ml online-endpoint create -n ${ env.ENDPOINT_NAME }} -f ai-core/config/endpoint.yml
      - name: Create or Update Online Deployment (Idempotent Logic)
        run: |
          echo "Checking status of deployment: ${ env.DEPLOYMENT_NAME }}..."
          if az ml online-deployment show -n ${ env.DEPLOYMENT_NAME }} -e ${ env.ENDPOINT_NAME }}; then
            echo "Deployment exists. Proceeding with UPDATE..."
            az ml online-deployment update -n ${ env.DEPLOYMENT_NAME }} -e ${ env.ENDPOINT_NAME }} -f ai-core/conf
          else
            echo "Deployment does not exist. Proceeding with CREATE..."
            az ml online-deployment create -n ${ env.DEPLOYMENT_NAME }} -e ${ env.ENDPOINT_NAME }} -f ai-core/conf
          fi
      - name: Route Traffic to Deployment
        run: |
          echo "Routing 100% traffic to ${ env.DEPLOYMENT_NAME }}..."
          az ml online-endpoint update -n ${ env.ENDPOINT_NAME }} -traffic "${ env.DEPLOYMENT_NAME }}=100"
```

**Xử lý Existing Artifact (Docker Image & Model)**
Nếu muốn bỏ qua các bước khi đã có sẵn artifact, thay thế các step tương ứng bằng logic sau:

1.  **Docker Build & Push (Skip nếu có tag):**
    ```yaml
    - name: Docker Build & Push Image
      run: |
        IMAGE_URI="${ env.ACR_NAME }}.azurecr.io/football-tracking-api:${ env.IMAGE_TAG }}"
        echo "Target Image URI: $IMAGE_URI"
        sed -i "s|image: .*|image: $IMAGE_URI|g" ai-core/config/deployment.yml
        TAG_EXISTS=$(az acr repository show-tags -n ${ env.ACR_NAME } --repository football-tracking-api --query "[?contains(@, '${{ env.IMAGE_TAG }}')]" -o tsv)
        if [ -n "$TAG_EXISTS" ]; then
          echo "Image with tag ${ env.IMAGE_TAG }} already exists in ACR. SKIPPING build and push."
        else
          echo "Tag not found. Building and pushing new Docker image..."
          docker build -t $IMAGE_URI ./ai-core
          docker push $IMAGE_URI
        fi
    ```

2.  **Register Model (Skip nếu version đã có):**
    ```yaml
    - name: Register Ensemble Model
      run: |
        MODEL_NAME=$(grep 'name:' ai-core/config/ensemble_model.yml | awk '{print $2}' | tr -d " " | tr -d "\"")
        MODEL_VERSION=$(grep 'version:' ai-core/config/ensemble_model.yml | awk '{print $2}' | tr -d " " | tr -d "\"")
        if [ -z "$MODEL_VERSION" ]; then
          echo "No explicit version found in YAML. Proceeding with auto-increment registration..."
          az ml model create -f ai-core/config/ensemble_model.yml
          exit 0
        fi
        echo "Checking if Model: $MODEL_NAME, Version: $MODEL_VERSION exists..."
        if az ml model show --name "$MODEL_NAME" --version "$MODEL_VERSION" > /dev/null 2>&1; then
          echo "Model $MODEL_NAME version $MODEL_VERSION already exists. SKIPPING registration."
        else
          echo "Model version not found. Registering model..."
          az ml model create -f ai-core/config/ensemble_model.yml
        fi
    ```

## Lỗi gặp phải và Cách khắc phục

| Lỗi / Anti-pattern | Cách khắc phục / Quy tắc thiết lập |
| :--- | :--- |
| **Lỗi:** `az ml online-deployment create` báo lỗi "deployment already exists" khi chạy lần 2. | **Quy tắc:** Lệnh `create` không idempotent. Phải kiểm tra sự tồn tại trước (`az ml online-deployment show`) và sử dụng `update` nếu có. |
| **Lỗi:** Azure ML không kéo image mới khi deployment được `update` nhưng tag image (`v1`) không đổi. | **Quy tắc:** Phải dùng tag động (ví dụ: `v1.${{ github.run_number }}` hoặc `${{ github.sha }}`). Sử dụng `sed` để inject tag mới vào `deployment.yml` trước khi deploy. |
| **Lỗi:** `docker push` thất bại do thiếu quyền. | **Quy tắc:** Service Principal (AZURE_CREDENTIALS) cần có quyền `AcrPush` trên ACR, không chỉ Contributor trên Workspace. |
| **Lỗi:** Model và Image build lại mỗi commit gây đầy ACR và Model Registry. | **Giải pháp:** <br>1. **Docker (ACR):** Sử dụng Layer Caching (Docker) giúp tiết kiệm dung lượng, chỉ tăng thêm layer thay đổi. Tuy nhiên cần thiết lập **Retention Policy** để xóa tag cũ.<br>2. **Model Registry:** Khác với ACR, Model Registry lưu toàn bộ blob (ví dụ 100MB) mỗi version. Không nên auto-increment khi code thay đổi nhỏ. <br> **Giải pháp đề xuất:** <br> - **Trigger theo Tag:** Chỉ chạy pipeline khi có Git Tag (ví dụ: `v1.0.0`) thay vì mọi commit.<br> - **Checksum Validation:** Tính hash (MD5/SHA) của file model weights và lưu vào tag của Model Registry. So sánh hash hiện tại với phiên bản mới nhất để bỏ qua đăng ký nếu trọng số không đổi. |

## Khái niệm & Định nghĩa

**1. Azure Container Registry (ACR) - Cơ chế lưu trữ Docker Image**
*   **Định nghĩa:** Docker image được xây dựng dựa trên các layer (UnionFS). Khi đẩy image, các layer mới sẽ được thêm vào. Nếu chỉ thay đổi code (layer ứng dụng), ACR chỉ tăng dung lượng của layer đó (thường vài KB/MB), không phải toàn bộ image 3-5GB.
*   **Ví dụ:** Build image từ file `inference.py`. Nếu chỉ sửa dòng `print` trong `inference.py`, Docker cache sẽ sử dụng lại các layer OS và Python (3GB), chỉ tạo layer mới vài KB.

**2. Azure ML Model Registry - Cơ chế lưu trữ**
*   **Định nghĩa:** Mỗi version của model (khi chạy `az ml model create`) sẽ tạo một bản sao vật lý của toàn bộ thư mục artifacts (weight, code) lên Blob Storage. Điều này có nghĩa là nếu trọng số YOLO 100MB không thay đổi, mỗi lần đăng ký model mới đều tốn thêm 100MB dung lượng.

**3. Immutability (Tính bất biến) trong MLOps**
*   **Định nghĩa:** Artifact (Code, Model, Image) không được thay đổi sau khi đã tạo. Mọi thay đổi về logic hay dữ liệu đều dẫn đến một artifact mới với version/tag khác.
*   **Ví dụ:** Không dùng tag `:latest` hoặc `:v1` cố định cho Production. Dùng `:sha-abc123` để biết chính xác commit nào tạo ra image đó.

## Các phương án đã cân nhắc

| Phương án | Ưu điểm | Nhược điểm | Được chọn? |
| :--- | :--- | :--- | :--- |
| **1. Pipeline đơn (Toàn diện)** | Tự động hóa toàn bộ, giảm thao tác thủ công, đảm bảo tính nhất quán. | Phải xử lý logic phức tạp (idempotent), cần quản lý version artifact để tránh lãng phí. | **Có** (Đã sửa workflow theo cách này). |
| **2. Chạy pipeline mỗi commit (Auto-increment)** | Đảm bảo luôn có artifact mới ứng với code mới, dễ dàng rollback đến commit cụ thể. | Gây phình to Model Registry (vì lưu toàn bộ blob) và ACR (nếu thay đổi requirements). Chi phí cao. | **Không** (Yêu cầu bổ sung Retention Policy). |
| **3. Kích hoạt pipeline bằng Git Tag (Semantic Release)** | Chỉ chạy khi release ổn định, giảm 90% artifact rác. | Không tự động deploy cho mọi commit nhỏ (có thể chấp nhận trong môi trường Production). | **Đề xuất** (Giải pháp cân bằng giữa tự động hóa và chi phí). |
| **4. Checksum Validation cho Model Weights** | Ngăn chặn đăng ký model mới khi dữ liệu không đổi, tiết kiệm chi phí. | Tăng độ phức tạp trong workflow (cần tính hash và so sánh). | **Đề xuất** (Nên áp dụng để tối ưu FinOps). |
</final_markdown>