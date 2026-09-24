---
source_url: https://gemini.google.com/app/2fe39c9d3e02529e
conversation_date: 2026-09-01
context_week: Tuần 4-5
conversation_types: [LAP_KE_HOACH, TRANH_LUAN_QUYET_DINH, FIX_CODE, LY_THUYET]
ai300_domains: ["Design and implement MLOps infrastructure", "Model lifecycle"]
technologies: [Azure ML, MLflow, YOLO, Ultralytics, GitHub Actions, Python, YAML, Azure CLI, Docker, CPU Compute Cluster, Datastore, Model Registry]
key_decision: "Tách checkpoint khỏi hành động đăng ký: đưa file .pt lên Datastore làm Data Asset, chạy validation job trên CPU cluster để log metrics và tự động register model vào Registry nếu đạt ngưỡng; loại bỏ hoàn toàn Kaggle và không gộp chung Resource Group cho các dự án khác loại."
status: resolved
---

## Bối cảnh & Vấn đề

- Dự án YOLO tracking đã có checkpoint local (`best.pt`) và tập validation (`dummy_data`).
- Người dùng không có GPU trên Azure ML (tài khoản sinh viên) nên không thể train lại YOLO trong pipeline.
- Cần thiết lập CI/CD để đưa model vào Azure ML Model Registry với lineage đầy đủ, đồng thời ôn thi chứng chỉ AI-300 (trọng tâm: Model lifecycle, MLOps infrastructure).
- Vấn đề đặt ra: loại bỏ hoàn toàn Kaggle khỏi kiến trúc, vì Kaggle không phải service Azure, gây phức tạp về bảo mật (webhook, Service Principal, Entra ID).

## Quyết định cuối cùng & Lý do

**Kiến trúc được chọn:**
- **Bước 1:** Đẩy checkpoint `best.pt` lên Azure Datastore dưới dạng Data Asset (`uri_file`). Đây là "data", không phải "model" – hợp lệ.
- **Bước 2:** Chạy CommandJob `validate_and_register.py` trên CPU cluster. Job này mount checkpoint và validation set, chạy inference bằng YOLO, tính mAP và latency, log các metrics vào MLflow, và đăng ký model vào Registry nếu mAP >= ngưỡng.
- **Bước 3:** CI/CD trigger bởi GitHub Actions khi push code vào thư mục `src/` hoặc thay đổi `job.yml`.
- **Lý do:** Đơn giản, bảo mật cao (không cần secrets 2 phía), native Azure ML, phù hợp với yêu cầu thi AI-300 (tập trung vào Data Asset, Command Job, MLflow tracking, Model Registry).

**Phương án bị loại bỏ:**
- **Kaggle + Webhook:** KHÔNG dùng vì yêu cầu Service Principal, Entra ID, secrets phức tạp; Kaggle không phải service Azure, khó tích hợp và bảo trì.

**Xử lý vấn đề GPU:**
- **Mock Training Job:** Dùng để học cơ chế (mlflow.autolog, CommandJob) – chạy trên CPU với sklearn digits, không liên quan đến YOLO. Chạy tay 1 lần, không đưa vào CI/CD.
- **Validation & Promotion Job:** Core CI/CD, chạy YOLO inference trên CPU (không cần GPU). Đây mới là pipeline thật.

**Quyết định về Resource Group:**
- **KHÔNG** gộp chung RG cho hai dự án (CV tracking và GenAI chatbot). Lý do: RG miễn phí, gộp không tiết kiệm chi phí; gây ô nhiễm tracking, xung đột lifecycle, tăng blast radius.
- **Giải pháp:** Tách thành 2 RG: `rg-cv-tracking-prod` và `rg-genai-agent-prod`. Nên dùng IaC (Bicep/Terraform) để tự động hóa.

## Lệnh và Cấu hình cụ thể đã dùng

**3.1. Lệnh tạo Data Asset cho checkpoint (chạy 1 lần)**
```bash
az ml data create --name yolo-checkpoint-raw --version 1 \
  --path ./local/best.pt --type uri_file \
  --datastore workspaceblobstore
```

