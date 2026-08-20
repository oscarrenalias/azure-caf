# Build context: app/  (one level up from this file)
# docker build -f agent/Dockerfile -t rag-agent .

FROM python:3.12-slim

COPY --from=ghcr.io/astral-sh/uv:latest /uv /usr/local/bin/uv

WORKDIR /app

# Install only agent dependencies (cached before source copy)
COPY pyproject.toml uv.lock ./
RUN uv sync --frozen --no-dev --extra agent

COPY agent/ ./agent/

EXPOSE 8088

CMD ["uv", "run", "python", "agent/main.py"]
