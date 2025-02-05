# syntax=docker/dockerfile:1

######## WebUI Frontend Build ########
FROM --platform=$BUILDPLATFORM node:22-alpine3.20 AS build

WORKDIR /app

# Install build dependencies
RUN npm cache clean --force && \
    apk add --no-cache python3 make g++

# Copy package files and install dependencies
COPY package*.json ./
ENV NODE_OPTIONS="--max-old-space-size=6144"
RUN npm ci --prefer-offline --no-audit --legacy-peer-deps

# Copy source and build
COPY . .
RUN npm run pyodide:fetch && npm run build

######## Backend Build ########
FROM python:3.11-slim-bookworm AS base

# Set environment variables
ENV ENV=prod \
    PORT=8080 \
    OLLAMA_BASE_URL="/ollama" \
    WHISPER_MODEL="base" \
    WHISPER_MODEL_DIR="/app/backend/data/cache/whisper/models" \
    RAG_EMBEDDING_MODEL="sentence-transformers/all-MiniLM-L6-v2" \
    SENTENCE_TRANSFORMERS_HOME="/app/backend/data/cache/embedding/models" \
    TIKTOKEN_ENCODING_NAME="cl100k_base" \
    TIKTOKEN_CACHE_DIR="/app/backend/data/cache/tiktoken" \
    HF_HOME="/app/backend/data/cache/embedding/models" \
    PYTHONUNBUFFERED=1

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

# Copy requirements
COPY backend/requirements.txt ./requirements.txt

# Install Python packages in stages
RUN pip install --no-cache-dir wheel setuptools pip uv

# Install PyTorch CPU version
RUN pip install --no-cache-dir torch torchvision torchaudio --index-url https://download.pytorch.org/whl/cpu

# Install dependencies with retry logic in case of transient errors
RUN for i in $(seq 1 3); do \
    uv pip install --system -r requirements.txt --no-cache-dir && break || \
    sleep 5; \
    done

# Pre-download models with retry logic
RUN for i in $(seq 1 3); do \
    python -c "from sentence_transformers import SentenceTransformer; SentenceTransformer('sentence-transformers/all-MiniLM-L6-v2', device='cpu')" && \
    python -c "from faster_whisper import WhisperModel; WhisperModel('base', device='cpu', compute_type='int8')" && \
    python -c "import tiktoken; tiktoken.get_encoding('cl100k_base')" && break || \
    sleep 5; \
    done

# Copy built frontend and backend files
COPY --from=build /app/build /app/build
COPY backend .

EXPOSE 8080

# Start with 2 workers for 2 vCPU system
CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8080", "--workers", "2"]
