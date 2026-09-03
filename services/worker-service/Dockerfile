FROM python:3.12-slim

WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir temporalio==1.18.2 httpx==0.28.1

COPY activities.py workflows.py worker.py ./

CMD ["python", "worker.py"]
