# SPDX-License-Identifier: GPL-3.0-or-later
#
# Converts a multilingual CLIP to Core ML:
#   image tower: openai/clip-vit-base-patch32 (vision + projection), 224x224
#   text tower:  sentence-transformers/clip-ViT-B-32-multilingual-v1
#                (multilingual DistilBERT trained to land in the same 512-d space)
# Russian queries can then be compared with photos directly, no translation.
#
# Usage: python convert-mclip.py <out dir>   (macOS, writes .mlpackage + vocab)

import json
import os
import sys

import coremltools as ct
import numpy as np
import torch
from PIL import Image
from sentence_transformers import SentenceTransformer
from transformers import CLIPModel, CLIPProcessor

OUT = sys.argv[1]
VARIANT = "mclip_b32"
MAX_LEN = 64
os.makedirs(OUT, exist_ok=True)
torch.set_grad_enabled(False)


def cos(a, b):
    a = np.asarray(a, dtype=np.float32).ravel()
    b = np.asarray(b, dtype=np.float32).ravel()
    return float(a @ b / (np.linalg.norm(a) * np.linalg.norm(b)))


# ---------------------------------------------------------------- text tower
st = SentenceTransformer(
    "sentence-transformers/clip-ViT-B-32-multilingual-v1",
    device="cpu",
    model_kwargs={"attn_implementation": "eager"},
)
st.eval()
print(st)
tokenizer = st.tokenizer


class TextTower(torch.nn.Module):
    def __init__(self, st):
        super().__init__()
        self.bert = st[0].auto_model
        self.dense = st[2]

    def forward(self, input_ids, attention_mask):
        hidden = self.bert(input_ids=input_ids, attention_mask=attention_mask)[0]
        mask = attention_mask.unsqueeze(-1).to(hidden.dtype)
        pooled = (hidden * mask).sum(1) / mask.sum(1).clamp(min=1e-9)
        return self.dense({"sentence_embedding": pooled})["sentence_embedding"]


def encode(text):
    t = tokenizer(text, padding="max_length", truncation=True, max_length=MAX_LEN, return_tensors="pt")
    return t["input_ids"], t["attention_mask"]


text_tower = TextTower(st).eval()
ids, mask = encode("собака на пляже")
reference = st.encode(["собака на пляже"])[0]
assert cos(text_tower(ids, mask)[0], reference) > 0.999, "text wrapper differs from sentence-transformers"

traced_text = torch.jit.trace(text_tower, (ids, mask))
text_ml = ct.convert(
    traced_text,
    inputs=[
        ct.TensorType(name="input_ids", shape=(1, MAX_LEN), dtype=np.int32),
        ct.TensorType(name="attention_mask", shape=(1, MAX_LEN), dtype=np.int32),
    ],
    outputs=[ct.TensorType(name="embedding")],
    convert_to="mlprogram",
    minimum_deployment_target=ct.target.iOS17,
)
# Weights stay float16. An int8 version crashed on iPhone: when Core ML ran the
# text tower on the GPU, MPSGraph tried to unpack the whole 92M-entry embedding
# table at compile time and aborted with an allocation error.
text_ml.short_description = "Multilingual CLIP text encoder (clip-ViT-B-32-multilingual-v1)"
text_ml.save(os.path.join(OUT, f"{VARIANT}_text.mlpackage"))

# Vocabulary for the Swift WordPiece tokenizer, plus expected token ids to check it.
vocab = sorted(tokenizer.get_vocab().items(), key=lambda kv: kv[1])
with open(os.path.join(OUT, f"{VARIANT}_vocab.txt"), "w", encoding="utf-8") as f:
    for token, index in vocab:
        f.write(token + "\n")
samples = ["Попугай", "собака на пляже летом", "Счёт за электричество, март!", "a dog on the beach", "ёжик 2024"]
with open(os.path.join(OUT, f"{VARIANT}_tokens.json"), "w", encoding="utf-8") as f:
    json.dump(
        {"max_length": MAX_LEN, "samples": [{"text": s, "ids": encode(s)[0][0].tolist()} for s in samples]},
        f,
        ensure_ascii=False,
    )

# ---------------------------------------------------------------- image tower
clip = CLIPModel.from_pretrained("openai/clip-vit-base-patch32", attn_implementation="eager").eval()
processor = CLIPProcessor.from_pretrained("openai/clip-vit-base-patch32")


class ImageTower(torch.nn.Module):
    def __init__(self, clip):
        super().__init__()
        self.clip = clip
        self.register_buffer("mean", torch.tensor([0.48145466, 0.4578275, 0.40821073]).view(1, 3, 1, 1))
        self.register_buffer("std", torch.tensor([0.26862954, 0.26130258, 0.27577711]).view(1, 3, 1, 1))

    def forward(self, image):  # image: 0...1 RGB
        return self.clip.get_image_features(pixel_values=(image - self.mean) / self.std)


image_tower = ImageTower(clip).eval()
example = torch.rand(1, 3, 224, 224)
traced_image = torch.jit.trace(image_tower, example)
image_ml = ct.convert(
    traced_image,
    inputs=[ct.ImageType(name="image", shape=(1, 3, 224, 224), scale=1 / 255.0, color_layout=ct.colorlayout.RGB)],
    outputs=[ct.TensorType(name="embedding")],
    convert_to="mlprogram",
    minimum_deployment_target=ct.target.iOS17,
)
image_ml.short_description = "CLIP ViT-B/32 image encoder"
image_ml.save(os.path.join(OUT, f"{VARIANT}_image.mlpackage"))

# ---------------------------------------------------------------- checks
rng = np.random.default_rng(0)
pil = Image.fromarray((rng.random((224, 224, 3)) * 255).astype(np.uint8))
torch_image = image_tower(torch.from_numpy(np.asarray(pil, dtype=np.float32) / 255).permute(2, 0, 1)[None])[0]
ml_image = image_ml.predict({"image": pil})["embedding"]
print("image torch vs coreml cos", cos(torch_image, ml_image))
assert cos(torch_image, ml_image) > 0.99

for text in ["Попугай", "a dog on the beach"]:
    i, m = encode(text)
    ml_text = text_ml.predict({"input_ids": i.numpy().astype(np.int32), "attention_mask": m.numpy().astype(np.int32)})["embedding"]
    c = cos(st.encode([text])[0], ml_text)
    print(f"text torch vs coreml cos «{text}»", c)
    assert c > 0.98

# Russian and English phrasings of the same thing should land close together.
ru = st.encode(["фотография собаки"])[0]
en = st.encode(["a photo of a dog"])[0]
other = st.encode(["a photo of a mountain"])[0]
print("ru/en dog", cos(ru, en), "ru dog / en mountain", cos(ru, other))
assert cos(ru, en) > cos(ru, other)
print("done")
