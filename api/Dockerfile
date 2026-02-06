FROM python:3.11-alpine

WORKDIR /app

# Install dependencies (including curl for healthcheck)
RUN apk add --no-cache postgresql-dev gcc musl-dev curl

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY app.py .

EXPOSE 5000

# Use single worker to avoid multiple init threads
CMD ["gunicorn", "--bind", "0.0.0.0:5000", "--workers", "1", "app:app"]
