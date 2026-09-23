"""
Microsoft Foundry AI-300 Golden Dataset evaluation runner.

Current SDK target:
    azure-ai-projects==2.7.0
This script uses the current AIProjectClient + OpenAI-compatible Evals API.

Install:
    pip install "azure-ai-projects==2.7.0" azure-identity python-dotenv

Authentication:
    az login

Required environment variables:
    FOUNDRY_PROJECT_ENDPOINT
        Example:
        https://<account>.services.ai.azure.com/api/projects/<project>

    FOUNDRY_JUDGE_DEPLOYMENT
        LLM deployment used by the Foundry evaluators, e.g. gpt-5-mini.

    FOUNDRY_AGENT_NAME
        Foundry prompt/hosted agent name to evaluate.

Optional:
    FOUNDRY_AGENT_VERSION
        Pin an agent version. If omitted, Foundry uses the latest version.

    GOLDEN_DATASET
        Local JSONL path. Default: ./golden_dataset.jsonl

    CONTEXT_DIR
        Directory containing context files referenced by the dataset's
        "context" field. Example:
            context: "split1_2.md"
        The script will replace that filename with the file contents before
        uploading the evaluation dataset.

    DATASET_NAME
        Foundry dataset name. Default: MS-AI300-Golden-Dataset

    DATASET_VERSION
        Dataset version. Default: UTC timestamp.

    QUALITY_GRADER_EVALUATOR_NAME
        Optional backend evaluator name for the Quality Grader.
        Default: builtin.quality
        If your Foundry tenant exposes a different catalog identifier,
        override this variable rather than changing the script.

Important:
    The six 1-5 evaluators are configured with threshold=5.
    Quality Grader intentionally receives NO explicit threshold here and
    therefore uses the service's own default. This avoids inventing a
    threshold contract that is not exposed in the current public SDK docs.

Expected source dataset schema per row:
    {
      "query": "...",
      "ground_truth": "...",
      "context": "split1_2.md"
    }

The script keeps only those three fields in the uploaded evaluation dataset.
"""

from __future__ import annotations

import json
import os
import sys
import time
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from azure.ai.projects import AIProjectClient
from azure.identity import DefaultAzureCredential
from azure.ai.projects.models import TestingCriterionAzureAIEvaluator
from dotenv import load_dotenv


# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

load_dotenv()

FOUNDRY_PROJECT_ENDPOINT = os.environ["FOUNDRY_PROJECT_ENDPOINT"]
FOUNDRY_JUDGE_DEPLOYMENT = os.environ["FOUNDRY_JUDGE_DEPLOYMENT"]
FOUNDRY_AGENT_NAME = os.environ["FOUNDRY_AGENT_NAME"]
FOUNDRY_AGENT_VERSION = os.environ.get("FOUNDRY_AGENT_VERSION")

GOLDEN_DATASET = Path(os.environ.get("GOLDEN_DATASET", "./golden_dataset.jsonl"))
CONTEXT_DIR = Path(os.environ.get("CONTEXT_DIR", GOLDEN_DATASET.parent))

DATASET_NAME = os.environ.get("DATASET_NAME", "MS-AI300-Golden-Dataset")
DATASET_VERSION = os.environ.get(
    "DATASET_VERSION",
    datetime.now(timezone.utc).strftime("%Y%m%d-%H%M%S"),
)

QUALITY_GRADER_EVALUATOR_NAME = os.environ.get("QUALITY_GRADER_EVALUATOR_NAME")

THRESHOLD_FILE = Path(
    os.environ.get(
        "THRESHOLD_FILE",
        str(Path(__file__).with_name("threshold.json")),
    )
)

POLL_SECONDS = int(os.environ.get("POLL_SECONDS", "5"))
EVAL_NAME_PREFIX = os.environ.get(
    "EVAL_NAME_PREFIX",
    "MS-AI300-with-thngoc",
)


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

REQUIRED_FIELDS = {"query", "ground_truth", "context"}


def fail(message: str) -> None:
    raise RuntimeError(message)


