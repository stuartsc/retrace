"""Offline, authored-corpus retrieval experiment; never opens a Retrace library.

This is an evaluation tool, not an index, production permission fence or model worker.
The caller supplies the frozen export produced by ProgressiveRecallBenchmarkTests.
"""
from __future__ import annotations

import argparse
import hashlib
from importlib.metadata import version
import json
import math
import os
from pathlib import Path
import platform
import resource
import signal
import subprocess
import sys
import time
import uuid

HERE = Path(__file__).resolve().parent
DATASET = HERE.parents[1] / "docs/fixtures/progressive-recall/phase2d/dataset.json"
DATASET_SHA256 = "93b521bf9f5fc9bcd621b9e91a485c8fcc0681c3057a9f5237effad91e41b694"
MINILM = "sentence-transformers/all-MiniLM-L6-v2"
BGE = "BAAI/bge-reranker-v2-m3"
MAX_RSS_BYTES = 12 * 1024**3


def digest(path: Path) -> str:
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def chunk_inputs(text, tokenizer, budget=224, overlap=32):
    """Keep all tokens and original offsets; prefer a nearby line/sentence boundary.

    Inference consumes the original token IDs, avoiding lossy decode/re-tokenize.
    Complete original evidence remains in the immutable export for expansion.
    """
    if budget <= 0 or overlap < 0 or overlap >= budget:
        raise ValueError("Chunk budget must make forward progress")
    encoded = tokenizer(text, add_special_tokens=False, truncation=False,
                        return_offsets_mapping=True)
    ids, offsets = encoded["input_ids"], encoded["offset_mapping"]
    chunks, start = [], 0
    while start < len(ids):
        end = min(start + budget, len(ids))
        if end < len(ids):
            lower = max(start + overlap + 1, end - min(48, budget // 4))
            for candidate in range(end, lower - 1, -1):
                boundary = text[offsets[candidate - 1][1]:offsets[candidate][0]]
                previous = text[offsets[candidate - 1][0]:offsets[candidate - 1][1]]
                if "\n" in boundary or previous.endswith((".", "!", "?", ";")):
                    end = candidate
                    break
        first_char = 0 if start == 0 else offsets[start][0]
        last_char = len(text) if end == len(ids) else offsets[end][0]
        chunks.append(dict(input_ids=ids[start:end], tokenStart=start, tokenEnd=end,
                           start=first_char, end=last_char, text=text[first_char:last_char]))
        if end == len(ids):
            break
        start = end - overlap
    return chunks


def evidence_key(reference):
    required = {"source", "storeID", "observationID", "frameID", "extractionRevision", "blockIDs"}
    if set(reference) != required or reference["source"] not in {"native", "rewind"}:
        raise ValueError("Malformed exact evidence reference")
    normalized = dict(reference)
    for key in ("storeID", "observationID"):
        normalized[key] = str(uuid.UUID(reference[key]))
    frame = reference["frameID"]
    if (not isinstance(frame, dict) or set(frame) != {"value"}
            or type(frame["value"]) is not int or frame["value"] <= 0
            or type(reference["extractionRevision"]) is not int or reference["extractionRevision"] < 0):
        raise ValueError("Invalid evidence revision/frame")
    blocks = reference["blockIDs"]
    if (not isinstance(blocks, list) or any(type(block) is not int or block < 0 for block in blocks)
            or len(set(blocks)) != len(blocks)):
        raise ValueError("Invalid selected blocks")
    return json.dumps(normalized, sort_keys=True, separators=(",", ":"))


def fuse_rankings(rankings, allowed, constant=60):
    if constant <= 0 or len(set(allowed)) != len(allowed):
        raise ValueError("Invalid fusion pool/constant")
    positions = {key: index for index, key in enumerate(allowed)}
    scores = {}
    for ranking in rankings:
        if len(set(ranking)) != len(ranking) or any(key not in positions for key in ranking):
            raise ValueError("Channel contains duplicate, stale or disallowed evidence")
        for rank, key in enumerate(ranking, 1):
            scores[key] = scores.get(key, 0) + 1 / (constant + rank)
    return sorted(scores, key=lambda key: (-scores[key], positions[key]))


def verify_files(directory, artifacts):
    inventory = set()
    for path in directory.rglob("*"):
        if path.is_dir() and not path.is_symlink():
            continue
        if not path.is_file():
            raise ValueError("Unexpected non-file artifact in model snapshot")
        inventory.add(str(path.relative_to(directory)))
    if inventory != set(artifacts):
        raise ValueError("Model snapshot contains missing or unpinned loader inputs")
    for relative, expected in artifacts.items():
        name = Path(relative)
        if name.is_absolute() or ".." in name.parts:
            raise ValueError("Artifact path escapes its snapshot")
        path = directory / name  # HF snapshots intentionally symlink to the blob cache.
        if (not path.is_file() or path.stat().st_size != expected["bytes"]
                or digest(path) != expected["sha256"]):
            raise ValueError(f"Artifact pin mismatch: {relative}")


def run_owned(command, *, timeout, environment, output):
    """Own one process group; drain it on deadline, RSS limit or interruption."""
    if timeout <= 0:
        raise ValueError("Deadline must be positive")
    process = subprocess.Popen(command, env=environment, stdout=output,
                               stderr=subprocess.STDOUT, start_new_session=True)
    deadline = time.monotonic() + timeout
    try:
        while process.poll() is None:
            if time.monotonic() >= deadline:
                raise TimeoutError("Owned benchmark worker exceeded its deadline")
            usage = subprocess.run(["/bin/ps", "-o", "rss=", "-p", str(process.pid)],
                                   capture_output=True, text=True, timeout=2, check=False)
            if usage.returncode == 0 and usage.stdout.strip():
                if int(usage.stdout.strip()) * 1024 > MAX_RSS_BYTES:
                    raise MemoryError("Owned benchmark worker exceeded 12 GiB RSS")
            time.sleep(min(0.1, max(0, deadline - time.monotonic())))
        return process.returncode
    finally:
        # Kill the owned group even if its leader exited, so descendants cannot
        # keep running after a failed/finished request. Never use a global pkill.
        try:
            os.killpg(process.pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
        try:
            process.wait(timeout=3)
        except subprocess.TimeoutExpired:
            pass
        # Waiting for the leader is not evidence that every owned descendant
        # honoured SIGTERM (or even that the leader was still running).
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        if process.returncode is None:
            process.wait(timeout=3)


def read_json(path, maximum_bytes=4 * 1024**2, expected_sha256=None):
    if path.stat().st_size > maximum_bytes:
        raise ValueError("Benchmark input exceeds its bounded file budget")
    data = path.read_bytes()
    if len(data) > maximum_bytes:
        raise ValueError("Benchmark input grew beyond its bounded file budget")
    if expected_sha256 is not None and hashlib.sha256(data).hexdigest() != expected_sha256:
        raise ValueError("Frozen input SHA256 mismatch")
    def invalid_constant(value):
        raise ValueError(f"Non-finite JSON number: {value}")
    return json.loads(data, parse_constant=invalid_constant)


def load_export(path, expected_sha256):
    if not isinstance(expected_sha256, str) or len(expected_sha256) != 64 or any(c not in "0123456789abcdef" for c in expected_sha256):
        raise ValueError("Supply the frozen SHA256 emitted by the Swift exporter")
    dataset = read_json(DATASET, expected_sha256=DATASET_SHA256)
    exported = read_json(path, expected_sha256=expected_sha256)
    if (exported.get("kind") != "retrace-authored-recall-benchmark"
            or exported.get("schemaVersion") != 1 or exported.get("datasetSHA256") != DATASET_SHA256):
        raise ValueError("Expected the frozen authored-corpus export")
    screens = exported["screens"]
    expected_screens = {screen["id"]: screen for screen in dataset["screens"]}
    if len(screens) != 8 or {screen["id"] for screen in screens} != set(expected_screens):
        raise ValueError("Export is not the reviewed eight-screen corpus")
    refs = {}
    for screen in screens:
        expected = expected_screens[screen["id"]]
        for field in ("imageSHA256", "capturedAt", "appBundleID", "title"):
            if screen[field] != expected[field]:
                raise ValueError(f"Changed authored screen: {screen['id']} / {field}")
        main, chrome = screen["mainText"], screen["chromeText"]
        if not isinstance(main, str) or not isinstance(chrome, str) or len(main) + len(chrome) > 131072:
            raise ValueError("Unexpected text payload")
        if hashlib.sha256((main + "\n" + chrome).encode()).hexdigest() != screen["textSHA256"]:
            raise ValueError("Retained text digest mismatch")
        if screen["ref"]["source"] != "native":
            raise ValueError("This experiment accepts authored native evidence only")
        refs[screen["id"]] = evidence_key(screen["ref"])
    if len(set(refs.values())) != 8:
        raise ValueError("Duplicate exact evidence in export")
    questions = exported["questions"]
    if len(questions) != 12 or [q["id"] for q in questions] != [q["id"] for q in dataset["questions"]]:
        raise ValueError("Changed benchmark questions")
    for question, expected in zip(questions, dataset["questions"]):
        for field in ("id", "question", "keywordQuery", "constraints", "expectedIDs"):
            if question[field] != expected[field]:
                raise ValueError(f"Changed frozen question: {question['id']} / {field}")
        allowed = question["allowedIDs"]
        if len(set(allowed)) != len(allowed) or not set(allowed) <= set(refs):
            raise ValueError("Malformed allowed pool")
        if not set(question["expectedIDs"]) <= set(allowed):
            raise ValueError("Oracle is outside the allowed pool")
        if [evidence_key(ref) for ref in question["expectedRefs"]] != [refs[i] for i in expected["expectedIDs"]]:
            raise ValueError("Oracle binding changed source/store/revision")
        for channel in ("fullQuestion", "authoredKeywords"):
            ordered = question[channel]["orderedIDs"]
            if len(set(ordered)) != len(ordered) or not set(ordered) <= set(allowed):
                raise ValueError("Lexical ranking violates the frozen pool")
            if [evidence_key(ref) for ref in question[channel]["orderedRefs"]] != [refs[i] for i in ordered]:
                raise ValueError("Lexical result changed source/store/revision")
            elapsed = question[channel]["elapsedMs"]
            if len(elapsed) != 4 or any(type(x) not in (int, float) or not math.isfinite(x) or x < 0 for x in elapsed):
                raise ValueError("Expected four measured lexical samples")
    checks = exported.get("safetyChecks", {})
    if (set(checks) != {"wrongStoreRefused", "sameNumericCrossSourceRefused", "excludedAppRefused", "deletedRefRefused"}
            or not all(value is True for value in checks.values())):
        raise ValueError("Exact-reference refusal checks did not pass")
    return dataset, exported, refs


def ranking_metrics(questions, rankings):
    values = []
    for question in questions:
        expected = set(question["expectedIDs"])
        ranking = rankings[question["id"]]
        ranks = [ranking.index(key) + 1 for key in expected if key in ranking]
        values.append({"questionID": question["id"],
                       **{f"recallAt{k}": len(expected.intersection(ranking[:k])) / len(expected) for k in (1, 3, 5)},
                       "reciprocalRank": 1 / min(ranks) if ranks else 0})
    return {"perQuestion": values,
            "mean": {key: sum(row[key] for row in values) / len(values)
                     for key in ("recallAt1", "recallAt3", "recallAt5", "reciprocalRank")}}


def worker(args):
    started = time.perf_counter()
    dataset, exported, refs = load_export(args.export, args.export_sha256)
    pins = read_json(HERE / "model-pins.json")
    if platform.python_version() != pins["python"]:
        raise ValueError("Python version differs from the frozen runtime")
    for package, expected in pins["runtime"].items():
        if version(package) != expected:
            raise ValueError(f"Runtime version mismatch: {package}")
    paths = {}
    for name in (MINILM, BGE):
        pin = pins["models"][name]
        path = args.cache / ("models--" + name.replace("/", "--")) / "snapshots" / pin["revision"]
        verify_files(path, pin["artifacts"])
        paths[name] = path
    import numpy as np
    import torch
    from transformers import AutoModel, AutoModelForSequenceClassification, AutoTokenizer

    torch.set_num_threads(pins["threads"])
    torch.set_num_interop_threads(pins["interopThreads"])
    torch.manual_seed(0)
    torch.use_deterministic_algorithms(True)
    options = dict(local_files_only=True, trust_remote_code=False)
    config = dataset["ranking"]
    screens, questions = exported["screens"], exported["questions"]
    texts = {s["id"]: s["mainText"] + "\n" + s["chromeText"] for s in screens}
    result = {"schemaVersion": 1, "kind": "authored-corpus-ranking-results", "datasetSHA256": DATASET_SHA256,
              "exportSHA256": args.export_sha256, "pinsSHA256": digest(HERE / "model-pins.json"),
              "scriptSHA256": digest(Path(__file__)), "modelPins": pins, "rankingConfiguration": config,
              "runtime": {"platform": platform.platform(), "processor": platform.machine(),
                          "torchGitRevision": torch.version.git_version, "torchCPUConfiguration": torch.__config__.show()},
              "scope": "Offline authored OCR snapshot; no production index/readiness or image reopening.",
              "rankings": {}, "latencyMs": {}, "scores": {}, "safetyChecks": exported["safetyChecks"]}
    for method, channel in (("lexicalFullQuestion", "fullQuestion"), ("lexicalAuthoredKeywords", "authoredKeywords")):
        result["rankings"][method] = {q["id"]: q[channel]["orderedIDs"] for q in questions}
        result["latencyMs"][method] = {q["id"]: q[channel]["elapsedMs"] for q in questions}

    load_start = time.perf_counter()
    tokenizer = AutoTokenizer.from_pretrained(paths[MINILM], use_fast=True, **options)
    model = AutoModel.from_pretrained(paths[MINILM], use_safetensors=True, **options).eval().to(device="cpu", dtype=torch.float32)
    result["miniLMLoadMs"] = (time.perf_counter() - load_start) * 1000

    def encode(chunks):
        vectors = []
        for offset in range(0, len(chunks), config["batchSize"]):
            batch = chunks[offset:offset + config["batchSize"]]
            inputs = [tokenizer.prepare_for_model(c["input_ids"], add_special_tokens=True,
                      truncation=False, return_attention_mask=True) for c in batch]
            if any(len(item["input_ids"]) > config["miniLMTotalTokens"] for item in inputs):
                raise ValueError("MiniLM complete input exceeds its pinned budget")
            tensor = tokenizer.pad(inputs, padding=True, return_tensors="pt")
            with torch.inference_mode():
                output = model(**tensor).last_hidden_state
                mask = tensor["attention_mask"].unsqueeze(-1).to(output.dtype)
                pooled = (output * mask).sum(1) / mask.sum(1).clamp(min=1e-9)
                vectors.append(torch.nn.functional.normalize(pooled, p=2, dim=1).numpy())
        return np.concatenate(vectors).astype(np.float32)

    index_start = time.perf_counter()
    chunks_by_id = {key: chunk_inputs(text, tokenizer, config["miniLMContentTokens"], config["miniLMOverlapTokens"])
                    for key, text in texts.items()}
    if any(not chunks for chunks in chunks_by_id.values()):
        raise ValueError("Authored corpus unexpectedly has no tokenizable text")
    vectors_by_id = {key: encode(chunks) for key, chunks in chunks_by_id.items()}
    np.save(args.output / "minilm-vectors.npy", np.concatenate(list(vectors_by_id.values())), allow_pickle=False)
    chunk_index = [{"id": key, "ref": next(s["ref"] for s in screens if s["id"] == key),
                    "chunks": [{k: v for k, v in c.items() if k != "input_ids"} for c in chunks]}
                   for key, chunks in chunks_by_id.items()]
    (args.output / "minilm-chunks.json").write_text(json.dumps(chunk_index, indent=2) + "\n")
    result["miniLMIndexMs"] = (time.perf_counter() - index_start) * 1000
    result["indexBytes"] = {name: (args.output / name).stat().st_size
                            for name in ("minilm-vectors.npy", "minilm-chunks.json")}
    result["rankings"]["embedding"] = {}
    result["latencyMs"]["embedding"] = {}
    result["scores"]["embedding"] = {}
    for question in questions:
        samples, observed = [], []
        for repetition in range(1 + config["warmRepetitions"]):
            before = time.perf_counter()
            q_vectors = encode(chunk_inputs(question["question"], tokenizer,
                               config["miniLMContentTokens"], config["miniLMOverlapTokens"]))
            scores = {key: float((q_vectors @ vectors_by_id[key].T).max(axis=1).mean()) for key in question["allowedIDs"]}
            ranking = sorted(scores, key=lambda key: (-scores[key], question["allowedIDs"].index(key)))
            samples.append((time.perf_counter() - before) * 1000)
            observed.append(ranking)
            if "workerEntryToFirstEmbeddingResultMs" not in result:
                result["workerEntryToFirstEmbeddingResultMs"] = (time.perf_counter() - started) * 1000
        if any(row != observed[0] for row in observed):
            raise ValueError("Embedding ordering changed across repeated runs")
        result["rankings"]["embedding"][question["id"]] = observed[0]
        result["latencyMs"]["embedding"][question["id"]] = samples
        result["scores"]["embedding"][question["id"]] = scores
    result["rankings"]["fusion"] = {}
    inverse_refs = {value: key for key, value in refs.items()}
    for question in questions:
        channels = [[refs[key] for key in result["rankings"][method][question["id"]]]
                    for method in ("lexicalFullQuestion", "embedding")]
        fused = fuse_rankings(channels, [refs[key] for key in question["allowedIDs"]], config["reciprocalRankConstant"])
        result["rankings"]["fusion"][question["id"]] = [inverse_refs[key] for key in fused]
    del model

    load_start = time.perf_counter()
    tokenizer = AutoTokenizer.from_pretrained(paths[BGE], use_fast=True, **options)
    model = AutoModelForSequenceClassification.from_pretrained(paths[BGE], use_safetensors=True, **options).eval().to(device="cpu", dtype=torch.float32)
    result["rerankerLoadMs"] = (time.perf_counter() - load_start) * 1000
    result["rankings"]["rerankedPool"] = {}
    result["latencyMs"]["rerankedPool"] = {}
    result["scores"]["rerankedPool"] = {}
    passage_chunks = {key: chunk_inputs(text, tokenizer) for key, text in texts.items()}
    for question in questions:
        samples, observed = [], []
        for repetition in range(1 + config["warmRepetitions"]):
            before = time.perf_counter()
            queries = chunk_inputs(question["question"], tokenizer)
            pairs, owners = [], []
            for key in question["allowedIDs"]:
                for query_index, query in enumerate(queries):
                    for passage in passage_chunks[key]:
                        item = tokenizer.prepare_for_model(query["input_ids"], pair_ids=passage["input_ids"],
                            add_special_tokens=True, truncation=False, return_attention_mask=True,
                            return_token_type_ids=False)
                        if len(item["input_ids"]) > config["rerankerPairTokens"]:
                            raise ValueError("Reranker pair exceeds its explicit operating budget")
                        pairs.append(item)
                        owners.append((key, query_index))
            best = {key: [-math.inf] * len(queries) for key in question["allowedIDs"]}
            for offset in range(0, len(pairs), config["batchSize"]):
                tensor = tokenizer.pad(pairs[offset:offset + config["batchSize"]], padding=True, return_tensors="pt")
                with torch.inference_mode():
                    scores = model(**tensor).logits.view(-1).float().tolist()
                for (key, query_index), score in zip(owners[offset:offset + len(scores)], scores):
                    if not math.isfinite(score):
                        raise ValueError("Non-finite reranker score")
                    best[key][query_index] = max(best[key][query_index], score)
            # A long question must cover every query window, not only its easiest clause.
            scores = {key: min(values) for key, values in best.items()}
            fused = result["rankings"]["fusion"][question["id"]]
            ranking = sorted(scores, key=lambda key: (-scores[key], fused.index(key)))
            samples.append((time.perf_counter() - before) * 1000)
            observed.append(ranking)
        if any(row != observed[0] for row in observed):
            raise ValueError("Reranker ordering changed across repeated runs")
        result["rankings"]["rerankedPool"][question["id"]] = observed[0]
        result["latencyMs"]["rerankedPool"][question["id"]] = samples
        result["scores"]["rerankedPool"][question["id"]] = scores
    result["metrics"] = {method: ranking_metrics(questions, rankings) for method, rankings in result["rankings"].items()}
    for name in (MINILM, BGE):
        verify_files(paths[name], pins["models"][name]["artifacts"])
    result["modelArtifactsUnchanged"] = True
    result["peakRSSBytes"] = resource.getrusage(resource.RUSAGE_SELF).ru_maxrss * (1 if sys.platform == "darwin" else 1024)
    result["elapsedSeconds"] = time.perf_counter() - started
    result["complete"] = True
    (args.output / "results.json").write_text(json.dumps(result, indent=2, sort_keys=True, allow_nan=False) + "\n")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("mode", choices=("run", "worker"))
    parser.add_argument("--export", type=Path, required=True)
    parser.add_argument("--export-sha256", required=True, help="SHA256 emitted by the successful Swift export test")
    parser.add_argument("--cache", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--deadline", type=float, default=600)
    args = parser.parse_args()
    if args.mode == "worker":
        worker(args)
        return
    if not 1 <= args.deadline <= 600:
        parser.error("Deadline must be between 1 and 600 seconds")
    load_export(args.export, args.export_sha256)
    args.output.mkdir(mode=0o700, parents=False, exist_ok=False)
    inputs = {str(path): digest(path) for path in (args.export, DATASET, HERE / "model-pins.json", Path(__file__))}
    env = os.environ.copy()
    env.update(HF_HUB_OFFLINE="1", TRANSFORMERS_OFFLINE="1", TOKENIZERS_PARALLELISM="false",
               OMP_NUM_THREADS="2", MKL_NUM_THREADS="2", OPENBLAS_NUM_THREADS="2", PYTHONHASHSEED="0")
    command = ["/usr/bin/nice", "-n", "10", sys.executable, str(Path(__file__)), "worker", "--export", str(args.export),
               "--export-sha256", args.export_sha256, "--cache", str(args.cache), "--output", str(args.output)]
    started = time.perf_counter()
    receipt = {"inputsBefore": inputs, "expectedExportSHA256": args.export_sha256,
               "command": command, "deadlineSeconds": args.deadline, "rssLimitBytes": MAX_RSS_BYTES}
    try:
        with (args.output / "worker.log").open("x") as log:
            receipt["exitCode"] = run_owned(command, timeout=args.deadline, environment=env, output=log)
        if receipt["exitCode"] != 0:
            raise RuntimeError("Benchmark worker failed; inspect worker.log")
        results = read_json(args.output / "results.json")
        if results.get("complete") is not True:
            raise RuntimeError("Benchmark worker did not complete")
    except BaseException as error:
        receipt["error"] = str(error)
        raise
    finally:
        receipt["elapsedSeconds"] = time.perf_counter() - started
        receipt["inputsUnchanged"] = all(digest(Path(path)) == sha for path, sha in inputs.items())
        receipt["artifacts"] = {path.name: digest(path) for path in args.output.iterdir() if path.is_file()}
        (args.output / "receipt.json").write_text(json.dumps(receipt, indent=2, sort_keys=True) + "\n")
    if not receipt["inputsUnchanged"]:
        raise RuntimeError("Benchmark inputs changed during execution")
    print(json.dumps({"output": str(args.output), "elapsedSeconds": receipt["elapsedSeconds"], "metrics": results["metrics"]}, indent=2))


if __name__ == "__main__":
    main()
