
#!/usr/bin/env python3
"""
Complete Biometric Key Generation Pipeline
Phases:
  Phase 1 : Face Detection & Alignment  (RetinaFace ONNX)
  Phase 2 : Embedding Extraction        (AdaFace IR-101 ONNX + L2 renorm)
  Phase 3 : Scale ×2/×3/×4 → Clip [-1,+1] → 3-bit Gray-code Quantization
  Phase 4 : LDPC Fuzzy Commitment       (Proto_LDPC, N=52, m=42, Z=16)
  Phase 5 : Neural Min-Sum BP Decoding  (CORRECTED — explicit edge-list)

Real-world model (phone registration / login):
  REGISTRATION (enrollment):
    - User registers with video Vx.
    - Vx computes its OWN bitvec, nonce, helper data, and key hash.
    - Helper data + key hash are stored on the server.
    - Nothing from any other video is used during registration.

  LOGIN (verification):
    - User presents their face (probe video Vy, y != x).
    - Server returns Vx's helper data and key hash.
    - System tries to recover Vx's key using ONLY Vx's helper data.
    - ACCEPT if recovered key hash matches Vx's enrolled hash.
    - The probe contributes ONLY its face embedding — nothing else.

  KEY RULE: NO master helper data. NO per-probe nonce rebuild.
            Vx's helper data is fixed at registration and never changes.

MODIFICATIONS:
  - look4noncerate is DISABLED (commented out) — nonce = all-ones always.
  - Phase 3: scale=2/3/4, clip[-1,+1], 3-bit Gray-code quantization (from BCH pipeline).
    Pipeline: L2-unit → ×scale → clip[-1,+1] → 3-bit uniform quant → Gray code → bits
    BITVEC_LEN = 512 dims × 3 bits = 1536 bits
  - Pipeline runs for EACH scale (×2, ×3, ×4) independently.
"""

import hashlib
import logging
import math
import warnings
from itertools import product as iterproduct
from pathlib import Path
from typing import Dict, List, Optional, Tuple

import cv2
import numpy as np
import torch

warnings.filterwarnings("ignore")
logging.basicConfig(
    level=logging.INFO,
    format="[%(asctime)s] %(levelname)s %(message)s",
    datefmt="%H:%M:%S",
)
log = logging.getLogger(__name__)

#  PATHS  — edit to match your machine

BASE = Path.home() / "Documents/Desktop"

ALL_VIDEO_PATHS: Dict[str, str] = {
    "V1":  str(BASE / "Embeddings/IOS.mov"),
    "V2":  str(BASE / "Embeddings/IOS M-No Beard .mov"),
    "V3":  str(BASE / "Embeddings/Android .mp4"),
    "V4":  str(BASE / "Embeddings/Android no beard version 2.mp4"),
    "V5":  str(BASE / "Embeddings/Android video 5.mp4"),
    "V6":  str(BASE / "Embeddings/IOS -Sha V6 .MOV"),
    "V7":  str(BASE / "Embeddings/IOS - Rusl V7.mov"),
    # V8 = old V20 Glass Android, V9 = old V21 Glass IOS  (person_A)
    "V8":  str(Path.home() / "Documents/Desktop/Face Detection/Video_Dataset/V20 Glass Android .mp4"),
    "V9":  str(Path.home() / "Documents/Desktop/Face Detection/Video_Dataset/V21 Glass IOS.MOV"),
    # Makeup pairs
    "V10": str(Path.home() / "Documents/Desktop/Face Detection System/Video_Dataset/V8 instagram Make up.mp4"),
    "V11": str(Path.home() / "Documents/Desktop/Face Detection System/Video_Dataset/V8 instagram No make up.mp4"),
    "V12": str(Path.home() / "Documents/Desktop/Face Detection System/Video_Dataset/V9 Instagram Make up.mp4"),
    "V13": str(Path.home() / "Documents/Desktop/Face Detection System/Video_Dataset/V9 Instagram No make up.mp4"),
    "V14": str(Path.home() / "Documents/Desktop/Face Detection System/Video_Dataset/V10 Instagram Make up.mp4"),
    "V15": str(Path.home() / "Documents/Desktop/Face Detection System/Video_Dataset/V10 Instagram No make up.mp4"),
    "V16": str(Path.home() / "Documents/Desktop/Face Detection System/Video_Dataset/V11 instagram Make up.mp4"),
    "V17": str(Path.home() / "Documents/Desktop/Face Detection System/Video_Dataset/V11 instagram No make up.mp4"),
    "V18": str(Path.home() / "Documents/Desktop/Face Detection System/Video_Dataset/V12 instagram Make up.mp4"),
    "V19": str(Path.home() / "Documents/Desktop/Face Detection System/Video_Dataset/V12 instagram No make up.mp4"),
    "V20": str(Path.home() / "Documents/Desktop/Face Detection System/Video_Dataset/V13 instagram Make up.mp4"),
    "V21": str(Path.home() / "Documents/Desktop/Face Detection System/Video_Dataset/V13 instagram No make up.mp4"),
}

ALL_VIDEO_DISPLAY_NAMES: Dict[str, str] = {
    "V1":  "V1  IOS-Beard",
    "V2":  "V2  IOS-NoBrd",
    "V3":  "V3  Andr-Beard",
    "V4":  "V4  Andr-NoBrd",
    "V5":  "V5  Android5",
    "V6":  "V6  Sha",
    "V7":  "V7  Rusl",
    "V8":  "V8  Glass-Android",
    "V9":  "V9  Glass-IOS",
    "V10": "V10 Makeup-1",
    "V11": "V11 No Makeup-2",
    "V12": "V12 Makeup-1",
    "V13": "V13 No Makeup-2",
    "V14": "V14 Makeup-1",
    "V15": "V15 No Makeup-2",
    "V16": "V16 Makeup-1",
    "V17": "V17 No Makeup-2",
    "V18": "V18 Makeup-1",
    "V19": "V19 No Makeup-2",
    "V20": "V20 Makeup-1",
    "V21": "V21 No Makeup-2",
}

ALL_IDENTITY_MAP: Dict[str, str] = {
    "V1":  "person_A", "V2":  "person_A", "V3":  "person_A",
    "V4":  "person_A", "V5":  "person_B", "V6":  "person_C",
    "V7":  "person_D", "V8":  "person_A", "V9":  "person_A",
    "V10": "person_E", "V11": "person_E",
    "V12": "person_F", "V13": "person_F",
    "V14": "person_G", "V15": "person_G",
    "V16": "person_H", "V17": "person_H",
    "V18": "person_I", "V19": "person_I",
    "V20": "person_J", "V21": "person_J",
}

