---
source_url: https://gemini.google.com/app/9ced014fb6666dd
conversation_date: N/A
context_week: "Tuần 6"
conversation_types: [LAP_KE_HOACH, TRANH_LUAN_QUYET_DINH, FIX_HA_TANG]
ai300_domains: ["Design and implement MLOps infrastructure", "Model lifecycle"]
technologies: [Azure CLI, Azure ML Workspace, MLflow, Compute Instance, Compute Cluster, Container Registry, Online Endpoint, Batch Endpoint, GitHub Actions, Bicep, Application Insights, Data Drift, Managed Identity, Private Endpoint]
key_decision: "KHÔNG bypass training trên cloud; thay vào đó tách biệt pipeline và compute, dùng mô hình CPU cực nhẹ để học luồng training, và train YOLO offline rồi upload weight lên model registry."
status: resolved
---

## Bối cảnh & Vấn đề
- Người dùng đã có kinh nghiệm với nửa sau vòng đời mô hình (triển khai endpoint, đăng ký model trên Azure ML) nhưng chưa từng thực hiện log bằng MLflow và huấn luyện mô hình trên Azure.
- Hạn chế lớn: Azure Students **không cho phép GPU compute instance/cluster**, nên không thể deploy hoặc train YOLO trên cloud.
- Câu hỏi đặt ra: **Có nên bypass hoàn toàn việc training model trên cloud vì phần cứng không cho phép?**

## Quyết định cuối cùng & Lý do
- **Quyết định: TUYỆT ĐỐI KHÔNG bypass việc training trên cloud.**
- **Lý do:**
  - Mục tiêu của MLOps/AI-300 là xây dựng **quy trình tự động hóa và quản lý vòng đời**, không phụ thuộc vào phần cứng.
  - Đề thi sẽ kiểm tra cách cấu hình Job, định nghĩa Environment, mount Data, chứ không quan tâm thời gian huấn luyện.
- **Phương án bị loại bỏ:**
  - **KHÔNG dùng GPU cloud để train YOLO** vì Azure Students không hỗ trợ, nhưng vẫn có thể học luồng training với CPU.
  - **KHÔNG bypass training hoàn toàn** vì sẽ bỏ lỡ kiến thức trọng tâm về Model Lifecycle (25-30% đề thi).

## Lệnh và Cấu hình cụ thể đã dùng

### Ngày 1: Tracking cục bộ với MLflow
- Script Python mẫu:
```python
import mlflow
from sklearn.linear_model import LogisticRegression
from sklearn.datasets import load_iris
from sklearn.model_selection import train_test_split

mlflow.set_tracking_uri("azureml://<workspace-id>.ml.azure.com")
mlflow.set_experiment("cpu-training-experiment")

with mlflow.start_run():
    X, y = load_iris(return_X_y=True)
    X_train, X_test, y_train, y_test = train_test_split(X, y, test_size=0.2)
    
    mlflow.log_param("model_type", "LogisticRegression")
    model = LogisticRegression(max_iter=1000).fit(X_train, y_train)
    accuracy = model.score(X_test, y_test)
    mlflow.log_metric("accuracy", accuracy)
    
    mlflow.sklearn.log_model(model, "model")
    with open("dummy.txt", "w") as f:
        f.write("Artifact example")
    mlflow.log_artifact("dummy.txt")
```

### Ngày 2: Đóng gói và Thực thi Cloud Training (Command Job)
- File cấu hình `job.yml`:
```yaml
$schema: https://azuremlschemas.azureedge.net/latest/commandJob.schema.json
code:
  local_path: src
command: python train.py
environment: azureml:AzureML-sklearn-1.0-ubuntu20.04-py38-cpu:1
compute: azureml:cpu-cluster
experiment_name: cpu-training-experiment
```

- Lệnh thực thi:
```bash
az ml job create -f job.yml
```

### Ngày 3: Observability & Monitoring
- Bật Application Insights cho endpoint cũ:
```bash
az monitor app-insights component create --app <app-name> --location <location> --resource-group <rg>
```
- Cấu hình Data Drift detection (qua Azure ML Studio hoặc CLI).

### Ngày 4: Infrastructure as Code (Bicep)
- File `main.bicep`:
```bicep
resource workspace 'Microsoft.MachineLearningServices/workspaces@2023-04-01' = {
  name: 'mlw-example'
  location: resourceGroup().location
  properties: {
    storageAccount: storageAccount.id
    keyVault: keyVault.id
    applicationInsights: appInsights.id
  }
}
```
- Lệnh triển khai:
```bash
az deployment group create --resource-group <rg> --template-file main.bicep
```

### Ngày 5: Security & RBAC
- Tạo Managed Identity:
```bash
az identity create --name myIdentity --resource-group <rg>
```
- Gán quyền cho Compute:
```bash
az role assignment create --assignee <identity-id> --role "Storage Blob Data Reader" --scope <storage-id>
```

## Lỗi gặp phải và Cách khắc phục
- **Anti-pattern:** "Bypass training trên cloud vì không có GPU" → **Nguy cơ:** Bỏ lỡ kiến thức về Command Job, Environment, Data mounting, vốn là trọng tâm thi.
  - **Cách khắc phục:** Dùng mô hình CPU nhẹ để thực hành đầy đủ luồng training, log MLflow, và job scheduling.
- **Lỗi tiềm ẩn:** Không thể deploy YOLO lên cloud vì thiếu GPU.
  - **Cách khắc phục:** Train offline (local/Colab), upload weight lên Model Registry, deploy endpoint dùng CPU (dù chậm nhưng đúng quy trình).

## Lộ trình chi tiết Tuần 6

| Ngày | Mục tiêu | Hành động cụ thể | Chỉ tiêu hoàn thành |
|------|----------|------------------|----------------------|
| Ngày 1 | Tracking cục bộ với MLflow | Viết script train CPU, log params/metrics/artifacts lên Azure ML Studio | Thấy được run trong Azure ML Studio với đầy đủ thông số |
| Ngày 2 | Cloud Training (Command Job) | Tạo file `job.yml`, chạy `az ml job create`, quan sát pipeline tự động | Job chạy thành công trên CPU Cluster, log được MLflow |
| Ngày 3 | Observability & Monitoring | Bật Application Insights, cấu hình Data Drift detection | Có thể xem log latency/error và baseline data drift |
| Ngày 4 | Infrastructure as Code (Bicep) | Viết `main.bicep` khai báo Workspace, Storage, Key Vault, App Insights | Triển khai thành công bằng `az deployment group create` |
| Ngày 5 | Security & RBAC | Tạo Managed Identity, gán quyền đọc Storage cho Compute | Compute có thể truy cập Storage mà không cần connection string |

## Các phương án đã cân nhắc

| Phương án | Ưu điểm | Nhược điểm | Được chọn? |
|-----------|---------|------------|------------|
| Bypass hoàn toàn training trên cloud | Tiết kiệm thời gian, tránh giới hạn GPU | Mất kiến thức trọng tâm Model Lifecycle (25-30% đề thi) | **KHÔNG** |
| Tách biệt pipeline và compute, dùng CPU model để học | Nắm vững luồng training, không phụ thuộc GPU | Không train được YOLO trên cloud | **CÓ** |
| Train YOLO offline (local/Colab) + upload weight lên Registry | Vẫn học được inference, deploy endpoint | Inference chậm trên CPU, không tối ưu performance | **CÓ (kết hợp)** |
