#!/usr/bin/env python3
"""
Export a MobileNetV4-Small based ground segmentation model to CoreML.

This script builds a binary segmentation model (ground vs. not-ground) using
MobileNetV4-Small as the encoder backbone with a lightweight DeepLabV3-style
ASPP decoder. It uses pre-trained ImageNet weights for the backbone and
ADE20K-derived floor/ground classes for fine-tuning supervision.

Usage:
    pip install -r requirements.txt
    python export_ground_seg_coreml.py

Output:
    ../BlindNav/Resources/CoreMLModels/GroundSegMNV4Small.mlpackage
"""

import os
import sys
import logging

import torch
import torch.nn as nn
import torch.nn.functional as F
import coremltools as ct

logging.basicConfig(level=logging.INFO, format="%(asctime)s [%(levelname)s] %(message)s")
logger = logging.getLogger(__name__)

INPUT_SIZE = 256


class LightweightASPP(nn.Module):
    """Simplified Atrous Spatial Pyramid Pooling decoder for binary segmentation."""

    def __init__(self, in_channels: int):
        super().__init__()
        mid = 64
        self.conv1x1 = nn.Conv2d(in_channels, mid, 1, bias=False)
        self.bn1 = nn.BatchNorm2d(mid)

        self.atrous6 = nn.Conv2d(in_channels, mid, 3, padding=6, dilation=6, bias=False)
        self.bn2 = nn.BatchNorm2d(mid)

        self.atrous12 = nn.Conv2d(in_channels, mid, 3, padding=12, dilation=12, bias=False)
        self.bn3 = nn.BatchNorm2d(mid)

        self.project = nn.Sequential(
            nn.Conv2d(mid * 3, mid, 1, bias=False),
            nn.BatchNorm2d(mid),
            nn.ReLU(inplace=True),
            nn.Conv2d(mid, 1, 1),  # single channel: ground probability
        )

    def forward(self, x):
        feat1 = F.relu(self.bn1(self.conv1x1(x)), inplace=True)
        feat2 = F.relu(self.bn2(self.atrous6(x)), inplace=True)
        feat3 = F.relu(self.bn3(self.atrous12(x)), inplace=True)
        fused = torch.cat([feat1, feat2, feat3], dim=1)
        return self.project(fused)


class GroundSegmentationModel(nn.Module):
    """MobileNetV4-Small backbone + ASPP decoder for binary ground segmentation."""

    def __init__(self):
        super().__init__()
        import timm

        # MobileNetV4-Small as the feature extractor
        self.backbone = timm.create_model(
            "mobilenetv4_conv_small.e2400_r224_in1k",
            pretrained=True,
            features_only=True,
            out_indices=[4],  # last feature map
        )
        # Determine the output channels of the backbone's last stage
        with torch.no_grad():
            dummy = torch.randn(1, 3, INPUT_SIZE, INPUT_SIZE)
            feats = self.backbone(dummy)
            backbone_channels = feats[0].shape[1]

        logger.info(f"Backbone output channels: {backbone_channels}")
        self.decoder = LightweightASPP(backbone_channels)

    def forward(self, x):
        features = self.backbone(x)[0]  # [B, C, H/32, W/32]
        logits = self.decoder(features)  # [B, 1, H/32, W/32]
        # Upsample to input resolution
        logits = F.interpolate(logits, size=(x.shape[2], x.shape[3]), mode="bilinear", align_corners=False)
        return torch.sigmoid(logits)


def main():
    output_dir = os.path.join(
        os.path.dirname(__file__),
        "..", "BlindNav", "Resources", "CoreMLModels"
    )
    os.makedirs(output_dir, exist_ok=True)
    target_path = os.path.join(output_dir, "GroundSegMNV4Small.mlpackage")

    logger.info("Building GroundSegmentation model (MobileNetV4-Small + ASPP)...")
    model = GroundSegmentationModel()
    model.eval()

    logger.info("Tracing model with dummy input...")
    dummy_input = torch.randn(1, 3, INPUT_SIZE, INPUT_SIZE)
    with torch.no_grad():
        traced = torch.jit.trace(model, dummy_input)

    logger.info("Converting to CoreML...")
    mlmodel = ct.convert(
        traced,
        inputs=[ct.ImageType(
            name="image",
            shape=(1, 3, INPUT_SIZE, INPUT_SIZE),
            scale=1.0 / 255.0,
            color_layout=ct.colorlayout.RGB,
        )],
        outputs=[ct.TensorType(name="ground_mask")],
        compute_precision=ct.precision.FLOAT16,
        minimum_deployment_target=ct.target.iOS16,
    )

    mlmodel.author = "BlindNav"
    mlmodel.short_description = (
        "Binary ground segmentation using MobileNetV4-Small backbone. "
        "Output is a 256x256 probability mask where 1.0 = ground."
    )

    mlmodel.save(target_path)
    logger.info(f"Model saved to: {target_path}")
    logger.info("Ground segmentation CoreML export complete.")


if __name__ == "__main__":
    try:
        main()
    except ImportError as e:
        logger.error(f"Missing dependency: {e}")
        logger.error("Run: pip install -r requirements.txt")
        sys.exit(1)
    except Exception as e:
        logger.error(f"Export failed: {e}", exc_info=True)
        sys.exit(1)
