FROM python:3.13-slim
COPY . /app
RUN pip install -r /app/requirements.txt
CMD ["opentelemetry-instrument", "uvicorn", "app:app"]
