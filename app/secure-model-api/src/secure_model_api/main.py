from __future__ import annotations

import logging
import math
import os
from contextlib import asynccontextmanager
from typing import Any

from fastapi import FastAPI, HTTPException
from pydantic import BaseModel, Field, field_validator

from secure_model_api.runtime import (
    ModelRuntime,
    ModelRuntimeError,
)


logging.basicConfig(
    level=os.getenv("LOG_LEVEL", "INFO"),
    format=(
        "%(asctime)s %(levelname)s "
        "%(name)s %(message)s"
    ),
)

logger = logging.getLogger("secure-model-api")
model_runtime = ModelRuntime.from_environment()


@asynccontextmanager
async def lifespan(app: FastAPI):
    try:
        model = model_runtime.load()
    except ModelRuntimeError:
        logger.exception("Model startup validation failed.")
        raise

    app.state.model_runtime = model_runtime

    logger.info(
        "Model ready: name=%s version=%s",
        model["name"],
        model["version"],
    )

    try:
        yield
    finally:
        model_runtime.cleanup()
        logger.info("Decrypted model cleanup completed.")


app = FastAPI(
    title="Secure Model API",
    version="0.1.0",
    lifespan=lifespan,
)


class PredictionRequest(BaseModel):
    features: list[float] = Field(
        min_length=1,
        max_length=128,
    )

    @field_validator("features")
    @classmethod
    def validate_features(
        cls,
        values: list[float],
    ) -> list[float]:
        if any(
            not math.isfinite(value) or abs(value) > 100
            for value in values
        ):
            raise ValueError(
                "Features must be finite values between -100 and 100."
            )

        return values


class PredictionResponse(BaseModel):
    model_version: str
    label: str
    confidence: float
    score: float


@app.get("/health")
def health() -> dict[str, str]:
    return {"status": "healthy"}


@app.get("/ready")
def ready() -> dict[str, Any]:
    if not model_runtime.loaded:
        raise HTTPException(
            status_code=503,
            detail="Model is not ready.",
        )

    return {
        "status": "ready",
        "model_loaded": True,
    }


@app.post(
    "/predict",
    response_model=PredictionResponse,
)
def predict(
    request: PredictionRequest,
) -> dict[str, Any]:
    try:
        return model_runtime.predict(request.features)
    except ModelRuntimeError as exc:
        raise HTTPException(
            status_code=422,
            detail=str(exc),
        ) from exc