# Every video acts as an enrollee
ALL_ENROLLEES: List[str] = list(ALL_VIDEO_PATHS.keys())

ADAFACE_WEIGHTS = str(
    Path.home() / "Documents/Desktop/Face Detection System/Weights/adaface-onnx/adaface_ir_101.onnx"
)
RETINAFACE_WEIGHTS = str(
    BASE / "Face Detection/retinaface-pytorch/weights/retinaface_mv2.onnx"
)

WIFAKEY_META = Path("./WiFaKey/LDPC_MetaData")
BG0_PATH  = str(WIFAKEY_META / "BaseGraph/BaseGraph2_Set0.txt")
BG1_PATH  = str(WIFAKEY_META / "BaseGraph/BaseGraph2_Set1.txt")
BG2_PATH  = str(WIFAKEY_META / "BaseGraph/BaseGraph2_Set2.txt")
GM16_PATH = str(WIFAKEY_META / "BaseGraph_GM/LDPC_GM_BG2_16.txt")
GM3_PATH  = str(WIFAKEY_META / "BaseGraph_GM/LDPC_GM_BG2_3.txt")
GM10_PATH = str(WIFAKEY_META / "BaseGraph_GM/LDPC_GM_BG2_10.txt")
GM6_PATH  = str(WIFAKEY_META / "BaseGraph_GM/LDPC_GM_BG2_6.txt")

WIFAKEY_ROOT = Path("./WiFaKey")
WEIGHTS_DIR  = WIFAKEY_ROOT / "Weights_Var_MS"
BIASES_DIR   = WIFAKEY_ROOT / "Biases_Var_MS"

#  PHASE 1 CONFIG  (RetinaFace)
RETINAFACE_CFG = {
    'min_sizes':   [[16, 32], [64, 128], [256, 512]],
    'steps':       [8, 16, 32],
    'variance':    [0.1, 0.2],
    'clip':        False,
    'out_channel': 64,
}

FRAMES_TO_USE  = 20
FACE_SIZE      = 112
RETINA_H       = 640
RETINA_W       = 360
RGB_MEAN       = (104, 117, 123)
CONF_THRESHOLD = 0.6
NMS_THRESHOLD  = 0.4
PRE_NMS_TOPK   = 5000

REFERENCE_PTS = np.array([
    [38.2946, 51.6963],
    [73.5318, 51.6963],
    [56.0252, 71.7366],
    [41.5493, 92.3655],
    [70.7299, 92.3655],
], dtype=np.float32)

#  PHASE 3 CONFIG  — Scale, Clip, Gray-code Quantization

# *** CHANGED: now a list of scales to sweep ***
QUANT_SCALES   = [5]     # pipeline runs independently for each scale
QUANT_BITS     = 3             # 3-bit Gray-code quantization  (unchanged)
EMB_DIM        = 512
BITVEC_LEN     = EMB_DIM * QUANT_BITS   # 512 × 3 = 1536 bits

#  PHASE 4 CONFIG

LDPC_N      = 52
LDPC_M      = 42
LDPC_Z      = 16
LDPC_CODE_N = LDPC_N * LDPC_Z           # 832 bits
LDPC_CODE_K = (LDPC_N - LDPC_M) * LDPC_Z  # 160 bits
BP_ITERS    = 15

#  PHASE 1 — RETINAFACE INFRASTRUCTURE

class PriorBox:
    def __init__(self, cfg, image_size):
        self.image_size   = image_size
        self.clip         = cfg['clip']
        self.steps        = cfg['steps']
        self.min_sizes    = cfg['min_sizes']
        self.feature_maps = [
            [math.ceil(image_size[0] / s), math.ceil(image_size[1] / s)]
            for s in self.steps
        ]

    def generate_anchors(self):
        anchors = []
        for k, (map_h, map_w) in enumerate(self.feature_maps):
            step = self.steps[k]
            for i, j in iterproduct(range(map_h), range(map_w)):
                for min_size in self.min_sizes[k]:
                    s_kx = min_size / self.image_size[1]
                    s_ky = min_size / self.image_size[0]
                    cx   = (j + 0.5) * step / self.image_size[1]
                    cy   = (i + 0.5) * step / self.image_size[0]
                    anchors += [cx, cy, s_kx, s_ky]
        out = torch.tensor(anchors, dtype=torch.float32).view(-1, 4)
        if self.clip:
            out.clamp_(0, 1)
        return out


def decode_boxes(loc, priors, variances):
    cxcy  = priors[:, :2] + loc[:, :2] * variances[0] * priors[:, 2:]
    wh    = priors[:, 2:] * torch.exp(loc[:, 2:] * variances[1])
    boxes = torch.empty_like(loc)
    boxes[:, :2] = cxcy - wh / 2
    boxes[:, 2:] = cxcy + wh / 2
    return boxes


def decode_landmarks(predictions, priors, variances):
    pred = predictions.view(predictions.size(0), 5, 2)
    lm   = (priors[:, :2].unsqueeze(1)
            + pred * variances[0] * priors[:, 2:].unsqueeze(1))
    return lm.view(lm.size(0), -1)


def nms(dets, threshold):
    x1, y1, x2, y2, scores = (
        dets[:, 0], dets[:, 1], dets[:, 2], dets[:, 3], dets[:, 4]
    )
    areas = (x2 - x1 + 1) * (y2 - y1 + 1)
    order = scores.argsort()[::-1]
    keep  = []
    while order.size > 0:
        i = order[0]; keep.append(i)
        xx1 = np.maximum(x1[i], x1[order[1:]])
        yy1 = np.maximum(y1[i], y1[order[1:]])
        xx2 = np.minimum(x2[i], x2[order[1:]])
        yy2 = np.minimum(y2[i], y2[order[1:]])
        w   = np.maximum(0.0, xx2 - xx1 + 1)
        h   = np.maximum(0.0, yy2 - yy1 + 1)
        ovr = (w * h) / (areas[i] + areas[order[1:]] - w * h)
        order = order[np.where(ovr <= threshold)[0] + 1]
    return keep


