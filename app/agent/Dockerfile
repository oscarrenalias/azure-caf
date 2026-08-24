FROM python:3.13-slim
COPY --from=ghcr.io/astral-sh/uv:latest /uv /usr/local/bin/uv
WORKDIR /app
COPY . user_agent/
WORKDIR /app/user_agent
RUN uv sync --frozen --no-dev
EXPOSE 8088
RUN PYTHONDONTWRITEBYTECODE= python3 -m compileall -q . || true
CMD ["uv", "run", "python", "main.py"]
