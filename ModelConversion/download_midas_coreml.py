#!/usr/bin/env python3
"""
Download and convert MiDaS v2.1 Small to CoreML for depth estimation.

MiDaS v2.1 Small is a lightweight monocular depth prediction model that
produces relative inverse depth maps from single RGB images.

Usage:
    pip install -r requirements.txt
    python download_midas_coreml.py

Output:
    ../BlindNav/Resources/CoreMLModels/MiDaSv2Small.mlpackage
"""

import os
import sys
import logging

import torch
import coremltools as ct

logging.basicConfig(level=logging.INFO, format="%(asctime)s [%(levelname)s] %(message)s")
logger = logging.getLogger(__name__)

INPUT_SIZE = 256


def main():
    output_dir = os.path.join(
        os.path.dirname(__file__),
        "..", "BlindNav", "Resources", "CoreMLModels"
    )
    os.makedirs(output_dir, exist_ok=True)
    target_path = os.path.join(output_dir, "MiDaSv2Small.mlpackage")

    logger.info("Loading MiDaS v2.1 Small from torch.hub...")
    model = torch.hub.load("intel-isl/MiDaS", "MiDaS_small", trust_repo=True)
    model.eval()

    logger.info(f"Tracing model with {INPUT_SIZE}x{INPUT_SIZE} input...")
    dummy = torch.randn(1, 3, INPUT_SIZE, INPUT_SIZE)
    with torch.no_grad():
        traced = torch.jit.trace(model, dummy, check_trace=False)

    logger.info("Converting to CoreML...")
    mlmodel = ct.convert(
        traced,
        inputs=[ct.ImageType(
            name="image",
            shape=(1, 3, INPUT_SIZE, INPUT_SIZE),
            scale=1.0 / 255.0,
            color_layout=ct.colorlayout.RGB,
        )],
        outputs=[ct.TensorType(name="depth_map")],
        compute_precision=ct.precision.FLOAT16,
        minimum_deployment_target=ct.target.iOS16,
    )

    mlmodel.author = "BlindNav (Intel ISL MiDaS v2.1 Small)"
    mlmodel.short_description = (
        "Monocular depth estimation. Input: 256x256 RGB. "
        "Output: relative inverse depth map (higher values = closer objects)."
    )

    mlmodel.save(target_path)
    logger.info(f"Model saved to: {target_path}")
    logger.info("MiDaS CoreML export complete.")


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