class RetinaFaceDetector:
    def __init__(self, model_path):
        import onnxruntime as ort
        providers = (
            ["CUDAExecutionProvider", "CPUExecutionProvider"]
            if "CUDAExecutionProvider" in ort.get_available_providers()
            else ["CPUExecutionProvider"]
        )
        self.session = ort.InferenceSession(model_path, providers=providers)
        self.cfg     = RETINAFACE_CFG
        log.info(f"RetinaFace ONNX loaded | {providers[0]}")

    def _preprocess(self, frame):
        img  = np.float32(frame)
        img -= np.array(RGB_MEAN, dtype=np.float32)
        img  = img.transpose(2, 0, 1)
        return np.expand_dims(img, 0)

    def detect(self, frame):
        img_h, img_w = frame.shape[:2]
        inp          = self._preprocess(frame)
        outputs      = self.session.run(None, {'input': inp})
        loc_raw      = torch.tensor(outputs[0].squeeze(0))
        conf_raw     = outputs[1].squeeze(0)
        lm_raw       = torch.tensor(outputs[2].squeeze(0))

        priorbox  = PriorBox(self.cfg, image_size=(img_h, img_w))
        priors    = priorbox.generate_anchors()
        boxes     = decode_boxes(loc_raw, priors, self.cfg['variance'])
        landmarks = decode_landmarks(lm_raw, priors, self.cfg['variance'])

        bbox_scale = torch.tensor([img_w, img_h, img_w, img_h], dtype=torch.float32)
        boxes      = (boxes * bbox_scale).cpu().numpy()
        lm_scale   = torch.tensor([img_w, img_h] * 5, dtype=torch.float32)
        landmarks  = (landmarks * lm_scale).cpu().numpy()
        scores     = conf_raw[:, 1]

        mask = scores > CONF_THRESHOLD
        boxes, landmarks, scores = boxes[mask], landmarks[mask], scores[mask]
        if len(scores) == 0:
            return None

        order     = scores.argsort()[::-1][:PRE_NMS_TOPK]
        boxes, landmarks, scores = boxes[order], landmarks[order], scores[order]
        dets      = np.hstack((boxes, scores[:, np.newaxis])).astype(np.float32)
        keep      = nms(dets, NMS_THRESHOLD)
        return dets[keep][0, :4], landmarks[keep][0]


def _umeyama(src, dst):
    n    = src.shape[0]
    mu_s = src.mean(0); mu_d = dst.mean(0)
    sc   = src - mu_s;  dc   = dst - mu_d
    vs   = (sc ** 2).sum() / n
    if vs < 1e-10:
        return None
    cov = (dc.T @ sc) / n
    try:
        U, S, Vt = np.linalg.svd(cov)
    except np.linalg.LinAlgError:
        return None
    d = np.ones(2)
    if np.linalg.det(U) * np.linalg.det(Vt) < 0:
        d[-1] = -1
    R = U @ np.diag(d) @ Vt
    c = (S * d).sum() / vs
    t = mu_d - c * R @ mu_s
    M = np.zeros((2, 3), dtype=np.float32)
    M[:, :2] = c * R
    M[:, 2]  = t
    return M


def umeyama_align(frame, landmarks):
    src_pts = landmarks.reshape(5, 2).astype(np.float32)
    M       = _umeyama(src_pts, REFERENCE_PTS)
    if M is None:
        return None
    return cv2.warpAffine(
        frame, M, (FACE_SIZE, FACE_SIZE),
        flags=cv2.INTER_LANCZOS4,
        borderMode=cv2.BORDER_REFLECT,
    )
#  PHASE 2 — ADAFACE
class AdaFaceModel:
    def __init__(self, model_path):
        import onnxruntime as ort
        providers = (
            ["CUDAExecutionProvider", "CPUExecutionProvider"]
            if "CUDAExecutionProvider" in ort.get_available_providers()
            else ["CPUExecutionProvider"]
        )
        self.session     = ort.InferenceSession(model_path, providers=providers)
        self.input_name  = self.session.get_inputs()[0].name
        self.output_name = self.session.get_outputs()[0].name
        log.info(f"AdaFace IR-101 ONNX loaded | {providers[0]}")

    def raw_embedding(self, face_bgr):
        img = cv2.cvtColor(face_bgr, cv2.COLOR_BGR2RGB)
        img = (img.astype(np.float32) / 255.0 - 0.5) / 0.5
        img = img.transpose(2, 0, 1)[np.newaxis]
        out = self.session.run([self.output_name], {self.input_name: img})
        emb = out[0][0] if out[0].ndim == 2 else out[0]
        return emb.astype(np.float32)


def extract_frames_every_n(video_path, stride=5):
    cap = cv2.VideoCapture(video_path)
    if not cap.isOpened():
        raise RuntimeError(f"Cannot open: {video_path}")
    frames = []
    idx = 0
    while True:
        ret, frame = cap.read()
        if not ret or frame is None:
            break
        if idx % stride == 0:
            frames.append(frame)
        idx += 1
    cap.release()
    if not frames:
        raise RuntimeError(f"No frames: {video_path}")
    log.info(f"Extracted {len(frames)} frames (every {stride}th) from {Path(video_path).name}")
    return frames


def embed_video(video_path, adaface, detector, show_resize=True):
    """
    Embed a video and return the L2-normalised average embedding.
    """
    name       = Path(video_path).name
    all_frames = extract_frames_every_n(video_path, stride=5)

    n_no_face = 0; n_umeyama_fail = 0
    aligned_pool = []
    printed_size = False

    for orig_frame in all_frames:
        if not printed_size and show_resize:
            print(f"  [{name}] BEFORE resize: {orig_frame.shape[1]}x{orig_frame.shape[0]} (WxH)")

        frame_retina = cv2.resize(orig_frame, (RETINA_W, RETINA_H),
                                  interpolation=cv2.INTER_LINEAR)

        if not printed_size and show_resize:
            print(f"  [{name}] AFTER  resize: {frame_retina.shape[1]}x{frame_retina.shape[0]} (WxH)")
        printed_size = True

        result = detector.detect(frame_retina)
        if result is None:
            n_no_face += 1; continue

        bbox, lm = result
        aligned  = umeyama_align(frame_retina, lm)
        if aligned is None:
            n_umeyama_fail += 1; continue

        gray      = cv2.cvtColor(aligned, cv2.COLOR_BGR2GRAY)
        sharpness = float(cv2.Laplacian(gray, cv2.CV_64F).var())
        aligned_pool.append((sharpness, aligned))

    log.info(f"  [{name}] no_face={n_no_face}  umeyama_fail={n_umeyama_fail}  "
             f"aligned={len(aligned_pool)}")

    if not aligned_pool:
        log.error(f"  [{name}] FAILED — zero aligned faces.")
        return None

    aligned_pool.sort(key=lambda t: t[0], reverse=True)
    top_frames = aligned_pool[:FRAMES_TO_USE]
    log.info(f"  [{name}] Using top {len(top_frames)} sharpest aligned faces")

    unit_vecs = []
    for _, face_112 in top_frames:
        raw = adaface.raw_embedding(face_112)
        n   = np.linalg.norm(raw)
        if n > 1e-10:
            unit_vecs.append((raw / n).astype(np.float32))

    if not unit_vecs:
        log.error(f"  [{name}] No valid embeddings.")
        return None

    avg      = np.mean(np.stack(unit_vecs, 0), 0).astype(np.float32)
    avg_norm = np.linalg.norm(avg)
    if avg_norm < 1e-10:
        log.error(f"  [{name}] Near-zero average."); return None

    # L2-normalised average embedding — Phase 3 (scale/clip/quant) applied next
    final = (avg / avg_norm).astype(np.float32)
    log.info(f"  [{name}] Final embedding: dim={final.shape[0]}  "
             f"norm={np.linalg.norm(final):.6f}  "
             f"min={final.min():.4f}  max={final.max():.4f}  "
             f"mean={final.mean():.4f}")
    return final

