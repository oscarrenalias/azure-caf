FROM python:3.13-slim
COPY --from=ghcr.io/astral-sh/uv:latest /uv /usr/local/bin/uv
WORKDIR /app
COPY . .
RUN uv sync --frozen --no-dev
EXPOSE 8000
CMD ["uv", "run", "chainlit", "run", "app.py", "--host", "0.0.0.0", "--port", "8000"]
