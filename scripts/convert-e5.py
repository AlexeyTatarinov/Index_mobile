#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Converts intfloat/multilingual-e5-small to a Core ML mlprogram with int8 weights.
# The model takes input_ids and attention_mask (int32, [1, 256]) and returns the
# masked mean-pooled, L2-normalized sentence embedding [1, 384] named "embedding".
# Also writes the HF tokenizer.json and reference ids/embeddings for the Swift tests.
# Usage: python3 scripts/convert-e5.py <outdir>
# E5_MODEL may point to another HF id or a local directory (used for testing).

import json
import os
import shutil
import sys

import numpy as np
import torch
import coremltools as ct
import coremltools.optimize.coreml as cto
from tokenizers import Tokenizer
from transformers import AutoModel, AutoTokenizer

MODEL_ID = os.environ.get("E5_MODEL", "intfloat/multilingual-e5-small")
SEQ_LEN = 256
PACKAGE = "multilingual_e5_small.mlpackage"

REFERENCE_TEXTS = [
    "query: как оформить налоговый вычет",
    "passage: Договор аренды квартиры № 15 от 3 марта 2024 г.",
    "query: tax deduction for apartment",
    "passage: Счёт-фактура №A-17/2023, сумма 12 500,00 руб. (НДС 20%)",
    "query: e-mail от Ивана про invoice и VPN",
    "Ёлка и щёлк 2024!",
    "passage: Заявление на имущественный налоговый вычет при покупке квартиры",
    "Рецепт борща со сметаной",
]


class E5Embedder(torch.nn.Module):
    """Embeddings + encoder with a hand-made additive mask (fp16 safe), then mean pooling."""

    def __init__(self, bert):
        super().__init__()
        self.bert = bert

    def forward(self, input_ids, attention_mask):
        ids = input_ids.long()
        mask = attention_mask.float()
        hidden = self.bert.embeddings(input_ids=ids, token_type_ids=torch.zeros_like(ids))
        # -1e4 instead of finfo.min: the latter becomes -inf in fp16 and 0 * -inf = NaN.
        additive = (1.0 - mask)[:, None, None, :] * -10000.0
        hidden = self.bert.encoder(hidden, attention_mask=additive)[0]
        summed = (hidden * mask[:, :, None]).sum(dim=1)
        count = mask.sum(dim=1, keepdim=True).clamp(1.0, 1e4)
        mean = summed / count
        # Scale down before squaring to stay inside the fp16 range.
        peak = torch.max(mean.abs(), dim=-1, keepdim=True).values + 1e-6
        mean = mean / peak
        norm = torch.sqrt((mean * mean).sum(dim=-1, keepdim=True)).clamp(1e-6, 1e4)
        return mean / norm


def allowed_char(ch):
    """Scripts the app needs: Latin, Cyrillic, digits, punctuation and common symbols."""
    o = ord(ch)
    return (
        o < 0x0250                     # Basic Latin, Latin-1, Latin Extended-A/B
        or 0x0400 <= o <= 0x052F       # Cyrillic + supplement
        or 0x1E00 <= o <= 0x1EFF       # Latin Extended Additional
        or 0x2000 <= o <= 0x22FF       # punctuation, currency, letterlike (№), arrows, math
        or o == 0x2581                 # ▁ (SentencePiece word start)
    )