def load_thresholds() -> dict[str, Any]:
    if not THRESHOLD_FILE.exists():
        fail(f"Threshold file not found: {THRESHOLD_FILE}")

    try:
        data = json.loads(THRESHOLD_FILE.read_text(encoding="utf-8"))
    except json.JSONDecodeError as exc:
        fail(f"Invalid threshold.json: {exc}")

    required = [
        "relevance",
        "groundedness",
        "coherence",
        "fluency",
        "similarity",
        "response_completeness",
        "quality_grader",
    ]

    missing = [key for key in required if key not in data]
    if missing:
        fail(f"threshold.json missing keys: {', '.join(missing)}")

    for key in required[:-1]:
        value = data[key].get("threshold")
        if value != 5:
            fail(
                f"{key} threshold must be exactly 5 for this configuration; "
                f"found {value!r}"
            )

    if not data["quality_grader"].get("use_service_default", False):
        fail(
            "quality_grader must use the service default in this script. "
            "Set use_service_default=true."
        )

    return data


def resolve_context(raw_context: str) -> str:
    """
    If context looks like a filename and exists, load its contents.
    Otherwise treat it as already-materialized context text.
    """
    text = str(raw_context).strip()

    # Prefer the exact path relative to CONTEXT_DIR.
    candidate = CONTEXT_DIR / text
    if candidate.is_file():
        return candidate.read_text(encoding="utf-8")

    # Also allow a path relative to the golden dataset location.
    candidate = GOLDEN_DATASET.parent / text
    if candidate.is_file():
        return candidate.read_text(encoding="utf-8")

    # Heuristic: short values ending in a common document extension are
    # probably intended to be filenames. Keep them as-is but warn loudly.
    lowered = text.lower()
    if len(text) < 260 and lowered.endswith(
        (".md", ".txt", ".json", ".pdf", ".docx")
    ):
        print(
            f"[WARN] Context file not found for {text!r}; "
            "Groundedness will receive the literal filename."
        )

    return text


def normalize_dataset(source: Path) -> Path:
    if not source.is_file():
        fail(f"Golden dataset not found: {source}")

    runtime_dir = Path(".foundry_eval_runtime")
    runtime_dir.mkdir(parents=True, exist_ok=True)

    runtime_path = runtime_dir / (
        f"{source.stem}-{DATASET_VERSION}-runtime.jsonl"
    )

    rows = []
    with source.open("r", encoding="utf-8") as handle:
        for line_no, line in enumerate(handle, start=1):
            stripped = line.strip()
            if not stripped:
                continue

            try:
                obj = json.loads(stripped)
            except json.JSONDecodeError as exc:
                fail(f"{source}:{line_no}: invalid JSON: {exc}")

            if not isinstance(obj, dict):
                fail(f"{source}:{line_no}: each row must be a JSON object")

            keys = set(obj.keys())
            if keys != REQUIRED_FIELDS:
                fail(
                    f"{source}:{line_no}: expected exactly "
                    f"{sorted(REQUIRED_FIELDS)}, got {sorted(keys)}"
                )

            for field in REQUIRED_FIELDS:
                if not isinstance(obj[field], str):
                    fail(
                        f"{source}:{line_no}: field {field!r} must be a string"
                    )

            rows.append(
                {
                    "query": obj["query"],
                    "ground_truth": obj["ground_truth"],
                    "context": resolve_context(obj["context"]),
                }
            )

    if not rows:
        fail("Golden dataset contains no usable rows.")

    with runtime_path.open("w", encoding="utf-8") as handle:
        for row in rows:
            handle.write(
                json.dumps(row, ensure_ascii=False, separators=(",", ":"))
                + "\n"
            )

    print(f"[INFO] Normalized {len(rows)} rows -> {runtime_path}")
    return runtime_path


