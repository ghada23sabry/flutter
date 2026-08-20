FROM python:3.14-slim

WORKDIR /app

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1

COPY pyproject.toml ./
COPY app ./app
COPY migrations ./migrations
COPY alembic.ini ./
COPY entrypoint.sh ./

RUN pip install --no-cache-dir . \
    && chmod +x entrypoint.sh

EXPOSE 8000

CMD ["./entrypoint.sh"]