def prune_vocabulary(tokenizer, model):
    """Drops pieces of other scripts (CJK, Arabic, ...) to shrink the embedding table.
    Text in Latin/Cyrillic tokenizes exactly as before (dropped pieces could never
    match it); the kept rows keep their original order, so special ids stay 0..3.
    Returns the pruned tokenizers.Tokenizer and the old -> new id map."""
    data = json.loads(tokenizer.backend_tokenizer.to_str())
    vocab = data["model"]["vocab"]
    specials = {t["id"] for t in data.get("added_tokens", [])} | {0, 1, 2, 3}
    keep = [i for i, (piece, _) in enumerate(vocab) if i in specials or all(allowed_char(c) for c in piece)]
    old_to_new = {old: new for new, old in enumerate(keep)}
    data["model"]["vocab"] = [vocab[i] for i in keep]
    data["model"]["unk_id"] = old_to_new[data["model"].get("unk_id", 3)]
    data["added_tokens"] = [dict(t, id=old_to_new[t["id"]]) for t in data.get("added_tokens", []) if t["id"] in old_to_new]

    def remap(node):
        if isinstance(node, dict):
            for key, value in node.items():
                if key == "ids" and isinstance(value, list):
                    node[key] = [old_to_new[v] for v in value]
                else:
                    remap(value)
        elif isinstance(node, list):
            for value in node:
                remap(value)
    remap(data.get("post_processor"))

    with torch.no_grad():
        old_table = model.embeddings.word_embeddings.weight
        new_table = old_table[torch.tensor(keep)].clone()
        model.embeddings.word_embeddings = torch.nn.Embedding.from_pretrained(new_table, freeze=True, padding_idx=1)
        model.config.vocab_size = len(keep)
    print(f"Vocabulary pruned: {len(vocab)} -> {len(keep)} pieces")
    return Tokenizer.from_str(json.dumps(data, ensure_ascii=False)), old_to_new, data


def reference_embedding(model, ids):
    """Plain HF forward pass (no padding) with the standard e5 pooling, in fp32."""
    with torch.no_grad():
        input_ids = torch.tensor([ids], dtype=torch.long)
        mask = torch.ones_like(input_ids)
        out = model(input_ids=input_ids, attention_mask=mask).last_hidden_state
        pooled = (out * mask[:, :, None]).sum(1) / mask.sum(1, keepdim=True)
        pooled = torch.nn.functional.normalize(pooled, p=2, dim=-1)
    return pooled[0].numpy().astype(np.float32)


def padded(ids):
    input_ids = np.full((1, SEQ_LEN), 1, dtype=np.int32)  # <pad> = 1
    mask = np.zeros((1, SEQ_LEN), dtype=np.int32)
    n = min(len(ids), SEQ_LEN)
    input_ids[0, :n] = ids[:n]
    mask[0, :n] = 1
    return input_ids, mask


def cosine(a, b):
    a = np.asarray(a, dtype=np.float64).ravel()
    b = np.asarray(b, dtype=np.float64).ravel()
    return float(np.dot(a, b) / (np.linalg.norm(a) * np.linalg.norm(b) + 1e-12))