#  PHASE 3 — SCALE × N → CLIP [-1,+1] → 3-BIT GRAY-CODE QUANTIZATION
#  (extracted from BCH pipeline, bch_pipeline_copy2.py)

def _to_gray(n: int) -> int:
    """Convert integer to Gray code."""
    return n ^ (n >> 1)


def embedding_to_bitvec(embedding: np.ndarray,
                         scale: int,
                         bits: int  = QUANT_BITS) -> np.ndarray:
    """
    Convert an L2-normalised embedding to a binary bit-vector.

    Pipeline (identical to BCH pipeline, bch_pipeline_copy2.py):
      1. Multiply by scale  (×2, ×3, or ×4)
      2. Clip to [-1, +1]
      3. Uniform quantization to integers [0, 2^bits - 1]
      4. Gray-code encode each integer
      5. Unpack to bits  →  EMB_DIM × bits = 1536 bits

    Parameters
    ----------
    embedding : L2-normalised 512-dim float32 vector
    scale     : integer scale factor (2, 3, or 4)
    bits      : bits per dimension   (default QUANT_BITS = 3)

    Returns
    -------
    np.ndarray of shape (EMB_DIM * bits,) dtype uint8
    """
    levels = (1 << bits) - 1                                    # 7 for 3-bit
    scaled = np.clip(embedding * scale, -1.0, 1.0)              # scale & clip
    q      = np.clip(
        np.round((scaled + 1.0) / 2.0 * levels).astype(np.int32),
        0, levels
    )                                                            # integers [0,7]
    g      = np.array([_to_gray(int(v)) for v in q], dtype=np.int32)  # Gray code
    result = np.zeros(len(g) * bits, dtype=np.uint8)
    for i, val in enumerate(g):
        for b in range(bits):
            result[i * bits + (bits - 1 - b)] = (int(val) >> b) & 1
    return result.astype(np.uint8)


def _quantize_probe(probe_emb: np.ndarray,
                    scale: int,
                    bits: int  = QUANT_BITS) -> np.ndarray:
    """
    Quantize a probe embedding using the same fixed scale/clip/Gray pipeline.
    At login, the probe is quantized with the same parameters used at enrollment.
    """
    return embedding_to_bitvec(probe_emb, scale=scale, bits=bits)


#  look4noncerate is DISABLED
#  Nonce is always all-ones (no masking).

# def look4noncerate(...): ...   # DISABLED — see original code

#  PHASE 4 — PROTO_LDPC

class Proto_LDPC:
    def __init__(self, N, m, Z):
        self.code_n = N
        self.Z      = Z
        self.code_k = N - m

        code_GM16 = np.loadtxt(GM16_PATH, dtype=int, delimiter=',')
        code_GM3  = np.loadtxt(GM3_PATH,  dtype=int, delimiter=',')
        code_GM10 = np.loadtxt(GM10_PATH, dtype=int, delimiter=',')
        code_GM6  = np.loadtxt(GM6_PATH,  dtype=int, delimiter=',')
        gm_map    = {16: code_GM16, 3: code_GM3, 10: code_GM10, 6: code_GM6}

        if Z not in gm_map:
            raise ValueError(f"Unsupported Z={Z}")
        self.G_matrix = gm_map[Z]

        log.info(f"Proto_LDPC: N={N}, m={m}, Z={Z}")
        log.info(f"  code_n={N*Z} bits, code_k={self.code_k*Z} bits")
        log.info(f"  G_matrix shape: {self.G_matrix.shape}")

    def encode_LDPC(self, x_bits):
        return (np.dot(x_bits, self.G_matrix) % 2).astype(np.uint8)


#  PHASE 5 — CORRECTED NEURAL MIN-SUM BP DECODER

def _build_edge_list(proto_pcm, Z):
    M, N = proto_pcm.shape
    check_list, var_list, proto_list = [], [], []
    proto_edge_num = 0
    for j in range(N):
        for i in range(M):
            s = proto_pcm[i, j]
            if s == -1:
                continue
            shift = int(s) % Z
            for h in range(Z):
                check_list.append(i * Z + h)
                var_list.append(j * Z + (h + shift) % Z)
                proto_list.append(proto_edge_num)
            proto_edge_num += 1
    return (np.array(check_list, dtype=np.int32),
            np.array(var_list,   dtype=np.int32),
            np.array(proto_list, dtype=np.int32),
            proto_edge_num)


def _load_bp_weights(n_iters, n_proto):
    weights_list, biases_list = [], []
    learned = True
    for i in range(n_iters):
        wp = WEIGHTS_DIR / f"Weights_Var{i}.txt"
        bp = BIASES_DIR  / f"Biases_Var{i}.txt"
        if wp.exists() and bp.exists():
            w = np.loadtxt(str(wp), delimiter=',', dtype=np.float32)
            b = np.loadtxt(str(bp), delimiter=',', dtype=np.float32)
        else:
            learned = False
            w = np.full(n_proto, 0.8,  dtype=np.float32)
            b = np.full(n_proto, 0.15, dtype=np.float32)
        weights_list.append(w); biases_list.append(b)
    return weights_list, biases_list, learned


