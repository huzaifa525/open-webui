# syntax=docker/dockerfile:1

# Define base arguments
ARG USE_EMBEDDING_MODEL=sentence-transformers/all-MiniLM-L6-v2
ARG USE_TIKTOKEN_ENCODING_NAME="cl100k_base"
ARG BUILD_HASH=dev-build
ARG UID=0
ARG GID=0

######## WebUI Frontend Build ########
FROM --platform=$BUILDPLATFORM node:22-alpine3.20 AS build
ARG BUILD_HASH

WORKDIR /app

# Install dependencies with clean npm state
RUN npm cache clean --force

# Copy package files first for better caching
COPY package*.json ./
RUN npm ci --prefer-offline --no-audit --legacy-peer-deps

# Copy source files and build frontend
COPY . .
ENV NODE_OPTIONS="--max-old-space-size=2048"
RUN npm run build

######## Backend Build ########
FROM python:3.11-slim-bookworm AS base

# Set environment variables
ENV ENV=prod \
    PORT=8080 \
    OLLAMA_BASE_URL="/ollama" \
    OPENAI_API_BASE_URL="" \
    OPENAI_API_KEY="" \
    WEBUI_SECRET_KEY="" \
    SCARF_NO_ANALYTICS=true \
    DO_NOT_TRACK=true \
    ANONYMIZED_TELEMETRY=false \
    WHISPER_MODEL="base" \
    WHISPER_MODEL_DIR="/app/backend/data/cache/whisper/models" \
    RAG_EMBEDDING_MODEL="$USE_EMBEDDING_MODEL" \
    SENTENCE_TRANSFORMERS_HOME="/app/backend/data/cache/embedding/models" \
    TIKTOKEN_ENCODING_NAME="cl100k_base" \
    TIKTOKEN_CACHE_DIR="/app/backend/data/cache/tiktoken" \
    HF_HOME="/app/backend/data/cache/embedding/models"

WORKDIR /app/backend

# Install system dependencies
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
    git \
    build-essential \
    pandoc \
    netcat-openbsd \
    curl \
    jq \
    gcc \
    python3-dev \
    ffmpeg \
    libsm6 \
    libxext6 && \
    rm -rf /var/lib/apt/lists/*

# Copy and install Python dependencies
COPY --chown=$UID:$GID ./backend/requirements.txt ./requirements.txt

# Install pip packages optimized for CPU
RUN pip3 install uv && \
    pip3 install torch torchvision torchaudio --index-url https://download.pytorch.org/whl/cpu --no-cache-dir && \
    uv pip install --system -r requirements.txt --no-cache-dir && \
    python -c "import os; from sentence_transformers import SentenceTransformer; SentenceTransformer(os.environ['RAG_EMBEDDING_MODEL'], device='cpu')" && \
    python -c "import os; from faster_whisper import WhisperModel; WhisperModel(os.environ['WHISPER_MODEL'], device='cpu', compute_type='int8', download_root=os.environ['WHISPER_MODEL_DIR'])" && \
    python -c "import os; import tiktoken; tiktoken.get_encoding(os.environ['TIKTOKEN_ENCODING_NAME'])"

# Copy built frontend and backend files
COPY --from=build /app/build /app/build
COPY --chown=$UID:$GID ./backend .

EXPOSE 8080

CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8080"]