def main():
    if len(sys.argv) != 2:
        print("usage: convert-e5.py <outdir>", file=sys.stderr)
        sys.exit(2)
    out_dir = sys.argv[1]
    os.makedirs(out_dir, exist_ok=True)

    print(f"Loading {MODEL_ID}")
    tokenizer = AutoTokenizer.from_pretrained(MODEL_ID, use_fast=True)
    model = AutoModel.from_pretrained(MODEL_ID, attn_implementation="eager", torch_dtype=torch.float32)
    model.eval()

    # An all-zero row (the <pad> embedding) gets a zero int8 scale; give it a tiny
    # nonzero value. Pad positions are masked out, so results do not change.
    with torch.no_grad():
        table = model.embeddings.word_embeddings.weight
        zero_rows = (table.abs().sum(dim=1) == 0).nonzero().flatten()
        if len(zero_rows) > 0:
            table[zero_rows] = 1e-4

    # Original ids and embeddings, to prove pruning changes nothing for RU/EN text.
    original = {t: (tokenizer(t)["input_ids"], reference_embedding(model, tokenizer(t)["input_ids"])) for t in REFERENCE_TEXTS}

    pruned, old_to_new, pruned_json = prune_vocabulary(tokenizer, model)
    for text, (old_ids, old_emb) in original.items():
        new_ids = pruned.encode(text).ids
        if new_ids != [old_to_new[i] for i in old_ids]:
            sys.exit(f"pruned tokenizer differs for {text!r}: {new_ids}")
        c = cosine(reference_embedding(model, new_ids), old_emb)
        if c < 0.9999:
            sys.exit(f"pruned model differs for {text!r}: cosine {c:.6f}")

    # tokenizer.json in the HF fast format, read by SentencePieceTokenizer.swift.
    with open(os.path.join(out_dir, "e5_tokenizer.json"), "w", encoding="utf-8") as f:
        json.dump(pruned_json, f, ensure_ascii=False)

    class Pruned:
        def __call__(self, text):
            return {"input_ids": pruned.encode(text).ids}

        def convert_ids_to_tokens(self, ids):
            return [pruned.id_to_token(i) for i in ids]

    tokenizer = Pruned()

    wrapper = E5Embedder(model).eval()
    example = padded(tokenizer(REFERENCE_TEXTS[0])["input_ids"])
    example_t = tuple(torch.from_numpy(a) for a in example)

    # The wrapper must agree with the plain HF forward before we trace it.
    with torch.no_grad():
        for text in REFERENCE_TEXTS:
            ids = tokenizer(text)["input_ids"]
            ours = wrapper(*(torch.from_numpy(a) for a in padded(ids)))[0].numpy()
            c = cosine(ours, reference_embedding(model, ids))
            if c < 0.999:
                sys.exit(f"wrapper mismatch for {text!r}: cosine {c:.5f}")

    with torch.no_grad():
        traced = torch.jit.trace(wrapper, example_t, strict=False)

    print("Converting to Core ML")
    mlmodel = ct.convert(
        traced,
        inputs=[
            ct.TensorType(name="input_ids", shape=(1, SEQ_LEN), dtype=np.int32),
            ct.TensorType(name="attention_mask", shape=(1, SEQ_LEN), dtype=np.int32),
        ],
        outputs=[ct.TensorType(name="embedding", dtype=np.float32)],
        convert_to="mlprogram",
        minimum_deployment_target=ct.target.iOS17,
        compute_units=ct.ComputeUnit.ALL,
    )

    print("Quantizing weights to int8")
    config = cto.OptimizationConfig(
        global_config=cto.OpLinearQuantizerConfig(mode="linear_symmetric", dtype="int8", granularity="per_channel")
    )
    mlmodel = cto.linear_quantize_weights(mlmodel, config=config)
    mlmodel.short_description = "intfloat/multilingual-e5-small, mean pooled and L2-normalized, int8 weights"

    package = os.path.join(out_dir, PACKAGE)
    shutil.rmtree(package, ignore_errors=True)
    mlmodel.save(package)

    references = []
    for text in REFERENCE_TEXTS:
        ids = tokenizer(text)["input_ids"]
        references.append({
            "text": text,
            "input_ids": [int(i) for i in ids],
            "tokens": tokenizer.convert_ids_to_tokens(ids),
            "embedding": [round(float(x), 7) for x in reference_embedding(model, ids)],
        })
    with open(os.path.join(out_dir, "e5_reference.json"), "w", encoding="utf-8") as f:
        json.dump({"model": MODEL_ID, "sequence_length": SEQ_LEN, "items": references}, f, ensure_ascii=False)

    # Core ML predictions only work on macOS; skip the check elsewhere.
    try:
        loaded = ct.models.MLModel(package, compute_units=ct.ComputeUnit.CPU_ONLY)
        worst = 1.0
        for item in references:
            input_ids, mask = padded(item["input_ids"])
            pred = loaded.predict({"input_ids": input_ids, "attention_mask": mask})
            c = cosine(pred["embedding"], item["embedding"])
            worst = min(worst, c)
            print(f"cosine {c:.5f}  {item['text']}")
    except Exception as e:  # noqa: BLE001
        print(f"Core ML prediction unavailable, skipping check: {e}")
    else:
        if worst < 0.95:
            # Do not leave a broken package in the CI cache.
            shutil.rmtree(package, ignore_errors=True)
            sys.exit(f"Core ML model diverges from PyTorch: worst cosine {worst:.4f}")
        if worst < 0.98:
            print(f"warning: worst cosine {worst:.4f} is below 0.98")

    print(f"Saved {package}")


if __name__ == "__main__":
    main()