def neural_minsum_decode(received_hard, proto_ldpc, n_iters=BP_ITERS):
    code_PCM0 = np.loadtxt(BG0_PATH, dtype=int, delimiter='\t')
    Z         = proto_ldpc.Z
    code_m    = LDPC_M * Z
    code_n    = LDPC_N * Z

    check_arr, var_arr, proto_arr, n_proto = _build_edge_list(code_PCM0, Z)
    weights_list, biases_list, learned     = _load_bp_weights(n_iters, n_proto)
    log.info(f"  [BP decoder] learned weights loaded: {learned}  "
             f"(fallback to init values if False)")

    ch_llr = 1.0 - 2.0 * received_hard.astype(np.float64)
    c2v    = np.zeros(len(check_arr), dtype=np.float64)
    INF    = 1e15

    for it in range(n_iters):
        total = ch_llr.copy()
        np.add.at(total, var_arr, c2v)
        v2c = total[var_arr] - c2v

        mags = np.abs(v2c)

        neg     = (v2c < 0).astype(np.int32)
        neg_cnt = np.zeros(code_m, dtype=np.int32)
        np.add.at(neg_cnt, check_arr, neg)
        total_sign = 1.0 - 2.0 * (neg_cnt % 2).astype(np.float64)
        sign_self  = np.where(v2c >= 0, 1.0, -1.0)
        sign_ex    = total_sign[check_arr] * sign_self

        min1 = np.full(code_m, INF, dtype=np.float64)
        np.minimum.at(min1, check_arr, mags)

        is_min1  = (mags == min1[check_arr])
        cnt_min1 = np.zeros(code_m, dtype=np.int32)
        np.add.at(cnt_min1, check_arr, is_min1.astype(np.int32))

        tmp  = np.where(is_min1, INF, mags)
        min2 = np.full(code_m, INF, dtype=np.float64)
        np.minimum.at(min2, check_arr, tmp)
        min2 = np.where(cnt_min1 >= 2, min1, min2)

        sole_min = is_min1 & (cnt_min1[check_arr] == 1)
        mag_ex   = np.where(sole_min, min2[check_arr], min1[check_arr])

        raw_c2v = sign_ex * mag_ex

        w = weights_list[it][proto_arr].astype(np.float64)
        b = biases_list[it][proto_arr].astype(np.float64)

        scaled = np.abs(raw_c2v) * w + b
        scaled = np.maximum(0.0, scaled)
        c2v    = np.where(raw_c2v != 0.0, scaled * np.sign(raw_c2v), 0.0)
        c2v    = np.clip(c2v, -1e6, 1e6)

    total = ch_llr.copy()
    np.add.at(total, var_arr, c2v)
    return (total < 0).astype(np.uint8)

#  FUZZY COMMITMENT — REGISTRATION (enrollment)

def register(enr_bitvec, enr_nonce, proto_ldpc):
    """
    REGISTRATION step — called exactly once per enrollee.

    Takes the enrollee's own bitvec and nonce.  Produces:
      - helper   : stored on server, never changes
      - key_hash : stored on server, never changes
    """
    bitvec_nonce = np.bitwise_and(enr_bitvec, enr_nonce)
    message_bits = bitvec_nonce[:LDPC_CODE_K].copy()
    codeword     = proto_ldpc.encode_LDPC(message_bits)
    helper       = np.bitwise_xor(
        bitvec_nonce[:LDPC_CODE_N].astype(np.uint8),
        codeword.astype(np.uint8)
    )
    key_hash = hashlib.sha256(np.packbits(message_bits).tobytes()).hexdigest()
    return {
        "bitvec_nonce": bitvec_nonce,
        "message":      message_bits,
        "codeword":     codeword,
        "helper":       helper,       # → goes to server
        "key_hash":     key_hash,     # → goes to server
    }

#  KEY RECOVERY WITH BER — LOGIN (verification)

def login_attempt(
        probe_emb:    np.ndarray,
        enr_bitvec:   np.ndarray,
        enr_nonce:    np.ndarray,
        enr_helper:   np.ndarray,   # ← from server (enrollee's only)
        enr_key_hash: str,          # ← from server (enrollee's only)
        proto_ldpc:   "Proto_LDPC",
        scale:        int,          # *** CHANGED: accept scale parameter ***
) -> Dict:
    """
    LOGIN step — called for each probe video against a registered enrollee.

    The probe contributes ONLY its face embedding.
    All cryptographic material (nonce, helper, key_hash, bitvec) belongs
    exclusively to the registered enrollee.

    BV  = raw Hamming distance before nonce masking
    BVN = Hamming distance after nonce masking (what the decoder sees)
    """
    # Quantize probe using the SAME fixed scale/clip/Gray pipeline as enrollment
    probe_bv = _quantize_probe(probe_emb, scale=scale)  # *** CHANGED: pass scale ***

    # BV — raw, before nonce masking
    bv_h   = int(np.sum(probe_bv != enr_bitvec))
    bv_ber = bv_h / BITVEC_LEN * 100.0

    # BVN — after applying ENROLLEE's nonce
    probe_bvn = np.bitwise_and(probe_bv.astype(np.uint8), enr_nonce)
    enr_bvn   = np.bitwise_and(enr_bitvec.astype(np.uint8), enr_nonce)
    bvn_h   = int(np.sum(probe_bvn != enr_bvn))
    bvn_ber = bvn_h / BITVEC_LEN * 100.0

    # LDPC fuzzy decoding using ENROLLEE's helper (from server)
    received = np.bitwise_xor(
        probe_bvn[:LDPC_CODE_N].astype(np.uint8),
        enr_helper.astype(np.uint8)
    )
    pre_synd = int(np.sum(proto_ldpc.encode_LDPC(received[:LDPC_CODE_K]) != received))

    decoded   = neural_minsum_decode(received, proto_ldpc, n_iters=BP_ITERS)
    cand_msg  = decoded[:LDPC_CODE_K].copy()
    cand_cw   = proto_ldpc.encode_LDPC(cand_msg)
    post_synd = int(np.sum(cand_cw != decoded))
    cw_ber    = post_synd / LDPC_CODE_N * 100.0

    # Compare recovered hash with enrolled hash (from server)
    recovered_hash = hashlib.sha256(np.packbits(cand_msg).tobytes()).hexdigest()
    hash_match     = (recovered_hash == enr_key_hash)
    decision       = "ACCEPT" if (hash_match and post_synd == 0) else "REJECT"

    return {
        "bv_hamming":       bv_h,
        "bv_ber_pct":       bv_ber,
        "bvn_hamming":      bvn_h,
        "bvn_ber_pct":      bvn_ber,
        "pre_decode_synd":  pre_synd,
        "syndrome_errors":  post_synd,
        "ber_codeword_pct": cw_ber,
        "recovered_hash":   recovered_hash,
        "hash_match":       hash_match,
        "decision":         decision,
    }
#  REGISTRATION + LOGIN PIPELINE FOR ONE ENROLLEE

