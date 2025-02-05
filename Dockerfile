# syntax=docker/dockerfile:1

# Define build arguments
ARG USE_OLLAMA=false
ARG USE_EMBEDDING_MODEL=sentence-transformers/all-MiniLM-L6-v2
ARG USE_RERANKING_MODEL=""
ARG USE_TIKTOKEN_ENCODING_NAME="cl100k_base"
ARG BUILD_HASH=dev-build
ARG UID=0
ARG GID=0

######## WebUI Frontend Build ########
FROM --platform=$BUILDPLATFORM node:22-alpine3.20 AS build
ARG BUILD_HASH

WORKDIR /app

# Copy and install dependencies
COPY package.json package-lock.json ./
RUN npm ci --legacy-peer-deps

# Copy source files and build
COPY . .
ENV NODE_OPTIONS="--max-old-space-size=4096" # Prevents memory crashes
RUN npm run build

######## Backend (CPU-Only) ########
FROM python:3.11-slim-bookworm AS base

ARG USE_OLLAMA
ARG USE_EMBEDDING_MODEL
ARG USE_RERANKING_MODEL
ARG UID
ARG GID

## Environment Variables ##
ENV ENV=prod \
    PORT=8080 \
    USE_OLLAMA_DOCKER=${USE_OLLAMA} \
    USE_EMBEDDING_MODEL_DOCKER=${USE_EMBEDDING_MODEL} \
    USE_RERANKING_MODEL_DOCKER=${USE_RERANKING_MODEL} \
    OLLAMA_BASE_URL="/ollama" \
    OPENAI_API_BASE_URL="" \
    OPENAI_API_KEY="" \
    WEBUI_SECRET_KEY="" \
    SCARF_NO_ANALYTICS=true \
    DO_NOT_TRACK=true \
    ANONYMIZED_TELEMETRY=false \
    WHISPER_MODEL="base" \
    WHISPER_MODEL_DIR="/app/backend/data/cache/whisper/models" \
    RAG_EMBEDDING_MODEL="$USE_EMBEDDING_MODEL_DOCKER" \
    RAG_RERANKING_MODEL="$USE_RERANKING_MODEL_DOCKER" \
    SENTENCE_TRANSFORMERS_HOME="/app/backend/data/cache/embedding/models" \
    TIKTOKEN_ENCODING_NAME="cl100k_base" \
    TIKTOKEN_CACHE_DIR="/app/backend/data/cache/tiktoken" \
    HF_HOME="/app/backend/data/cache/embedding/models"

WORKDIR /app/backend

# Set up non-root user if needed
RUN if [ $UID -ne 0 ]; then \
    if [ $GID -ne 0 ]; then \
    addgroup --gid $GID app; \
    fi; \
    adduser --uid $UID --gid $GID --home /home/app --disabled-password --no-create-home app; \
    fi

# Install system dependencies
RUN apt-get update && \
    apt-get install -y --no-install-recommends git build-essential pandoc netcat-openbsd curl jq \
    gcc python3-dev ffmpeg libsm6 libxext6 && \
    rm -rf /var/lib/apt/lists/*

# Copy Python dependencies and install them
COPY --chown=$UID:$GID ./backend/requirements.txt ./requirements.txt

# Install dependencies for CPU-only (NO CUDA)
RUN pip3 install uv && \
    pip3 install torch torchvision torchaudio --index-url https://download.pytorch.org/whl/cpu --no-cache-dir && \
    uv pip install --system -r requirements.txt --no-cache-dir

# Pre-load models to cache (for faster first-time execution)
RUN python -c "import os; from sentence_transformers import SentenceTransformer; SentenceTransformer(os.environ['RAG_EMBEDDING_MODEL'], device='cpu')" && \
    python -c "import os; from faster_whisper import WhisperModel; WhisperModel(os.environ['WHISPER_MODEL'], device='cpu', compute_type='int8', download_root=os.environ['WHISPER_MODEL_DIR'])" && \
    python -c "import os; import tiktoken; tiktoken.get_encoding(os.environ['TIKTOKEN_ENCODING_NAME'])"

# Set permissions
RUN chown -R $UID:$GID /app

# Copy built frontend
COPY --from=build /app/dist /app/dist

# Set entrypoint
CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8080"]