**3.2. Script `mock_train.py` (chạy tay để học cơ chế)**
```python
import mlflow
import argparse
from sklearn.datasets import load_iris
from sklearn.linear_model import LogisticRegression
from sklearn.model_selection import train_test_split
from sklearn.metrics import accuracy_score

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--penalty", type=float, default=1.0)
    args = parser.parse_args()

    mlflow.autolog()
    with mlflow.start_run():
        X, y = load_iris(return_X_y=True)
        X_train, X_test, y_train, y_test = train_test_split(X, y, test_size=0.2)
        model = LogisticRegression(C=args.penalty, max_iter=200)
        model.fit(X_train, y_train)
        preds = model.predict(X_test)
        acc = accuracy_score(y_test, preds)
        mlflow.log_metric("manual_accuracy", acc)

if __name__ == "__main__":
    main()
```

**3.3. Script `src/validate_and_register.py` (core CI/CD)**
```python
import argparse
import mlflow
from ultralytics import YOLO

def parse_args():
    parser = argparse.ArgumentParser()
    parser.add_argument("--checkpoint_path", type=str, required=True, help="Đường dẫn mount file best.pt")
    parser.add_argument("--data_path", type=str, required=True, help="Đường dẫn mount thư mục dummy_data (chứa data.yaml)")
    parser.add_argument("--map_threshold", type=float, default=0.75, help="Ngưỡng mAP50-95 để promote mô hình")
    return parser.parse_args()

def main():
    args = parse_args()
    with mlflow.start_run() as run:
        print(f"Loading model from: {args.checkpoint_path}")
        model = YOLO(args.checkpoint_path)
        yaml_path = f"{args.data_path}/data.yaml"
        print("Bắt đầu validation trên CPU...")
        metrics = model.val(data=yaml_path, device='cpu')
        map50_95 = metrics.box.map
        map50 = metrics.box.map50
        latency_ms = sum(metrics.speed.values())

        mlflow.log_metric("map50_95", map50_95)
        mlflow.log_metric("map50", map50)
        mlflow.log_metric("latency_ms", latency_ms)
        mlflow.log_artifact(args.checkpoint_path, artifact_path="model_weights")

        if map50_95 >= args.map_threshold:
            print(f"Validation passed: map {map50_95:.4f} >= {args.map_threshold}. Đăng ký mô hình...")
            model_uri = f"runs:/{run.info.run_id}/model_weights"
            mlflow.register_model(model_uri=model_uri, name="yolo-football-tracker")
        else:
            raise SystemExit(f"Validation failed: map {map50_95:.4f} < {args.map_threshold}. Hủy quy trình promote.")

if __name__ == "__main__":
    main()
```

**3.4. Azure ML Command Job (`job.yml`)**
```yaml
$schema: https://azuremlschemas.azureedge.net/latest/commandJob.schema.json
type: command
description: YOLO Validation and Registration Job
experiment_name: yolo-ci-cd-pipeline
command: >-
  python src/validate_and_register.py
  --checkpoint_path ${{inputs.model_checkpoint}}
  --data_path ${{inputs.validation_data}}
  --map_threshold 0.70
inputs:
  model_checkpoint:
    type: uri_file
    path: azureml:yolo-checkpoint-raw:1
  validation_data:
    type: uri_folder
    path: azureml:yolo-dummy-data:1
environment: azureml:yolo-cpu-env@latest
compute: azureml:cpu-cluster
```

**3.5. GitHub Actions Workflow (`.github/workflows/mlops.yml`)**
```yaml
name: YOLO MLops Pipeline
on:
  push:
    branches:
      - main
    paths:
      - 'src/**'
      - 'job.yml'
  workflow_dispatch:

jobs:
  validate-and-register:
    runs-on: ubuntu-latest
    steps:
      - name: Checkout repository
        uses: actions/checkout@v3
      - name: Azure Login
        uses: azure/login@v1
        with:
          creds: ${{ secrets.AZURE_CREDENTIALS }}
      - name: Install az ml extension
        run: az extension add -n ml -y
      - name: Submit Validation Job
        run: |
          az ml job create \
            --file job.yml \
            --resource-group <tên_resource_group> \
            --workspace-name <tên_workspace> \
            --stream
```

## Lỗi gặp phải và Cách khắc phục

- **Anti-pattern:** Gộp "training thật" (YOLO cần GPU) và "validation/promotion" vào cùng một pipeline. → **Cách khắc phục:** Tách rõ: Mock training (CPU, sklearn) để học cơ chế, validation job (CPU, YOLO) cho CI/CD thực tế.
- **Sai lầm:** Nghĩ rằng Resource Group gây tốn phí và nên gộp để tiết kiệm. → **Khắc phục:** RG miễn phí, việc gộp không tiết kiệm chi phí mà còn gây rủi ro; cần tách RG theo domain.
- **Lưu ý về environment:** YOLO inference yêu cầu thư viện `ultralytics`; cần tạo custom environment (docker image) chứa đủ dependencies, không dùng base image mặc định.