def run_enrollee(
        enrollee_vid:   str,
        all_embeddings: Dict[str, Optional[np.ndarray]],
        proto_ldpc:     "Proto_LDPC",
        scale:          int,        # *** CHANGED: accept scale parameter ***
) -> Dict:
    """
    Simulates the full registration + login flow for one registered user.

    REGISTRATION:
      1. Scale enrollee's L2-normalised embedding by ×scale, clip to [-1,+1],
         quantize to 3-bit Gray code → bitvec (1536 bits).
      2. Nonce = all-ones (look4noncerate is DISABLED).
      3. Build helper data and key hash.  Store on server.

    LOGIN:
      For every OTHER video (probe):
        - Apply identical scale/clip/quant to probe embedding.
        - Use ONLY the registered enrollee's helper data and key hash
          (fetched from server) to attempt key recovery.
        - The probe contributes nothing except its face embedding.
        - The enrollee is never tested against itself.
    """
    SEP  = "=" * 90
    SEP2 = "-" * 90

    enr_name     = ALL_VIDEO_DISPLAY_NAMES[enrollee_vid]
    enr_identity = ALL_IDENTITY_MAP[enrollee_vid]
    enr_emb      = all_embeddings.get(enrollee_vid)

    lines: List[str] = []

    def out(s=""):
        print(s)
        lines.append(s)

    out(f"\n{SEP}")
    out(f"  REGISTERED USER : {enr_name}  ({enr_identity})  [scale=×{scale}]")
    out(SEP)

    if enr_emb is None:
        out(f"  ERROR: Embedding for {enr_name} is None. Skipping.")
        return {
            "enrollee": enrollee_vid, "lines": lines, "results": {},
            "genuine_total": 0, "correct_accepts": 0, "false_rejects": 0,
            "impostor_total": 0, "correct_rejects": 0, "false_accepts": 0,
            "far": 0.0, "frr": 0.0, "n_kept": 0,
        }

    # REGISTRATION 
    out(f"\n  REGISTRATION ")
    out(f"  Pipeline: L2-unit → ×{scale} → clip[-1,+1] → "
        f"{QUANT_BITS}-bit Gray quant → {BITVEC_LEN} bits")

    # Phase 3: scale × N, clip [-1,+1], 3-bit Gray-code quantization
    bitvec_enr = embedding_to_bitvec(enr_emb, scale=scale, bits=QUANT_BITS)  # *** CHANGED: pass scale ***
    out(f"  bitvec sum={bitvec_enr.sum()}  density={bitvec_enr.mean():.4f}")

    # Nonce = all-ones (look4noncerate DISABLED)
    enr_nonce = np.ones(BITVEC_LEN, dtype=np.uint8)
    n_kept    = int(enr_nonce.sum())
    out(f"\n  [look4noncerate] DISABLED — nonce = all-ones "
        f"({n_kept}/{BITVEC_LEN} bits kept, 0 masked)")

    # Build helper data and key hash — these go to the server.
    reg = register(bitvec_enr, enr_nonce, proto_ldpc)
    enr_helper   = reg["helper"]    # stored on server
    enr_key_hash = reg["key_hash"]  # stored on server

    out(f"\n  [Phase 4] Registration complete. Stored on server:")
    out(f"    key_hash = {enr_key_hash}")
    out(f"    helper   sum={enr_helper.sum()}  density={enr_helper.mean():.4f}")
    out(f"    bitvec_nonce sum={reg['bitvec_nonce'].sum()}  "
        f"density={reg['bitvec_nonce'].mean():.4f}")
    out(f"\n  NOTE: helper + key_hash are FIXED. They never change between logins.")

    #  LOGIN 
    out(f"\n   LOGIN ATTEMPTS ")
    out(f"  Each probe uses ONLY {enr_name}'s helper data from the server.")
    out(f"  Enrollee {enrollee_vid} ({enr_name}) is excluded — no self-test.")
    out(f"\n{SEP2}")
    out(f"  {'Video':<22}  {'Identity':<10}  {'Type':<8}  "
        f"{'BV-Hamm':>8}  {'BV-BER%':>7}  "
        f"{'BVN-Hamm':>9}  {'BVN-BER%':>8}  "
        f"{'PreSynd':>7}  {'PostSynd':>8}  {'CW-BER%':>7}  "
        f"{'HashMatch':>9}  {'DECISION':<8}")
    out(f"  {'─'*22}  {'─'*10}  {'─'*8}  "
        f"{'─'*8}  {'─'*7}  "
        f"{'─'*9}  {'─'*8}  "
        f"{'─'*7}  {'─'*8}  {'─'*7}  {'─'*9}  {'─'*8}")

    login_results: Dict[str, Dict] = {}
    correct_accepts = 0; correct_rejects = 0
    false_rejects   = 0; false_accepts   = 0
    genuine_total   = 0; impostor_total  = 0

    for vid in ALL_VIDEO_PATHS:

        # Enrollee never tests against itself
        if vid == enrollee_vid:
            out(f"  {ALL_VIDEO_DISPLAY_NAMES[vid]:<22}  "
                f"[REGISTERED USER — skipped, no self-test]")
            continue

        probe_emb = all_embeddings.get(vid)
        if probe_emb is None:
            out(f"  {ALL_VIDEO_DISPLAY_NAMES[vid]:<22}  SKIPPED (embedding failed)")
            continue

        is_genuine = (ALL_IDENTITY_MAP[vid] == enr_identity)
        kind       = "GENUINE " if is_genuine else "IMPOSTOR"

        # LOGIN: probe uses ONLY the registered enrollee's server data
        r = login_attempt(
            probe_emb    = probe_emb,
            enr_bitvec   = bitvec_enr,    # enrollee's own bitvec
            enr_nonce    = enr_nonce,     # all-ones (look4noncerate disabled)
            enr_helper   = enr_helper,    # from server — enrollee's only
            enr_key_hash = enr_key_hash,  # from server — enrollee's only
            proto_ldpc   = proto_ldpc,
            scale        = scale,         # *** CHANGED: pass scale ***
        )
        login_results[vid] = r
        hm_str = "YES" if r["hash_match"] else "NO"

        out(f"  {ALL_VIDEO_DISPLAY_NAMES[vid]:<22}  "
            f"{ALL_IDENTITY_MAP[vid]:<10}  {kind:<8}  "
            f"{r['bv_hamming']:>8}  {r['bv_ber_pct']:>6.2f}%  "
            f"{r['bvn_hamming']:>9}  {r['bvn_ber_pct']:>7.2f}%  "
            f"{r['pre_decode_synd']:>7}  {r['syndrome_errors']:>8}  "
            f"{r['ber_codeword_pct']:>6.2f}%  {hm_str:>9}  {r['decision']:<8}")

        if is_genuine:
            genuine_total += 1
            if r["decision"] == "ACCEPT": correct_accepts += 1
            else:                          false_rejects   += 1
        else:
            impostor_total += 1
            if r["decision"] == "REJECT": correct_rejects += 1
            else:                          false_accepts   += 1

    # Detailed hash comparison
    out(f"\n{SEP2}")
    out(f"  DETAILED HASH COMPARISON")
    out(f"  Registered hash (server) : {enr_key_hash}")
    out(SEP2)
    for vid, r in login_results.items():
        is_genuine = (ALL_IDENTITY_MAP[vid] == enr_identity)
        kind       = "GENUINE " if is_genuine else "IMPOSTOR"
        match_sym  = "MATCH " if r["hash_match"] else "DIFFER"
        out(f"  [{vid}] {ALL_VIDEO_DISPLAY_NAMES[vid]:<22} [{kind}]  "
            f"PreSynd={r['pre_decode_synd']:>3}  "
            f"PostSynd={r['syndrome_errors']:>3}  "
            f"Hash:{match_sym}  -> {r['decision']}")
        if not r["hash_match"]:
            out(f"       Recovered : {r['recovered_hash'][:44]}...")

    # Summary
    far = false_accepts / max(impostor_total, 1) * 100.0
    frr = false_rejects / max(genuine_total,  1) * 100.0

    out(f"\n{SEP}")
    out(f"  SUMMARY — Registered user: {enr_name}  ({enr_identity})  [scale=×{scale}]")
    out(SEP)
    out(f"  Quantization               : scale=×{scale}  clip[-1,+1]  {QUANT_BITS}-bit Gray")
    out(f"  look4noncerate             : DISABLED (nonce = all-ones)")
    out(f"  Bits kept by nonce         : {n_kept}/{BITVEC_LEN}  (100% — no masking)")
    out(f"  Genuine  login attempts : {genuine_total}  (excludes registered user)")
    out(f"    Correct ACCEPT        : {correct_accepts}")
    out(f"    False   REJECT        : {false_rejects}")
    out(f"  Impostor login attempts : {impostor_total}")
    out(f"    Correct REJECT        : {correct_rejects}")
    out(f"    False   ACCEPT        : {false_accepts}")
    out(f"  FAR : {far:.1f}%   FRR : {frr:.1f}%")

    if false_accepts == 0 and false_rejects == 0:
        out("  RESULT: PERFECT SEPARATION")
    elif false_rejects > 0 and false_accepts == 0:
        out(f"  RESULT: {false_rejects} FALSE REJECT(s)  — security intact (FAR=0%)")
    elif false_accepts > 0:
        out(f"  RESULT: {false_accepts} FALSE ACCEPT(s)  — SECURITY BREACH")
    out(SEP)

    return {
        "enrollee":        enrollee_vid,
        "n_kept":          n_kept,
        "genuine_total":   genuine_total,
        "correct_accepts": correct_accepts,
        "false_rejects":   false_rejects,
        "impostor_total":  impostor_total,
        "correct_rejects": correct_rejects,
        "false_accepts":   false_accepts,
        "far":             far,
        "frr":             frr,
        "lines":           lines,
        "results":         login_results,
    }