def build_testing_criteria(thresholds: dict[str, Any]) -> list[Any]:
    """
    All requested evaluators are configured here.

    The six quality evaluators use threshold=5.
    Quality Grader intentionally does not receive a threshold parameter.
    """

    def criterion(
        name: str,
        evaluator_name: str,
        mapping: dict[str, str],
        *,
        use_threshold: bool = True,
    ) -> TestingCriterionAzureAIEvaluator:
        init_params = {"deployment_name": FOUNDRY_JUDGE_DEPLOYMENT}

        if use_threshold:
            init_params["threshold"] = thresholds[name]["threshold"]

        return TestingCriterionAzureAIEvaluator(
            type="azure_ai_evaluator",
            name=name,
            evaluator_name=evaluator_name,
            initialization_parameters=init_params,
            data_mapping=mapping,
        )

    return [
        criterion(
            "relevance",
            "builtin.relevance",
            {
                "query": "{{item.query}}",
                "response": "{{sample.output_text}}",
            },
        ),
        criterion(
            "groundedness",
            "builtin.groundedness",
            {
                "query": "{{item.query}}",
                "response": "{{sample.output_text}}",
                "context": "{{item.context}}",
            },
        ),
        criterion(
            "coherence",
            "builtin.coherence",
            {
                "query": "{{item.query}}",
                "response": "{{sample.output_text}}",
            },
        ),
        criterion(
            "fluency",
            "builtin.fluency",
            {
                "response": "{{sample.output_text}}",
            },
        ),
        criterion(
            "similarity",
            "builtin.similarity",
            {
                "query": "{{item.query}}",
                "response": "{{sample.output_text}}",
                "ground_truth": "{{item.ground_truth}}",
            },
        ),
        criterion(
            "response_completeness",
            "builtin.response_completeness",
            {
                "ground_truth": "{{item.ground_truth}}",
                "response": "{{sample.output_text}}",
            },
        ),
        criterion(
            "quality_grader",
            QUALITY_GRADER_EVALUATOR_NAME,
            {
                "query": "{{item.query}}",
                "response": "{{sample.output_text}}",
                "context": "{{item.context}}",
            },
            use_threshold=False,
        ),
    ]


def get_attr(obj: Any, key: str, default: Any = None) -> Any:
    if isinstance(obj, dict):
        return obj.get(key, default)
    return getattr(obj, key, default)


def result_passed(result: Any) -> bool:
    explicit = get_attr(result, "passed")
    if explicit is not None:
        return bool(explicit)

    label = get_attr(result, "label")
    if label is not None:
        return str(label).lower() == "pass"

    return True


def result_name(result: Any) -> str:
    return str(get_attr(result, "name", "?"))


def result_score(result: Any) -> Any:
    return get_attr(result, "score", None)