## Lộ trình chi tiết (Sprint 1 tuần)

| Ngày | Mục tiêu | Hoạt động cụ thể |
|------|----------|------------------|
| **Ngày 1** | Chuẩn bị Data Assets & Environment | Đẩy `best.pt` lên Datastore dưới dạng `uri_file`. Đẩy `dummy_data` (có `data.yaml`) lên Datastore dưới dạng `uri_folder`. Tạo custom environment chứa `ultralytics`, `mlflow`. |
| **Ngày 2** | Thực thi Mock Training (chạy tay) | Chạy `mock_train.py` trên CPU cluster, xác minh `mlflow.autolog`, CommandJob parameters, Experiment Tracking. |
| **Ngày 3-4** | Lập trình Validation & Promotion Logic | Hoàn thiện `validate_and_register.py`. Xử lý đường dẫn mount (Linux path). Trích xuất metrics từ YOLO (`mAP50-95`, `latency_ms`). |
| **Ngày 5** | Cấu hình Azure ML Job (YAML) | Viết `job.yml` kết nối Data Inputs, Code, Environment, Compute. Kiểm thử bằng `az ml job create`. |
| **Ngày 6-7** | CI/CD Pipeline với GitHub Actions | Viết workflow YAML. Thiết lập OIDC hoặc Service Principal secret. Kích hoạt trigger khi push code vào `src/` hoặc `job.yml`. Xác nhận model tự động được đăng ký vào Registry nếu pass validation. |

## Khái niệm & Định nghĩa

| Thuật ngữ | Định nghĩa | Ví dụ trong hội thoại |
|-----------|------------|-----------------------|
| **Data Asset** | Tài nguyên quản lý dữ liệu trong Azure ML, có thể là file hoặc thư mục, được mount vào compute khi chạy job. | `az ml data create` để đưa `best.pt` lên Datastore, sau đó dùng làm input trong `job.yml`. |
| **Command Job** | Đơn vị thực thi một script/lệnh trên compute target, với inputs/outputs được định nghĩa rõ ràng. | Job YAML gọi `python validate_and_register.py` với các inputs là `model_checkpoint` và `validation_data`. |
| **MLflow Tracking** | Ghi lại metrics, parameters, artifacts của một run; trong Azure ML, URI tracking tự động trỏ về workspace. | `mlflow.log_metric("map50_95", map50_95)` và `mlflow.log_artifact(checkpoint_path, artifact_path="model_weights")`. |
| **Model Registry** | Kho lưu trữ có phiên bản các model đã đăng ký, hỗ trợ lineage và deployment. | `mlflow.register_model(model_uri=f"runs:/{run.info.run_id}/model_weights", name="yolo-football-tracker")`. |
| **Promotion Gate** | Điều kiện kiểm tra trước khi cho phép đăng ký model vào Registry (ví dụ: mAP >= ngưỡng). | Nếu `map50_95 >= args.map_threshold` thì đăng ký, ngược lại raise SystemExit. |

## Các phương án đã cân nhắc

| Phương án | Ưu điểm | Nhược điểm | Được chọn? |
|-----------|---------|------------|------------|
| **Kaggle + Webhook** (cũ) | Lineage có thể đạt được, nhưng phức tạp. | Cần Service Principal, Entra ID, secrets 2 phía; Kaggle không phải service Azure; khó bảo trì. | **KHÔNG** |
| **Local checkpoint + Datastore + Validation job** (mới) | Đơn giản, bảo mật thấp (chỉ Azure), native Azure ML, phù hợp thi AI-300. | Không có training thật trên Azure (nhưng không cần thiết). | **CÓ** |
| **Gộp chung Resource Group** | Tiện quản lý, nhìn tổng thể. | Không tiết kiệm chi phí (RG free); ô nhiễm tracking; blast radius lớn; xung đột lifecycle (CV vs GenAI). | **KHÔNG** |
| **Tách Resource Group** | Rõ ràng domain, dễ quản lý, giảm blast radius, tracking sạch. | Phải cấu hình 2 lần (có thể dùng IaC). | **CÓ** |

**Tiêu chí quyết định:** Giảm độ phức tạp, bám sát yêu cầu AI-300 (tập trung vào Azure ML native), tránh phụ thuộc bên thứ ba, tối ưu bảo mật và chi phí (RG không tạo chi phí).