#  MAIN
def main():
    for path, label in [
        (str(ALL_VIDEO_PATHS["V1"]), "V1 video"),
        (ADAFACE_WEIGHTS,            "AdaFace weights"),
        (RETINAFACE_WEIGHTS,         "RetinaFace weights"),
        (BG0_PATH,                   "BaseGraph2_Set0"),
        (GM16_PATH,                  "LDPC_GM_BG2_16"),
    ]:
        if not Path(path).exists():
            raise FileNotFoundError(f"{label} not found: {path}")

    learned_weights_present = (
        WEIGHTS_DIR.exists() and BIASES_DIR.exists() and
        (WEIGHTS_DIR / "Weights_Var0.txt").exists() and
        (BIASES_DIR  / "Biases_Var0.txt").exists()
    )

    SEP  = "=" * 90
    SEP2 = "-" * 90

    print("\n" + SEP)
    print("  BIOMETRIC KEY GENERATION PIPELINE")
    print(f"  WiFaKey Parameters: N={LDPC_N}, m={LDPC_M}, Z={LDPC_Z}, BP_iters={BP_ITERS}")
    print(f"  Phase 3 Quantization: scales={QUANT_SCALES}  clip[-1,+1]  {QUANT_BITS}-bit Gray code")
    print(f"  BITVEC_LEN = {EMB_DIM} dims × {QUANT_BITS} bits = {BITVEC_LEN} bits")
    print(f"  look4noncerate             : DISABLED (nonce = all-ones always)")
    print(f"  Total videos: {len(ALL_VIDEO_PATHS)}")
    print(SEP)
    print("  REAL-WORLD MODEL (phone registration / login):")
    print(f"    REGISTRATION: Enrollee registers once. L2-normalised embedding scaled ×N,")
    print(f"      clipped [-1,+1], quantized to {QUANT_BITS}-bit Gray code → bitvec.")
    print("      Nonce = all-ones. Stores helper + key_hash on server.")
    print("      Nothing from other videos touches the key.")
    print("    LOGIN: Probe embedding processed with identical scale/clip/quant.")
    print("      Probe contributes only its face embedding. Enrollee's helper data")
    print("      is used unchanged. No master helper. No per-probe nonce rebuild.")
    print("    NO SELF-TEST: Enrollee never tested against its own registration.")
    print(SEP)
    if learned_weights_present:
        print("  [BP decoder] Learned Neural Min-Sum weights FOUND — full decoder active.")
    else:
        print("  [BP decoder] WARNING: No learned weights — using init values (w=0.8, b=0.15).")

    # Load models
    print("\n[INIT] Loading models...")
    adaface  = AdaFaceModel(ADAFACE_WEIGHTS)
    detector = RetinaFaceDetector(RETINAFACE_WEIGHTS)

    # Phase 1+2: Embed ALL videos  (done ONCE — embeddings are scale-independent)
    print(f"\n{SEP}")
    print("  PHASE 1 + 2  |  Face Detection -> Embedding -> L2 Renormalisation")
    print(SEP)

    all_embeddings: Dict[str, Optional[np.ndarray]] = {}
    for vid, vpath in ALL_VIDEO_PATHS.items():
        print(f"\n  [{vid}] {ALL_VIDEO_DISPLAY_NAMES[vid]} <- {Path(vpath).name}")
        emb = embed_video(vpath, adaface, detector, show_resize=True)
        all_embeddings[vid] = emb
        if emb is not None:
            print(f"  [{vid}] OK  norm={np.linalg.norm(emb):.6f}  "
                  f"mean={emb.mean():.4f}  std={emb.std():.4f}")
        else:
            print(f"  [{vid}] FAILED — will be skipped")

    succeeded = [v for v in ALL_VIDEO_PATHS if all_embeddings.get(v) is not None]
    failed    = [v for v in ALL_VIDEO_PATHS if all_embeddings.get(v) is None]
    print(f"\n{SEP}")
    print(f"  Embeddings OK    : {len(succeeded)}/{len(ALL_VIDEO_PATHS)}  {succeeded}")
    if failed:
        print(f"  Embeddings FAILED: {failed}")
    print(SEP)

    # Phase 3+4+5  — run independently for each scale
    proto_ldpc = Proto_LDPC(N=LDPC_N, m=LDPC_M, Z=LDPC_Z)

    # Accumulate all output lines for the results file
    all_result_lines: List[str] = []

    # Results file header
    all_result_lines.append("=" * 90)
    all_result_lines.append("  BIOMETRIC KEY GENERATION PIPELINE — FULL RESULTS")
    all_result_lines.append(f"  WiFaKey: N={LDPC_N}, m={LDPC_M}, Z={LDPC_Z}, BP_iters={BP_ITERS}")
    all_result_lines.append(f"  Phase 3: scales={QUANT_SCALES}  clip[-1,+1]  {QUANT_BITS}-bit Gray code")
    all_result_lines.append(f"  BITVEC_LEN = {BITVEC_LEN} bits")
    all_result_lines.append(f"  look4noncerate : DISABLED (nonce = all-ones)")
    all_result_lines.append("=" * 90)
    all_result_lines.append("")
    all_result_lines.append("  REAL-WORLD MODEL:")
    all_result_lines.append("    REGISTRATION: Each video registers once with its OWN helper data.")
    all_result_lines.append(f"      L2-norm embedding → ×scale → clip[-1,+1] → {QUANT_BITS}-bit Gray → bitvec.")
    all_result_lines.append("      Nonce = all-ones (look4noncerate DISABLED).")
    all_result_lines.append("      Helper data and key_hash stored on server. Never rebuilt.")
    all_result_lines.append("    LOGIN: Probe processed with identical scale/clip/quant.")
    all_result_lines.append("      Probe contributes only its face embedding.")
    all_result_lines.append("      NO master helper data. NO per-probe nonce rebuild.")
    all_result_lines.append("      Registered user never tested against itself (no self-test).")
    all_result_lines.append("")
    all_result_lines.append("  VIDEO REGISTRY:")
    for vid in ALL_VIDEO_PATHS:
        all_result_lines.append(
            f"    {vid:<4}  {ALL_VIDEO_DISPLAY_NAMES[vid]:<22}  "
            f"identity={ALL_IDENTITY_MAP[vid]}"
        )
    all_result_lines.append("")

    # *** CHANGED: outer loop over scales ***
    for scale in QUANT_SCALES:
        scale_header = f"  SCALE ×{scale} RESULTS"
        print(f"\n{'='*90}")
        print(scale_header)
        print(f"{'='*90}")

        all_result_lines.append("")
        all_result_lines.append("=" * 90)
        all_result_lines.append(scale_header)
        all_result_lines.append("=" * 90)
        all_result_lines.append("")

        summary_rows: List[Dict] = []

        for enrollee_vid in ALL_ENROLLEES:
            if all_embeddings.get(enrollee_vid) is None:
                print(f"\n  SKIPPING {enrollee_vid} — embedding unavailable.")
                continue

            result = run_enrollee(
                enrollee_vid   = enrollee_vid,
                all_embeddings = all_embeddings,
                proto_ldpc     = proto_ldpc,
                scale          = scale,   # *** CHANGED: pass scale ***
            )

            all_result_lines.extend(result["lines"])
            all_result_lines.append("")

            summary_rows.append({
                "vid":             enrollee_vid,
                "name":            ALL_VIDEO_DISPLAY_NAMES[enrollee_vid],
                "identity":        ALL_IDENTITY_MAP[enrollee_vid],
                "n_kept":          result.get("n_kept", 0),
                "genuine_total":   result.get("genuine_total", 0),
                "correct_accepts": result.get("correct_accepts", 0),
                "false_rejects":   result.get("false_rejects", 0),
                "impostor_total":  result.get("impostor_total", 0),
                "correct_rejects": result.get("correct_rejects", 0),
                "false_accepts":   result.get("false_accepts", 0),
                "far":             result.get("far", 0.0),
                "frr":             result.get("frr", 0.0),
            })

        # Summary table for this scale
        summary_lines: List[str] = []
        summary_lines.append("")
        summary_lines.append("=" * 90)
        summary_lines.append(f"  OVERALL SUMMARY — ALL REGISTERED USERS  [scale=×{scale}]")
        summary_lines.append("=" * 90)
        summary_lines.append(
            f"  {'Registered User':<22}  {'Identity':<10}  {'NKept':>6}  "
            f"{'GA':>4}  {'FR':>4}  {'CR':>4}  {'FA':>4}  "
            f"{'FAR%':>6}  {'FRR%':>6}  {'Result':<22}"
        )
        summary_lines.append(
            f"  {'─'*22}  {'─'*10}  {'─'*6}  "
            f"{'─'*4}  {'─'*4}  {'─'*4}  {'─'*4}  "
            f"{'─'*6}  {'─'*6}  {'─'*22}"
        )
        for row in summary_rows:
            if row["false_accepts"] == 0 and row["false_rejects"] == 0:
                result_str = "PERFECT SEPARATION"
            elif row["false_rejects"] > 0 and row["false_accepts"] == 0:
                result_str = f"{row['false_rejects']} FALSE REJECT(s)"
            else:
                result_str = f"{row['false_accepts']} FALSE ACCEPT(s)"
            summary_lines.append(
                f"  {row['name']:<22}  {row['identity']:<10}  {row['n_kept']:>6}  "
                f"{row['correct_accepts']:>4}  {row['false_rejects']:>4}  "
                f"{row['correct_rejects']:>4}  {row['false_accepts']:>4}  "
                f"{row['far']:>5.1f}%  {row['frr']:>5.1f}%  {result_str:<22}"
            )
        summary_lines.append("")
        summary_lines.append(
            "  NKept = nonce bits kept (always = BITVEC_LEN, look4noncerate disabled)  |  "
            "GA=Correct Accepts  FR=False Rejects  CR=Correct Rejects  FA=False Accepts"
        )
        summary_lines.append("=" * 90)

        for sl in summary_lines:
            print(sl)

        all_result_lines.extend(summary_lines)

    # Save ALL scale results to a single file
    results_path = Path("results.txt")
    with open(results_path, "w", encoding="utf-8") as f:
        f.write("\n".join(all_result_lines))
        f.write("\n")

    print(f"\n  All results saved to: {results_path.resolve()}")
    print("=" * 90)


if __name__ == "__main__":
    main()