def result_reason(result: Any) -> str:
    return str(get_attr(result, "reason", ""))


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main() -> int:
    thresholds = load_thresholds()
    runtime_dataset = normalize_dataset(GOLDEN_DATASET)

    eval_name = (
        f"{EVAL_NAME_PREFIX}-"
        f"{datetime.now(timezone.utc).strftime('%Y%m%d-%H%M%S')}"
    )

    print()
    print("=" * 78)
    print("Microsoft Foundry AI-300 evaluation")
    print("=" * 78)
    print(f"Judge deployment : {FOUNDRY_JUDGE_DEPLOYMENT}")
    print(f"Target agent     : {FOUNDRY_AGENT_NAME}")
    print(f"Agent version    : {FOUNDRY_AGENT_VERSION or 'latest'}")
    print(f"Dataset          : {runtime_dataset}")
    print(
        f"Quality Grader   : "
        f"{QUALITY_GRADER_EVALUATOR_NAME or '<must be configured>'}"
    )
    print(f"Evaluation       : {eval_name}")
    print("=" * 78)

    credential = DefaultAzureCredential()

    with (
        credential,
        AIProjectClient(
            endpoint=FOUNDRY_PROJECT_ENDPOINT,
            credential=credential,
        ) as project_client,
        project_client.get_openai_client() as client,
    ):
        # 1) Upload the normalized golden dataset to Foundry.
        dataset = project_client.datasets.upload_file(
            name=DATASET_NAME,
            version=DATASET_VERSION,
            file_path=str(runtime_dataset),
        )

        print(f"[INFO] Foundry dataset uploaded: {dataset.id}")

        # 2) Define the immutable evaluation schema.
        data_source_config = {
            "type": "custom",
            "item_schema": {
                "type": "object",
                "properties": {
                    "query": {"type": "string"},
                    "ground_truth": {"type": "string"},
                    "context": {"type": "string"},
                },
                "required": ["query", "ground_truth", "context"],
            },
            "include_sample_schema": True,
        }

        # 3) Create the evaluation definition.
        testing_criteria = build_testing_criteria(thresholds)

        evaluation = client.evals.create(
            name=eval_name,
            data_source_config=data_source_config,
            testing_criteria=testing_criteria,
        )

        print(f"[INFO] Evaluation created: {evaluation.id}")

        # 4) Create a run against the Foundry agent.
        data_source = {
            "type": "azure_ai_target_completions",
            "source": {
                "type": "file_id",
                "id": dataset.id,
            },
            "input_messages": {
                "type": "template",
                "template": [
                    {
                        "type": "message",
                        "role": "user",
                        "content": {
                            "type": "input_text",
                            "text": "{{item.query}}",
                        },
                    }
                ],
            },
            "target": {
                "type": "azure_ai_agent",
                "name": FOUNDRY_AGENT_NAME,
                **(
                    {"version": FOUNDRY_AGENT_VERSION}
                    if FOUNDRY_AGENT_VERSION
                    else {}
                ),
            },
        }

        eval_run = client.evals.runs.create(
            eval_id=evaluation.id,
            name=f"{eval_name}-run",
            metadata={
                "dataset_name": DATASET_NAME,
                "dataset_version": DATASET_VERSION,
                "judge_deployment": FOUNDRY_JUDGE_DEPLOYMENT,
                "agent_name": FOUNDRY_AGENT_NAME,
                "agent_version": FOUNDRY_AGENT_VERSION or "latest",
            },
            data_source=data_source,
        )

        print(f"[INFO] Evaluation run started: {eval_run.id}")

        # 5) Poll.
        terminal_statuses = {"completed", "failed", "canceled"}
        while eval_run.status not in terminal_statuses:
            time.sleep(POLL_SECONDS)
            eval_run = client.evals.runs.retrieve(
                run_id=eval_run.id,
                eval_id=evaluation.id,
            )
            print(f"[INFO] status={eval_run.status}")

        print()
        print(f"Status     : {eval_run.status}")
        print(f"Report URL : {eval_run.report_url}")

        if eval_run.status != "completed":
            print("[FAIL] Foundry evaluation run did not complete successfully.")
            return 2

        # 6) Strict CI/CD gate:
        #    every evaluator result on every item must be Pass.
        output_items = list(
            client.evals.runs.output_items.list(
                run_id=eval_run.id,
                eval_id=evaluation.id,
            )
        )

        total_items = len(output_items)
        failing_items = 0
        failures: list[dict[str, Any]] = []

        print()
        print("-" * 78)
        print("Per-item evaluator results")
        print("-" * 78)

        for idx, item in enumerate(output_items, start=1):
            results = get_attr(item, "results", None) or []
            item_failed = False

            for result in results:
                passed = result_passed(result)
                if not passed:
                    item_failed = True
                    failures.append(
                        {
                            "item": idx,
                            "evaluator": result_name(result),
                            "score": result_score(result),
                            "reason": result_reason(result),
                        }
                    )

                status = "PASS" if passed else "FAIL"
                print(
                    f"[{status}] item={idx:03d} "
                    f"metric={result_name(result)} "
                    f"score={result_score(result)!r}"
                )

            if item_failed:
                failing_items += 1

        print("-" * 78)
        print(f"Items evaluated : {total_items}")
        print(f"Items with fail  : {failing_items}")

        summary_path = Path(".foundry_eval_runtime") / "last_run_summary.json"
        summary = {
            "evaluation_id": evaluation.id,
            "evaluation_name": evaluation.name,
            "run_id": eval_run.id,
            "status": eval_run.status,
            "report_url": eval_run.report_url,
            "dataset_id": dataset.id,
            "dataset_name": DATASET_NAME,
            "dataset_version": DATASET_VERSION,
            "judge_deployment": FOUNDRY_JUDGE_DEPLOYMENT,
            "agent_name": FOUNDRY_AGENT_NAME,
            "agent_version": FOUNDRY_AGENT_VERSION or "latest",
            "strict_gate": "all_evaluator_results_must_pass",
            "failures": failures,
        }

        summary_path.write_text(
            json.dumps(summary, ensure_ascii=False, indent=2),
            encoding="utf-8",
        )

        if failures:
            print()
            print("[FAIL] Strict quality gate FAILED.")
            print(f"[INFO] Detailed summary: {summary_path}")
            return 1

        print()
        print("[PASS] Strict quality gate PASSED.")
        print(f"[INFO] Detailed summary: {summary_path}")
        return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except KeyboardInterrupt:
        print("\n[FAIL] Interrupted by user.", file=sys.stderr)
        raise SystemExit(130)
    except Exception as exc:
        print(f"\n[ERROR] {exc}", file=sys.stderr)
        raise SystemExit(2)
