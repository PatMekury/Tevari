FROM python:3.11-slim

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    HF_HOME=/models \
    PORT=8080

WORKDIR /app

RUN apt-get update \
    && apt-get install --yes --no-install-recommends espeak-ng \
    && rm -rf /var/lib/apt/lists/*

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# Fetch the Apache-licensed model while the image is built, rather than on a
# user's first Story request.
RUN python -c "from kokoro import KPipeline; KPipeline(lang_code='a')"

COPY app ./app

CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8080"]
