#!/usr/bin/env python3
"""
Export YOLOE-11S to CoreML format for iOS deployment.

YOLOE is an open-vocabulary detector. We call model.set_classes() before
export to bake text embeddings for indoor-navigation objects into the
CoreML model (the text encoder is not included in the CoreML graph).

Usage:
    pip install -r requirements.txt
    python export_yoloe_coreml.py

Output:
    ../blindpplapp/Resources/YOLOE11S.mlpackage
"""

import logging
import os
import sys

logging.basicConfig(
    level=logging.INFO, format="%(asctime)s [%(levelname)s] %(message)s"
)
logger = logging.getLogger(__name__)

# Indoor-navigation vocabulary: these labels get baked into the CoreML model.
# Add or remove entries as needed, then re-run the export.
NAVIGATION_CLASSES = [
    # Passage & access
    "door",
    "doorway",
    "exit sign",
    "entrance",
    "elevator",
    "escalator",
    "stairs",
    "staircase",
    "bathroom sign",
    # "hallway",
    # "corridor",
    # Fixtures & furniture
    "chair",
    "table",
    "desk",
    "bench",
    "couch",
    "trash can",
    "recycling bin",
    "vending machine",
    "water fountain",
    # Signage & wayfinding
    "sign",
    "room number",
    "restroom sign",
    "fire extinguisher",
    "emergency exit",
    # Accessibility
    "handrail",
    "ramp",
    # Common obstacles
    "person",
    "wheelchair",
    "cart",
    "luggage",
    "pillar",
    "column",
    "wall",
    # Rooms / destinations
    "restroom",
    "bathroom",
    "toilet",
    # Misc useful
    "window",
    "clock",
    "light",
    "plant",
    "potted plant",
]


def main():
    try:
        from ultralytics import YOLOE

        output_dir = os.path.join(
            os.path.dirname(__file__), "..", "blindpplapp", "Resources"
        )
        os.makedirs(output_dir, exist_ok=True)

        logger.info("Loading YOLOE-11S model...")
        model = YOLOE("yoloe-11s-seg.pt")

        logger.info(
            "Setting %d navigation-specific classes...", len(NAVIGATION_CLASSES)
        )
        model.set_classes(NAVIGATION_CLASSES)
        logger.info("Classes: %s", NAVIGATION_CLASSES)

        logger.info("Exporting to CoreML format...")
        # nms=False: NMS is only supported for YOLO26 Detect models, not YOLOE.
        # Post-processing (NMS, confidence filter) is handled in Swift instead.
        # imgsz uses 16:9 aspect ratio to match camera input (1280x720) preventing distortion.
        # 736x414 provides ~32% more pixels than 640x360 for better small object detection.
        model.export(
            format="coreml",
            nms=False,
            imgsz=[736, 414],
        )

        exported_path = "yoloe-11s-seg.mlpackage"
        target_path = os.path.join(output_dir, "YOLOE11S.mlpackage")

        if os.path.exists(exported_path):
            import shutil

            if os.path.exists(target_path):
                shutil.rmtree(target_path)
            shutil.move(exported_path, target_path)
            logger.info(f"Model exported to: {target_path}")
        else:
            logger.error(
                f"Expected export at {exported_path} not found. Check ultralytics output."
            )
            sys.exit(1)

        logger.info(
            "YOLOE CoreML export complete with %d classes.", len(NAVIGATION_CLASSES)
        )

    except ImportError as e:
        logger.error(f"Missing dependency: {e}")
        logger.error("Run: pip install -r requirements.txt")
        sys.exit(1)
    except Exception as e:
        logger.error(f"Export failed: {e}", exc_info=True)
        sys.exit(1)


if __name__ == "__main__":
    main()
